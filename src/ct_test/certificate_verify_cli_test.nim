## ``ct test verify`` and the optional pre-commit gate (CTC-3f), through the
## shipped CLI, against real git and a real local certificate store.
##
## NO MOCKS OF GIT OR THE STORE. Every workspace is a real repository; every
## certificate the cases rely on is issued by a real ``ct test run`` and
## published by the shipped writer into a scratch ``TEST_CERTIFICATES_DIR``;
## every verdict comes from a real ``ct test verify`` PROCESS, so its exit
## status and its one stderr line are observed exactly as a hook sees them.
## The hook case installs a real ``.git/hooks/pre-commit`` holding the
## documented line (``PreCommitHookCommand``) and drives real ``git commit``
## variants, so ``GIT_INDEX_FILE`` is whatever git really sets.
##
## How ``ct`` is reached. The lane builds no ``ct`` binary, so ``ct`` here is a
## two-line shell script on ``PATH`` that re-invokes THIS test binary in a
## child role, which calls the shipped CLI entry point (``runCtTest``) with
## the arguments it was given — exactly what ``src/ct/codetracer.nim`` does
## for ``ct test discover|run|verify``. The script also appends the exit
## status to a log, which is how the hook case asserts that the gate exited
## 1 rather than merely "non-zero". The child's provider registry is the
## default one PLUS one in-process fixture provider (``*.fixture`` files under
## ``tests/``) that can run and pass, because no shipped provider can pass a
## test here without a language toolchain — the seam
## ``certificate_cli_test.nim`` justifies. Discovery, orchestration, issuance,
## publishing, the content ids and the verifier are the shipped code. The
## default registry's ``nim-unittest`` provider discovers ``tests/*.nim`` and
## cannot run it, which is the "target that cannot run on this platform".
##
## Every child inherits ``TEST_CERTIFICATES_DIR`` through a role variable,
## because the force-imported ``state_isolation`` gives every test PROCESS its
## own private store at start-up; the child re-points it at the case's
## scratch root before running anything. Nothing here touches the user's
## store, global git configuration or hooks path (``GIT_CONFIG_GLOBAL`` is
## ``/dev/null`` for every git call).

import std/[json, options, os, osproc, posix, strutils, unittest]

import contracts
import discovery
import certificate
import certificate_issuance
import certificate_local_store
import certificate_store
import certificate_content_id
import certificate_content_id_native
import certificate_verify_cli
import ct_test

const
  RoleVariable = "CT_VERIFY_TEST_ROLE"
  UserRootVariable = "CT_VERIFY_TEST_USER_ROOT"
  SystemRootVariable = "CT_VERIFY_TEST_SYSTEM_ROOT"
  FixtureProviderId = "fixture-verify"

# ---------------------------------------------------------------------------
# The in-process fixture provider (also used by the child role)
# ---------------------------------------------------------------------------

proc fixtureInfo(): TestProviderInfo =
  TestProviderInfo(
    id: FixtureProviderId, language: "fixture", framework: "inproc",
    displayName: "In-process verify fixture provider", version: "test",
    capabilities: TestCapabilities(
      canDiscoverProject: true, canDiscoverFile: true, canLocateTests: true,
      canRunProject: true, canRunFile: true, canRunSingle: true,
      canCapturePerTestOutput: true, emitsStructuredEvents: true))

proc fixtureItem(file: string): TestItem =
  TestItem(
    id: makeTestItemId(FixtureProviderId, "fixture", "inproc", file,
                       file & "::passes"),
    providerId: FixtureProviderId, language: "fixture", framework: "inproc",
    name: "passes", kind: tikCase, file: file,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1, endColumn: 2),
    selector: file & "::passes", tags: @["fixture"],
    location: LocationProvenance(source: lskPattern,
      detail: "in-process fixture", confidence: lcHigh))

proc fixtureFiles(root: string): seq[string] {.gcsafe.} =
  if dirExists(root / "tests"):
    for kind, path in walkDir(root / "tests"):
      if kind == pcFile and path.endsWith(".fixture"):
        result.add "tests/" & path.extractFilename

proc fixtureCatalog(items: seq[TestItem]): TestCatalog =
  TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: fixtureInfo(),
              items: items)

proc fixtureRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](diagnostics: @[], value: @[
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestStarted,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId),
    TestEvent(schemaVersion: TestEventSchemaVersion, kind: tekTestFinished,
              providerId: FixtureProviderId, runId: scope.testId,
              testId: scope.testId, status: some(tsPassed), durationMs: 1)])

