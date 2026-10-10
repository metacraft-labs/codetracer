## CTC-3e — `ct test` publishes to the user's local certificate store.
##
## Replaces ``certificate_default_store_test.nim`` (CTC-2's workspace store at
## ``.ct/certificates``), which was retired with that store on 2026-10-10; the
## milestone records which of its cases moved here, which were inverted and
## which were dropped with the ignore guard they tested.
##
## The chain is real end to end. The CLI cases drive the shipped entry point
## (`ct_test.runCtTest`, the proc `ct test run` reaches) against real git
## repositories in a temporary directory, with ``TEST_CERTIFICATES_DIR``
## pointed at a scratch root: real discovery, the real worker pool, real git,
## the real `issueCertificate`, the real publish into a real directory tree,
## and the shipped reader (`certificate_store.readCertificateStore` /
## `lookupLocalStore`) reading it back. The concurrency cases run real
## concurrent PROCESSES — this test binary re-invoked in a writer or a pruner
## role — against one real root, while this process reads it.
##
## MOCKING POLICY (CLAUDE.md requires every mock to be justified here)
## -------------------------------------------------------------------
## * **The in-process fixture provider.** A `ct test` run needs a provider
##   that can actually RUN something, and every shipped provider needs a
##   language toolchain CI may not have, which would make this suite's subject
##   "is node installed" rather than "where does the record land". The fixture
##   supplies exactly what a language adapter supplies — `detect`,
##   `discoverProject`, `run` — and reports a pass for the test it really was
##   asked to run. Nothing in discovery, orchestration, issuance or publication
##   is stubbed. The same seam ``certificate_issuance_test.nim`` justifies.
##
## * **The indicator's fact reader, in the end-to-end case only.** The status
##   bar gathers its facts through the platform facade, which needs a Platform
##   installed and belongs to the ViewModel lanes (covered there by
##   ``certificate_indicator_native_test.nim`` against a real repository and
##   a real local store). Here W is computed over the same real repository by
##   the same content-id recipe the facade drives, and everything downstream
##   — the local-store lookup, the verifier, the evaluator — is shipped code.
##
## ENVIRONMENT
## -----------
## `getTempDir()` MUST NOT be inside a git repository (asserted in the first
## case). Every case points ``TEST_CERTIFICATES_DIR`` and
## ``TEST_CERTIFICATES_SYSTEM_DIR`` at scratch directories, so nothing here can
## write or read the user's real store.

import std/[algorithm, json, options, os, osproc, sequtils, streams, strtabs,
            strutils, times, unittest]

import contracts
import certificate
import certificate_content_id
import certificate_content_id_native
import certificate_issuance
import certificate_local_store
import certificate_store
import ct_test
import discovery

import ../frontend/viewmodel/viewmodels/certificate_indicator_vm

# ---------------------------------------------------------------------------
# Child roles. The concurrency cases re-invoke this binary; a child does its
# one job and exits before any suite runs.
# ---------------------------------------------------------------------------

const RoleVariable = "CT_LOCAL_STORE_TEST_ROLE"

proc childRoots(root: string): CertificateStoreRoots =
  CertificateStoreRoots(available: true, user: root, system: "")

if getEnv(RoleVariable) == "publish":
  # Publish the document in $DOC $COUNT times; print one line per failure
  # and the retry count, exit 1 on any failure.
  let root = getEnv("CT_LS_ROOT")
  let document = readFile(getEnv("CT_LS_DOC"))
  let workspace = getEnv("CT_LS_WORKSPACE")
  var failures = 0
  var retries = 0
  for i in 1 .. parseInt(getEnv("CT_LS_COUNT")):
    let outcome = publishToLocalStore(childRoots(root), workspace, document)
    if outcome.retried: inc retries
    if not outcome.written:
      inc failures
      echo "FAILED: ", outcome.error
  echo "retries=", retries
  quit(if failures == 0: 0 else: 1)

if getEnv(RoleVariable) == "prune":
  # Prune with no retention at all until the stop file appears.
  let root = getEnv("CT_LS_ROOT")
  let stop = getEnv("CT_LS_STOP")
  var rounds = 0
  while not fileExists(stop):
    discard pruneLocalStore(root, 0, [])
    inc rounds
  echo "rounds=", rounds
  quit(0)

# ---------------------------------------------------------------------------
# Countable assertions (`ci/lib/run-nim-test-lane.sh` scores CHECKS).
# ---------------------------------------------------------------------------
var checksRun = 0

template ck(condition: untyped) =
  inc checksRun
  check condition

# ---------------------------------------------------------------------------
# The in-process fixture provider
# ---------------------------------------------------------------------------

const
  FixtureProviderId = "fixture-local-store"
  FixtureLanguage = "fixture"
  FixtureFramework = "inproc"
  FixtureTestFile = "tests/calc_test.fixture"

proc fixtureInfo(): TestProviderInfo =
  TestProviderInfo(
    id: FixtureProviderId, language: FixtureLanguage,
    framework: FixtureFramework,
    displayName: "In-process local-store fixture provider", version: "test",
    capabilities: TestCapabilities(
      canDiscoverProject: true, canDiscoverFile: true, canLocateTests: true,
      canRunProject: true, canRunFile: true, canRunSingle: true,
      canCapturePerTestOutput: true, emitsStructuredEvents: true))

