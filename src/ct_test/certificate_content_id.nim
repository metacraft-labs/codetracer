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
## The host's git runner is its own type, not the native process bridge's
## ``CapturedRun``, for three reasons: the recipe needs to add
## ``GIT_INDEX_FILE`` to git's environment, it parses ``write-tree`` and
## ``ls-tree`` output that must not have stderr warnings mixed into it, and a
## non-native host cannot import the bridge. Nothing here imports
## ``certificate_issuance`` either: the signing path has no business within
## reach of this module.
##
## What computing an id writes
## ---------------------------
## Loose blob and tree objects in the repository's object store, and nothing
## else in the repository: no ref, no index, no working-tree file. The user's
## index is copied into a temporary directory the host provides and every
## index operation runs against the copy (Content-Id §4.1 "Producers SHOULD
## compute it in a temporary index, so the user's staging area is neither read
## as the tested state nor modified").
##
## A host whose git answers later
## ------------------------------
## The recipe is written synchronously — each git call returns its reply —
## and stays that way: it is the specification of the computation, and a
## second, callback-shaped copy of it would be the drift this module exists to
## prevent. A host that must not wait for git (the Electron renderer's main
## thread: Status-Bar.md, "A refresh never stalls the window") drives the SAME
## recipe through ``runResumable``, which re-runs it from the start each time
## a reply arrives and replays the answers it already has. See
## ``runResumable`` for how, and for what that costs.

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
  ## The §4 algorithm ``name`` identifies, by exact string equality.
  ## The parser first checks the portable Content-Id §1 identifier grammar.
  for algorithm in ContentAlgorithm:
    if $algorithm == name:
      return (true, algorithm)
  (false, caGitTreeSha1)

proc isLowerHex(text: string): bool =
  for ch in text:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc isPortableAlgorithm(name: string): bool =
  ## Content-Id §1: portable across store implementations and filesystems,
  ## including Windows reserved devices, even when parsed on another host.
  if name.len == 0 or name.len > 64:
    return false
  for ch in name:
    if ch notin {'a'..'z', '0'..'9', '-'}:
      return false
  if name in ["con", "prn", "aux", "nul"]:
    return false
  if name.len == 4 and name[0..2] in ["com", "lpt"] and name[3] in {'1'..'9'}:
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
  if not isPortableAlgorithm(result.algorithmName):
    result.form = cifMalformed
    result.problem = "the algorithm identifier is not portable (Content-Id §1)"
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

type DigestedManifestEntry = object
  ## A ``ManifestEntry`` whose content has already been hashed: what the
  ## recipe builds from a tree, so that no blob's bytes are held longer than
  ## it takes to hash them (``readBlobDigests``).
  path: string
  mode: string
  digest: string
    ## Lowercase hex SHA-256 of the content.

proc manifestOver[E](entries: openArray[E]; scope: openArray[string];
                     digestOf: proc(entry: E): string): ContentIdResult =
  ## The one body of ``manifest-v1-sha256`` — validation, scope, order and
  ## records — over entries of either form. ``digestOf`` is asked only for
  ## the in-scope entries that become records.
  for prefix in scope:
    let problem = scopePathProblem(prefix)
    if problem.len > 0:
      return failed(problem)
  var selected: seq[E]
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
  selected.sort(proc(a, b: E): int = byteOrder(a.path, b.path))
  var records = ""
  for i, entry in selected:
    if i > 0 and selected[i - 1].path == entry.path:
      return failed("entry path `" & entry.path & "` is listed twice; " &
                    "manifest paths are unique")
    records.add entry.mode
    records.add ' '
    records.add digestOf(entry)
    records.add ' '
    records.add entry.path
    records.add '\0'
  computed(caManifestV1Sha256, sha256Hex(records))

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
  manifestOver(entries, scope,
    proc(entry: ManifestEntry): string = sha256Hex(entry.content))