proc fixtureDetect(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
  ProviderResult[bool](value: fixtureFiles(projectRoot).len > 0)

proc fixtureDiscoverProject(projectRoot: string):
    ProviderResult[TestCatalog] {.gcsafe.} =
  var items: seq[TestItem]
  for file in fixtureFiles(projectRoot):
    items.add fixtureItem(file)
  ProviderResult[TestCatalog](value: fixtureCatalog(items))

proc fixtureDiscoverFile(projectRoot, file: string):
    ProviderResult[TestCatalog] {.gcsafe.} =
  var items: seq[TestItem]
  if file.endsWith(".fixture"):
    items.add fixtureItem("tests/" & file.extractFilename)
  ProviderResult[TestCatalog](value: fixtureCatalog(items))

proc verifyRegistry(): ProviderRegistry =
  var provider = TestProvider(info: fixtureInfo())
  provider.detect = fixtureDetect
  provider.discoverProject = fixtureDiscoverProject
  provider.discoverFile = fixtureDiscoverFile
  provider.run = fixtureRun
  result = newDefaultProviderRegistry()
  result.providers.add M1Provider(provider: provider, relevantConfigFiles: @[])

# ---------------------------------------------------------------------------
# The child role: `ct`, as the shim script invokes it
# ---------------------------------------------------------------------------

if getEnv(RoleVariable) == "ct":
  putEnv("TEST_CERTIFICATES_DIR", getEnv(UserRootVariable))
  putEnv("TEST_CERTIFICATES_SYSTEM_DIR", getEnv(SystemRootVariable))
  quit(runCtTest(commandLineParams(), verifyRegistry(), newDiscoveryCache()))

# ---------------------------------------------------------------------------
# Scratch, processes and git
# ---------------------------------------------------------------------------

let scratchRoot = getTempDir() / ("ct-verify-cli-" & $getCurrentProcessId())
removeDir(scratchRoot)
createDir(scratchRoot)
let shimDir = scratchRoot / "bin"
let shimLog = scratchRoot / "ct-exits.log"
createDir(shimDir)
writeFile(shimDir / "ct", "#!/bin/sh\n" &
  RoleVariable & "=ct " & quoteShell(getAppFilename()) & " \"$@\"\n" &
  "status=$?\n" &
  "printf '%s %s\\n' \"$status\" \"$*\" >> " & quoteShell(shimLog) & "\n" &
  "exit $status\n")
setFilePermissions(shimDir / "ct", {fpUserRead, fpUserWrite, fpUserExec})
putEnv("PATH", shimDir & ":" & getEnv("PATH"))
# No user or system git configuration reaches a case: no global hooksPath, no
# signing, no default branch name, no aliases.
putEnv("GIT_CONFIG_GLOBAL", "/dev/null")
putEnv("GIT_CONFIG_NOSYSTEM", "1")

var storeCounter = 0

type Store = object
  user: string
  system: string        ## TEST_CERTIFICATES_SYSTEM_DIR; the root is <it>/<uid>

proc freshStore(): Store =
  ## A new, empty pair of roots, exported for every child from now on.
  inc storeCounter
  let base = scratchRoot / ("store-" & $storeCounter)
  result = Store(user: base / "user", system: base / "system")
  putEnv(UserRootVariable, result.user)
  putEnv(SystemRootVariable, result.system)

proc systemRoot(store: Store): string = store.system / $getuid()

proc roots(store: Store): CertificateStoreRoots =
  CertificateStoreRoots(available: true, user: store.user,
                        system: store.systemRoot)

type Ran = object
  code: int
  stdout: string
  stderr: string

proc runIn(dir: string; command: string; args: openArray[string]): Ran =
  ## `command args` in `dir`, stdout and stderr captured separately.
  let outFile = scratchRoot / "out.txt"
  let errFile = scratchRoot / "err.txt"
  var p = startProcess("/bin/sh", workingDir = dir,
    args = @["-c", "exec \"$0\" \"$@\" >" & quoteShell(outFile) & " 2>" &
             quoteShell(errFile), command] & @args,
    options = {poUsePath})
  result.code = p.waitForExit()
  p.close()
  result.stdout = readFile(outFile)
  result.stderr = readFile(errFile)

proc ct(dir: string; args: varargs[string]): Ran =
  runIn(dir, "ct", @args)

proc git(dir: string; args: varargs[string]): Ran =
  runIn(dir, "git", @args)

proc gitOk(dir: string; args: varargs[string]): string =
  let ran = git(dir, args)
  doAssert ran.code == 0, "git " & args.join(" ") & ": " & ran.stdout & ran.stderr
  result = ran.stdout
  result.stripLineEnd()

proc verify(dir: string; args: varargs[string]): Ran =
  ct(dir, @["test", "verify"] & @args)

proc verifyJson(dir: string; args: varargs[string]): tuple[ran: Ran; report: JsonNode] =
  result.ran = ct(dir, @["test", "verify"] & @args & @["--json"])
  result.report = parseJson(result.ran.stdout)

proc stderrLine(ran: Ran): string =
  ## The verdict line, asserted to be the ONLY line on stderr: a direct
  ## `ct test verify` writes exactly one.
  var lines: seq[string]
  for line in ran.stderr.splitLines():
    if line.len > 0:
      lines.add line
  doAssert lines.len == 1 and lines[0].startsWith(VerifyStderrPrefix),
    "expected exactly one verdict line, got:\n" & ran.stderr
  lines[0]

proc testRun(workspace: string; extra: varargs[string]): JsonNode =
  ## `ct test run`, which issues and publishes; returns its certificate report.
  let ran = ct(workspace, @["test", "run", "--workspace", workspace] & @extra)
  doAssert ran.code == 0, ran.stdout & ran.stderr
  let summary = parseJson(ran.stdout)
  doAssert summary["certificate"]["issued"].getBool, ran.stdout & ran.stderr
  doAssert summary["certificate"].hasKey("written_to"), ran.stdout
  summary["certificate"]

proc newRepo(name: string; parent = ""; objectFormat = ""): string =
  ## A committed repository named `name` holding two runnable fixture tests,
  ## one discoverable-but-unrunnable Nim suite and two plain tracked files.
  let base = (if parent.len > 0: parent else: scratchRoot / ("ws-" & name))
  result = base / name
  removeDir(result)
  createDir(result / "tests")
  writeFile(result / "tests" / "a.fixture", "a\n")
  writeFile(result / "tests" / "b.fixture", "b\n")
  writeFile(result / "tests" / "calc_test.nim",
            "import std/unittest\n\nsuite \"calc\":\n  test \"adds\":\n" &
            "    check 1 + 1 == 2\n")
  writeFile(result / "a.txt", "alpha\n")
  writeFile(result / "b.txt", "beta\n")
  writeFile(result / "gen.txt", "generated v0\n")
  if objectFormat.len > 0:
    discard gitOk(result, "init", "--initial-branch=main",
                  "--object-format=" & objectFormat, ".")
  else:
    discard gitOk(result, "init", "--initial-branch=main", ".")
  discard gitOk(result, "config", "user.email", "ct-test@example.invalid")
  discard gitOk(result, "config", "user.name", "ct test suite")
  discard gitOk(result, "config", "commit.gpgsign", "false")
  discard gitOk(result, "add", "-A")
  discard gitOk(result, "commit", "-q", "-m", "initial")

proc writeConfig(repo, text: string) =
  createDir(repo / ".codetracer")
  writeFile(repo / ".codetracer" / "test.toml", text)

proc stateContent(repo: string; state: ContentState): string =
  let host = nativeContentIdHost()
  let format = repositoryTreeAlgorithm(host, repo)
  doAssert format.ok, format.failure
  let computed = computeContentId(host, repo, state, format.algorithm)
  doAssert computed.outcome == cioComputed, computed.reason
  computed.id

proc hookStatuses(): seq[string] =
  ## The exit statuses `ct test verify --staged` returned, in order.
  if fileExists(shimLog):
    for line in readFile(shimLog).splitLines():
      if line.endsWith("test verify --staged"):
        result.add line.split(' ')[0]

proc installHook(repo, body: string) =
  let hook = repo / ".git" / "hooks" / "pre-commit"
  createDir(hook.parentDir)
  writeFile(hook, "#!/bin/sh\n" & body & "\n")
  setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})