proc fixtureItem(): TestItem =
  TestItem(
    id: makeTestItemId(FixtureProviderId, FixtureLanguage, FixtureFramework,
                       FixtureTestFile, FixtureTestFile & "::adds"),
    providerId: FixtureProviderId, language: FixtureLanguage,
    framework: FixtureFramework, name: "adds", kind: tikCase,
    file: FixtureTestFile,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 2),
    selector: FixtureTestFile & "::adds", tags: @["fixture"],
    location: LocationProvenance(source: lskPattern,
      detail: "in-process fixture", confidence: lcHigh))

proc fixtureRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](diagnostics: @[], value: @[
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId, status: some(tsPassed), durationMs: 1)])

proc fixtureDetect(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
  ProviderResult[bool](value: fileExists(projectRoot / FixtureTestFile))

proc fixtureDiscoverProject(projectRoot: string):
    ProviderResult[TestCatalog] {.gcsafe.} =
  ProviderResult[TestCatalog](value: TestCatalog(
    schemaVersion: TestCatalogSchemaVersion, provider: fixtureInfo(),
    items: (if fileExists(projectRoot / FixtureTestFile): @[fixtureItem()]
            else: @[])))

proc fixtureRegistry(): ProviderRegistry =
  var provider = TestProvider(info: fixtureInfo())
  provider.detect = fixtureDetect
  provider.discoverProject = fixtureDiscoverProject
  provider.run = fixtureRun
  ProviderRegistry(providers: @[
    M1Provider(provider: provider, relevantConfigFiles: @[])])

# ---------------------------------------------------------------------------
# Scratch space, repositories and the store root
# ---------------------------------------------------------------------------

let scratchRoot = getTempDir() / "ct-cert-local-store-" &
                  $getCurrentProcessId()

proc run(cmd: string; args: openArray[string]; cwd: string):
    tuple[output: string; code: int] =
  var p = startProcess(cmd, workingDir = cwd, args = @args,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc scratchDir(name: string): string =
  result = scratchRoot / name
  removeDir(result)
  createDir(result)

proc useStoreRoot(name: string): string =
  ## Point both store variables at fresh scratch locations for this case. The
  ## user root is NOT created: the producer creates it.
  result = scratchRoot / "stores" / name / "user-root"
  removeDir(scratchRoot / "stores" / name)
  createDir(scratchRoot / "stores" / name)
  putEnv("TEST_CERTIFICATES_DIR", result)
  putEnv("TEST_CERTIFICATES_SYSTEM_DIR", scratchRoot / "stores" / name /
         "system")

proc gitStatus(repo: string): string =
  run("git", ["status", "--porcelain=v1", "--untracked-files=normal"],
      repo).output.strip()

proc headTree(repo: string): string =
  run("git", ["rev-parse", "HEAD^{tree}"], repo).output.strip()

proc headCommit(repo: string): string =
  run("git", ["rev-parse", "HEAD"], repo).output.strip()

proc committedRepo(name: string): string =
  ## A repository holding exactly one fixture test file, committed, and no
  ## `.gitignore`: nothing may keep the run from dirtying the tree except the
  ## producer writing nothing into it.
  result = scratchDir(name)
  createDir(result / "tests")
  writeFile(result / FixtureTestFile, "adds\n")
  discard run("git", ["init", "--initial-branch=main", "."], result)
  discard run("git", ["config", "user.email", "ctc3e@example.invalid"], result)
  discard run("git", ["config", "user.name", "ctc3e suite"], result)
  discard run("git", ["config", "commit.gpgsign", "false"], result)
  discard run("git", ["add", "-A"], result)
  discard run("git", ["commit", "-m", "initial"], result)

proc summaryPathFor(name: string): string =
  ## Outside the workspace, so the suite's own output is not an untracked
  ## file in the tree whose cleanliness it measures.
  scratchRoot / "summaries" / name & ".json"

proc runCli(repo, name: string; extra: seq[string] = @[]):
    tuple[code: int; summary: JsonNode] =
  let path = summaryPathFor(name)
  createDir(parentDir(path))
  removeFile(path)
  let code = runCtTest(
    @["test", "run", "--workspace", repo, "--threads", "1",
      "--summary", path] & extra,
    fixtureRegistry(), newDiscoveryCache())
  var summary = newJObject()
  if fileExists(path):
    summary = parseJson(readFile(path))
  (code, summary)

proc storeFiles(root: string): seq[string] =
  ## Every file under ``root``, store-relative, sorted — temporaries included.
  result = @[]
  if dirExists(root):
    for path in walkDirRec(root):
      result.add path.relativePath(root).replace(DirSep, '/')
  result.sort()

proc workingTreeId(repo: string): string =
  let computed = computeContentId(nativeContentIdHost(), repo,
                                  workingTreeState(), caGitTreeSha1)
  if computed.outcome == cioComputed: computed.id else: ""

proc nativeRoots(): CertificateStoreRoots = nativeCertificateStoreRoots()

proc stateOracle(repo: string; state: ContentState): ContentOracle =
  ## One content state (W, H or S) computed by the content-id recipe the
  ## platform facade drives, over the real repository.
  result = proc(algorithm: string; paths: seq[string]): ContentAnswer
      {.closure.} =
    let (known, parsed) = lookupAlgorithm(algorithm)
    if not known:
      return ContentAnswer(computed: false, reason: "unknown algorithm")
    let computed = computeContentId(nativeContentIdHost(), repo, state,
                                    parsed, paths)
    if computed.outcome == cioComputed:
      ContentAnswer(computed: true, id: computed.id)
    else:
      ContentAnswer(computed: false, reason: computed.reason)

proc indicatorFor(repo: string): CertificateIndicatorModel =
  ## The shipped evaluator over the shipped reader, looking W, H and S up in
  ## the local store the way the indicator source does.
  let states = [stateOracle(repo, workingTreeState()),
                stateOracle(repo, commitState("HEAD")),
                stateOracle(repo, indexState())]
  var ids: seq[string] = @[]
  for state in states:
    let answer = state("git-tree-sha1", @[])
    if answer.computed and answer.id notin ids:
      ids.add answer.id
  evaluateCertificateIndicator(CertificateIndicatorFacts(
    store: readCertificateStore(nativeStoreAccess(), repo, LocalStoreQuery(
      roots: nativeRoots(), contentIds: ids)),
    vcs: WorkspaceVcsState(known: true, repo: repo.lastPathPart,
                           workingTree: states[0], head: states[1],
                           index: states[2]),
    platform: currentPlatform(),
    signatureVerifier: nil))

proc sampleDocument(content: string; platform = "linux/amd64";
                    signature = ""): string =
  var cert = TestCertificate(
    schema: CertificateSchema, framework: "ct-test", project: "demo",
    platform: platform, targets: @["tests/calc_test.fixture"],
    result: "passed", issuedAt: "2026-10-10T09:00:00Z", issuer: "ct-test",
    vcs: VcsState(repo: "demo", content: content, untracked: false),
    commands: @[@["ct", "test", "run"]])
  if signature.len > 0:
    cert.keyId = "example-key"
    cert.signature = CertificateSignature(algorithm: SignatureAlgorithm,
                                          value: signature)
  renderCertificate(cert)

proc bulkyDocument(content, platform: string): string =
  ## A record of about a megabyte (many attested commands), so a write takes
  ## long enough for a polling reader to land inside it if the writer ever
  ## exposed a partial file under a name a reader picks up.
  ## Signed (with a placeholder value: the store never verifies), so every
  ## publish REPLACES the file and every one of them is a write to observe.
  var cert = readCertificate(sampleDocument(content, platform,
                                            signature = "U1NIU0lH")).cert
  for i in 0 ..< 4000:
    cert.commands.add @["ct", "test", "run", "--partition",
                        "file:" & "p".repeat(200) & $i]
  renderCertificate(cert)

proc contentFor(i: int): string =
  "git-tree-sha1:" & toHex(i, 40).toLowerAscii

proc sha256Of(data: string): string =
  ## An INDEPENDENT SHA-256: coreutils' `sha256sum`, not the product's.
  let input = scratchRoot / "sha256-input"
  writeFile(input, data)
  run("sha256sum", [input], scratchRoot).output.split(' ')[0]

proc removeScratchRoot() =
  ## Called at module level once the suite has run — NOT from an exit hook:
  ## `scratchRoot` is a module-level `let` whose destructor runs before exit
  ## hooks under ORC (see 5175da85f).
  try: removeDir(scratchRoot)
  except CatchableError: discard

proc spawnSelf(env: openArray[(string, string)]): Process =
  var table = newStringTable()
  for key, value in envPairs():
    table[key] = value
  for (key, value) in env:
    table[key] = value
  startProcess(getAppFilename(), env = table,
               options = {poStdErrToStdOut})

# ---------------------------------------------------------------------------

suite "CTC-3e: the local certificate store":

  test "the temporary directory is outside any git repository":
    let probe = scratchDir("environment-check")
    let toplevel = run("git", ["rev-parse", "--show-toplevel"], probe)
    if toplevel.code == 0:
      echo "TMPDIR is inside a git repository (", toplevel.output.strip(), ")."
    ck toplevel.code != 0

  test "the store root follows TEST_CERTIFICATES_DIR, then the platform default":
    ## The resolver over injected environments, so every platform's answer is
    ## checked on this one (`certificate_store_roots`, SB-2a's, reused rather
    ## than duplicated), and the native resolver `ct test` publishes through.
    proc env(pairs: openArray[(string, string)]): StoreEnvironment =
      let captured = @pairs
      result = proc(name: string): string =
        for (key, value) in captured:
          if key == name: return value
        ""
    # The override wins on every platform.
    for platform in [srpUnix, srpMacos]:
      ck resolveCertificateStoreRoots(platform, env({
        "TEST_CERTIFICATES_DIR": "/srv/certs", "HOME": "/home/u",
        "XDG_STATE_HOME": "/home/u/state"}), "1000").user == "/srv/certs"
    ck resolveCertificateStoreRoots(srpWindows, env({
      "TEST_CERTIFICATES_DIR": "D:\\certs",
      "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local"}), "S-1").user ==
      "D:\\certs"
    # Linux/BSD: XDG_STATE_HOME, then ~/.local/state; a relative value of
    # either variable is ignored and reported.
    ck resolveCertificateStoreRoots(srpUnix, env({
      "HOME": "/home/u", "XDG_STATE_HOME": "/home/u/state"}), "1000").user ==
      "/home/u/state/test-certificates"
    let relative = resolveCertificateStoreRoots(srpUnix, env({
      "HOME": "/home/u", "XDG_STATE_HOME": "state",
      "TEST_CERTIFICATES_DIR": "certs"}), "1000")
    ck relative.user == "/home/u/.local/state/test-certificates"
    ck relative.problems.len == 2
    # macOS and Windows.
    ck resolveCertificateStoreRoots(srpMacos, env({"HOME": "/Users/u"}),
      "501").user == "/Users/u/Library/Application Support/test-certificates"
    ck resolveCertificateStoreRoots(srpWindows, env({
      "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local"}), "S-1").user ==
      "C:\\Users\\u\\AppData\\Local\\test-certificates"
    # The native resolver reads this process's environment on every call.
    let root = useStoreRoot("resolver")
    ck nativeCertificateStoreRoots().user == root
    putEnv("TEST_CERTIFICATES_DIR", "relative/certs")
    ck nativeCertificateStoreRoots().user != "relative/certs"
    discard useStoreRoot("resolver")

  test "a record lands at its content-addressed path":
    ## `<root>/v1/git-tree-sha1/<digest>/<sha256>.toml`, the digest being the
    ## content the record attests, and the sha256 recomputed here — with
    ## coreutils, not the product — over the record's canonical payload.
    ## The conformance half is `certificate_vectors_test.nim`'s `store/` walk.
    let root = useStoreRoot("path")
    let repo = committedRepo("path")
    let (code, summary) = runCli(repo, "path")
    ck code == 0
    let report = summary{"certificate"}
    checkpoint $report
    ck report{"issued"}.getBool
    let content = report{"content"}.getStr
    ck content == "git-tree-sha1:" & headTree(repo)
    ck not report.hasKey("store_notice")

    let files = storeFiles(root)
    checkpoint $files
    ck files.len == 1
    let document = readFile(root / files[0])
    ck document == report{"document"}.getStr
    let read = readCertificate(document)
    ck read.status == crsOk
    let payloadHash = sha256Of(canonicalPayload(read.cert))
    ck files[0] == "v1/git-tree-sha1/" & headTree(repo) & "/" & payloadHash &
                   ".toml"
    ck report{"written_to"}.getStr == root / "v1" / "git-tree-sha1" /
                                      headTree(repo) / payloadHash & ".toml"
    # Derived from the FIELDS, not the bytes: a non-canonical rendering of
    # the same record names the same file (the `store/` vectors pin the
    # signature-block half of this).
    let respaced = document.replace("\n\n[certificate]\n", "\n[certificate]\n")
    ck respaced != document
    ck localStoreRelativePathOf(respaced).path == files[0]
    # Owner-only root (§2.3 step 1).
    ck getFilePermissions(root) == {fpUserRead, fpUserWrite, fpUserExec}

  test "a content id cannot name a directory outside the store":
    ## The content id decides where a write lands, so it is checked before it
    ## becomes a path: split at the FIRST `:`, an algorithm that is one safe
    ## name, a digest that is lowercase hex.
    ck localStoreContentDir("git-tree-sha1:" & "a".repeat(40)).relative ==
       "v1/git-tree-sha1/" & "a".repeat(40)
    for bad in ["no-colon", ":abc", "git-tree-sha1:", "../x:abc",
                "a/b:abc", "..:abc", "git-tree-sha1:ABC", "git-tree-sha1:a:b",
                "git-tree-sha1:../../etc"]:
      checkpoint bad
      ck not localStoreContentDir(bad).ok
    # And a record carrying one is not published anywhere.
    let root = useStoreRoot("bad-content")
    let outcome = publishToLocalStore(nativeRoots(), scratchDir("bad-ws"),
                                      sampleDocument("../evil:abc"))
    ck not outcome.written
    ck outcome.error.len > 0
    ck not dirExists(root)

  test "identical re-issues are idempotent and concurrent producers never collide":
    let root = useStoreRoot("concurrent")
    let workspace = scratchDir("concurrent-ws")
    let content = contentFor(7)
    let docA = bulkyDocument(content, platform = "linux/amd64")
    let docB = bulkyDocument(content, platform = "macos/arm64")
    # The temporary name a writer uses is invisible to every reader (§2.3).
    let temporary = temporaryName("abc.toml")
    ck temporary.startsWith(".")
    ck not temporary.endsWith(".toml")
    ck not isLocalStoreRecordName(temporary)
    ck temporaryName("abc.toml") != temporary
    writeFile(scratchRoot / "docA.toml", docA)
    writeFile(scratchRoot / "docB.toml", docB)

    # The same record twice, in this process: one file.
    for i in 1 .. 2:
      ck publishToLocalStore(nativeRoots(), workspace, docA).written
    ck storeFiles(root).len == 1

    proc publisher(doc: string; count: int): Process =
      spawnSelf({RoleVariable: "publish", "CT_LS_ROOT": root,
                 "CT_LS_DOC": doc, "CT_LS_WORKSPACE": workspace,
                 "CT_LS_COUNT": $count})

    proc pollWhile(processes: seq[Process]): tuple[reads, bad: int] =
      ## A reader polling throughout: every `.toml` a reader would pick up
      ## must parse, completely, as one of the two documents.
      var running = true
      while running:
        running = processes.anyIt(it.running)
        if not dirExists(root / "v1"):
          continue
        for path in walkDirRec(root / "v1"):
          let name = path.extractFilename
          if not isLocalStoreRecordName(name):
            continue
          var text = ""
          try: text = readFile(path)
          except IOError: continue      # replaced between list and read
          inc result.reads
          if text != docA and text != docB:
            inc result.bad
            checkpoint "partial or foreign file at " & path & ": " &
                       $text.len & " bytes"

    # Two processes, different records for one content, at once.
    let different = @[publisher(scratchRoot / "docA.toml", 40),
                      publisher(scratchRoot / "docB.toml", 40)]
    let polled = pollWhile(different)
    for p in different:
      let output = p.outputStream.readAll()
      checkpoint output
      ck p.waitForExit() == 0
      p.close()
    checkpoint "reads while writing: " & $polled.reads
    ck polled.bad == 0
    let files = storeFiles(root)
    checkpoint $files
    # Both survive, nothing else is left behind (no temporaries).
    ck files.len == 2
    ck files.allIt(it.startsWith("v1/git-tree-sha1/" & content[14 .. ^1] & "/"))
    ck files.mapIt(readFile(root / it)).sorted == @[docA, docB].sorted

    # The same record from two processes at once: still one file per name.
    let same = @[publisher(scratchRoot / "docA.toml", 40),
                 publisher(scratchRoot / "docA.toml", 40)]
    let polledSame = pollWhile(same)
    for p in same:
      ck p.waitForExit() == 0
      p.close()
    ck polledSame.bad == 0
    ck storeFiles(root).len == 2

  test "a prune racing a publish costs at most one retried rename":
    ## A pruner keeping NOTHING runs flat out while a writer publishes into a
    ## directory the pruner is free to remove (made old before each round).
    ## Every publish succeeds; at most one retry each.
    let root = useStoreRoot("prune-race")
    let workspace = scratchDir("prune-race-ws")
    # Signed, so every publish really writes and renames (an unsigned one
    # would keep the existing file and never reach the rename).
    let doc = sampleDocument(contentFor(9), signature = "U1NIU0lH")
    let stop = scratchRoot / "race.stop"
    removeFile(stop)
    let pruner = spawnSelf({RoleVariable: "prune", "CT_LS_ROOT": root,
                            "CT_LS_STOP": stop})
    var failures = 0
    var retries = 0
    let relative = localStoreRelativePathOf(doc).path
    let dir = root / relative.parentDir
    # Through the full entry point, a few times ...
    for i in 1 .. 20:
      let outcome = publishToLocalStore(nativeRoots(), workspace, doc)
      if outcome.retried: inc retries
      if not outcome.written:
        inc failures
        checkpoint "publish " & $i & " failed: " & outcome.error
    # ... and through the bare write step in a tight loop, which is where the
    # race lives: the directory is made old (so the pruner may take it) and
    # written into at once, thousands of times.
    let deadline = getTime() + initDuration(seconds = 3)
    var writes = 0
    while getTime() < deadline:
      if dirExists(dir):
        try: setLastModificationTime(dir, getTime() - initDuration(days = 1))
        except OSError: discard
      let written = publishRecord(root, relative, doc, signed = true)
      inc writes
      if written.retried: inc retries
      if written.error.len > 0:
        inc failures
        checkpoint "write " & $writes & " failed: " & written.error
    writeFile(stop, "")
    let output = pruner.outputStream.readAll()
    discard pruner.waitForExit()
    pruner.close()
    checkpoint output & " retries=" & $retries
    echo "    prune race: ", output.strip(), ", publishes retried: ", retries
    ck failures == 0

  test "a signed record replaces its unsigned twin, and an unsigned one keeps the signed":
    ## §2.3: the two share a name (the signature block is outside the
    ## payload). A signing producer always replaces; an unsigned one may keep
    ## the existing file, and keeps it — replacing a signed copy with an
    ## unsigned one would silently discard the signature.
    let root = useStoreRoot("replace")
    let workspace = scratchDir("replace-ws")
    let content = contentFor(11)
    let unsigned = sampleDocument(content)
    var signedCert = readCertificate(unsigned).cert
    signedCert.keyId = "example-key"
    let unsignedWithKey = renderCertificate(signedCert)
    signedCert.signature = CertificateSignature(algorithm: SignatureAlgorithm,
                                                value: "U1NIU0lHAAAAAQ")
    let signed = renderCertificate(signedCert)
    let signedAgain = block:
      var again = signedCert
      again.signature.value = "U1NIU0lHAAAAAg"
      renderCertificate(again)
    ck localStoreRelativePathOf(signed).path ==
       localStoreRelativePathOf(unsignedWithKey).path

    let first = publishToLocalStore(nativeRoots(), workspace, unsignedWithKey)
    ck first.written and not first.kept
    let path = first.path
    let viaSigned = publishToLocalStore(nativeRoots(), workspace, signed)
    ck viaSigned.path == path
    ck not viaSigned.kept
    ck readFile(path) == signed
    # An unsigned re-issue keeps the signed copy.
    let viaUnsigned = publishToLocalStore(nativeRoots(), workspace,
                                          unsignedWithKey)
    ck viaUnsigned.written and viaUnsigned.kept
    ck readFile(path) == signed
    # A signing producer replaces even a signed copy: it just made its own.
    discard publishToLocalStore(nativeRoots(), workspace, signedAgain)
    ck readFile(path) == signedAgain
    ck storeFiles(root).len == 1

  test "retention keeps the newest N content directories and HEAD's content":
    let root = useStoreRoot("retention")
    let repo = committedRepo("retention")
    let headId = "git-tree-sha1:" & headTree(repo)
    let keep = 4
    let past = getTime() - initDuration(days = 30)
    # HEAD's content first, so it is the OLDEST directory in the store.
    ck publishToLocalStore(nativeRoots(), repo, sampleDocument(headId),
                           keep = keep).written
    let headDir = root / "v1" / "git-tree-sha1" / headTree(repo)
    setLastModificationTime(headDir, past)
    var dirs: seq[string] = @[]
    for i in 1 .. keep + 3:
      let content = contentFor(100 + i)
      let outcome = publishToLocalStore(nativeRoots(), repo,
                                        sampleDocument(content), keep = keep)
      ck outcome.written
      let dir = root / "v1" / "git-tree-sha1" / content[14 .. ^1]
      setLastModificationTime(dir, past + initDuration(hours = i))
      dirs.add dir
    # One more publish, so the last directory's backdating is seen too.
    let last = contentFor(200)
    ck publishToLocalStore(nativeRoots(), repo, sampleDocument(last),
                           keep = keep).written
    var remaining: seq[string] = @[]
    for kind, path in walkDir(root / "v1" / "git-tree-sha1"):
      remaining.add path
    remaining.sort()
    checkpoint $remaining
    # N kept (the new one and the N-1 newest backdated), plus HEAD's.
    ck remaining.len == keep + 1
    ck headDir in remaining
    ck (root / "v1" / "git-tree-sha1" / last[14 .. ^1]) in remaining
    for i in 0 ..< dirs.len:
      ck (dirs[i] in remaining) == (i >= dirs.len - (keep - 1))
    # Pruning happens on publish only: reading changes nothing.
    let before = storeFiles(root)
    for i in 1 .. 3:
      for id in [headId, contentFor(101), last]:
        discard lookupLocalStore(nativeStoreAccess(), nativeRoots(), id)
    ck storeFiles(root) == before

  test "a directory a producer is writing into is never pruned":
    let root = useStoreRoot("writing-into")
    let old = getTime() - initDuration(days = 2)
    var dirs: seq[string] = @[]
    for i in 1 .. 3:
      let dir = root / "v1" / "git-tree-sha1" / contentFor(300 + i)[14 .. ^1]
      createDir(dir)
      dirs.add dir
    # dirs[0]: a writer's temporary file, fresh.
    writeFile(dirs[0] / (".x.toml" & TemporaryMarker & "1"), "partial")
    setLastModificationTime(dirs[0], old)
    # dirs[1]: a temporary file a crashed writer left a day ago.
    writeFile(dirs[1] / (".y.toml" & TemporaryMarker & "2"), "partial")
    setLastModificationTime(dirs[1] / (".y.toml" & TemporaryMarker & "2"), old)
    setLastModificationTime(dirs[1], old)
    # dirs[2]: created a moment ago, before any file — fresh by its mtime.
    let outcome = pruneLocalStore(root, 0, [])
    checkpoint $outcome
    ck dirExists(dirs[0])
    ck not dirExists(dirs[1])
    ck dirExists(dirs[2])

  test "a certificate issued in one clone is found from another with identical content":
    let root = useStoreRoot("clones")
    discard root
    let first = committedRepo("clone-a")
    writeFile(first / FixtureTestFile, "adds, edited\n")   # uncommitted
    let (code, summary) = runCli(first, "clone-a")
    ck code == 0
    ck summary{"certificate"}{"issued"}.getBool
    let content = summary{"certificate"}{"content"}.getStr

    # Same directory NAME, different places: the indicator also requires the
    # record's `repo` to be this checkout's name (its own policy, not the
    # binding), and a second clone of a project usually keeps the name.
    let second = scratchRoot / "elsewhere" / "clone-a"
    removeDir(second)
    createDir(second.parentDir)
    discard run("git", ["clone", "-q", first, second], scratchRoot)
    writeFile(second / FixtureTestFile, "adds, edited\n")
    let worktree = scratchRoot / "worktrees" / "clone-a"
    removeDir(worktree)
    createDir(worktree.parentDir)
    discard run("git", ["worktree", "add", "-q", "--detach", worktree], first)
    writeFile(worktree / FixtureTestFile, "adds, edited\n")
    for other in [second, worktree]:
      let w = workingTreeId(other)
      checkpoint other & ": " & w
      ck w == content
      let found = lookupLocalStore(nativeStoreAccess(), nativeRoots(), w)
      ck found.found.len == 1
      ck found.found[0].text == summary{"certificate"}{"document"}.getStr
      ck indicatorFor(other).state == cisCertified

  test "ct test no longer touches .ct/":
    let root = useStoreRoot("dot-ct")
    discard root
    # A fresh repository: no `.ct/` after a run.
    let fresh = committedRepo("dot-ct-fresh")
    ck runCli(fresh, "dot-ct-fresh").summary{"certificate"}{"issued"}.getBool
    ck not dirExists(fresh / ".ct")

    # A repository holding CTC-2's guard and a record that WOULD cover W,
    # had anything read it. A fresh store root: content ids do not depend on
    # the repository, so the run above already covers this repository's
    # identical content.
    discard useStoreRoot("dot-ct-old")
    let old = committedRepo("dot-ct-old")
    createDir(old / AbandonedCtTestStoreDir)
    let guard = "# Written by `ct test`.\n*\n"
    writeFile(old / ".ct" / ".gitignore", guard)
    let planted = sampleDocument("git-tree-sha1:" & headTree(old),
                                 platform = currentPlatform())
    let plantedPath = old / AbandonedCtTestStoreDir /
                      currentPlatform().replace('/', '-') & ".toml"
    writeFile(plantedPath, planted)
    # The reader does not see it: nothing in the local store, nothing found.
    let before = readCertificateStore(nativeStoreAccess(), old, LocalStoreQuery(
      roots: nativeRoots(), contentIds: @[workingTreeId(old)]))
    ck before.certificates.len == 0
    ck AbandonedCtTestStoreDir notin before.searched
    ck indicatorFor(old).state == cisNoCertificates

    let (code, summary) = runCli(old, "dot-ct-old")
    ck code == 0
    ck summary{"certificate"}{"document"}.getStr != planted
    ck AbandonedCtTestStoreDir notin summary{"certificate"}{"written_to"}.getStr
    # Both left byte-identical, and nothing new under `.ct/`.
    ck readFile(old / ".ct" / ".gitignore") == guard
    ck readFile(plantedPath) == planted
    var underCt: seq[string] = @[]
    for path in walkDirRec(old / ".ct"):
      underCt.add path
    ck underCt.len == 2

  test "publishing leaves the working tree untouched":
    ## Replaces CTC-2's "the published record does not dirty the tree, and
    ## the next run certifies", whose ignore guard no longer exists: there is
    ## nothing to ignore, because nothing is written into the tree.
    let root = useStoreRoot("untouched")
    let repo = committedRepo("untouched")
    let statusBefore = gitStatus(repo)
    ck statusBefore == ""
    let first = runCli(repo, "untouched-1")
    ck first.summary{"certificate"}{"issued"}.getBool
    ck gitStatus(repo) == statusBefore
    let second = runCli(repo, "untouched-2")
    ck second.summary{"certificate"}{"issued"}.getBool
    ck second.summary{"certificate"}{"untracked"}.getBool == false
    ck gitStatus(repo) == statusBefore
    # Every file of the repository's working tree is the fixture's own.
    var files: seq[string] = @[]
    for path in walkDirRec(repo, skipSpecial = true):
      if not path.relativePath(repo).startsWith(".git"):
        files.add path.relativePath(repo)
    ck files == @[FixtureTestFile]
    # And everything either run wrote is in the store, under this content.
    let stored = storeFiles(root)
    ck stored.len in 1 .. 2      # two when the runs' issued_at differ
    let content = first.summary{"certificate"}{"content"}.getStr
    ck stored.allIt(it.startsWith("v1/git-tree-sha1/" & content[14 .. ^1] & "/"))

  test "a store root inside the repository is refused":
    ## The working tree again, by another name. Refused, reported, and the
    ## run's exit code is unchanged.
    let repo = committedRepo("root-inside")
    putEnv("TEST_CERTIFICATES_DIR", repo / "certs")
    let (code, summary) = runCli(repo, "root-inside")
    ck code == 0
    let report = summary{"certificate"}
    checkpoint $report
    ck report{"issued"}.getBool
    ck not report.hasKey("written_to")
    ck "inside the repository" in report{"write_error"}.getStr
    ck not dirExists(repo / "certs")
    ck gitStatus(repo) == ""
    discard useStoreRoot("root-inside")

  test "the second consecutive run still certifies":
    ## CTC-3d's case, on the local store: with a tracked edit present
    ## throughout, two consecutive runs give the same content, untracked =
    ## false, and `git status` shows the edit and nothing of the producer's.
    let root = useStoreRoot("consecutive")
    let repo = committedRepo("consecutive")
    writeFile(repo / FixtureTestFile, "adds, and now subtracts\n")
    let edited = "M " & FixtureTestFile
    ck gitStatus(repo) == edited
    let first = runCli(repo, "consecutive-1")
    ck first.code == 0
    let firstReport = first.summary{"certificate"}
    ck firstReport{"issued"}.getBool
    ck firstReport{"untracked"}.getBool == false
    let content = firstReport{"content"}.getStr
    ck content != "git-tree-sha1:" & headTree(repo)
    ck gitStatus(repo) == edited
    let second = runCli(repo, "consecutive-2")
    let secondReport = second.summary{"certificate"}
    ck secondReport{"issued"}.getBool
    ck secondReport{"untracked"}.getBool == false
    ck secondReport{"content"}.getStr == content
    ck gitStatus(repo) == edited
    ck storeFiles(root).len == 2       # issued_at differs: two claims
    discard run("git", ["commit", "-q", "-a", "-m", "subtract"], repo)
    ck content == "git-tree-sha1:" & headTree(repo)
    ck indicatorFor(repo).state == cisCertified

  test "a reprobuild-free project reads certified after ct test":
    ## CTC-2's end-to-end proof on the local store: no reprobuild, no flag, and
    ## the shipped reader and evaluator find and accept what `ct test` wrote.
    discard useStoreRoot("no-reprobuild")
    let repo = committedRepo("no-reprobuild")
    let (code, summary) = runCli(repo, "no-reprobuild")
    ck code == 0
    ck not dirExists(repo / ".repro")
    let model = indicatorFor(repo)
    checkpoint $model.state & " — " & model.summary & " (" &
               model.certificateName & ")"
    ck model.state == cisCertified
    ck model.certificateName == summary{"certificate"}{"written_to"}.getStr
    # The control: a commit moves W to content no record attests, and the
    # lookup by content finds nothing for it (Status-Bar SB-2b decides the
    # label; here the reader simply has no candidate).
    writeFile(repo / "extra.txt", "later\n")
    discard run("git", ["add", "-A"], repo)
    discard run("git", ["commit", "-m", "move on"], repo)
    let moved = indicatorFor(repo)
    ck moved.state == cisNoCertificates
    ck moved.label == NoCertificatesLabel
    discard runCli(repo, "no-reprobuild-2")
    ck indicatorFor(repo).state == cisCertified

  test "a reprobuild-free project shows certified after ct test, with no commit":
    ## Status-Bar SB-2b: CTC-2's end-to-end case against CTC-3d's producer,
    ## with NO commit between the run and the check. Edit, run `ct test`, and
    ## the shipped evaluator over the shipped reader reads "Certified,
    ## uncommitted"; partial staging adds the staged-content warning; `git
    ## commit -a` reads "Certified" with no run in between and the store
    ## unchanged.
    let root = useStoreRoot("uncommitted")
    let repo = committedRepo("uncommitted")
    writeFile(repo / "NOTES.txt", "notes\n")
    discard run("git", ["add", "-A"], repo)
    discard run("git", ["commit", "-q", "-m", "notes"], repo)
    writeFile(repo / FixtureTestFile, "adds, and now subtracts\n")
    writeFile(repo / "NOTES.txt", "notes, revised\n")
    let (code, summary) = runCli(repo, "uncommitted")
    ck code == 0
    ck summary{"certificate"}{"issued"}.getBool
    ck summary{"certificate"}{"content"}.getStr != "git-tree-sha1:" &
                                                   headTree(repo)
    let tested = indicatorFor(repo)
    checkpoint $tested.state & " — " & tested.label & " — " & tested.summary
    ck tested.state == cisCertified
    ck tested.label == CertifiedUncommittedLabel
    ck tested.certificateName == summary{"certificate"}{"written_to"}.getStr
    # Nothing staged: the staged content is HEAD's, not what was tested.
    ck StagedDiffersWarning in tested.summary

    # Stage HALF of the change: still certified (W is what was tested), and
    # the tooltip warns that `git commit` without `-a` would not be covered.
    discard run("git", ["add", FixtureTestFile], repo)
    let partial = indicatorFor(repo)
    ck partial.label == CertifiedUncommittedLabel
    ck partial.summary == UncommittedCertifiedSummary & " " &
                          StagedDiffersWarning

    # `git commit -a`: no run in between, and the store unchanged.
    let storeBefore = storeFiles(root)
    discard run("git", ["commit", "-q", "-a", "-m", "subtract"], repo)
    ck gitStatus(repo) == ""
    let committed = indicatorFor(repo)
    checkpoint $committed.state & " — " & committed.label
    ck committed.state == cisCertified
    ck committed.label == CertifiedLabel
    ck committed.summary == CommittedCertifiedSummary
    ck storeFiles(root) == storeBefore

  test "a withheld run publishes nothing":
    let root = useStoreRoot("withheld")
    let repo = committedRepo("withheld")
    discard run("git", ["update-index", "--assume-unchanged", FixtureTestFile],
                repo)
    writeFile(repo / FixtureTestFile, "adds, differently\n")
    let (code, summary) = runCli(repo, "withheld")
    ck code == 0
    let report = summary["certificate"]
    ck report{"issued"}.getBool == false
    ck report{"withheld_reason"}.getStr == $wrIndexHidesWorktree
    ck not report.hasKey("written_to")
    ck not dirExists(root)
    ck not dirExists(repo / ".ct")

  test "a record that could not be written is reported, never claimed as published":
    let root = useStoreRoot("unwritable")
    let repo = committedRepo("unwritable")
    createDir(root)
    setFilePermissions(root, {fpUserRead, fpUserExec})
    try:
      let (code, summary) = runCli(repo, "unwritable")
      let report = summary{"certificate"}
      checkpoint $report
      ck code == 0
      ck report{"issued"}.getBool
      ck report{"write_error"}.getStr.len > 0
      ck not report.hasKey("written_to")
      ck storeFiles(root).len == 0
    finally:
      setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})

  test "the usage text says where a run publishes":
    let usage = ctTestUsageMessage()
    ck "TEST_CERTIFICATES_DIR" in usage
    ck "local certificate store" in usage
    ck "v1/<algorithm>/" in usage
    ck "--certificate <path>" notin usage
    ck ".ct/" notin usage
    ck "--no-certificate" in usage

delEnv("TEST_CERTIFICATES_DIR")
delEnv("TEST_CERTIFICATES_SYSTEM_DIR")
removeScratchRoot()

echo "CHECKS: ", checksRun