proc manifestOfDigests(entries: openArray[DigestedManifestEntry]): ContentIdResult =
  ## ``manifestV1Sha256`` over entries whose contents are already hashed,
  ## whole-repository (the recipe has already restricted the tree to scope).
  manifestOver(entries, [],
    proc(entry: DigestedManifestEntry): string = entry.digest)

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
    setModificationTime*: proc(path: string; unixSeconds: int64): HostFileResult
                                {.closure, gcsafe.}
      ## Set the modification time of the file at ``path`` (whole seconds
      ## since the Unix epoch). Used on the temporary index only — see
      ## ``StatDistrustTime``.
    pathExists*: proc(path: string): bool {.closure, gcsafe.}
      ## Whether anything — file, directory or symlink, dangling or not — is
      ## at ``path``.
    removeDir*: proc(path: string) {.closure, gcsafe.}
      ## Remove a directory ``makeTempDir`` created, with its contents.
    blobDigests: proc(toplevel: string; objectIds: seq[string]): BlobDigests
                     {.closure, gcsafe.}
      ## NOT EXPORTED, and ``nil`` on every host but one: the host
      ## ``runResumable`` builds for each attempt, which answers the whole
      ## list as ONE journaled operation (see "Driving the recipe over an
      ## asynchronous git"). ``nil`` means ``readBlobDigests``' own loop of
      ## ``git cat-file`` calls through ``git``. Private so that no host can
      ## supply a second way of reading a blob: the driver that sets it lives
      ## in this module and runs the very command the loop runs.

  BlobDigests = object
    ## ``readBlobDigests``' answer: the lowercase hex SHA-256 of each blob's
    ## content, in the order asked, or why they could not all be read.
    ok: bool
    failure: string
    digests: seq[string]

  AsyncContentGitRunner* = proc(call: GitCall;
                                done: proc(reply: GitReply) {.closure, gcsafe.})
                               {.closure, gcsafe.}
    ## Run one git command and deliver its reply LATER, by calling ``done``
    ## exactly once. ``done`` may also be called before the runner returns
    ## (a launch error reported inline); ``runResumable`` accepts both.

  AsyncContentIdHost* = object
    ## ``ContentIdHost`` for a host whose git answers asynchronously. The
    ## file operations stay synchronous: they are a temporary directory, one
    ## file copy and one ``utimes``, which no host has reason to defer, and
    ## keeping them synchronous is what lets ``runResumable`` hand the recipe
    ## a plain ``ContentIdHost``.
    git*: AsyncContentGitRunner
    makeTempDir*: proc(): HostFileResult {.closure, gcsafe.}
    copyFile*: proc(source, destination: string): HostFileResult {.closure, gcsafe.}
    setModificationTime*: proc(path: string; unixSeconds: int64): HostFileResult
                                {.closure, gcsafe.}
    pathExists*: proc(path: string): bool {.closure, gcsafe.}
    removeDir*: proc(path: string) {.closure, gcsafe.}

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

const StatDistrustTime* = 1'i64
  ## The modification time, in seconds since the Unix epoch, given to the
  ## temporary index before ``git add --update`` runs in it.
  ##
  ## WHY. ``add --update`` skips reading a file whose stat data (size, mtime,
  ## ctime, inode, ...) matches its index entry, and re-reads one that
  ## matches only when the entry is "racily clean": its recorded mtime is
  ## not older than the mtime of the INDEX FILE being read
  ## (https://git-scm.com/docs/racy-git, ``is_racy_timestamp`` in git's
  ## ``read-cache.c``). A copy of the user's index carries the copy's fresh
  ## mtime, so a same-size edit made in the same second as the last write of
  ## the real index — which git, reading the REAL index, would re-read — was
  ## taken as clean, and the content id named the OLD content: a certificate
  ## could name content its tests never ran, and a changed tree could read
  ## Certified (CTC-3b, 2026-10-10).
  ##
  ## Preserving the real index's mtime on the copy would only restore git's
  ## own heuristic, which still trusts stat data: a rewrite that leaves size,
  ## mtime and inode unchanged (``cp -p``, ``rsync -t``, a restore, or a
  ## coarse-mtime filesystem) and whose ctime git does not compare
  ## (``core.trustctime=false``, ``core.checkStat=minimal``) is invisible to
  ## it. Dating the copy at the epoch instead makes EVERY entry with a real
  ## mtime racily clean, so git compares every tracked file's CONTENT with
  ## its indexed blob, whatever the clocks, the skew between them or the
  ## filesystem's timestamp granularity. It is still ``add --update`` doing
  ## the work, so filters, ``autocrlf`` and every other rule apply exactly as
  ## Content-Id §4.1 spells them; only the stat shortcut is gone. The cost is
  ## reading every tracked file once per computation, as on a fresh clone's
  ## first ``git status``.
  ##
  ## ``1``, not ``0``: git takes an index timestamp of zero to mean "unknown"
  ## and then treats NO entry as racy. The one entry this leaves to the stat
  ## check is a file whose mtime is exactly the epoch (0), with every other
  ## compared stat field unchanged.

