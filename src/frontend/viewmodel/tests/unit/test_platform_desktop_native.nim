## test_platform_desktop_native.nim
##
## The desktop instantiation of the platform facade, against the real host.
##
## NS1 asks for a "Desktop instantiation, with the existing product passing its
## suite unchanged". The second half of that is the lane matrix; this is the
## first half — evidence that the reference instantiation actually does what its
## signatures promise, rather than merely satisfying them.
##
## ## Nothing here is mocked, and nothing here is skipped
##
## Every case touches the real filesystem in a real temporary directory and
## spawns a real child process. There is no in-memory filesystem and no fake
## `Process`: a facade whose desktop instantiation was only ever exercised
## against a stub would be a facade nobody had checked. The directory is created
## per run and removed in `teardown`.
##
## This suite is C-backend only, and that is a fact about its subject rather
## than a skip: `host/desktop_native.nim` is `{.error.}` on the JS target by
## design, because the Electron renderer's instantiation is a different module
## (`host/desktop_electron.nim`) reaching different APIs. `ci/lib/test-lane-files.sh`
## therefore excludes this file from `vm-unit-js` by name, in the same way and
## for the same reason it excludes `test_project_action_runner.nim`.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_platform_desktop_native.nim

import std/[os, strutils, times, unittest]

import ../../platform/platform
import ../../host/desktop_native

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  ## See the note on the identical helper in `test_platform_facade.nim`: the
  ## drain is centralised so a forgotten one cannot turn an assertion into a
  ## no-op.
  var captured: PlatformOutcome[T]
  var settled = false

  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true

  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true

  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "a facade future never settled"
  captured

suite "the desktop instantiation serves the filesystem facade for real":

  setup:
    let host = newDesktopNativePlatform()
    let root = getTempDir() / "ct-ns1-fs-" & $getCurrentProcessId() &
               "-" & $epochTime().int64
    createDir(root)

  teardown:
    removeDir(root)

  test "a write is readable back, byte for byte":
    let path = root / "main.nr"
    check awaitOutcome(host.fs.writeText(path, "fn main() {}\n")).ok
    let read = awaitOutcome(host.fs.readText(path))
    check read.ok
    check read.value == "fn main() {}\n"

  test "bytes round-trip through the byte-oriented pair":
    let path = root / "blob.bin"
    let payload = @[byte(0), byte(1), byte(200), byte(255)]
    check awaitOutcome(host.fs.writeBytes(path, payload)).ok
    let read = awaitOutcome(host.fs.readBytes(path))
    check read.ok
    check read.value == payload

  test "a missing file is pkNotFound, not a generic failure":
    ## Callers branch on this to distinguish "no file" from "cannot read the
    ## file", and the two want different UI. A facade that collapsed them would
    ## look correct and be useless.
    let read = awaitOutcome(host.fs.readText(root / "absent.nr"))
    check not read.ok
    check read.error.kind == pkNotFound

  test "stat reports a missing path as missing rather than as an error":
    ## Deliberately different from `readText`: asking whether something exists
    ## is not an error when it does not.
    let stat = awaitOutcome(host.fs.stat(root / "absent.nr"))
    check stat.ok
    check stat.value.kind == fekMissing

  test "stat distinguishes a file from a directory and reports its size":
    check awaitOutcome(host.fs.writeText(root / "sized.txt", "12345")).ok
    let fileStat = awaitOutcome(host.fs.stat(root / "sized.txt"))
    check fileStat.ok
    check fileStat.value.kind == fekFile
    check fileStat.value.size == 5
    check fileStat.value.modifiedMs > 0

    check awaitOutcome(host.fs.createDir(root / "sub")).ok
    let dirStat = awaitOutcome(host.fs.stat(root / "sub"))
    check dirStat.ok
    check dirStat.value.kind == fekDirectory

  test "exists answers over stat without inventing an error":
    check awaitOutcome(host.fs.writeText(root / "here.txt", "x")).ok
    let present = awaitOutcome(host.fs.exists(root / "here.txt"))
    check present.ok
    check present.value
    let absent = awaitOutcome(host.fs.exists(root / "nowhere.txt"))
    check absent.ok
    check not absent.value

  test "a directory listing gives names, never paths":
    ## The contract in `fs.nim`: "The entry's own name, never a full path. The
    ## caller joins with `paths./` — which keeps a container's absolute paths
    ## out of the UI." Asserted because it is the kind of thing an
    ## implementation gets wrong in the convenient direction.
    check awaitOutcome(host.fs.createDir(root / "proj")).ok
    check awaitOutcome(host.fs.writeText(root / "proj" / "a.nr", "")).ok
    check awaitOutcome(host.fs.createDir(root / "proj" / "nested")).ok

    let listing = awaitOutcome(host.fs.listDir(root / "proj"))
    check listing.ok
    check listing.value.len == 2
    for entry in listing.value:
      check DirSep notin entry.name
      check entry.name in ["a.nr", "nested"]
      if entry.name == "a.nr": check entry.kind == fekFile
      else: check entry.kind == fekDirectory

  test "createDir is recursive and idempotent":
    let deep = root / "a" / "b" / "c"
    check awaitOutcome(host.fs.createDir(deep)).ok
    check awaitOutcome(host.fs.createDir(deep)).ok
    check dirExists(deep)

  test "remove refuses a missing path by name and removes a tree when asked":
    let missing = awaitOutcome(host.fs.remove(root / "gone", recursive = true))
    check not missing.ok
    check missing.error.kind == pkNotFound

    check awaitOutcome(host.fs.createDir(root / "tree" / "inner")).ok
    check awaitOutcome(host.fs.writeText(root / "tree" / "inner" / "f", "x")).ok
    check awaitOutcome(host.fs.remove(root / "tree", recursive = true)).ok
    check not dirExists(root / "tree")

  test "copy and move do what they say":
    check awaitOutcome(host.fs.writeText(root / "one.txt", "content")).ok
    check awaitOutcome(host.fs.copy(root / "one.txt", root / "two.txt")).ok
    check awaitOutcome(host.fs.readText(root / "two.txt")).value == "content"
    check awaitOutcome(host.fs.move(root / "two.txt", root / "three.txt")).ok
    check not fileExists(root / "two.txt")
    check awaitOutcome(host.fs.readText(root / "three.txt")).value == "content"

  test "append adds without truncating":
    check awaitOutcome(host.fs.writeText(root / "log", "a")).ok
    check awaitOutcome(host.fs.appendText(root / "log", "b")).ok
    check awaitOutcome(host.fs.readText(root / "log")).value == "ab"

  test "a temporary directory is created and is real":
    let temp = awaitOutcome(host.fs.makeTempDir("ct-ns1-"))
    check temp.ok
    check dirExists(temp.value)
    removeDir(temp.value)

