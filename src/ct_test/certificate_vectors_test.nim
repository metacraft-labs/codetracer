## The conformance-vector walker for the test-certificate standard.
##
## ``test-certificates-spec/vectors/`` is **plain data with no runner** — that
## is deliberate, so that nothing in the standard's repository has to be
## invoked, imported, ported or trusted in order to claim conformance
## (``vectors/README.md``). This file is CodeTracer's own thin walker over it.
##
## It walks all five groups:
##
## * ``payload/`` — serialize ``fields.json`` and compare byte for byte with
##   ``canonical.txt``. Plus the one optional ``received.toml``, a deliberately
##   non-canonical rendering of the same values that MUST parse to the same
##   payload (Canonical-Payload.md §5).
## * ``signature/`` — **verify**, never reproduce. Conformance.md §2 sets that
##   direction: SSH signature framing is an implementation's own business,
##   while verification is what interoperability actually needs. Three of the
##   six vectors MUST fail, and one of them (``wrong-namespace``) is a genuine
##   signature by the right key over exactly these bytes, made under the
##   namespace OpenSSH uses for commit signing.
## * ``content/`` — compute every id ``expected.json`` lists from the
##   tracked entries in ``entries.json``, through CTC-3b's content-id library:
##   ``manifest-v1-sha256`` directly over the entries, and ``git-tree-*`` with
##   real git — each entry written as an object and staged into the index of
##   a scratch repository of the matching object format, whose content id the
##   library then computes, scoped by its own §4.1 recipe (the README's
##   re-derivation, run rather than trusted).
## * ``verify/`` — the three-valued outcome, plus which certificates were
##   ignored / rejected / unevaluated. Those three fates are the ones an
##   implementation confuses, so their classification is normative even though
##   the wording is not. ``state.json``'s ``content`` list is the content
##   oracle: an algorithm or scope it does not list is one this consumer
##   cannot compute, never a mismatch. Its ``commit`` is informational and is
##   read by nothing.
## * ``store/`` — parse ``certificate.toml`` (non-canonical renderings
##   included), rebuild its canonical payload from the parsed fields, and
##   derive ``v1/<algorithm>/<digest>/<sha256 of the payload>.toml``
##   (Transport.md §2.2), compared with ``expected-path.txt``.
##
## ``index.json`` is cross-checked against what was walked, in both directions:
## every case a walked group lists must be on disk and vice versa, and every
## group ``index.json`` declares must be one this walker walks. A case that
## has silently gone missing is a case that stops testing anything, and a
## whole group the walker does not know about is the same failure at a larger
## scale.
##
## WHICH REVISION OF THE VECTORS IS WALKED
## ----------------------------------------
## The walker conforms to ONE stated revision of the standard, recorded as a
## full commit id in ``certificate_vectors.pin`` next to this file. The suite
## does not read the sibling repository's checkout: it runs
## ``git archive <pin> vectors`` against the sibling's object store, unpacks
## the result into a fresh temporary directory, walks that and removes it. So a
## developer whose sibling is on a newer branch and the CI job walk the same
## bytes, and an uncommitted edit in the sibling's working tree changes
## nothing. Moving to a newer revision of the standard is a deliberate act:
## the pin moves in the same change that teaches the walker (and the producer)
## the new rules.
##
## A pin the sibling's object store does not contain — never fetched, or a
## shallow clone — fails the suite naming the pin and the fetch remedy. It
## never skips and never falls back to the checkout.
##
## The sibling itself is required: when it is absent this suite **fails
## loudly** rather than skipping — a missing required sibling that quietly
## turns a suite green is the failure mode
## ``codetracer-specs/Working-with-the-CodeTracer-Repos.md`` Part 2 exists to
## forbid.
##
## ``CT_TEST_CERTIFICATE_VECTORS`` remains an explicit override for an
## already-exported ``vectors`` directory (a layout where the sibling does not
## resolve). The walk is then UNPINNED and the log says so; neither the
## ``ct-test-certificates`` lane nor CI sets it, and under CI (``CI`` or
## ``GITHUB_ACTIONS`` set) the override is refused and the suite fails.

import std/[algorithm, base64, json, os, osproc, sets, streams,
            strtabs, strutils, tempfiles, unittest]

import certificate
import certificate_content_id
import certificate_content_id_native
import certificate_signature
import certificate_verification

const
  SpecRepositoryName = "test-certificates-spec"
  PinFileName = "certificate_vectors.pin"
  VectorsOverrideVariable = "CT_TEST_CERTIFICATE_VECTORS"

  WalkedGroups* = ["payload", "signature", "content", "verify", "store"]
    ## The ``index.json`` groups this walker understands. A group the
    ## standard declares and this list lacks fails the suite by name.

# ---------------------------------------------------------------------------
# Running git without inheriting a caller's repository
# ---------------------------------------------------------------------------

proc childEnvironment(): StringTableRef =
  ## The current environment minus the variables that redirect git to another
  ## repository. When this suite runs from inside a git hook (or any wrapper
  ## that exports ``GIT_DIR``), an inherited ``GIT_DIR`` would make every
  ## ``git -C <sibling>`` below silently operate on the CALLER's repository.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
               "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
               "GIT_COMMON_DIR", "GIT_NAMESPACE"]:
      continue
    result[key] = value