proc gitCallOf(cwd: string; args: openArray[string]; indexFile = ""): GitCall =
  ## The exact command ``runGit`` runs for ``args`` — written once, because
  ## ``runResumable``'s blob reader runs the same commands outside ``runGit``.
  var env = PathspecEnvironment
  var argv = @["git"]
  if indexFile.len > 0:
    env.add ("GIT_INDEX_FILE", indexFile)
    # Under `core.splitIndex` a write to the temporary index would also write
    # a `sharedindex.*` file into the repository's git directory (and expire
    # old ones there). A temporary index is always written whole instead.
    argv.add ["-c", "core.splitIndex=false"]
    # A filesystem monitor lets git skip the stat check entirely for entries
    # it last reported unchanged, and a monitor that has not yet delivered an
    # event is exactly the race `StatDistrustTime` closes. With it off, git
    # drops the monitor's "valid" marks it read from the copy.
    argv.add ["-c", "core.fsmonitor=false"]
  GitCall(argv: argv & @args, cwd: cwd, env: env)

proc stepOf(reply: GitReply; args: openArray[string]): GitStep =
  ## Turn every way a git command can fail into a sentence.
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

proc runGit(host: ContentIdHost; cwd: string; args: openArray[string];
            indexFile = ""): GitStep =
  ## Run one git command and turn every way it can fail into a sentence.
  stepOf(host.git(gitCallOf(cwd, args, indexFile)), args)

proc blobReadArgs(objectId: string): seq[string] =
  ## The command that reads one blob's content for ``manifest-v1-sha256``.
  @["cat-file", "blob", objectId]

proc readBlobDigests(host: ContentIdHost; toplevel: string;
                     objectIds: seq[string]): BlobDigests =
  ## The SHA-256 of each blob's content, in order — what a manifest record
  ## carries (Content-Id §4.2) — or the first read that failed.
  ##
  ## One ``git cat-file blob`` per object, and each content hashed as soon as
  ## it is read, so no more than one blob is held at a time. A host built by
  ## ``runResumable`` answers the whole list itself (``blobDigests``),
  ## running the same commands; see "Driving the recipe over an asynchronous
  ## git" for why the list is one operation there.
  if objectIds.len == 0:
    return BlobDigests(ok: true)
  if not host.blobDigests.isNil:
    return host.blobDigests(toplevel, objectIds)
  for objectId in objectIds:
    let blob = runGit(host, toplevel, blobReadArgs(objectId))
    if not blob.ok:
      return BlobDigests(failure: blob.failure)
    result.digests.add sha256Hex(blob.stdout)
  result.ok = true

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
  var entries: seq[DigestedManifestEntry]
  var blobs: seq[string]
    ## The object id of every blob entry, in listing order.
  var blobEntries: seq[int]
    ## Where in ``entries`` each of ``blobs`` goes.
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
      blobEntries.add entries.len
      blobs.add objectId
      entries.add DigestedManifestEntry(path: path, mode: mode)
    of "commit":
      # A gitlink: the nested repository's revision, as git spells it.
      entries.add DigestedManifestEntry(path: path, mode: mode,
                                        digest: sha256Hex(objectId))
    else:
      return failed("`git ls-tree -r` listed a " & kind & " entry `" & path &
                    "`, which a manifest has no record for")
  # Every blob is read only once the whole listing is known to be readable,
  # and as ONE list: under `runResumable` that is one journaled operation
  # rather than one re-run of this recipe per file.
  let read = readBlobDigests(host, toplevel, blobs)
  if not read.ok:
    return failed(read.failure)
  if read.digests.len != blobs.len:
    return failed("reading " & $blobs.len & " blobs answered " &
                  $read.digests.len & " digests")
  for i, at in blobEntries:
    entries[at].digest = read.digests[i]
  manifestOfDigests(entries)

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
  ##   working-tree content — re-reading every file, never trusting stat
  ##   data (``StatDistrustTime``) — and drops deleted ones while adding nothing
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
        # Every entry racily clean, so `add --update` reads every tracked
        # file's content rather than trusting stat data — see
        # `StatDistrustTime`. Done here, after the §3 detection, so a
        # `git status` that detection runs does not hash the tree as well.
        # (A missing index was replaced by an empty one above; dating it is
        # harmless.)
        let aged = host.setModificationTime(temporaryIndex, StatDistrustTime)
        if not aged.ok:
          return failed("could not set the temporary index's modification " &
                        "time: " & aged.error)
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