proc certificateFor(content, repo: string; targets: seq[string];
                    framework = CtTestFramework; platform = ""): string =
  ## A well-formed, unsigned record, for the cases that need one no run
  ## could produce (another framework, another algorithm).
  renderCertificate(TestCertificate(
    schema: CertificateSchema, framework: framework, project: repo,
    platform: (if platform.len > 0: platform else: currentPlatform()),
    targets: targets, result: "passed", issuedAt: "2026-10-10T10:00:00Z",
    issuer: "ct-verify-suite",
    vcs: VcsState(repo: repo, content: content, untracked: false),
    commands: @[@["ct-test", "test", "run"]]))

proc placeInStore(store: Store; document: string; system = false): string =
  ## A record at its content-addressed path, by the shipped writer's own
  ## path derivation.
  let relative = localStoreRelativePathOf(document)
  doAssert relative.error.len == 0, relative.error
  result = (if system: store.systemRoot else: store.user) / relative.path
  createDir(result.parentDir)
  writeFile(result, document)

proc contentDir(store: Store; content: string): string =
  let dir = localStoreContentDir(content)
  doAssert dir.ok, dir.problem
  store.user / dir.relative

# ---------------------------------------------------------------------------

suite "ct test verify (CTC-3f)":

  test "the usage text documents verify, its exit codes and the one-line hook":
    let usage = ctTestUsageMessage()
    check "verify (--staged | --worktree | --commit <rev>)" in usage
    check "--targets" in usage
    check "--platform" in usage
    check ".codetracer/test.toml" in usage
    check "exits 0 covered, 1 not covered" in usage
    check "2 could not decide" in usage
    check "NO certificate was found" in usage
    check "none matched" in usage
    # The hook, and the two things the standard says about it (Standard.md
    # §5.1): advisory, and last.
    check PreCommitHookCommand == "ct test verify --staged"
    check ("`" & PreCommitHookCommand & "`") in usage
    check "LAST" in usage
    check "not the enforcement point" in usage
    check "--no-verify" in usage
    check "after every hook step that rewrites staged content" in usage

  test "a command line verify cannot act on exits 2, never 1":
    let repo = newRepo("usage")
    discard freshStore()
    for args in [@[], @["--staged", "--worktree"], @["--commit"],
                 @["--staged", "--bogus"], @["--staged", "--targets", "a,,b"],
                 @["--commit", "--staged"]]:
      checkpoint(args.join(" "))
      let ran = verify(repo, args)
      check ran.code == VerifyUndecided
      check stderrLine(ran).startsWith(VerifyStderrPrefix & "could not decide (exit 2)")

  test "ct test verify gates a commit from a pre-commit hook":
    let repo = newRepo("hook")
    let store = freshStore()
    installHook(repo, PreCommitHookCommand)
    removeFile(shimLog)
    writeFile(repo / "a.txt", "alpha edited\n")
    writeFile(repo / "b.txt", "beta edited\n")
    let tested = testRun(repo)
    let w1 = tested["content"].getStr
    check w1 == stateContent(repo, workingTreeState())
    let start = gitOk(repo, "rev-parse", "HEAD")

    # 1. A partial `git add` of the tested content is refused, exit 1, "none
    #    found": no run ever saw a tree with only a.txt's change.
    discard gitOk(repo, "add", "a.txt")
    let partial = git(repo, "commit", "-m", "partial")
    check partial.code != 0
    check gitOk(repo, "rev-parse", "HEAD") == start
    check hookStatuses() == @["1"]
    check "ct test verify: not covered (exit 1) — none found" in partial.stderr

    # 2. `git commit <path>`: git evaluates the hook against its TEMPORARY
    #    index (HEAD plus the named paths), not the user's. The user's index
    #    now holds both changes — exactly the tested content — and the commit
    #    of a.txt alone is still refused, because that is not what it records.
    discard gitOk(repo, "add", "b.txt")
    check verify(repo, "--staged").code == VerifyCovered     # the user's index
    let onlyA = git(repo, "commit", "-m", "only a", "--", "a.txt")
    check onlyA.code != 0
    check gitOk(repo, "rev-parse", "HEAD") == start
    check hookStatuses() == @["1", "0", "1"]
    check "none found" in onlyA.stderr

    # 3. `git commit -a` of the tested content succeeds, with no second run.
    let all = git(repo, "commit", "-a", "-m", "tested")
    check all.code == 0
    check hookStatuses() == @["1", "0", "1", "0"]
    check "ct test verify: covered (exit 0)" in all.stderr
    check stateContent(repo, commitState("HEAD")) == w1

    # 4. `git commit <paths>` with NOTHING staged: the user's index equals
    #    HEAD, git's temporary index holds both tested edits, and the hook
    #    judges the latter — so the commit goes through.
    writeFile(repo / "a.txt", "alpha twice\n")
    writeFile(repo / "b.txt", "beta twice\n")
    let w2 = testRun(repo)["content"].getStr
    check gitOk(repo, "diff", "--cached", "--name-only") == ""
    let paths = git(repo, "commit", "-m", "by paths", "--", "a.txt", "b.txt")
    check paths.code == 0
    check hookStatuses()[^1] == "0"
    check stateContent(repo, commitState("HEAD")) == w2

    # 5. A hook step that rewrites staged content BEFORE the gate is seen by
    #    it: the rewritten tree was never tested, so the commit is refused.
    writeFile(repo / "a.txt", "alpha thrice\n")
    discard testRun(repo)
    installHook(repo, "printf 'generated by the hook\\n' > gen.txt\n" &
                      "git add gen.txt\n" & PreCommitHookCommand)
    let rewrittenFirst = git(repo, "commit", "-a", "-m", "rewritten first")
    check rewrittenFirst.code != 0
    check hookStatuses()[^1] == "1"
    discard gitOk(repo, "checkout", "HEAD", "--", "gen.txt")

    # ...and one that rewrites AFTER the gate produces a commit the gate
    # never saw: it passes, and the commit it made is not covered. That is
    # why the documented rule is "run it last" (usage case above).
    installHook(repo, PreCommitHookCommand & " || exit $?\n" &
                      "printf 'generated by the hook\\n' > gen.txt\n" &
                      "git add gen.txt")
    let rewrittenAfter = git(repo, "commit", "-a", "-m", "rewritten after")
    check rewrittenAfter.code == 0
    check hookStatuses()[^1] == "0"
    check readFile(repo / "gen.txt") == "generated by the hook\n"
    check verify(repo, "--commit", "HEAD").code == VerifyNotCovered
    discard store

  test "a commit of the tested content is covered without a second run, through the CLI":
    let repo = newRepo("commit")
    discard freshStore()
    writeFile(repo / "a.txt", "alpha edited\n")
    writeFile(repo / "b.txt", "beta edited\n")
    discard testRun(repo)
    check verify(repo, "--commit", "HEAD").code == VerifyNotCovered
    discard gitOk(repo, "commit", "-q", "-a", "-m", "tested")
    let covered = verify(repo, "--commit", "HEAD")
    check covered.code == VerifyCovered
    check stderrLine(covered).startsWith(VerifyStderrPrefix & "covered (exit 0)")
    # Control: an amended MESSAGE changes the commit, not its tree.
    discard gitOk(repo, "commit", "-q", "--amend", "-m", "reworded")
    check verify(repo, "--commit", "HEAD").code == VerifyCovered
    # Control: committing one of two tested changes is not covered; the rest
    # on top of it is.
    writeFile(repo / "a.txt", "alpha again\n")
    writeFile(repo / "b.txt", "beta again\n")
    discard testRun(repo)
    discard gitOk(repo, "commit", "-q", "-m", "half", "--", "a.txt")
    check verify(repo, "--commit", "HEAD").code == VerifyNotCovered
    discard gitOk(repo, "commit", "-q", "-a", "-m", "rest")
    check verify(repo, "--commit", "HEAD").code == VerifyCovered
    # Control: the tested change rebased onto an upstream commit that adds
    # another file is different content, and not covered.
    let tip = gitOk(repo, "rev-parse", "HEAD")
    discard gitOk(repo, "checkout", "-q", "-b", "upstream", "HEAD~1")
    writeFile(repo / "other.txt", "upstream\n")
    discard gitOk(repo, "add", "other.txt")
    discard gitOk(repo, "commit", "-q", "-m", "upstream adds a file")
    discard gitOk(repo, "checkout", "-q", "main")
    check gitOk(repo, "rev-parse", "HEAD") == tip
    check verify(repo, "--commit", "HEAD").code == VerifyCovered
    discard gitOk(repo, "rebase", "-q", "upstream")
    check verify(repo, "--commit", "HEAD").code == VerifyNotCovered

  test "none found and none matched are reported differently":
    let repo = newRepo("found")
    let store = freshStore()
    writeFile(repo / "a.txt", "alpha edited\n")
    let w = stateContent(repo, workingTreeState())
    # An empty store: none found, naming both roots' directories searched.
    let empty = verifyJson(repo, "--worktree")
    check empty.ran.code == VerifyNotCovered
    let emptyLine = stderrLine(empty.ran)
    check "not covered (exit 1) — none found" in emptyLine
    check w in emptyLine
    check store.user in emptyLine
    check store.systemRoot in emptyLine
    check empty.report["finding"].getStr == "none-found"
    # Records for ANOTHER content, in their own directory, are not consulted
    # at all (Transport.md §2.4: lookup by content id) — still none found.
    discard testRun(repo)                       # certifies the edit...
    writeFile(repo / "a.txt", "alpha edited differently\n")   # ...then moves on
    let elsewhere = verify(repo, "--worktree")
    check elsewhere.code == VerifyNotCovered
    check "none found" in stderrLine(elsewhere)
    # A record for another content MISFILED into this content's directory is
    # found, reported, and not evidence: none matched.
    let w2 = stateContent(repo, workingTreeState())
    let other = certificateFor(w, "found", @["tests/a.fixture", "tests/b.fixture"])
    createDir(store.contentDir(w2))
    writeFile(store.contentDir(w2) / "misfiled.toml", other)
    let misfiled = verifyJson(repo, "--worktree")
    check misfiled.ran.code == VerifyNotCovered
    let misfiledLine = stderrLine(misfiled.ran)
    check "not covered (exit 1) — none matched: 1 record(s) found" in misfiledLine
    check "misfiled.toml" in misfiledLine
    check misfiled.report["finding"].getStr == "none-matched"
    # A record for THIS content covering only part of the requirement: none
    # matched, naming the target that is missing.
    discard placeInStore(store, certificateFor(w2, "found", @["tests/a.fixture"]))
    let partial = verify(repo, "--worktree")
    check partial.code == VerifyNotCovered
    let partialLine = stderrLine(partial)
    check "none matched: 2 record(s) found" in partialLine
    check "none covering tests/b.fixture on " & currentPlatform() in partialLine
    check "none found" notin partialLine

  test "coverage is the union of several partial certificates":
    let repo = newRepo("union")
    discard freshStore()
    writeFile(repo / "a.txt", "alpha edited\n")
    discard testRun(repo, "--file", repo / "tests" / "a.fixture")
    let half = verify(repo, "--worktree")
    check half.code == VerifyNotCovered
    check "tests/b.fixture" in stderrLine(half)
    discard testRun(repo, "--file", repo / "tests" / "b.fixture")
    let whole = verifyJson(repo, "--worktree")
    check whole.ran.code == VerifyCovered
    check whole.report["found"].len == 2
    # The Nim suite was discovered, cannot run here, and is not required.
    check whole.report["requirement"]["source"].getStr == "discovered"
    check whole.report["requirement"]["targets"].to(seq[string]) ==
          @["tests/a.fixture", "tests/b.fixture"]
    check whole.report["requirement"]["not_required"].to(seq[string]) ==
          @["tests/calc_test.nim"]

  test "the default requirement prefers the declared target list":
    let repo = newRepo("declared")
    discard freshStore()
    writeConfig(repo, "schema = \"codetracer.test.v1\"\n[certificate]\n" &
                      "targets = [\"tests/a.fixture\"]\n")
    discard gitOk(repo, "add", "-A")
    discard gitOk(repo, "commit", "-q", "-m", "declare a")
    discard testRun(repo, "--file", repo / "tests" / "a.fixture")
    # Discovery reports a, b and the Nim suite; the declared list is a only.
    let declared = verifyJson(repo, "--worktree")
    check declared.ran.code == VerifyCovered
    check declared.report["requirement"]["source"].getStr == "declared"
    check declared.report["requirement"]["file"].getStr == ".codetracer/test.toml"
    check ".codetracer/test.toml" in stderrLine(declared.ran)
    check verify(repo, "--staged").code == VerifyCovered
    check verify(repo, "--commit", "HEAD").code == VerifyCovered
    # --targets overrides the file, in both directions.
    let overB = verify(repo, "--worktree", "--targets", "tests/b.fixture")
    check overB.code == VerifyNotCovered
    check "tests/b.fixture" in stderrLine(overB)
    check verify(repo, "--worktree", "--targets",
                 "tests/a.fixture,tests/b.fixture").code == VerifyNotCovered
    check verify(repo, "--worktree", "--targets", "tests/a.fixture",
                 "--targets", "tests/a.fixture").code == VerifyCovered
    # --platform overrides the host platform: a platform nobody ran on is
    # not covered, and the gap names it.
    let elsewhere = verify(repo, "--worktree", "--platform", "plan9/mips")
    check elsewhere.code == VerifyNotCovered
    check "on plan9/mips" in stderrLine(elsewhere)
    check verify(repo, "--worktree", "--platform",
                 currentPlatform() & ",plan9/mips").code == VerifyNotCovered
    check verify(repo, "--worktree", "--platform",
                 currentPlatform()).code == VerifyCovered

    # Without the KEY: discovery decides, and the unrunnable Nim suite is not
    # required. (The config is tracked, so this is new content.)
    writeConfig(repo, "schema = \"codetracer.test.v1\"\n[certificate]\n")
    discard testRun(repo, "--file", repo / "tests" / "a.fixture")
    let noKey = verifyJson(repo, "--worktree")
    check noKey.ran.code == VerifyNotCovered
    check noKey.report["requirement"]["source"].getStr == "discovered"
    check noKey.report["missing"][0]["targets"].to(seq[string]) ==
          @["tests/b.fixture"]
    discard testRun(repo, "--file", repo / "tests" / "b.fixture")
    check verify(repo, "--worktree").code == VerifyCovered

    # Without the FILE: the same.
    removeDir(repo / ".codetracer")
    discard testRun(repo)
    let noFile = verifyJson(repo, "--worktree")
    check noFile.ran.code == VerifyCovered
    check noFile.report["requirement"]["source"].getStr == "discovered"
    check "tests/calc_test.nim" notin
          noFile.report["requirement"]["targets"].to(seq[string])

    # The list is read from the STATE: an unstaged edit to the file moves
    # the working tree's requirement and not the index's.
    discard gitOk(repo, "add", "-A")
    discard gitOk(repo, "commit", "-q", "-m", "no config")
    writeConfig(repo, "schema = \"codetracer.test.v1\"\n[certificate]\n" &
                      "targets = [\"tests/never.fixture\"]\n")
    let staged = verifyJson(repo, "--staged")
    check staged.ran.code == VerifyCovered
    check staged.report["requirement"]["source"].getStr == "discovered"

  test "an unreadable ct test config is reported, not ignored":
    let repo = newRepo("broken-config")
    discard freshStore()
    # A certificate covering every discovered target exists for this exact
    # content, so a verifier that read the broken file as "no declared list"
    # would answer 0. It must answer 2, naming the file.
    var checkedBroken = 0
    for broken in ["schema = \"codetracer.test.v9\"\n[certificate]\n" &
                     "targets = [\"tests/a.fixture\"]\n",
                   "schema = \"codetracer.test.v1\"\n[certificate]\n" &
                     "targetz = [\"tests/a.fixture\"]\n",
                   "schema = \"codetracer.test.v1\"\n[certificate]\n" &
                     "targets = 2\n"]:
      inc checkedBroken
      checkpoint(broken)
      writeConfig(repo, broken)
      discard gitOk(repo, "add", "-A")
      discard gitOk(repo, "commit", "-q", "-m", "config " & $checkedBroken)
      discard testRun(repo)
      for state in [@["--worktree"], @["--staged"], @["--commit", "HEAD"]]:
        let ran = verify(repo, state)
        check ran.code == VerifyUndecided
        let line = stderrLine(ran)
        check "could not decide (exit 2)" in line
        check ".codetracer/test.toml" in line
        check "no requirement is assumed" in line
      # --targets does not need the file, so it is not consulted.
      check verify(repo, "--worktree", "--targets",
                   "tests/a.fixture").code == VerifyCovered
    check checkedBroken == 3
    # A broken file only on disk does not affect the staged state.
    writeConfig(repo, "schema = \"codetracer.test.v1\"\n[certificate]\n" &
                      "targets = [\"tests/a.fixture\"]\n")
    discard gitOk(repo, "add", "-A")
    discard gitOk(repo, "commit", "-q", "-m", "fixed")
    discard testRun(repo)
    writeConfig(repo, "this is not toml\n")
    check verify(repo, "--staged").code == VerifyCovered
    check verify(repo, "--worktree").code == VerifyUndecided

  test "a state ct test verify cannot judge exits 2":
    # A git-tree-sha256 record in a SHA-1 repository: this consumer cannot
    # compute that algorithm here, so the record is unevaluated and — being
    # about the required targets — makes the outcome unverifiable, never "not
    # covered". A content-addressed lookup cannot reach such a record (its
    # directory is named by an id nobody here can compute); it is found in
    # the workspace carrier the store reader pools.
    let repo = newRepo("sha256-record")
    discard freshStore()
    let carrier = repo / ".repro" / "workspace" / "certificates"
    createDir(carrier)
    writeFile(carrier / "sha256.toml", certificateFor(
      "git-tree-sha256:" & repeat("ab", 32), "sha256-record",
      @["tests/a.fixture", "tests/b.fixture"]))
    let unverifiable = verifyJson(repo, "--worktree")
    check unverifiable.ran.code == VerifyUndecided
    let line = stderrLine(unverifiable.ran)
    check "could not decide (exit 2)" in line
    check "git-tree-sha256" in line
    check unverifiable.report["unevaluated"].len == 1
    # ...and once the requirement is covered by records evaluated end to
    # end, the unevaluated one no longer matters (Verification.md §7.1).
    discard testRun(repo)
    check verify(repo, "--worktree").code == VerifyCovered

    # --worktree and --staged with an unmerged index: no content id.
    let merge = newRepo("unmerged")
    discard gitOk(merge, "checkout", "-q", "-b", "side")
    writeFile(merge / "a.txt", "side\n")
    discard gitOk(merge, "commit", "-q", "-a", "-m", "side")
    discard gitOk(merge, "checkout", "-q", "main")
    writeFile(merge / "a.txt", "main\n")
    discard gitOk(merge, "commit", "-q", "-a", "-m", "main")
    check git(merge, "merge", "side").code != 0
    for state in ["--worktree", "--staged"]:
      let ran = verify(merge, state)
      check ran.code == VerifyUndecided
      let mergeLine = stderrLine(ran)
      check "has no content id" in mergeLine
      check "unmerged" in mergeLine
      check "a.txt" in mergeLine
    # A revision that does not exist, and a directory that is no repository.
    check verify(repo, "--commit", "no-such-revision").code == VerifyUndecided
    let outside = scratchRoot / "not-a-repository"
    createDir(outside)
    let notRepo = verify(outside, "--worktree")
    check notRepo.code == VerifyUndecided
    check "not inside a git working tree" in stderrLine(notRepo)
    # Nothing to require: no declared list, and nothing discovered can run.
    let nothing = newRepo("nothing-runnable")
    removeFile(nothing / "tests" / "a.fixture")
    removeFile(nothing / "tests" / "b.fixture")
    let nothingRan = verify(nothing, "--worktree")
    check nothingRan.code == VerifyUndecided
    check "nothing to require" in stderrLine(nothingRan)
    # An unreadable USER root: it could not look, which is not "none found".
    let store = freshStore()
    createDir(store.user)
    setFilePermissions(store.user, {})
    let unreadable = verify(repo, "--worktree")
    setFilePermissions(store.user, {fpUserRead, fpUserWrite, fpUserExec})
    if getuid() != 0:
      check unreadable.code == VerifyUndecided
      check "could not be read" in stderrLine(unreadable)

  test "a certificate issued in clone a/ covers the same content in clone b/":
    # 2026-10-10: the clones live in directories with DIFFERENT names, and the
    # record names `a` as its `vcs.repo`. `ct test verify` does not compare
    # that with `b` — Verification.md §4.1 leaves the comparison to the
    # consumer, and requiring it would hide every certificate a sibling clone
    # or worktree issued for the same content (Transport.md §2.2). The name is
    # reported, never matched.
    let a = newRepo("a", scratchRoot / "clones")
    discard freshStore()
    let b = scratchRoot / "clones" / "b"
    removeDir(b)
    discard gitOk(scratchRoot, "clone", "-q", a, b)
    discard gitOk(b, "config", "user.email", "ct-test@example.invalid")
    discard gitOk(b, "config", "user.name", "ct test suite")
    for clone in [a, b]:
      writeFile(clone / "a.txt", "the same edit\n")
    let issued = testRun(a)
    check readCertificate(readFile(issued["written_to"].getStr)).cert.vcs.repo == "a"
    let fromB = verifyJson(b, "--worktree")
    check fromB.ran.code == VerifyCovered
    check fromB.report["found"].len == 1
    check fromB.report["rejected"].len == 0
    # This checkout's own name is in the report, informational.
    check fromB.report["repo"].getStr == "b"
    discard gitOk(b, "add", "a.txt")
    check verify(b, "--staged").code == VerifyCovered
    # Control: different content in B is not covered by A's record — the
    # content decides, not the name.
    writeFile(b / "b.txt", "only in b\n")
    let differs = verifyJson(b, "--worktree")
    check differs.ran.code == VerifyNotCovered
    check differs.report["finding"].getStr == "none-found"

  test "both roots are read: the system root counts, and an unreadable one is reported":
    let repo = newRepo("roots")
    let store = freshStore()
    writeFile(repo / "a.txt", "alpha edited\n")
    let issued = testRun(repo)
    let written = issued["written_to"].getStr
    check written.startsWith(store.user)
    # The same record in both roots is evaluated once.
    let document = readFile(written)
    discard placeInStore(store, document, system = true)
    let both = verifyJson(repo, "--worktree")
    check both.ran.code == VerifyCovered
    check both.report["found"].len == 1
    # Only in the system root (a signing daemon's): still covered.
    removeFile(written)
    let systemOnly = verifyJson(repo, "--worktree")
    check systemOnly.ran.code == VerifyCovered
    check systemOnly.report["found"][0].getStr.startsWith(store.systemRoot)
    # An unreadable system root is reported, and the user root still read.
    discard placeInStore(store, document)
    setFilePermissions(store.systemRoot, {})
    let blocked = verify(repo, "--worktree")
    setFilePermissions(store.systemRoot, {fpUserRead, fpUserWrite, fpUserExec})
    if getuid() != 0:
      check blocked.code == VerifyCovered
      check "system root" in stderrLine(blocked)

  test "only ct-test records are evaluated":
    let repo = newRepo("frameworks")
    let store = freshStore()
    writeFile(repo / "a.txt", "alpha edited\n")
    let w = stateContent(repo, workingTreeState())
    # A reprobuild record that would cover the state on every count but its
    # framework: ignored, not rejected, and not coverage.
    discard placeInStore(store, certificateFor(w, "frameworks",
      @["tests/a.fixture", "tests/b.fixture"], framework = "reprobuild"))
    let ignored = verifyJson(repo, "--worktree")
    check ignored.ran.code == VerifyNotCovered
    check ignored.report["ignored"].len == 1
    check ignored.report["rejected"].len == 0
    let line = stderrLine(ignored.ran)
    check "none matched" in line
    check "ignored (not ct-test) 1" in line
    check "reprobuild" in line
    # The ct-test run covers it; the reprobuild record is still named.
    discard testRun(repo)
    let covered = verifyJson(repo, "--worktree")
    check covered.ran.code == VerifyCovered
    check covered.report["ignored"].len == 1
    check "ignored (not ct-test) 1" in stderrLine(covered.ran)

  test "an earlier-draft record is reported as such, and is not coverage":
    let repo = newRepo("earlier")
    let store = freshStore()
    writeFile(repo / "a.txt", "alpha edited\n")
    let w = stateContent(repo, workingTreeState())
    let draft = certificateFor(w, "earlier",
      @["tests/a.fixture", "tests/b.fixture"]).replace(
        "content = \"" & w & "\"\n",
        "commit = \"" & gitOk(repo, "rev-parse", "HEAD") & "\"\nclean = false\n")
    check "commit = " in draft
    createDir(store.contentDir(w))
    writeFile(store.contentDir(w) / "draft.toml", draft)
    let ran = verifyJson(repo, "--worktree")
    check ran.ran.code == VerifyNotCovered
    let line = stderrLine(ran.ran)
    check "none matched" in line
    check "earlier-draft" in line
    check "run the tests" in line
    check ran.report["rejected"].len == 1

removeDir(scratchRoot)