suite "the desktop instantiation runs real processes":

  setup:
    let host = newDesktopNativePlatform()

  test "a one-shot run captures stdout and a zero exit":
    let run = awaitOutcome(host.process.run(
      processSpec("echo", @["hello", "facade"])))
    check run.ok
    check run.value.exit.exitCode == 0
    check run.value.exit.succeededExit
    check run.value.stdout.strip() == "hello facade"

  test "a non-zero exit is a successful call with a failing exit":
    ## The distinction the facade insists on: the *call* succeeded — the
    ## program ran — and the program said no. A facade that reported this as
    ## `PlatformOutcome.ok == false` would make "cannot run git" and "git said
    ## no" indistinguishable, which is the exact confusion `ui/git_cli.nim`'s
    ## catch-all `except: return ""` shipped with.
    let run = awaitOutcome(host.process.run(
      processSpec("sh", @["-c", "exit 3"])))
    check run.ok
    check run.value.exit.exitCode == 3
    check not run.value.exit.succeededExit

  test "stderr is captured separately from stdout":
    let run = awaitOutcome(host.process.run(
      processSpec("sh", @["-c", "echo out; echo err 1>&2"])))
    check run.ok
    check run.value.stdout.strip() == "out"
    check run.value.stderr.strip() == "err"

  test "stdin supplied up front reaches the child":
    let run = awaitOutcome(host.process.run(
      ProcessSpec(command: "cat", args: @[], stdinText: "piped\n")))
    check run.ok
    check run.value.stdout.strip() == "piped"

  test "environment additions reach the child without clearing the rest":
    let run = awaitOutcome(host.process.run(ProcessSpec(
      command: "sh", args: @["-c", "echo $CT_NS1_PROBE"],
      env: @[(key: "CT_NS1_PROBE", value: "set-by-facade")])))
    check run.ok
    check run.value.stdout.strip() == "set-by-facade"

  test "a program that does not exist is pkNotFound, not a crash":
    let run = awaitOutcome(host.process.run(
      processSpec("ct-no-such-program-ns1")))
    check not run.ok
    check run.error.kind == pkNotFound

  test "which finds a real program and refuses an unreal one":
    let found = awaitOutcome(host.process.which("sh"))
    check found.ok
    check found.value.len > 0
    let missing = awaitOutcome(host.process.which("ct-no-such-program-ns1"))
    check not missing.ok
    check missing.error.kind == pkNotFound

  test "a watchable child reports its exit through the callback":
    ## The `start` half of §9.3's requirement: a long run must not be a
    ## blocking call. This drives the poll the way a host's event loop would.
    var exited = false
    var observedCode = -1

    proc onOutput(chunk: ProcessOutputChunk) = discard
    proc onExit(exit: ProcessExit) =
      exited = true
      observedCode = exit.exitCode

    let started = awaitOutcome(host.process.start(
      processSpec("sh", @["-c", "exit 0"]), onOutput, onExit))
    check started.ok
    check ($started.value).len > 0

    # Poll the way a host would, with a bounded number of turns so a wedged
    # child fails the test rather than hanging the lane.
    var turns = 0
    while not exited and turns < 200:
      pumpDesktopProcesses()
      sleep(10)
      inc turns
    check exited
    check observedCode == 0