# ---------------------------------------------------------------------------
# Driving the recipe over an asynchronous git (runResumable)
# ---------------------------------------------------------------------------
#
# WHY JOURNAL-AND-REPLAY, AND NOT A SECOND RECIPE. The recipe above is
# synchronous, and it is the ONE implementation of Content-Id §4/§5 every
# CodeTracer host drives (module header). A host that cannot wait for git —
# the Electron renderer, whose main thread is the UI — could have been given a
# continuation-passing copy of it, and the two would then have to agree
# forever about every git argument, every parse and every refusal: the
# producer/verifier drift Content-Id §1 warns about, inside one binary.
#
# Instead the recipe is RE-RUN. Each run ("attempt") goes through a
# synthesized synchronous ``ContentIdHost`` that journals every operation by
# its position in the run. On a later attempt the operations already in the
# journal are answered from it — the same git reply, the same temporary
# directory, the same file result — without performing anything again. The
# first git call that is NOT in the journal is launched through the
# asynchronous runner, and the attempt is "suspended": every further
# operation in it returns an inert failure without side effects, so the
# recipe runs to a (meaningless) end, and its answer is discarded. When the
# reply arrives it is appended to the journal and the recipe is run again,
# one step further. The attempt that completes without launching anything
# is the answer.
#
# Sound because the recipe is deterministic in its host's answers: given the
# same replies it asks the same questions in the same order. That is checked,
# not assumed — a replayed git call whose argv, cwd or environment differs
# from the journal's ends the computation with a failure reply naming
# non-deterministic replay, rather than replaying a wrong answer or waiting
# for one that will never come.
#
# WHAT IT COSTS, honestly. A computation that makes N journaled operations
# runs N + 1 attempts, and attempt k replays the k - 1 answers before it, so
# the in-process work is quadratic in N. That is acceptable only while N is a
# handful and each answer is small, which is why the blobs of a
# ``manifest-v1-sha256`` are ONE operation here, not one per file.
#
# * The tree algorithms make about eight git calls (W), and replaying them is
#   string parsing measured in microseconds.
# * ``manifest-v1-sha256`` reads every blob of the tree. Journaled one call at
#   a time, as the synchronous loop issues them, attempt k would copy and the
#   final attempt would hash the content of every file read so far: measured
#   2026-10-22 over 400 files of 27 KB under node, 48 s of main-thread work
#   instead of 3.6 s, with single tasks of 326 ms, growing with the tree. So
#   ``readBlobDigests`` asks for the whole list at once (the private
#   ``blobDigests`` hook of the attempt's host), and the driver answers it by
#   running the SAME ``git cat-file blob`` commands one at a time, hashing each
#   content in the task its reply arrives in and keeping only the digest. The
#   journal then holds one entry of N digests, and the number of attempts no
#   longer depends on the size of the tree. The longest task left is hashing
#   the largest single file.
#
# Every attempt is one task between two git replies, so the work is spread
# across the event loop, never one long block of the thread the user is
# waiting on — the property this exists for.
#
# What is NOT replayed: ``removeDir``. The recipe removes its temporary
# directory in a ``finally``, so every suspended attempt would reach it and
# remove the directory the next attempt still needs. A removal is therefore
# recorded and performed only by the attempt that completes without
# suspending — exactly once, after the last git call.

proc asyncContentIdHost*(files: ContentIdHost;
                         git: AsyncContentGitRunner): AsyncContentIdHost =
  ## An asynchronous host with ``files``' file operations and ``git`` for git
  ## (``files.git`` is not used). One set of file-operation closures then
  ## serves a host's synchronous and asynchronous forms alike.
  AsyncContentIdHost(git: git, makeTempDir: files.makeTempDir,
                     copyFile: files.copyFile,
                     setModificationTime: files.setModificationTime,
                     pathExists: files.pathExists, removeDir: files.removeDir)

