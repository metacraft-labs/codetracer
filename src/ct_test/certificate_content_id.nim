## Content identifiers for test certificates — computing them, and knowing
## when there is none.
##
## Implements ``test-certificates-spec/Content-Id.md``: the self-describing
## content id a revised certificate carries in ``[certificate.vcs] content``,
## which binds the certificate to the CONTENT of the tracked files rather than
## to a commit. The rules are normative and unforgiving in one particular way:
## a producer and a verifier that compute an id differently never disagree
## loudly, they simply find that nothing matches. So this module is the ONE
## place CodeTracer computes a content id, and every caller — the producer, the
## verifier and the status bar's hosts — is meant to drive this recipe rather
## than restate it.
##
## What is here
## ------------
## * ``parseContentId`` — classify a content id as well-formed in a §4
##   algorithm, well-formed in an algorithm outside §4, or malformed
##   (Content-Id §1). It never repairs one: an uppercase or abbreviated digest
##   is malformed, not "close enough".
## * ``computeContentId`` — the id of a state of a git repository, for one of
##   the three states Content-Id §5 names (a working tree, the index being
##   committed, a commit), whole-repository or scoped, in
##   ``git-tree-sha1`` / ``git-tree-sha256`` (§4.1) or ``manifest-v1-sha256``
##   (§4.2).
## * ``manifestV1Sha256`` — §4.2 over an explicit entry list, for the
##   ``content/`` conformance vectors and for a record some other producer
##   issued in a VCS-independent form. `ct test` never emits it.
## * Detection of the Content-Id §3 states that have NO content id, each
##   returned as a value naming the condition and the paths, never as an id
##   that silently omits what the tests read.
##
## How it reaches git and the filesystem
## -------------------------------------
## Through ``ContentIdHost`` only. This module imports no process and no
## filesystem API, so a host with its own way of running git (a native
## process, Electron's child processes, a facade endpoint) drives exactly this
## recipe. ``certificate_content_id_native.nim`` is the native host.
##
## The host's git runner is not ``certificate_issuance.GitCommandRunner``,
## for three reasons: the recipe needs to add ``GIT_INDEX_FILE`` to git's
## environment, it parses ``write-tree`` and ``ls-tree`` output that must not
## have stderr warnings mixed into it, and that type is defined over the
## native process bridge's ``CapturedRun``, which a non-native host cannot
## import. Importing ``certificate_issuance`` would also put the signing path
## within reach of this module, and nothing here has any business there.
##
## What computing an id writes
## ---------------------------
## Loose blob and tree objects in the repository's object store, and nothing
## else in the repository: no ref, no index, no working-tree file. The user's
## index is copied into a temporary directory the host provides and every
## index operation runs against the copy (Content-Id §4.1 "Producers SHOULD
## compute it in a temporary index, so the user's staging area is neither read
## as the tested state nor modified").

import std/[algorithm, sequtils, strutils]

# ---------------------------------------------------------------------------
# Content ids: form and classification (Content-Id §1)
# ---------------------------------------------------------------------------

type
  ContentAlgorithm* = enum
    ## The algorithms Content-Id §4 defines. The string value is the
    ## identifier as it appears before the ``:`` of a content id, compared by
    ## exact string equality.
    caGitTreeSha1 = "git-tree-sha1"
    caGitTreeSha256 = "git-tree-sha256"
    caManifestV1Sha256 = "manifest-v1-sha256"

  ContentIdForm* = enum
    cifWellFormed
      ## An algorithm in §4 and a lowercase hex digest of exactly its length.
    cifUnknownAlgorithm
      ## Syntactically sound, in an algorithm §4 does not define. NOT
      ## malformed: only the algorithm defines the digest length, and a later
      ## revision may define it. A verifier treats it as an algorithm it
      ## cannot compute (Content-Id §5).
    cifMalformed
      ## Decidably invalid (Verification §4.1.1).

  ParsedContentId* = object
    form*: ContentIdForm
    text*: string
      ## The input, verbatim. Never normalised.
    algorithmName*: string
      ## Everything before the FIRST ``:``; empty when there is none.
    digest*: string
      ## Everything after the first ``:``.
    algorithm*: ContentAlgorithm
      ## Meaningful only when ``form == cifWellFormed``.
    problem*: string
      ## Why the id is malformed; empty otherwise.

const
  DigestLength*: array[ContentAlgorithm, int] = [40, 64, 64]
    ## The digest length, in hex digits, each §4 algorithm defines.

  EmptyManifestDigest* =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ## SHA-256 of the empty string: the ``manifest-v1-sha256`` digest of a
    ## scope holding no entries (Content-Id §4.2).