suite "an empty workingDir means the platform's default, and the platform supplies it":

  test "test_empty_working_dir_is_the_platforms_default_not_the_callers_cwd":
    ## `ProcessSpec.workingDir`'s contract, asserted because a caller was
    ## removed on the strength of it — NS1's call-site migration.
    ##
    ## `ui/git_cli.nim` computed its own fallback: when no project folder was
    ## open it passed `electronProcess.cwd()` as the working directory. The
    ## facade's own documentation says that is wrong on every platform, not
    ## just the web: "Empty means the platform's default, which on the web is
    ## the project store root and in a container is the workspace root. **Never
    ## the front end's own cwd — a front end has no business having one.**"
    ##
    ## Removing that fallback is only safe if the platform really does supply a
    ## default, so that is what this asserts rather than trusting the sentence.
    ## Both desktop instantiations happen to inherit the process's directory —
    ## `osproc.startProcess` with an empty `workingDir`, and node's
    ## `execFileSync` with `cwd: undefined` — which is exactly what the deleted
    ## fallback was computing by hand.
    let host = newDesktopNativePlatform()
    if not host.can(capProcessSpawn):
      skip()
    else:
      let here = getCurrentDir()

      let default = awaitOutcome(host.process.run(processSpec("pwd")))
      check default.ok
      check default.value.stdout.strip() == here

      # THE COUNTER-CHECK, and it is the half that can fail. "Empty means the
      # platform's default" is also satisfied by an instantiation that ignores
      # `workingDir` entirely — it would pass the assertion above for every
      # input. So an explicit directory must actually be honoured, and it is
      # checked against a directory that is NOT the one above.
      let elsewhere = "/"
      check elsewhere != here
      var spec = processSpec("pwd")
      spec.workingDir = elsewhere
      let explicitRun = awaitOutcome(host.process.run(spec))
      check explicitRun.ok
      check explicitRun.value.stdout.strip() == elsewhere

suite "the desktop instantiation declares no capability it cannot serve":

  test "every capability the profile claims has a working operation behind it":
    ## The check that keeps the capability table honest in the direction that
    ## matters: a profile that over-claims produces buttons that fail at run
    ## time, which is precisely what capabilities-as-data exists to prevent.
    let host = newDesktopNativePlatform()

    if host.can(capFilesystemRead):
      let read = awaitOutcome(host.fs.readText("/definitely/not/here"))
      check read.error.kind != pkNotSupported
    if host.can(capProcessSpawn):
      let run = awaitOutcome(host.process.run(processSpec("echo", @["x"])))
      check run.ok
    if host.can(capSettingsRead):
      # `pkNotFound` exactly — not "not pkNotSupported", and not a disjunction
      # that includes the value it is trying to rule out. A check written as
      # `a == X or a == Y` followed by `a != X` cannot distinguish a correct
      # implementation from one that returns Y for every input, and this
      # repository has shipped that shape before.
      let value = awaitOutcome(host.settings.get(ssSession, "ns1-absent-key"))
      check not value.ok
      check value.error.kind == pkNotFound

    # And the other direction: what it does NOT claim, it refuses by name
    # rather than by crashing.
    check not host.can(capClipboardWrite)
    let clip = awaitOutcome(host.clipboard.writeText("x"))
    check not clip.ok
    check clip.error.kind == pkNotSupported
    check host.degradedBehaviour(capClipboardWrite).len > 20

suite "the desktop instantiation serves settings against the real host":

  setup:
    let host = newDesktopNativePlatform()

  teardown:
    discard awaitOutcome(host.settings.delete(ssSession, "ns1-test-key"))

  test "a setting written is read back, and an unset one is pkNotFound":
    let absent = awaitOutcome(host.settings.get(ssSession, "ns1-test-key"))
    check not absent.ok
    check absent.error.kind == pkNotFound

    check awaitOutcome(host.settings.set(ssSession, "ns1-test-key", "value")).ok
    let present = awaitOutcome(host.settings.get(ssSession, "ns1-test-key"))
    check present.ok
    check present.value == "value"

  test "a key cannot escape its scope directory":
    ## `keyPath` sanitises, and this is the assertion that it does. A settings
    ## store that can write anywhere is not a settings store.
    check awaitOutcome(host.settings.set(
      ssSession, "../../escaped", "should-not-escape")).ok
    check not fileExists(getTempDir() / "escaped.txt")
    discard awaitOutcome(host.settings.delete(ssSession, "../../escaped"))

  test "the host environment is readable and reports an unset name honestly":
    let path = awaitOutcome(host.settings.environment("PATH"))
    check path.ok
    check path.value.len > 0
    let unset = awaitOutcome(host.settings.environment("CT_NS1_DEFINITELY_UNSET"))
    check not unset.ok
    check unset.error.kind == pkNotFound