type
  JournalKind = enum
    jkGit, jkMakeTempDir, jkCopyFile, jkSetModificationTime, jkPathExists,
    jkBlobDigests

  JournalEntry = object
    ## One operation a previous attempt performed, at its position in the run.
    kind: JournalKind
    call: GitCall
      ## ``jkGit``: the call exactly as the recipe issued it.
    reply: GitReply
      ## ``jkGit``: git's answer.
    arguments: seq[string]
      ## A file operation's arguments, and ``jkBlobDigests``' top level and
      ## object ids, so a replay can check it asks the same.
    file: HostFileResult
      ## ``jkMakeTempDir``, ``jkCopyFile``, ``jkSetModificationTime``.
    exists: bool
      ## ``jkPathExists``.
    digests: BlobDigests
      ## ``jkBlobDigests``.

  ResumableAttempt = ref object
    position: int
      ## How many journal entries this attempt has consumed.
    suspended: bool
      ## This attempt launched a git call; its answer will be discarded.
    diverged: string
      ## Non-empty once a replayed operation did not match the journal: why.
    removals: seq[string]
      ## ``removeDir`` requests, performed only if the attempt completes.

  ResumableRun = ref object
    host: AsyncContentIdHost
    journal: seq[JournalEntry]
    waiting: bool
      ## A launched operation — one git call, or one list of blob reads —
      ## has not answered yet.
    attempting: bool
      ## An attempt is on the stack: an answer delivered now (inline, by the
      ## runner) is journaled and picked up when the attempt returns, never
      ## by re-entering the recipe from inside itself.
    finished: bool
    drive: proc() {.closure.}
      ## Run attempts until one suspends or completes. Built by
      ## ``runResumable``, which knows the computation's type.

  BlobRead = ref object
    ## One ``jkBlobDigests`` operation in progress: its blobs are read one
    ## ``git cat-file`` at a time, each hashed when its reply arrives.
    run: ResumableRun
    toplevel: string
    objectIds: seq[string]
    arguments: seq[string]
    digests: seq[string]
    next: int
      ## The blob being read.

const
  NotYetAnswered = "not performed: the computation is waiting for an " &
                   "earlier git call to answer"
  NonDeterministicReplay* = "non-deterministic replay"
    ## Begins the reason a computation fails when a re-run asked for a
    ## different operation than the run before it.

proc describeCall(call: GitCall): string =
  "`" & call.argv.join(" ") & "` in `" & call.cwd & "`"

proc sameCall(a, b: GitCall): bool =
  a.argv == b.argv and a.cwd == b.cwd and a.env == b.env

type ReplayStep = enum
  rsReplay      ## answer from the journal entry
  rsDiverged    ## the journal disagrees; answer a failure
  rsSuspended   ## not in the journal, and the attempt is suspended: inert
  rsPerform     ## not in the journal: perform (or launch) it now

proc replayStep(run: ResumableRun; attempt: ResumableAttempt;
                kind: JournalKind; arguments: seq[string]): ReplayStep =
  ## Decide how a non-``jkGit`` operation is answered in this attempt.
  if attempt.diverged.len > 0:
    return rsDiverged
  if attempt.position < run.journal.len:
    let entry = run.journal[attempt.position]
    if entry.kind != kind or entry.arguments != arguments:
      attempt.diverged = NonDeterministicReplay & ": the computation asked " &
        "for " & $kind & " " & arguments.join(" ") & " where its previous " &
        "run asked for " & $entry.kind & " " & entry.arguments.join(" ")
      return rsDiverged
    inc attempt.position
    return rsReplay
  if attempt.suspended:
    return rsSuspended
  rsPerform

proc receive(run: ResumableRun; entry: JournalEntry) =
  ## The launched operation answered: journal it and run the next attempt.
  if run.finished or not run.waiting:
    return
  run.waiting = false
  run.journal.add entry
  if run.attempting:
    # Delivered before the runner returned. The attempt that launched it is
    # still running; `drive` sees `waiting == false` when it returns and runs
    # the next attempt itself.
    return
  run.drive()

proc launch(run: ResumableRun; call: GitCall) =
  run.waiting = true
  var delivered = false
  let target = run
  run.host.git(call, proc(reply: GitReply) {.closure, gcsafe.} =
    # Exactly once, whatever the runner does: a node child can report both
    # `error` and `close`, and a reply after the answer changes nothing.
    if delivered:
      return
    delivered = true
    # The continuation runs the recipe, which is not annotated gcsafe; it
    # runs on the thread that delivered the reply, the only one this run is
    # ever touched from (the bridge `outcome.thenOutcome` also casts).
    {.cast(gcsafe).}:
      target.receive(JournalEntry(kind: jkGit, call: call, reply: reply)))