proc lookupAlgorithm*(name: string): tuple[known: bool; algorithm: ContentAlgorithm] =
  ## The §4 algorithm ``name`` identifies, by exact string equality — so
  ## ``Git-Tree-SHA1`` is an unknown algorithm, not ``git-tree-sha1``.
  for algorithm in ContentAlgorithm:
    if $algorithm == name:
      return (true, algorithm)
  (false, caGitTreeSha1)

proc isLowerHex(text: string): bool =
  for ch in text:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc parseContentId*(text: string): ParsedContentId =
  ## Classify ``text`` per Content-Id §1. The id is split at the FIRST ``:``,
  ## so a second ``:`` lands in the digest and makes it non-hex.
  ##
  ## Nothing is repaired: an uppercase digest is not lowercased, an
  ## abbreviated digest is not matched the way git matches abbreviated object
  ## ids, and a bare digest is not assigned an algorithm. Each of those is a
  ## malformed id, because §1 forbids a verifier to repair one into validity.
  result = ParsedContentId(text: text)
  let colon = text.find(':')
  if colon < 0:
    result.form = cifMalformed
    result.problem = "it has no `:` separating the algorithm from the digest"
    return
  result.algorithmName = text[0 ..< colon]
  result.digest = text[colon + 1 .. ^1]
  if result.algorithmName.len == 0:
    result.form = cifMalformed
    result.problem = "nothing precedes the `:`, so it names no algorithm"
    return
  if result.digest.len == 0:
    result.form = cifMalformed
    result.problem = "the digest after the `:` is empty"
    return
  if not result.digest.isLowerHex():
    result.form = cifMalformed
    result.problem =
      if result.digest.toLowerAscii().isLowerHex():
        "the digest contains uppercase hex digits; a digest is lowercase " &
          "and is never lowercased on a reader's behalf"
      else:
        "the digest contains characters other than `0`-`9` and `a`-`f`"
    return
  let (known, algorithm) = lookupAlgorithm(result.algorithmName)
  if not known:
    # Its digest length cannot be judged: only the algorithm defines it.
    result.form = cifUnknownAlgorithm
    return
  result.algorithm = algorithm
  if result.digest.len != DigestLength[algorithm]:
    result.form = cifMalformed
    result.problem =
      "a " & $algorithm & " digest has exactly " & $DigestLength[algorithm] &
      " hex digits and this one has " & $result.digest.len &
      " (an abbreviated digest is not matched as a prefix)"
    return
  result.form = cifWellFormed

proc formatContentId*(algorithm: ContentAlgorithm; digest: string): string =
  ## ``<algorithm>:<digest>``, the self-describing form of Content-Id §1.
  $algorithm & ":" & digest

# ---------------------------------------------------------------------------
# Outcomes
# ---------------------------------------------------------------------------

type
  NoContentIdCondition* = enum
    ## The Content-Id §3 states that have no honest content id. A producer
    ## MUST NOT issue a certificate in any of them; a status display MUST NOT
    ## read one as a computed id.
    ncUnmergedEntries = "the index has unmerged entries"
    ncAssumeUnchanged = "entries are marked assume-unchanged"
    ncSkipWorktreePresent =
      "entries are marked skip-worktree while their file is present"
    ncSubmoduleModified = "a nested repository has modified content"
    ncUnrepresentablePath = "a path cannot be represented"

  NoContentIdState* = object
    condition*: NoContentIdCondition
    paths*: seq[string]
      ## The repository paths in the condition, sorted and deduplicated.

  ContentIdOutcome* = enum
    cioComputed
      ## ``id`` holds the content id.
    cioNoContentId
      ## The state is one Content-Id §3 says has no content id; ``states``
      ## names each condition found and its paths.
    cioCannotCompute
      ## The algorithm cannot be computed for this state — ``git-tree-sha256``
      ## against a SHA-1 repository, say. Content-Id §5: a verifier reports
      ## that as unverifiable, never as a mismatch.
    cioFailed
      ## The computation itself failed: not a git repository, a revision that
      ## does not exist, an invalid scope, git exiting non-zero. ``reason``
      ## says which. Never converted into an id.

  ContentIdResult* = object
    outcome*: ContentIdOutcome
    id*: string
      ## The full self-describing id; empty unless ``cioComputed``.
    algorithm*: ContentAlgorithm
      ## The algorithm asked for; not meaningful when ``cioFailed``.
    digest*: string
      ## The part of ``id`` after the ``:``.
    states*: seq[NoContentIdState]
      ## Every §3 condition found, when ``cioNoContentId``.
    reason*: string
      ## Empty when computed. Otherwise what prevented an id, in terms an
      ## operator can act on.

proc computed(algorithm: ContentAlgorithm; digest: string): ContentIdResult =
  ContentIdResult(outcome: cioComputed, algorithm: algorithm, digest: digest,
                  id: formatContentId(algorithm, digest))