proc runTool(command: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  ## Run ``command`` with ``args`` (no shell, so no quoting hazards), merging
  ## stderr into the returned output. A command that cannot be started at all
  ## is reported as exit code -1 with the reason, never raised: the callers
  ## turn every failure into a named, actionable message.
  try:
    let process = startProcess(command, args = args, env = childEnvironment(),
                               options = {poUsePath, poStdErrToStdOut})
    defer: process.close()
    let output = process.outputStream.readAll()
    result = (process.waitForExit(), output)
  except OSError as err:
    result = (-1, "could not run `" & command & "`: " & err.msg)

proc git(repository: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runTool("git", @["-C", repository] & @args)

# ---------------------------------------------------------------------------
# The pin, and extracting the vectors at it
# ---------------------------------------------------------------------------

proc isFullCommitId(value: string): bool =
  ## A SHA-1 (40) or SHA-256 (64) object id in lowercase hex. An abbreviated
  ## id is refused: abbreviations become ambiguous as a repository grows, and
  ## a pin that silently starts naming a different commit is no pin.
  (value.len == 40 or value.len == 64) and
    value.allCharsInSet({'0'..'9', 'a'..'f'})

proc readPin*(path: string): tuple[pin: string; error: string] =
  ## Read a pin file: exactly one line holding a full commit id (a trailing
  ## newline is allowed). Anything else is an error naming the file.
  if not fileExists(path):
    return ("", "the vectors pin file does not exist: " & path)
  var content: string
  try:
    content = readFile(path)
  except IOError as err:
    return ("", "could not read the vectors pin file " & path & ": " & err.msg)
  let pin = content.strip(leading = false, chars = {'\n'})
  if not pin.isFullCommitId:
    return ("", "the vectors pin file " & path & " must hold exactly one " &
                "full, lowercase commit id of " & SpecRepositoryName &
                " (40 or 64 hex digits), found: " & escape(content))
  (pin, "")

proc pinFilePath(): string =
  currentSourcePath().parentDir / PinFileName

proc specRepositoryPath(): string =
  ## The sibling checkout of the standard, relative to this source file:
  ## src/ct_test/<this file> -> src/ct_test -> src -> repo root -> workspace.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    SpecRepositoryName

type
  ExtractedVectors* = object
    ## The ``vectors/`` tree of one revision, unpacked outside the repository.
    ok*: bool
    vectors*: string   ## the unpacked ``vectors`` directory, when ``ok``
    scratch*: string   ## the temporary directory holding it; ``discardVectors``
                       ## removes it
    error*: string     ## why extraction failed, when not ``ok``

proc discardVectors*(extracted: ExtractedVectors) =
  ## Remove the temporary directory an extraction created. Idempotent.
  if extracted.scratch.len > 0 and dirExists(extracted.scratch):
    try:
      removeDir(extracted.scratch)
    except OSError:
      discard # a leaked temp dir must not mask the suite's verdict

proc extractVectorsAt*(repository, pin: string): ExtractedVectors =
  ## Unpack ``vectors/`` as it is at commit ``pin`` of ``repository`` into a
  ## fresh temporary directory, via ``git archive``. Only the object store is
  ## read: neither the checked-out revision nor the working tree of
  ## ``repository`` matters, and nothing in it is written.
  ##
  ## Every failure is an error naming what is missing and how to fix it; no
  ## failure produces an empty directory that a walker could mistake for "no
  ## cases".
  if not pin.isFullCommitId:
    return ExtractedVectors(error: "not a full commit id: " & escape(pin))
  if not dirExists(repository):
    return ExtractedVectors(error:
      "the " & SpecRepositoryName & " sibling repository was not found at " &
      repository & "; clone it beside this checkout (or point " &
      VectorsOverrideVariable & " at an exported `vectors` directory for an " &
      "unpinned walk)")
  let probe = git(repository, ["cat-file", "-e", pin & "^{commit}"])
  if probe.exitCode != 0:
    return ExtractedVectors(error:
      "the pinned revision " & pin & " is not in the object store of " &
      repository & " (never fetched, or a shallow clone). Fetch it: " &
      "`git -C " & repository & " fetch origin` (add `--unshallow` for a " &
      "shallow clone). git said: " & probe.output.strip())

  var scratch: string
  try:
    scratch = createTempDir("ct-test-certificate-vectors-", "")
  except OSError as err:
    return ExtractedVectors(error:
      "could not create a temporary directory for the vectors: " & err.msg)
  result = ExtractedVectors(scratch: scratch)

  let archive = scratch / "vectors.tar"
  let archived = git(repository,
                     ["archive", "--format=tar", "-o", archive, pin, "vectors"])
  if archived.exitCode != 0:
    result.error = "`git archive " & pin & " vectors` failed in " & repository &
                   ": " & archived.output.strip()
    discardVectors(result)
    return
  let unpacked = runTool("tar", ["-x", "-f", archive, "-C", scratch])
  if unpacked.exitCode != 0:
    result.error = "could not unpack the vectors archive: " &
                   unpacked.output.strip()
    discardVectors(result)
    return
  try:
    removeFile(archive)
  except OSError:
    discard # harmless: it is inside `scratch`, which is removed later
  if not fileExists(scratch / "vectors" / "index.json"):
    result.error = "revision " & pin & " of " & repository &
                   " has no vectors/index.json"
    discardVectors(result)
    return
  result.ok = true
  result.vectors = scratch / "vectors"

# ---------------------------------------------------------------------------
# Reading the vectors
# ---------------------------------------------------------------------------

proc sortedCaseDirs(group: string): seq[string] =
  ## Every case directory in a group, by name. Directory names are case ids and
  ## are stable; a rename is a new case.
  ##
  ## A case is identified by its ``pins.md``, because "every case directory
  ## carries a ``pins.md``" is the directory contract and a group may hold
  ## directories that are not cases — ``signature/keys/`` holds the published
  ## signing keys. Walking by that marker also satisfies the contract's other
  ## instruction, to ignore what you do not recognise: a walker that fails on
  ## a new optional entry is a walker that cannot be updated.
  result = @[]
  if not dirExists(group):
    return
  for kind, path in walkDir(group):
    if kind == pcDir and fileExists(path / "pins.md"):
      result.add path.lastPathPart
  result.sort()

proc sortedFiles(dir: string): seq[string] =
  result = @[]
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile:
      result.add path.lastPathPart
  result.sort()

proc strSeq(node: JsonNode; key: string): seq[string] =
  ## Read a string array. Guarded on ``hasKey`` on purpose: ``node{key}``
  ## returns ``nil`` for a missing key, and iterating ``nil`` is a segfault
  ## that takes the whole binary — and every later case — down with it.
  result = @[]
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return
  let child = node[key]
  if child.kind != JArray:
    return
  for item in child.items:
    if item.kind == JString:
      result.add item.getStr

proc str(node: JsonNode; key: string): string =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return ""
  let child = node[key]
  if child.kind == JString: child.getStr else: ""

proc boolean(node: JsonNode; key: string): bool =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return false
  let child = node[key]
  child.kind == JBool and child.getBool

proc certificateFromFields(fields: JsonNode): TestCertificate =
  ## Build a record from a vector's ``fields.json``.
  ##
  ## The values there are **inputs, not canonical output**: ``targets`` and
  ## ``paths`` arrive in whatever order the producer observed them and may
  ## contain duplicates, and ``key_id`` / ``paths`` / ``worktree`` are absent
  ## when they do not apply. Sorting, deduplication and omission are the
  ## serializer's job, not this reader's.
  let certificate = if fields.hasKey("certificate"): fields["certificate"] else: nil
  result = TestCertificate(
    schema: fields.str("schema"),
    framework: certificate.str("framework"),
    project: certificate.str("project"),
    platform: certificate.str("platform"),
    targets: certificate.strSeq("targets"),
    result: certificate.str("result"),
    issuedAt: certificate.str("issued_at"),
    issuer: certificate.str("issuer"),
    keyId: certificate.str("key_id"))

  let vcs = if certificate != nil and certificate.hasKey("vcs"): certificate["vcs"] else: nil
  # `paths` and `base` absent mean "does not apply"; `paths` present and
  # empty means the same as absent (vectors/README.md, Group 1).
  result.vcs = VcsState(
    repo: vcs.str("repo"),
    paths: vcs.strSeq("paths"),
    content: vcs.str("content"),
    untracked: vcs.boolean("untracked"),
    base: vcs.str("base"))

  if certificate != nil and certificate.hasKey("command"):
    let commands = certificate["command"]
    if commands.kind == JArray:
      for entry in commands.items:
        result.commands.add entry.strSeq("argv")

proc describeBytes(value: string): string =
  ## Render a payload with its line structure visible, so a one-byte
  ## disagreement is legible in the failure output rather than being a wall of
  ## identical-looking text.
  result = ""
  for line in value.split('\n'):
    result.add "  |" & line & "|\n"

# ---------------------------------------------------------------------------
# Walking: each group walk returns its cases and its failures, so a test can
# assert on a walk of ANY tree — the pinned extraction, a scratch clone's
# working tree — and not only on the one this process happens to point at.
# ---------------------------------------------------------------------------

type
  GroupWalk* = object
    cases*: seq[string]     ## the case ids walked, by name
    failures*: seq[string]  ## one human-readable entry per failed case

proc readJson(path: string): JsonNode =
  ## Parse a vector file, raising with the path on a malformed one so the
  ## failure names the case rather than only the parser position.
  try:
    parseJson(readFile(path))
  except CatchableError as err:
    raise newException(ValueError, path & ": " & err.msg)

proc walkPayload*(root: string): GroupWalk =
  ## ``payload/``: serialize each ``fields.json`` and compare byte for byte.
  let group = root / "payload"
  result.cases = sortedCaseDirs(group)
  if result.cases.len == 0:
    result.failures.add "payload/: no cases found under " & group
  for name in result.cases:
    let dir = group / name
    if not fileExists(dir / "fields.json") or not fileExists(dir / "canonical.txt"):
      result.failures.add "payload/" & name & ": missing fields.json or canonical.txt"
      continue
    let expected = readFile(dir / "canonical.txt")
    var produced = ""
    try:
      produced = canonicalPayload(certificateFromFields(readJson(dir / "fields.json")))
    except CatchableError as err:
      result.failures.add "payload/" & name & ": serialization raised " & err.msg
      continue
    if produced != expected:
      result.failures.add "payload/" & name & " diverged\nexpected:\n" &
        describeBytes(expected) & "produced:\n" & describeBytes(produced) &
        "see " & (dir / "pins.md") & " for the rule this case pins"

proc walkReceived*(root: string): GroupWalk =
  ## ``payload/escapes/received.toml`` uses CRLF, aligned ``=``, tables and
  ## keys in a different order, a TOML literal string, ``\uXXXX`` escapes and
  ## an empty signature block. Parsing it MUST produce exactly
  ## ``canonical.txt``: a verifier reconstructs the payload from the parsed
  ## **fields**, never by slicing the received file, or a cosmetically
  ## reformatted certificate would fail against its own valid signature
  ## (Canonical-Payload.md §5).
  let dir = root / "payload" / "escapes"
  result.cases = @["escapes/received.toml"]
  if not fileExists(dir / "received.toml"):
    result.failures.add "payload/escapes/received.toml is missing"
    return
  let read = readCertificate(readFile(dir / "received.toml"))
  if read.status != crsOk:
    result.failures.add "payload/escapes/received.toml did not read: " &
                        $read.status & " " & read.detail
  elif canonicalPayload(read.cert) != readFile(dir / "canonical.txt"):
    result.failures.add "payload/escapes/received.toml parsed to a different payload:\n" &
                        describeBytes(canonicalPayload(read.cert))

proc walkSignature*(root: string): GroupWalk =
  ## ``signature/``: verify each detached signature, expecting ``verify`` or
  ## ``fail`` exactly.
  let group = root / "signature"
  result.cases = sortedCaseDirs(group)
  if result.cases.len == 0:
    result.failures.add "signature/: no cases found under " & group
  for name in result.cases:
    let dir = group / name
    if not fileExists(dir / "expect.txt"):
      result.failures.add "signature/" & name & ": no expect.txt"
      continue
    let
      payload = readFile(dir / "canonical.txt")
      publicKey = readFile(dir / "key.pub").strip()
      signature = readFile(dir / "signature.b64").strip()
      expected = readFile(dir / "expect.txt").strip()
    let outcome = verifyDetachedSignature(payload, publicKey, signature)
    # `scUndecidable` is never an acceptable answer here: every input is
    # present and well-formed, so it would mean ssh-keygen could not be run.
    let wanted = if expected == "verify": scValid else: scInvalid
    if outcome.check != wanted:
      result.failures.add "signature/" & name & ": expected " & expected &
                          ", got " & $outcome.check & " (" & outcome.detail & ")"

# ---------------------------------------------------------------------------
# content/: content ids from tracked entries
# ---------------------------------------------------------------------------

proc scopeOf(node: JsonNode): seq[string] =
  ## A scope as a certificate's ``vcs.paths`` carries it: ``null``, absent
  ## and ``[]`` are all the whole repository; otherwise sorted and
  ## deduplicated.
  if node == nil or node.kind != JArray:
    return @[]
  var paths: seq[string] = @[]
  for item in node.items:
    if item.kind == JString:
      paths.add item.getStr
  sortedDeduplicated(paths)

proc readEntries(path: string): seq[ManifestEntry] =
  ## ``entries.json``: tracked entries in arbitrary order, content base64.
  let entries = readJson(path)
  if entries.kind != JArray:
    raise newException(ValueError, path & ": not a JSON array")
  for entry in entries.items:
    result.add ManifestEntry(path: entry.str("path"), mode: entry.str("mode"),
                             content: decode(entry.str("content_b64")))

const RepositoryRedirects = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
  "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_COMMON_DIR", "GIT_NAMESPACE"]

proc stagedRepository(scratch: string; entries: seq[ManifestEntry];
                      format: string): tuple[repo: string; error: string] =
  ## A scratch repository of object ``format`` (``sha1``/``sha256``) whose
  ## INDEX holds exactly ``entries`` — the README's re-derivation: every
  ## entry written as an object with ``git hash-object -w`` (a ``160000``
  ## entry is not an object; its revision is used as is) and staged at its
  ## mode and path. Nothing is checked out: the index is the state.
  let repo = scratch / ("repo-" & format)
  let init = runTool("git", ["init", "--quiet", "--object-format=" & format,
                             repo])
  if init.exitCode != 0:
    return ("", "git init --object-format=" & format & " failed: " &
                init.output.strip())
  for i, entry in entries:
    var oid = ""
    if entry.mode == "160000":
      oid = entry.content
    else:
      let blob = scratch / ("blob-" & format & "-" & $i)
      writeFile(blob, entry.content)
      # `--no-filters`: the entry's bytes are the object's bytes, whatever
      # autocrlf or attributes this machine has configured.
      let hashed = git(repo, ["hash-object", "-w", "--no-filters", "-t",
                              "blob", blob])
      if hashed.exitCode != 0:
        return ("", "git hash-object failed for `" & entry.path & "`: " &
                    hashed.output.strip())
      oid = hashed.output.strip()
    let staged = git(repo, ["update-index", "--add", "--cacheinfo",
                            entry.mode & "," & oid & "," & entry.path])
    if staged.exitCode != 0:
      return ("", "git update-index failed for `" & entry.path & "`: " &
                  staged.output.strip())
  (repo, "")

proc walkContentCase(dir, name: string; host: ContentIdHost): seq[string] =
  ## One ``content/`` case; returns its failures.
  let context = " (see " & (dir / "pins.md") & " for the rule this case pins)"
  let entries = readEntries(dir / "entries.json")
  let expected = readJson(dir / "expected.json")
  if expected.kind != JArray or expected.len == 0:
    return @["content/" & name & ": expected.json lists no ids"]
  let scratch = createTempDir("ct-test-certificate-content-", "")
  defer:
    try: removeDir(scratch)
    except OSError: discard
  var repos: seq[(string, string)] = @[]   # object format -> repository
  proc repositoryFor(format: string): tuple[repo: string; error: string] =
    for (known, repo) in repos:
      if known == format:
        return (repo, "")
    result = stagedRepository(scratch, entries, format)
    if result.error.len == 0:
      repos.add (format, result.repo)

  for want in expected.items:
    let algorithmName = want.str("algorithm")
    let scope = scopeOf(if want.hasKey("paths"): want["paths"] else: nil)
    let label = "content/" & name & " " & algorithmName & " over " &
                (if scope.len == 0: "the whole repository" else: $scope)
    let (known, algorithm) = lookupAlgorithm(algorithmName)
    if not known:
      result.add label & ": an algorithm this walker does not implement" &
                 context
      continue
    var produced: ContentIdResult
    case algorithm
    of caManifestV1Sha256:
      produced = manifestV1Sha256(entries, scope)
    of caGitTreeSha1, caGitTreeSha256:
      let format = if algorithm == caGitTreeSha1: "sha1" else: "sha256"
      let staged = repositoryFor(format)
      if staged.error.len > 0:
        result.add label & ": " & staged.error & context
        continue
      produced = computeContentId(host, staged.repo, indexState(), algorithm,
                                  scope)
    if produced.outcome != cioComputed:
      result.add label & ": no id (" & $produced.outcome & "): " &
                 produced.reason & context
    elif produced.id != want.str("id"):
      result.add label & ": expected " & want.str("id") & ", computed " &
                 produced.id & context

proc walkContent*(root: string): GroupWalk =
  ## ``content/``: every id in ``expected.json``, computed from
  ## ``entries.json``. All three algorithms are implemented, so none is
  ## skipped (a consumer that implements an algorithm and skips its vectors
  ## has tested nothing).
  let group = root / "content"
  result.cases = sortedCaseDirs(group)
  if result.cases.len == 0:
    result.failures.add "content/: no cases found under " & group
  # A caller's repository must not redirect the scratch repositories' git
  # (a hook exporting GIT_INDEX_FILE would make the index state read ITS
  # index). The library's host inherits the environment by design, so the
  # redirects are removed from this test process before it runs.
  for variable in RepositoryRedirects:
    delEnv(variable)
  let host = nativeContentIdHost()
  for name in result.cases:
    try:
      result.failures.add walkContentCase(group / name, name, host)
    except CatchableError as err:
      result.failures.add "content/" & name & ": raised " & err.msg

# ---------------------------------------------------------------------------
# store/: where the local certificate store keeps a certificate
# ---------------------------------------------------------------------------

proc storePathOf*(text: string): tuple[path: string; error: string] =
  ## ``v1/<algorithm>/<digest>/<payload-hash>.toml`` (Transport.md §2.2):
  ## the payload rebuilt from the PARSED fields — never the file's bytes, and
  ## never the signature block — hashed with SHA-256, and ``vcs.content``
  ## split at its FIRST ``:``.
  let read = readCertificate(text)
  if read.status != crsOk:
    return ("", "did not read: " & $read.status & " " & read.detail)
  let payload = canonicalPayload(read.cert)
  let content = read.cert.vcs.content
  let colon = content.find(':')
  if colon <= 0:
    return ("", "vcs.content `" & content & "` has no algorithm")
  ("v1/" & content[0 ..< colon] & "/" & content[colon + 1 .. ^1] & "/" &
   sha256Hex(payload) & ".toml", "")

proc walkStore*(root: string): GroupWalk =
  ## ``store/``: derive each certificate's store path and compare it with
  ## ``expected-path.txt`` (one line, its single LF not part of the path).
  let group = root / "store"
  result.cases = sortedCaseDirs(group)
  if result.cases.len == 0:
    result.failures.add "store/: no cases found under " & group
  for name in result.cases:
    let dir = group / name
    let context = " (see " & (dir / "pins.md") & " for the rule this case pins)"
    try:
      let expectedPath = readFile(dir / "expected-path.txt")
      if not expectedPath.endsWith("\n") or expectedPath.count('\n') != 1:
        result.failures.add "store/" & name &
          ": expected-path.txt is not one LF-terminated line" & context
        continue
      let text = readFile(dir / "certificate.toml")
      let derived = storePathOf(text)
      if derived.error.len > 0:
        result.failures.add "store/" & name & ": " & derived.error & context
        continue
      if derived.path != expectedPath[0 ..< ^1]:
        var note = ""
        # canonical.txt is a diagnostic, not an input: it shows where a
        # mismatch starts.
        if fileExists(dir / "canonical.txt"):
          let rebuilt = canonicalPayload(readCertificate(text).cert)
          if rebuilt != readFile(dir / "canonical.txt"):
            note = "\nthe rebuilt payload differs from canonical.txt:\n" &
                   describeBytes(rebuilt)
        result.failures.add "store/" & name & ": expected " &
          expectedPath[0 ..< ^1] & ", derived " & derived.path & note & context
    except CatchableError as err:
      result.failures.add "store/" & name & ": raised " & err.msg

proc namesOf(notes: seq[CertificateNote]): seq[string] =
  result = @[]
  for note in notes:
    result.add note.certificate
  result.sort()

proc expectedNames(expected: JsonNode; key: string): seq[string] =
  result = @[]
  if expected.hasKey(key) and expected[key].kind == JArray:
    for entry in expected[key].items:
      result.add entry.str("certificate")
  result.sort()

proc walkVerifyCase(dir, name: string): seq[string] =
  ## One ``verify/`` case; returns its failures.
  if not fileExists(dir / "expected.json"):
    return @["verify/" & name & ": no expected.json"]
  let
    stateJson = readJson(dir / "state.json")
    requirementJson = readJson(dir / "requirement.json")
    expected = readJson(dir / "expected.json")

  # The content oracle is `state.json`'s `content` list: the ids this
  # consumer can compute for the state, per algorithm and scope. A pair it
  # does not list is one this consumer CANNOT compute — unevaluated, never a
  # mismatch (Verification.md §4.1.1). `commit` is informational, and nothing
  # here reads it.
  var known: seq[tuple[algorithm: string; paths: seq[string]; id: string]] = @[]
  if stateJson.hasKey("content") and stateJson["content"].kind == JArray:
    for entry in stateJson["content"].items:
      known.add (entry.str("algorithm"),
                 scopeOf(if entry.hasKey("paths"): entry["paths"] else: nil),
                 entry.str("id"))
  let state = EvaluatedState(
    repo: stateJson.str("repo"),
    content: proc(algorithm: string; paths: seq[string]): ContentAnswer
        {.closure, gcsafe.} =
      for entry in known:
        if entry.algorithm == algorithm and entry.paths == paths:
          return ContentAnswer(computed: true, id: entry.id)
      ContentAnswer(computed: false,
        reason: "state.json lists no " & algorithm & " id over " &
                (if paths.len == 0: "the whole repository" else: $paths)))

  var requirement = Requirement(
    frameworksImplemented: requirementJson.strSeq("frameworks_implemented"),
    framework: requirementJson.str("framework"),
    targets: requirementJson.strSeq("targets"),
    platforms: requirementJson.strSeq("platforms"),
    requireSignature: requirementJson.boolean("require_signature"),
    paths: @[],
    pathsGiven: false)
  # `paths: null` means the whole repository, which is a *stronger* demand
  # than any scoped certificate satisfies — so null and [] are not the same
  # requirement and must not be conflated.
  if requirementJson.hasKey("paths") and requirementJson["paths"].kind == JArray:
    requirement.paths = requirementJson.strSeq("paths")
    requirement.pathsGiven = true

  var candidates: seq[CandidateCertificate] = @[]
  for fileName in sortedFiles(dir / "certificates"):
    candidates.add CandidateCertificate(
      name: fileName, text: readFile(dir / "certificates" / fileName))

  var store = KeyStore(readable: true)
  if fileExists(dir / "registered-keys.toml"):
    store = readKeyStore(readFile(dir / "registered-keys.toml"))

  let report = verifyCertificates(state, requirement, candidates, store,
                                  sshKeygenSignatureVerifier())
  let context = " (see " & (dir / "pins.md") & " for the rule this case pins)"

  if $report.outcome != expected.str("outcome"):
    result.add "verify/" & name & ": expected " & expected.str("outcome") &
               ", got " & $report.outcome & " — " & report.reason & context

  # `missing` is normative in content: a consumer must report which target,
  # on which platform, for which framework — not a bare pass/fail.
  var producedGaps: seq[string] = @[]
  for gap in report.missing:
    producedGaps.add gap.framework & "|" & gap.platform & "|" &
                      gap.targets.join(",")
  producedGaps.sort()
  var expectedGaps: seq[string] = @[]
  if expected.hasKey("missing") and expected["missing"].kind == JArray:
    for gap in expected["missing"].items:
      var targets = gap.strSeq("targets")
      targets.sort()
      expectedGaps.add gap.str("framework") & "|" & gap.str("platform") &
                        "|" & targets.join(",")
  expectedGaps.sort()
  if producedGaps != expectedGaps:
    result.add "verify/" & name & ": missing was " & $producedGaps &
               ", expected " & $expectedGaps & context

  # The three fates are normative in *which* certificates they name.
  for (fate, produced) in [("ignored", namesOf(report.ignored)),
                           ("rejected", namesOf(report.rejected)),
                           ("unevaluated", namesOf(report.unevaluated))]:
    let wanted = expectedNames(expected, fate)
    if produced != wanted:
      result.add "verify/" & name & ": " & fate & " was " & $produced &
                 ", expected " & $wanted & context

proc walkVerify*(root: string): GroupWalk =
  ## ``verify/``: the three-valued outcome and the three fates.
  let group = root / "verify"
  result.cases = sortedCaseDirs(group)
  if result.cases.len == 0:
    result.failures.add "verify/: no cases found under " & group
  for name in result.cases:
    try:
      result.failures.add walkVerifyCase(group / name, name)
    except CatchableError as err:
      result.failures.add "verify/" & name & ": raised " & err.msg

proc crossCheckIndex*(root: string; walked: openArray[string]): seq[string] =
  ## Compare ``index.json`` with the tree and with the walker. Returns one
  ## failure per disagreement:
  ##
  ## * a group ``index.json`` declares that is not in ``walked`` — named, with
  ##   its case count, because those cases would otherwise test nothing;
  ## * a walked group ``index.json`` does not declare;
  ## * a walked group whose listed cases differ from the case directories on
  ##   disk.
  result = @[]
  let indexPath = root / "index.json"
  if not fileExists(indexPath):
    return @["no index.json at " & indexPath]
  var index: JsonNode
  try:
    index = readJson(indexPath)
  except ValueError as err:
    return @["index.json is not valid JSON: " & err.msg]
  if index.kind != JObject or not index.hasKey("groups") or
      index["groups"].kind != JObject:
    return @["index.json has no `groups` object"]
  let groups = index["groups"]
  let walkedSet = toHashSet(walked)

  for group, entries in groups.pairs:
    if group notin walkedSet:
      let count = if entries.kind == JArray: entries.len else: 0
      result.add "group `" & group & "` (" & $count & " cases) is declared " &
                 "by index.json but this walker does not walk it"

  for group in walked:
    if not groups.hasKey(group):
      result.add "group `" & group & "` is walked but index.json does not declare it"
      continue
    var listed: seq[string] = @[]
    if groups[group].kind == JArray:
      for entry in groups[group].items:
        listed.add entry.str("name")
    listed.sort()
    let onDisk = sortedCaseDirs(root / group)
    if listed != onDisk:
      result.add "group `" & group & "`: index.json lists " & $listed &
                 " but the case directories on disk are " & $onDisk

type
  VectorsWalk* = object
    ## Everything one walk of a ``vectors`` tree found.
    index*: seq[string]  ## the index cross-check's failures
    payload*, received*, signature*, content*, verify*, store*: GroupWalk

proc walkVectors*(root: string): VectorsWalk =
  VectorsWalk(index: crossCheckIndex(root, WalkedGroups),
              payload: walkPayload(root), received: walkReceived(root),
              signature: walkSignature(root), content: walkContent(root),
              verify: walkVerify(root), store: walkStore(root))

proc caseCount*(walk: VectorsWalk): int =
  walk.payload.cases.len + walk.received.cases.len +
    walk.signature.cases.len + walk.content.cases.len +
    walk.verify.cases.len + walk.store.cases.len

proc failures*(walk: VectorsWalk): seq[string] =
  walk.index & walk.payload.failures & walk.received.failures &
    walk.signature.failures & walk.content.failures & walk.verify.failures &
    walk.store.failures

# ---------------------------------------------------------------------------
# Locating the tree this run walks
# ---------------------------------------------------------------------------

type
  VectorsSource = object
    root: string            ## the `vectors` directory to walk ("" = none)
    pinned: bool
    pin: string
    extraction: ExtractedVectors
    error: string

proc locateVectors(): VectorsSource =
  ## The explicit override first (unpinned, and said so), otherwise the
  ## sibling repository's object store at the pin.
  let override = getEnv(VectorsOverrideVariable)
  if override.len > 0:
    echo "    UNPINNED walk: ", VectorsOverrideVariable, "=", override,
         " — the vectors pin (", PinFileName, ") is NOT applied"
    # CI must walk the pin. An override that leaked into a CI environment
    # would turn the job into an unpinned walk that can still go green, so
    # there it is refused outright rather than only logged.
    if getEnv("CI").len > 0 or getEnv("GITHUB_ACTIONS").len > 0:
      return VectorsSource(error: VectorsOverrideVariable & " is set under " &
        "CI; an unpinned walk is refused there. Unset it so the vectors are " &
        "read at the pin in " & PinFileName)
    if not fileExists(override / "index.json"):
      return VectorsSource(error: VectorsOverrideVariable & " points at " &
        override & ", which has no index.json")
    return VectorsSource(root: override)
  let (pin, pinError) = readPin(pinFilePath())
  if pinError.len > 0:
    return VectorsSource(error: pinError)
  let extraction = extractVectorsAt(specRepositoryPath(), pin)
  if not extraction.ok:
    return VectorsSource(pin: pin, error: extraction.error)
  echo "    walking ", SpecRepositoryName, " vectors at the pin ", pin,
       " (git archive from ", specRepositoryPath(), ")"
  VectorsSource(root: extraction.vectors, pinned: true, pin: pin,
                extraction: extraction)

proc walkAndDiscard(source: VectorsSource): VectorsWalk =
  ## Walk ``source`` and, when the tree is a pinned extraction, remove the
  ## temporary directory before returning — whether or not the walk raised.
  ##
  ## Every case reads the returned ``VectorsWalk``; nothing touches the tree
  ## after this, so the extraction lives exactly as long as this call.
  ##
  ## That is deliberately NOT an exit hook. The suite used to register
  ## ``addExitProc proc() = discardVectors(source.extraction)`` from inside
  ## the ``suite`` block, where ``source`` is a block-scoped variable: the
  ## closure did not keep it alive, ORC destroyed it at the end of the block,
  ## and the hook later read freed memory as the directory to delete. When
  ## that garbage happened to be a path with an embedded NUL, ``removeDir``
  ## recursed until "call depth limit reached" and the binary exited 1 after
  ## every case had passed; garbage spelling an existing directory would
  ## have been deleted.
  if source.root.len == 0:
    return VectorsWalk()
  try:
    result = walkVectors(source.root)
  finally:
    discardVectors(source.extraction)

proc reportGroup(label: string; walk: GroupWalk) =
  echo "    walking ", walk.cases.len, " ", label, " cases: ",
       walk.cases.join(", ")
  for failure in walk.failures:
    checkpoint failure

# ---------------------------------------------------------------------------
# The suites
# ---------------------------------------------------------------------------

suite "test-certificate conformance vectors":
  let source = locateVectors()
  let walk = walkAndDiscard(source)

  test "the conformance vectors are present at the pin":
    ## A missing sibling or an unfetched pin fails here, once, loudly — rather
    ## than turning every case below into a silent pass.
    if source.error.len > 0:
      echo "    ", source.error
    check source.error.len == 0
    check source.root.len > 0

  test "index.json declares exactly the groups and cases this walker walks":
    ## A case — or a whole group — that has silently gone missing is one that
    ## stops testing anything (``vectors/README.md``).
    require source.root.len > 0
    for failure in walk.index:
      checkpoint failure
    check walk.index.len == 0

  test "payload vectors serialize byte-for-byte":
    require source.root.len > 0
    reportGroup("payload", walk.payload)
    check walk.payload.cases.len > 0
    check walk.payload.failures.len == 0

  test "a non-canonical rendering parses to the canonical payload":
    require source.root.len > 0
    for failure in walk.received.failures:
      checkpoint failure
    check walk.received.failures.len == 0

  test "signature vectors verify, or fail, exactly as expected":
    require source.root.len > 0
    reportGroup("signature", walk.signature)
    check walk.signature.cases.len > 0
    check walk.signature.failures.len == 0

  test "content-id vectors: every expected id is computed, in every algorithm":
    ## Content-Id.md §4 through CTC-3b's library: ``manifest-v1-sha256`` over
    ## the entries, ``git-tree-*`` by real git in scratch repositories of
    ## each object format.
    require source.root.len > 0
    reportGroup("content", walk.content)
    check walk.content.cases.len > 0
    check walk.content.failures.len == 0

  test "verification vectors produce the expected three-valued outcome":
    require source.root.len > 0
    reportGroup("verification", walk.verify)
    check walk.verify.cases.len > 0
    check walk.verify.failures.len == 0

  test "store-path vectors: each certificate lands at its content-addressed path":
    ## Transport.md §2.2: the payload is hashed, not the file — so a
    ## non-canonical rendering, and a signed record with or without its
    ## block, land on one name.
    require source.root.len > 0
    reportGroup("store", walk.store)
    check walk.store.cases.len > 0
    check walk.store.failures.len == 0

  test "the extracted vectors are removed once walked, leaving no cleanup for exit":
    ## The temporary directory is gone before the first case reads the walk,
    ## so nothing has to outlive this block to remove it (see
    ## ``walkAndDiscard`` for the use-after-free an exit hook caused).
    require source.root.len > 0
    if source.pinned:
      check source.extraction.scratch.len > 0
      check not dirExists(source.extraction.scratch)
      check not dirExists(source.root)

  if source.root.len > 0:
    echo "    ", walk.caseCount, " conformance cases walked",
         (if source.pinned: " at " & source.pin else: " (UNPINNED)")

suite "the vectors pin":
  ## These exercise the pin mechanism itself, against the real sibling's
  ## object store (read only) and against scratch clones of it.
  let repository = specRepositoryPath()
  let (pin, pinError) = readPin(pinFilePath())

  test "the pin file holds one full commit id":
    checkpoint pinError
    check pinError.len == 0

  test "a malformed pin file is refused, naming the file":
    let scratch = createTempDir("ct-test-certificate-pin-", "")
    defer: removeDir(scratch)
    for (label, content) in [("abbreviated", "d57e837\n"),
                             ("empty", ""),
                             ("two lines", pin & "\n" & pin & "\n"),
                             ("uppercase", pin.toUpperAscii & "\n"),
                             ("leading space", " " & pin & "\n")]:
      let path = scratch / "pin"
      writeFile(path, content)
      let read = readPin(path)
      checkpoint label & ": " & read.error
      check read.pin.len == 0
      check path in read.error
    check readPin(scratch / "absent").error.len > 0

  test "a pin absent from the object store fails loudly, naming the pin and the fetch remedy":
    ## Well-formed, but no repository will ever contain it.
    let absent = "0123456789abcdef0123456789abcdef01234567"
    let extracted = extractVectorsAt(repository, absent)
    checkpoint extracted.error
    check not extracted.ok
    check absent in extracted.error
    check "fetch" in extracted.error
    check extracted.vectors.len == 0
    check extracted.scratch.len == 0   # nothing was created to walk

  test "the walk does not depend on the sibling's checkout":
    ## A scratch clone of the sibling (``--shared``: it borrows the sibling's
    ## objects and never writes to them) is checked out at the pin, and one
    ## vectors file in its WORKING TREE is corrupted without committing.
    ## Walking that working tree must fail — proving the corruption is one the
    ## walker sees — while the pinned extraction from the same clone stays
    ## green with the same case count as the extraction from the sibling.
    require pinError.len == 0
    let baseline = extractVectorsAt(repository, pin)
    checkpoint baseline.error
    require baseline.ok
    let baselineWalk = walkVectors(baseline.vectors)
    discardVectors(baseline)
    check baselineWalk.failures.len == 0

    let scratch = createTempDir("ct-test-certificate-clone-", "")
    defer: removeDir(scratch)
    let clone = scratch / SpecRepositoryName
    let cloned = runTool("git", ["clone", "--quiet", "--shared", "--no-checkout",
                                 repository, clone])
    checkpoint cloned.output
    require cloned.exitCode == 0
    let checkedOut = git(clone, ["checkout", "--quiet", "--detach", pin])
    checkpoint checkedOut.output
    require checkedOut.exitCode == 0

    let corrupted = clone / "vectors" / "payload" / "minimal" / "canonical.txt"
    require fileExists(corrupted)
    writeFile(corrupted, readFile(corrupted) & "corrupted = true\n")

    let checkoutWalk = walkVectors(clone / "vectors")
    check checkoutWalk.failures.len > 0   # the corruption is visible there

    let extracted = extractVectorsAt(clone, pin)
    checkpoint extracted.error
    require extracted.ok
    let pinnedWalk = walkVectors(extracted.vectors)
    for failure in pinnedWalk.failures:
      checkpoint failure
    check pinnedWalk.failures.len == 0
    check pinnedWalk.caseCount == baselineWalk.caseCount
    check pinnedWalk.caseCount > 0
    discardVectors(extracted)
    check not dirExists(extracted.scratch)

  test "a group index.json declares and the walker does not walk fails the suite":
    ## At the pin the walker walks every group the standard declares, so the
    ## cross-check is silent. The guard is then shown for EACH group:
    ## dropping any one of them from the walked set — the mutation an
    ## incomplete walker amounts to — fails, naming exactly that group and
    ## its case count. (Before CTC-3c this test instead extracted a revision
    ## newer than the pin and asserted it named `content` and `store`; the
    ## pin now IS that revision's successor, so there is no unwalked group
    ## left to name.)
    require pinError.len == 0
    let atPin = extractVectorsAt(repository, pin)
    checkpoint atPin.error
    require atPin.ok
    let complete = crossCheckIndex(atPin.vectors, WalkedGroups)
    var dropped: seq[tuple[group: string; failures: seq[string]]] = @[]
    for group in WalkedGroups:
      var rest: seq[string] = @[]
      for other in WalkedGroups:
        if other != group:
          rest.add other
      dropped.add (group, crossCheckIndex(atPin.vectors, rest))
    let declared = readJson(atPin.vectors / "index.json")["groups"]
    discardVectors(atPin)
    for failure in complete:
      checkpoint failure
    check complete.len == 0
    for (group, failures) in dropped:
      checkpoint group & ": " & $failures
      let count = declared[group].len
      check failures.len == 1
      check failures.len == 1 and
            ("`" & group & "` (" & $count & " cases)") in failures[0] and
            "this walker does not walk it" in failures[0]