proc advance(read: BlobRead)

proc accept(read: BlobRead; reply: GitReply): bool =
  ## Fold the reply for blob ``read.next`` in: hash its content and keep
  ## only the digest. True when the operation is over — a read failed (the
  ## same sentence ``readBlobDigests``' loop gives), or this was the last.
  let step = stepOf(reply, blobReadArgs(read.objectIds[read.next]))
  var answer: BlobDigests
  if not step.ok:
    answer = BlobDigests(failure: step.failure)
  else:
    read.digests.add sha256Hex(step.stdout)
    inc read.next
    if read.next < read.objectIds.len:
      return false
    answer = BlobDigests(ok: true, digests: read.digests)
  read.run.receive(JournalEntry(kind: jkBlobDigests,
                                arguments: read.arguments, digests: answer))
  true

proc request(read: BlobRead): tuple[inline: bool; reply: GitReply] =
  ## Launch the read of blob ``read.next``. A proc of its own so that each
  ## call's flags live in an environment of their own: a Nim closure made in
  ## a loop body shares ONE environment across iterations
  ## (https://nim-lang.org/docs/manual.html#closures-creating-closures-in-loops).
  ## A reply delivered before the runner returns is handed back to
  ## ``advance``'s loop rather than handled here, so a runner that answers
  ## every call inline cannot grow the stack with the number of files.
  var returned = false
  var inline = false
  var inlineReply: GitReply
  var delivered = false
  read.run.host.git(gitCallOf(read.toplevel, blobReadArgs(read.objectIds[read.next])),
    proc(reply: GitReply) {.closure, gcsafe.} =
      if delivered:
        return
      delivered = true
      if not returned:
        inline = true
        inlineReply = reply
        return
      {.cast(gcsafe).}:
        if not read.accept(reply):
          read.advance())
  returned = true
  (inline, inlineReply)

proc advance(read: BlobRead) =
  ## Read blobs from ``read.next`` on until one answers later or the
  ## operation is over.
  while true:
    let (inline, reply) = read.request()
    if not inline or read.accept(reply):
      return

proc readBlobs(run: ResumableRun; toplevel: string; objectIds: seq[string];
               arguments: seq[string]) =
  ## Launch one ``jkBlobDigests`` operation (``objectIds`` is not empty:
  ## ``readBlobDigests`` answers an empty list itself).
  run.waiting = true
  BlobRead(run: run, toplevel: toplevel, objectIds: objectIds,
           arguments: arguments).advance()