proc failed(reason: string): ContentIdResult =
  ContentIdResult(outcome: cioFailed, reason: reason)

proc cannotCompute(algorithm: ContentAlgorithm; reason: string): ContentIdResult =
  ContentIdResult(outcome: cioCannotCompute, algorithm: algorithm, reason: reason)

proc noContentId(algorithm: ContentAlgorithm;
                 states: seq[NoContentIdState]): ContentIdResult =
  var parts: seq[string]
  for state in states:
    parts.add $state.condition & " (" & state.paths.join(", ") & ")"
  ContentIdResult(outcome: cioNoContentId, algorithm: algorithm, states: states,
                  reason: "this state has no content id: " & parts.join("; "))

proc sortedUnique(paths: seq[string]): seq[string] =
  result = paths
  result.sort(system.cmp[string])
  result = result.deduplicate(isSorted = true)

# ---------------------------------------------------------------------------
# Scopes (Standard §3.2.1)
# ---------------------------------------------------------------------------

proc scopePathProblem*(path: string): string =
  ## Why ``path`` is not a valid scope path, or "" when it is. Standard
  ## §3.2.1: repo-relative, ``/``-separated, never beginning with ``./`` or
  ## ``/`` and never ending with ``/``. NUL cannot be part of a path at all.
  ## A scope is rejected rather than tidied, for the reason Content-Id §1
  ## forbids repairing an id: a scope means exactly what it says, or nothing.
  if path.len == 0:
    "a scope path is empty"
  elif '\0' in path:
    "a scope path contains NUL"
  elif path.startsWith("/"):
    "scope path `" & path & "` begins with `/`; scope paths are repo-relative"
  elif path.startsWith("./"):
    "scope path `" & path & "` begins with `./`"
  elif path.endsWith("/"):
    "scope path `" & path & "` ends with `/`"
  else:
    ""

proc inScope*(path: string; scope: openArray[string]): bool =
  ## Whether repository path ``path`` is within ``scope``. An empty scope is
  ## the whole repository (Standard §3.2.1: absent and empty mean the same).
  ## A scope path names that file or the subtree beneath it, by whole path
  ## components: ``src/d`` does not contain ``src/db/a.c`` although it is a
  ## string prefix of it.
  if scope.len == 0:
    return true
  for prefix in scope:
    if path == prefix or (path.len > prefix.len and path.startsWith(prefix) and
                          path[prefix.len] == '/'):
      return true
  false

# ---------------------------------------------------------------------------
# manifest-v1-sha256 (Content-Id §4.2)
# ---------------------------------------------------------------------------

type
  ManifestEntry* = object
    ## One tracked path, as Content-Id §4.2 defines an entry.
    path*: string
      ## Repo-relative, ``/``-separated, the byte sequence the VCS records.
    mode*: string
      ## ``100644``, ``100755``, ``120000`` or ``160000``.
    content*: string
      ## The file's bytes, a symlink's target, or — for ``160000`` — the
      ## nested repository's revision id as ASCII.

const ManifestModes = ["100644", "100755", "120000", "160000"]

proc byteOrder(a, b: string): int =
  ## Plain unsigned comparison of raw bytes — the order §4.2 requires. Stated
  ## explicitly rather than left to a library ``cmp`` whose definition is not
  ## this function's contract: ``a.b`` (``2E``) sorts before ``a/b`` (``2F``).
  let common = min(a.len, b.len)
  for i in 0 ..< common:
    let x = uint8(a[i])
    let y = uint8(b[i])
    if x != y:
      return (if x < y: -1 else: 1)
  cmp(a.len, b.len)

# SHA-256 (FIPS 180-4), written out here because no vetted implementation
# compiles for both backends this recipe runs on. The Electron host (Status-Bar
# SB-2a) compiles this module with `nim js`; `nimcrypto`, which the native
# code uses elsewhere, does not compile for JS (its `utils` needs `zeroMem`),
# and the Nim standard library has no SHA-256. The digest only identifies
# public file content (no key, no secret), so a constant-time implementation
# is not required; correctness is, and `certificate_content_id_test.nim`
# checks it against the FIPS 180-4 examples and against the system
# `sha256sum` at every length around the padding boundaries and on large
# random inputs. Replace it if a dependency that serves both backends appears.
# https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf

const Sha256RoundConstants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(x: uint32; n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc sha256Hex*(data: string): string =
  ## Lowercase hex SHA-256 of ``data``'s bytes.
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  # Padding: a 1 bit, zeros to 56 mod 64 bytes, then the bit length as a
  # big-endian 64-bit integer.
  var message = data
  message.add char(0x80)
  while message.len mod 64 != 56:
    message.add char(0)
  let bitLength = uint64(data.len) * 8
  for shift in countdown(56, 0, 8):
    message.add char((bitLength shr shift) and 0xff)
  var w: array[64, uint32]
  for blockStart in countup(0, message.len - 1, 64):
    for t in 0 ..< 16:
      let i = blockStart + t * 4
      w[t] = (uint32(uint8(message[i])) shl 24) or
             (uint32(uint8(message[i + 1])) shl 16) or
             (uint32(uint8(message[i + 2])) shl 8) or
             uint32(uint8(message[i + 3]))
    for t in 16 ..< 64:
      let s0 = rotr(w[t - 15], 7) xor rotr(w[t - 15], 18) xor (w[t - 15] shr 3)
      let s1 = rotr(w[t - 2], 17) xor rotr(w[t - 2], 19) xor (w[t - 2] shr 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for t in 0 ..< 64:
      let bigS1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let choose = (e and f) xor ((not e) and g)
      let temp1 = hh + bigS1 + choose + Sha256RoundConstants[t] + w[t]
      let bigS0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let majority = (a and b) xor (a and c) xor (b and c)
      let temp2 = bigS0 + majority
      hh = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
  result = newStringOfCap(64)
  for word in h:
    result.add toHex(word, 8).toLowerAscii()

proc manifestV1Sha256*(entries: openArray[ManifestEntry];
                       scope: openArray[string] = []): ContentIdResult =
  ## ``manifest-v1-sha256`` over ``entries``, restricted to ``scope`` (empty:
  ## the whole repository). ``entries`` may arrive in any order.
  ##
  ## Each in-scope entry becomes ``<mode> SP <hex(sha256(content))> SP
  ## <path> NUL``; the records are concatenated in ascending byte order of the
  ## FULL path, and the digest is the lowercase hex SHA-256 of that. An empty
  ## scope is the SHA-256 of the empty string.
  ##
  ## A path containing NUL cannot be represented in a record and is a §3
  ## state with no content id, not an input error. Every other defect — an
  ## unknown mode, a path that is not repo-relative, a path listed twice — is
  ## a malformed entry list and fails.
  for prefix in scope:
    let problem = scopePathProblem(prefix)
    if problem.len > 0:
      return failed(problem)
  var selected: seq[ManifestEntry]
  var unrepresentable: seq[string]
  for entry in entries:
    if '\0' in entry.path:
      # Escaped so the reported path is printable; the raw path is the
      # problem being reported.
      if inScope(entry.path, scope):
        unrepresentable.add entry.path.replace("\0", "\\0")
      continue
    if entry.mode notin ManifestModes:
      return failed("entry `" & entry.path & "` has mode `" & entry.mode &
                    "`, which is not one of " & ManifestModes.join(", "))
    if entry.path.len == 0 or entry.path.startsWith("/") or
       entry.path.startsWith("./"):
      return failed("entry path `" & entry.path & "` is not repo-relative")
    if inScope(entry.path, scope):
      selected.add entry
  if unrepresentable.len > 0:
    return noContentId(caManifestV1Sha256, @[NoContentIdState(
      condition: ncUnrepresentablePath, paths: sortedUnique(unrepresentable))])
  selected.sort(proc(a, b: ManifestEntry): int = byteOrder(a.path, b.path))
  var records = ""
  for i, entry in selected:
    if i > 0 and selected[i - 1].path == entry.path:
      return failed("entry path `" & entry.path & "` is listed twice; " &
                    "manifest paths are unique")
    records.add entry.mode
    records.add ' '
    records.add sha256Hex(entry.content)
    records.add ' '
    records.add entry.path
    records.add '\0'
  computed(caManifestV1Sha256, sha256Hex(records))

# ---------------------------------------------------------------------------
# The host: how this module reaches git and the filesystem
# ---------------------------------------------------------------------------

type
  GitCall* = object
    argv*: seq[string]
      ## The command, beginning with ``git``.
    cwd*: string
    env*: seq[(string, string)]
      ## Added to (and overriding) the inherited environment. The inherited
      ## environment is otherwise kept: a pre-commit hook's ``GIT_INDEX_FILE``
      ## is exactly the index being committed (Content-Id §5).

  GitReply* = object
    exitCode*: int
      ## Negative when git could not be launched at all.
    stdout*: string
    stderr*: string
      ## Kept apart from ``stdout``: an object id parsed out of a stream with
      ## a warning interleaved would be wrong, not merely noisy.
    complete*: bool
      ## ``false`` when the output was cut by a capture bound or the call
      ## timed out. Part of a listing, cut at a record boundary, is
      ## indistinguishable from a complete shorter one, so an incomplete reply
      ## is always a failure.

  ContentGitRunner* = proc(call: GitCall): GitReply {.closure, gcsafe.}

  HostFileResult* = object
    ok*: bool
    missing*: bool
      ## ``copyFile`` only: the source does not exist, which is an answer
      ## (a repository with no index), not a failure.
    path*: string
      ## ``makeTempDir`` only: the directory created.
    error*: string

  ContentIdHost* = object
    ## Everything the recipe needs from its host. Temporary files are
    ## injected for the same reason git is: so every host runs this recipe
    ## rather than a copy of it.
    git*: ContentGitRunner
    makeTempDir*: proc(): HostFileResult {.closure, gcsafe.}
      ## A new, empty, private directory OUTSIDE the repository.
    copyFile*: proc(source, destination: string): HostFileResult {.closure, gcsafe.}
    pathExists*: proc(path: string): bool {.closure, gcsafe.}
      ## Whether anything — file, directory or symlink, dangling or not — is
      ## at ``path``.
    removeDir*: proc(path: string) {.closure, gcsafe.}
      ## Remove a directory ``makeTempDir`` created, with its contents.

  ContentStateKind* = enum
    ## The states Content-Id §5 computes an id for.
    cskWorkingTree
      ## The tracked files as they are in the working tree, computed in a
      ## temporary index (§4.1) — what a producer certifies.
    cskIndex
      ## The index being committed — what ``git write-tree`` returns,
      ## honouring the ``GIT_INDEX_FILE`` git sets for ``commit -a`` and
      ## ``commit <paths>``.
    cskCommit
      ## ``<revision>^{tree}``.

  ContentState* = object
    kind*: ContentStateKind
    revision*: string
      ## ``cskCommit`` only.

proc workingTreeState*(): ContentState = ContentState(kind: cskWorkingTree)
proc indexState*(): ContentState = ContentState(kind: cskIndex)
proc commitState*(revision: string): ContentState =
  ContentState(kind: cskCommit, revision: revision)

const
  PathspecEnvironment = @[
    # A caller's environment can change what a pathspec means. Scoped paths
    # are passed with `--literal-pathspecs` (Content-Id §4.1: "Pathspecs MUST
    # be literal"); these make sure no inherited setting fights that flag or
    # makes matching case-insensitive.
    ("GIT_GLOB_PATHSPECS", "0"),
    ("GIT_NOGLOB_PATHSPECS", "0"),
    ("GIT_ICASE_PATHSPECS", "0"),
    # Read-only commands such as `git status` opportunistically rewrite the
    # index they read. They only ever read a temporary copy here, but no
    # optional write is wanted anywhere in this recipe.
    ("GIT_OPTIONAL_LOCKS", "0")]

type
  GitStep = object
    ok: bool
    stdout: string
    failure: string

proc runGit(host: ContentIdHost; cwd: string; args: openArray[string];
            indexFile = ""): GitStep =
  ## Run one git command and turn every way it can fail into a sentence.
  var env = PathspecEnvironment
  var argv = @["git"]
  if indexFile.len > 0:
    env.add ("GIT_INDEX_FILE", indexFile)
    # Under `core.splitIndex` a write to the temporary index would also write
    # a `sharedindex.*` file into the repository's git directory (and expire
    # old ones there). A temporary index is always written whole instead.
    argv.add ["-c", "core.splitIndex=false"]
  let reply = host.git(GitCall(argv: argv & @args, cwd: cwd, env: env))
  let shown = "`git " & args.join(" ") & "`"
  if reply.exitCode < 0:
    return GitStep(failure: "could not run " & shown & ": " & reply.stderr.strip())
  if not reply.complete:
    return GitStep(failure: shown & " produced more output than could be " &
                   "captured, or timed out, so its answer is incomplete")
  if reply.exitCode != 0:
    return GitStep(failure: shown & " failed (exit " & $reply.exitCode & "): " &
                   reply.stderr.strip())
  GitStep(ok: true, stdout: reply.stdout)

proc singleLine(output: string): string =
  ## The one line a plumbing command printed, without its line terminator.
  ## Only the terminator is removed: a path may legitimately end in spaces.
  result = output
  result.stripLineEnd()

proc nulRecords(output: string): seq[string] =
  ## Split ``-z`` output into records. The final record is NUL-terminated, so
  ## the empty string after it is not a record.
  result = output.split('\0')
  if result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

# ---------------------------------------------------------------------------
# Detecting the states with no content id (Content-Id §3)
# ---------------------------------------------------------------------------

proc detectWorkingTreeConditions(host: ContentIdHost; toplevel, indexFile: string;
                                 scope: openArray[string]):
    tuple[ok: bool; states: seq[NoContentIdState]; failure: string] =
  ## Look for every §3 condition among the in-scope entries of ``indexFile``
  ## (a COPY of the user's index) and its working tree. Each condition found
  ## is reported with all of its paths, so a refusal can name them.
  var unmerged, assumeUnchanged, skipPresent, gitlinks: seq[string]

  # `ls-files -s -v` lists every index entry with its tag, mode and stage:
  # `<tag> SP <mode> SP <object> SP <stage> TAB <path>`. A lowercase tag is an
  # assume-unchanged entry, an `S`/`s` tag a skip-worktree entry, and a
  # non-zero stage an unmerged one (git-ls-files(1), "-t" and "-v").
  let listing = runGit(host, toplevel,
    @["--literal-pathspecs", "ls-files", "-z", "-s", "-v", "--"] & @scope,
    indexFile)
  if not listing.ok:
    return (false, @[], listing.failure)
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    let fields = (if tab < 0: @[] else: record[0 ..< tab].split(' '))
    if fields.len != 4 or fields[0].len != 1:
      return (false, @[], "`git ls-files -s -v` printed a record this " &
              "recipe cannot read: " & record.escape())
    let tag = fields[0][0]
    let mode = fields[1]
    let stage = fields[3]
    let path = record[tab + 1 .. ^1]
    if stage != "0":
      unmerged.add path
      continue
    if tag in {'a'..'z'}:
      assumeUnchanged.add path
    if tag in {'S', 's'} and host.pathExists(toplevel & "/" & path):
      # Absent is how sparse checkout normally leaves a skip-worktree entry,
      # and then the indexed content IS what the content id records; only a
      # present file is one git has been told not to look at.
      skipPresent.add path
    if mode == "160000":
      gitlinks.add path

  # A nested repository is identified by its checked-out commit alone, so
  # modified content inside it is a state the id cannot describe. Only
  # `git status` reads inside submodules; it is asked only when the scope
  # holds a gitlink at all. `--ignore-submodules=none` overrides any
  # configuration that would hide the answer. The `<sub>` field of a
  # porcelain v2 record is `S<c><m><u>`, and `m` is "tracked changes"
  # (git-status(1), "Porcelain Format Version 2"). Untracked files inside a
  # submodule are not modified content, just as untracked files at the top
  # level are reported separately rather than refused.
  var modifiedSubmodules: seq[string]
  if gitlinks.len > 0:
    let status = runGit(host, toplevel,
      @["--literal-pathspecs", "status", "--porcelain=v2", "-z",
        "--untracked-files=no", "--ignore-submodules=none", "--no-renames",
        "--"] & @scope,
      indexFile)
    if not status.ok:
      return (false, @[], status.failure)
    let records = nulRecords(status.stdout)
    var i = 0
    while i < records.len:
      let record = records[i]
      inc i
      if record.startsWith("1 ") or record.startsWith("2 "):
        # Type 1 has 8 space-separated fields before the path, type 2 has 9
        # and is followed by its original path as a separate record.
        let fixed = (if record[0] == '1': 8 else: 9)
        let fields = record.split(' ', maxsplit = fixed)
        if fields.len != fixed + 1:
          return (false, @[], "`git status --porcelain=v2` printed a record " &
                  "this recipe cannot read: " & record.escape())
        let sub = fields[2]
        if sub.len == 4 and sub[0] == 'S' and sub[2] == 'M':
          modifiedSubmodules.add fields[fixed]
        if record[0] == '2':
          inc i

  var states: seq[NoContentIdState]
  for (condition, paths) in [(ncUnmergedEntries, unmerged),
                             (ncAssumeUnchanged, assumeUnchanged),
                             (ncSkipWorktreePresent, skipPresent),
                             (ncSubmoduleModified, modifiedSubmodules)]:
    if paths.len > 0:
      states.add NoContentIdState(condition: condition, paths: sortedUnique(paths))
  (true, states, "")

proc detectUnmerged(host: ContentIdHost; toplevel, indexFile: string;
                    scope: openArray[string]):
    tuple[ok: bool; states: seq[NoContentIdState]; failure: string] =
  ## The one §3 condition that applies to an index being committed: an
  ## unmerged entry has no single content (and ``git write-tree`` refuses).
  ## Flags that hide the working tree do not matter there, because the index
  ## itself is what the commit records.
  let listing = runGit(host, toplevel,
    @["--literal-pathspecs", "ls-files", "-z", "--unmerged", "--"] & @scope,
    indexFile)
  if not listing.ok:
    return (false, @[], listing.failure)
  var paths: seq[string]
  for record in nulRecords(listing.stdout):
    let tab = record.find('\t')
    if tab < 0:
      return (false, @[], "`git ls-files --unmerged` printed a record this " &
              "recipe cannot read: " & record.escape())
    paths.add record[tab + 1 .. ^1]
  if paths.len == 0:
    return (true, @[], "")
  (true, @[NoContentIdState(condition: ncUnmergedEntries,
                            paths: sortedUnique(paths))], "")

# ---------------------------------------------------------------------------
# Computing an id
# ---------------------------------------------------------------------------

proc treeIdProblem(tree: string; format: ContentAlgorithm): string =
  ## Guard the step that turns git's output into a digest: anything but a
  ## full lowercase object id of the repository's format is a failure, never
  ## an id.
  let parsed = parseContentId(formatContentId(format, tree))
  if parsed.form != cifWellFormed:
    "git returned `" & tree & "` where a " & $format & " tree id was expected"
  else:
    ""

proc manifestOfTree(host: ContentIdHost; toplevel, tree: string): ContentIdResult =
  ## ``manifest-v1-sha256`` of a tree that already holds exactly the in-scope
  ## entries at their full paths. The tree's blobs ARE the content "as the VCS
  ## would record it" (§2), so a manifest over them agrees with one a
  ## producer computed over the same files.
  let listing = runGit(host, toplevel, @["ls-tree", "-r", "-z", "--full-tree", tree])
  if not listing.ok:
    return failed(listing.failure)
  var entries: seq[ManifestEntry]
  for record in nulRecords(listing.stdout):
    # `<mode> SP <type> SP <object> TAB <path>` (git-ls-tree(1)).
    let tab = record.find('\t')
    let fields = (if tab < 0: @[] else: record[0 ..< tab].split(' '))
    if fields.len != 3:
      return failed("`git ls-tree` printed a record this recipe cannot read: " &
                    record.escape())
    let (mode, kind, objectId) = (fields[0], fields[1], fields[2])
    let path = record[tab + 1 .. ^1]
    case kind
    of "blob":
      let blob = runGit(host, toplevel, @["cat-file", "blob", objectId])
      if not blob.ok:
        return failed(blob.failure)
      entries.add ManifestEntry(path: path, mode: mode, content: blob.stdout)
    of "commit":
      # A gitlink: the nested repository's revision, as git spells it.
      entries.add ManifestEntry(path: path, mode: mode, content: objectId)
    else:
      return failed("`git ls-tree -r` listed a " & kind & " entry `" & path &
                    "`, which a manifest has no record for")
  manifestV1Sha256(entries)

proc repositoryTreeAlgorithm*(host: ContentIdHost; repository: string):
    tuple[ok: bool; algorithm: ContentAlgorithm; failure: string] =
  ## The ``git-tree-*`` algorithm matching the repository's object format —
  ## the one a producer SHOULD use (Content-Id §4).
  let format = runGit(host, repository, @["rev-parse", "--show-object-format"])
  if not format.ok:
    return (false, caGitTreeSha1, format.failure)
  case singleLine(format.stdout)
  of "sha1": (true, caGitTreeSha1, "")
  of "sha256": (true, caGitTreeSha256, "")
  else:
    (false, caGitTreeSha1, "git reports object format `" &
     singleLine(format.stdout) & "`, which no content id algorithm is defined over")

proc computeContentId*(host: ContentIdHost; repository: string;
                       state: ContentState; algorithm: ContentAlgorithm;
                       scope: openArray[string] = []): ContentIdResult =
  ## The content id of ``state`` in the git repository containing
  ## ``repository``, in ``algorithm``, over ``scope`` (empty: the whole
  ## repository). Content-Id §4 and §5.
  ##
  ## The unscoped tree ``T`` is found first:
  ##
  ## * a working tree — the user's index is COPIED into a temporary directory
  ##   and, in the copy only: the §3 conditions are looked for (and reported
  ##   instead of an id), ``git add --update`` takes every tracked entry's
  ##   working-tree content and drops deleted ones while adding nothing
  ##   untracked, and ``git write-tree`` gives ``T`` (§4.1). A repository with
  ##   no index tracks nothing and its content is the empty tree;
  ## * the index being committed — the same copy, unmerged entries reported,
  ##   then ``git write-tree``. Writing the tree from a copy is not a nicety:
  ##   ``write-tree`` stores its cache-tree back into the index it read;
  ## * a commit — ``<revision>^{tree}``. There is nothing to normalise or
  ##   refuse (§5).
  ##
  ## A scope then keeps only the in-scope entries of ``T`` AT THEIR FULL
  ## PATHS, selected with literal pathspecs, in a second temporary index
  ## (§4.1, "Scoped"). That is not the subtree ``T:<path>``, which has lost
  ## its path. A scope matching nothing yields the empty tree.
  ##
  ## ``git-tree-*`` in the other object format is ``cioCannotCompute``.
  for prefix in scope:
    let problem = scopePathProblem(prefix)
    if problem.len > 0:
      return failed(problem)

  let top = runGit(host, repository, @["rev-parse", "--show-toplevel"])
  if not top.ok:
    return failed("`" & repository & "` is not inside a git working tree: " &
                  top.failure)
  # Every later command runs at the top level, so the repo-relative scope
  # paths mean the same thing whatever directory the caller named.
  let toplevel = singleLine(top.stdout)

  let format = repositoryTreeAlgorithm(host, toplevel)
  if not format.ok:
    return failed(format.failure)
  let treeAlgorithm = format.algorithm
  if algorithm != caManifestV1Sha256 and algorithm != treeAlgorithm:
    return cannotCompute(algorithm,
      $algorithm & " cannot be computed in this repository: its object " &
      "format makes its trees " & $treeAlgorithm & " ids")

  if state.kind == cskCommit and
     (state.revision.len == 0 or state.revision.startsWith("-")):
    # A leading `-` would be read as an option, not a revision.
    return failed("`" & state.revision & "` is not a revision")

  let scratch = host.makeTempDir()
  if not scratch.ok:
    return failed("could not create a temporary directory for the " &
                  "computation's index: " & scratch.error)
  try:
    var tree: string
    case state.kind
    of cskCommit:
      let resolved = runGit(host, toplevel,
        @["rev-parse", "--verify", "--quiet", state.revision & "^{tree}"])
      if not resolved.ok:
        return failed("`" & state.revision & "` does not name a commit or " &
                      "tree in this repository")
      tree = singleLine(resolved.stdout)
    of cskWorkingTree, cskIndex:
      # `--git-path index` honours GIT_INDEX_FILE, so "what is tracked" is
      # the index git itself would use here — the one being committed, when
      # this runs inside a commit's hook.
      let indexPath = runGit(host, toplevel,
        @["rev-parse", "--path-format=absolute", "--git-path", "index"])
      if not indexPath.ok:
        return failed(indexPath.failure)
      let temporaryIndex = scratch.path & "/index"
      let copy = host.copyFile(singleLine(indexPath.stdout), temporaryIndex)
      if copy.missing:
        # No index yet: nothing is tracked. Starting from an empty index
        # keeps one code path, and gives the empty tree in the repository's
        # own object format.
        let empty = runGit(host, toplevel, @["read-tree", "--empty"], temporaryIndex)
        if not empty.ok:
          return failed(empty.failure)
      elif not copy.ok:
        return failed("could not copy the index to a temporary file: " & copy.error)

      let detected =
        if state.kind == cskWorkingTree:
          detectWorkingTreeConditions(host, toplevel, temporaryIndex, scope)
        else:
          detectUnmerged(host, toplevel, temporaryIndex, scope)
      if not detected.ok:
        return failed(detected.failure)
      if detected.states.len > 0:
        return noContentId(algorithm, detected.states)

      if state.kind == cskWorkingTree:
        # No pathspec: since git 2.0 `add --update` without one covers the
        # whole tree, which is what `-- :/` in §4.1 spells, and it stays so
        # under an inherited GIT_LITERAL_PATHSPECS that would make `:/` a
        # file name.
        let update = runGit(host, toplevel, @["add", "--update"], temporaryIndex)
        if not update.ok:
          return failed(update.failure)
      let written = runGit(host, toplevel, @["write-tree"], temporaryIndex)
      if not written.ok:
        return failed(written.failure)
      tree = singleLine(written.stdout)
    let treeProblem = treeIdProblem(tree, treeAlgorithm)
    if treeProblem.len > 0:
      return failed(treeProblem)

    if scope.len > 0:
      # Equivalent to §4.1's `ls-tree -r ... -- <paths> | update-index
      # --index-info`, without needing a pipe into git: path-limited
      # `reset` copies exactly the matching entries of T into the empty
      # index, at their full paths, and never touches a ref or the working
      # tree (`-q` also skips the refresh that would stat the working tree).
      let scopedIndex = scratch.path & "/scoped-index"
      let empty = runGit(host, toplevel, @["read-tree", "--empty"], scopedIndex)
      if not empty.ok:
        return failed(empty.failure)
      let selected = runGit(host, toplevel,
        @["--literal-pathspecs", "reset", "-q", tree, "--"] & @scope, scopedIndex)
      if not selected.ok:
        return failed(selected.failure)
      let written = runGit(host, toplevel, @["write-tree"], scopedIndex)
      if not written.ok:
        return failed(written.failure)
      tree = singleLine(written.stdout)
      let scopedProblem = treeIdProblem(tree, treeAlgorithm)
      if scopedProblem.len > 0:
        return failed(scopedProblem)

    if algorithm == caManifestV1Sha256:
      return manifestOfTree(host, toplevel, tree)
    computed(treeAlgorithm, tree)
  finally:
    host.removeDir(scratch.path)
