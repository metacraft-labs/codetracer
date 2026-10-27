## Real subprocess negative controls impersonate old/broken engines using
## this test executable's probe modes. This keeps the subprocess boundary real
## and portable; a mandatory built-engine positive control prevents self-pass.
import std/[os, osproc, streams, strutils, tempfiles, unittest]
when not defined(windows):
  import std/posix
import ../../../common/replay_server_path

if paramCount() == 1 and paramStr(1) == "--build-revision":
  case getEnv("CT_TEST_REPLAY_PROBE")
  of "old": echo "replay-server 0.1.0"
  of "silent": sleep(60_000)
  of "stale": echo "codetracer-replay-build-v1 ", repeat("deadbeef", 5), " wrong-source"
  of "large": echo repeat('x', 2048)
  of "inherited":
    when not defined(windows):
      let child = fork()
      if child == 0:
        os.sleep(30_000)
        removeFile(getEnv("CT_TEST_REPLAY_CHILD") & ".alive")
        quit(0)
      writeFile(getEnv("CT_TEST_REPLAY_CHILD"), $child)
      writeFile(getEnv("CT_TEST_REPLAY_CHILD") & ".alive", "")
      echo "old engine"
  else: quit(2)
  quit(0)

proc fixtureGit(root: string; args: varargs[string]): string =
  ## A failed fixture command must not turn the across-commit control into
  ## a comparison of two working trees that never actually committed.
  let p = startProcess("git", workingDir = root,
    args = @["-c", "commit.gpgsign=false"] & @args,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  result = p.outputStream.readAll().strip()
  let code = p.waitForExit()
  if code != 0:
    raise newException(IOError, "fixture git " & args.join(" ") &
      " exited " & $code & ": " & result)

const ExpectedAssertions = when defined(windows): 13 else: 15
var checks = 0
template ck(condition: untyped) =
  inc checks
  check condition

suite "replay-server prerequisite revision":
  var saved: seq[(string, bool, string)]
  setup:
    for name in [ReplayServerBinEnv, "CODETRACER_REQUIRE_REPLAY_REVISION", "CT_TEST_REPLAY_PROBE"]:
      saved.add((name, existsEnv(name), getEnv(name)))
  teardown:
    for (name, present, value) in saved:
      if present: putEnv(name, value)
      else: delEnv(name)
    saved.setLen(0)

  test "an existing old engine is refused rather than used":
    putEnv(ReplayServerBinEnv, getAppFilename())
    putEnv("CODETRACER_REQUIRE_REPLAY_REVISION", "1")
    putEnv("CT_TEST_REPLAY_PROBE", "old")
    ck locateReplayServer() == ""

  test "a silent engine cannot hang the prerequisite probe":
    putEnv("CT_TEST_REPLAY_PROBE", "silent")
    ck "timed out" in replayServerRevisionProblem(getAppFilename(), codetracerCheckoutRoot(), 30)

  test "matching revision alone cannot hide different source bytes":
    putEnv("CT_TEST_REPLAY_PROBE", "stale")
    let problem = replayServerRevisionProblem(getAppFilename(), codetracerCheckoutRoot())
    ck "stale replay-server" in problem
    ck "deadbeef" in problem

  test "an unbounded response is refused":
    putEnv("CT_TEST_REPLAY_PROBE", "large")
    ck "response too large" in replayServerRevisionProblem(getAppFilename(), codetracerCheckoutRoot())

  test "fingerprints reflect working bytes and paths across commits":
    let dir = createTempDir("probe-source-", "")
    defer: removeDir(dir)
    discard fixtureGit(dir, "init", "-q")
    createDir(dir / "src/db-backend/src")
    let source = dir / "src/db-backend/src/main.rs"
    writeFile(source, "fn main() {}\n")
    discard fixtureGit(dir, "add", ".")
    discard fixtureGit(dir, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "commit", "-qm", "fixture")
    let baseline = replaySourceFingerprint(dir)
    ck baseline.len > 0
    writeFile(source, "fn main() { panic!(); }\n")
    ck replaySourceFingerprint(dir) != baseline
    writeFile(source, "fn main() {}\n")
    ck replaySourceFingerprint(dir) == baseline
    discard fixtureGit(dir, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
      "commit", "--allow-empty", "-qm", "same inputs")
    ck replaySourceFingerprint(dir) == baseline
    discard fixtureGit(dir, "mv", "src/db-backend/src/main.rs", "src/db-backend/src/renamed.rs")
    ck replaySourceFingerprint(dir) != baseline

  when not defined(windows):
    test "an exited engine's child holding stdout does not block refusal":
      let dir = createTempDir("probe-child-", "")
      let pidFile = dir / "child"
      putEnv("CT_TEST_REPLAY_CHILD", pidFile)
      putEnv("CT_TEST_REPLAY_PROBE", "inherited")
      defer:
        if fileExists(pidFile):
          discard posix.kill(Pid(parseInt(readFile(pidFile))), SIGKILL)
        delEnv("CT_TEST_REPLAY_CHILD")
        removeDir(dir)
      let problem = replayServerRevisionProblem(getAppFilename(), codetracerCheckoutRoot())
      ck "unsupported" in problem
      ck fileExists(pidFile & ".alive")

  test "the real engine reports the source fingerprint built from this checkout":
    # No stub can supply this positive control's expected fingerprint.
    let real = findReplayServerIn(codetracerCheckoutRoot())
    if real.len == 0:
      raise newException(IOError, "prerequisite missing: " & missingReplayServerMessage())
    ck replayServerRevisionProblem(real, codetracerCheckoutRoot()) == ""
    # The same actual engine is stale for a checkout with different backend
    # bytes. This exercises refusal against the real CLI, not only the stub.
    let other = createTempDir("other-replay-source-", "")
    defer: removeDir(other)
    discard fixtureGit(other, "init", "-q")
    createDir(other / "src/db-backend/src")
    writeFile(other / "src/db-backend/src/main.rs", "fn main() {}\n")
    discard fixtureGit(other, "add", ".")
    ck replaySourceFingerprint(other).len > 0
    ck "stale replay-server" in replayServerRevisionProblem(real, other)

suite "assertion tally":
  test "every assertion ran":
    check checks == ExpectedAssertions

echo "CHECKS: ", checks