proc attemptHost(run: ResumableRun; attempt: ResumableAttempt): ContentIdHost =
  ## The synchronous host one attempt of the recipe runs against.
  ContentIdHost(
    git: proc(call: GitCall): GitReply {.closure, gcsafe.} =
      if attempt.diverged.len > 0:
        return GitReply(exitCode: -1, stderr: attempt.diverged, complete: true)
      if attempt.position < run.journal.len:
        let entry = run.journal[attempt.position]
        if entry.kind != jkGit or not sameCall(entry.call, call):
          attempt.diverged = NonDeterministicReplay & ": the computation ran " &
            describeCall(call) & " where its previous run " &
            (if entry.kind == jkGit: "ran " & describeCall(entry.call)
             else: "performed " & $entry.kind)
          return GitReply(exitCode: -1, stderr: attempt.diverged, complete: true)
        inc attempt.position
        return entry.reply
      if not attempt.suspended:
        # The first git call this run has no answer for: ask for it, and
        # let the rest of this attempt run out inertly.
        attempt.suspended = true
        {.cast(gcsafe).}:
          run.launch(call)
      GitReply(exitCode: -1, stderr: NotYetAnswered, complete: true),
    makeTempDir: proc(): HostFileResult {.closure, gcsafe.} =
      case replayStep(run, attempt, jkMakeTempDir, @[])
      of rsReplay: run.journal[attempt.position - 1].file
      of rsDiverged: HostFileResult(error: attempt.diverged)
      of rsSuspended: HostFileResult(error: NotYetAnswered)
      of rsPerform:
        let made = run.host.makeTempDir()
        run.journal.add JournalEntry(kind: jkMakeTempDir, file: made)
        inc attempt.position
        made,
    copyFile: proc(source, destination: string): HostFileResult {.closure, gcsafe.} =
      let arguments = @[source, destination]
      case replayStep(run, attempt, jkCopyFile, arguments)
      of rsReplay: run.journal[attempt.position - 1].file
      of rsDiverged: HostFileResult(error: attempt.diverged)
      of rsSuspended: HostFileResult(error: NotYetAnswered)
      of rsPerform:
        let copied = run.host.copyFile(source, destination)
        run.journal.add JournalEntry(kind: jkCopyFile, arguments: arguments,
                                     file: copied)
        inc attempt.position
        copied,
    setModificationTime: proc(path: string; unixSeconds: int64): HostFileResult
                             {.closure, gcsafe.} =
      let arguments = @[path, $unixSeconds]
      case replayStep(run, attempt, jkSetModificationTime, arguments)
      of rsReplay: run.journal[attempt.position - 1].file
      of rsDiverged: HostFileResult(error: attempt.diverged)
      of rsSuspended: HostFileResult(error: NotYetAnswered)
      of rsPerform:
        let aged = run.host.setModificationTime(path, unixSeconds)
        run.journal.add JournalEntry(kind: jkSetModificationTime,
                                     arguments: arguments, file: aged)
        inc attempt.position
        aged,
    pathExists: proc(path: string): bool {.closure, gcsafe.} =
      case replayStep(run, attempt, jkPathExists, @[path])
      of rsReplay: run.journal[attempt.position - 1].exists
      of rsDiverged, rsSuspended: false
      of rsPerform:
        let exists = run.host.pathExists(path)
        run.journal.add JournalEntry(kind: jkPathExists, arguments: @[path],
                                     exists: exists)
        inc attempt.position
        exists,
    removeDir: proc(path: string) {.closure, gcsafe.} =
      # Deferred to the end of the attempt, and dropped if it suspended: see
      # the section header.
      attempt.removals.add(path),
    blobDigests: proc(toplevel: string; objectIds: seq[string]): BlobDigests
                     {.closure, gcsafe.} =
      # The whole list is ONE journaled operation: see the section header,
      # "WHAT IT COSTS".
      let arguments = @[toplevel] & objectIds
      case replayStep(run, attempt, jkBlobDigests, arguments)
      of rsReplay: run.journal[attempt.position - 1].digests
      of rsDiverged: BlobDigests(failure: attempt.diverged)
      of rsSuspended: BlobDigests(failure: NotYetAnswered)
      of rsPerform:
        attempt.suspended = true
        {.cast(gcsafe).}:
          run.readBlobs(toplevel, objectIds, arguments)
        BlobDigests(failure: NotYetAnswered))

proc runResumable*[T](host: AsyncContentIdHost;
                      compute: proc(host: ContentIdHost): T;
                      done: proc(value: T)) =
  ## Run ``compute`` — the recipe, or anything that drives it, such as the
  ## facade's ``contentIdOver`` with its ``git --version`` probe — over an
  ## asynchronous git, and call ``done`` with its answer exactly once.
  ##
  ## ``compute`` is run once per git call it makes, plus once (see the
  ## section header for how and at what cost); its value is used only from
  ## the run that needed no new git call. It must be deterministic in its
  ## host's answers — a run that asks something different from the run before
  ## it is answered with a failure naming ``NonDeterministicReplay`` and
  ## finishes — and it must not raise: an exception propagates to whatever
  ## delivered the reply, and ``done`` is then never called.
  ##
  ## If ``compute`` needs no git at all (an invalid scope, a refusal), or the
  ## runner answers every call inline, ``done`` runs before this returns.
  let run = ResumableRun(host: host)
  run.drive = proc() =
    while not run.finished:
      let attempt = ResumableAttempt()
      run.attempting = true
      var value: T
      try:
        value = compute(attemptHost(run, attempt))
      finally:
        run.attempting = false
      if attempt.suspended:
        if run.waiting:
          return          # `receive` resumes when the reply arrives
        continue          # it arrived inline and is journaled: go on
      run.finished = true
      for path in attempt.removals:
        host.removeDir(path)
      done(value)
  run.drive()
