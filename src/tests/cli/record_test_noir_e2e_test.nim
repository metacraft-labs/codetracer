## record_test_noir_e2e_test.nim
##
## `ct record-test` on a NOIR test makes a recording of that test — the real
## `ct`, the real `db-backend-record`, the real `nargo trace --test-name`.
##
## Issue: codetracer-pm `issues/2026-10-21-ct-record-test-cannot-record-a-noir-test.md`.
## Before the Noir route in `src/ct/trace/record.nim` `recordTest`, every
## Noir test fell to its final arm, "currently `ct record-test` not supported
## for this db-based language", and exited 1 — so the desktop editor's Run
## test, the Test Results pane's `⟳` and its record-and-open all failed on
## every Noir project.
##
## The cases:
##
## 1. A passing top-level test records, and `ct` prints `recordingId:<id>`.
## 2. The catalog's fully-qualified selector (`tests::test_nested`) and the
##    editor scan's bare name (`test_nested`) both record the nested test.
## 3. A FAILING test still records: tracing records an execution up to the
##    failure (the `Error` event); adjudicating it is `ct test run`'s job.
## 4. A name that matches no test fails, with nargo's own sentence.
## 5. A `.nr` file in no Noir package fails before nargo is run, saying why.
##
## And a guard on the harness itself: every run goes through
## `runWithDeadline`, and a run past its deadline is killed together with the
## processes it spawned, and reported as timed out.
##
## PREREQUISITE, AND IT FAILS BY NAME: a `nargo` that knows `trace
## --test-name` — `CODETRACER_NOIR_EXE_PATH` when set, else the dev shell's
## `nargo` (the flake's pinned noir). A noir sibling's build is never picked
## up implicitly, for the reason `scripts/detect-siblings.sh` gives: a stale
## one records on one machine only. A `nargo` from a noir revision before
## `--test-name` makes every recording case fail on `unexpected argument
## '--test-name'` — the honest answer for that pin, not a skip.
##
## Mocking justification (workspace policy on mock objects): none. Real
## binaries, a real Noir crate in a scratch directory, and a scratch
## `CODETRACER_HOME` so the recordings never reach the developer's own index.
##
## Compile and run:
##   nim c -r src/tests/cli/record_test_noir_e2e_test.nim

import std/[os, osproc, posix, strtabs, strutils, times, unittest]

const RecordTimeoutSeconds = 600
  ## A cold recording is slow, so this is generous -- but it is ENFORCED:
  ## `runWithDeadline` kills the run when it passes, and the case fails
  ## saying so, rather than wedging the lane on a hung recorder.

proc repoRoot(): string =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len == 0:
    result = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug") /
      "bin" / "ct"

proc nargoBinary(): string =
  ## `CODETRACER_NOIR_EXE_PATH`, else the `nargo` the dev shell puts on PATH
  ## (the flake pin). Whichever it is, `recordTest` hands it to `ct` as
  ## `CODETRACER_NOIR_EXE_PATH` (`paths.noirExe`'s override), so the recording
  ## is made by exactly the binary named here.
  result = getEnv("CODETRACER_NOIR_EXE_PATH", "")
  if result.len == 0:
    result = findExe("nargo")

let scratch = getTempDir() / ("ct-record-test-noir-" & $getCurrentProcessId())
removeDir(scratch)
let crate = scratch / "crate"
createDir(crate / "src")
writeFile(crate / "Nargo.toml",
  "[package]\nname = \"rt_noir\"\ntype = \"bin\"\nauthors = [\"\"]\n\n[dependencies]\n")
writeFile(crate / "Prover.toml", "x = \"1\"\ny = \"2\"\n")
writeFile(crate / "src" / "main.nr", """fn main(x: Field, y: pub Field) {
    assert(add_one(x) == y);
}

fn add_one(v: Field) -> Field {
    v + 1
}

#[test]
fn test_passes() {
    let r = add_one(2);
    assert(r == 3);
}

#[test]
fn test_fails() {
    let r = add_one(2);
    assert(r == 4);
}

mod tests {
    use crate::add_one;

    #[test]
    fn test_nested() {
        let r = add_one(10);
        assert(r == 11);
    }
}
""")
let lonely = scratch / "lonely"
createDir(lonely)
writeFile(lonely / "alone.nr", "#[test]\nfn t() {}\n")

const TimedOutCode* = -2
  ## `runWithDeadline`'s exit code for a run it had to kill.

var runCounter = 0
  ## Gives each run its own output file within this process's `scratch`.

proc inheritedEnv(): StringTableRef =
  ## This process's environment, as a table a run can add to. A run needs at
  ## least its `PATH`: with an empty table `sh` falls back to a built-in
  ## search path, which on NixOS holds no `sleep` or other coreutils.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v

proc runWithDeadline*(exe: string; args: seq[string]; env: StringTableRef;
                      timeoutSeconds: int): tuple[output: string, code: int] =
  ## Run `exe`, merged stdout+stderr, and give up after `timeoutSeconds`.
  ##
  ## THE DEADLINE IS REAL. Reading a pipe to EOF before `waitForExit(timeout)`
  ## blocks for as long as the child holds its stdout open, so the timeout
  ## could never fire. Here the child writes to a file (via `sh -c 'exec ..'`,
  ## so the shell is replaced and the pid is the child's own) and this loop
  ## polls `peekExitCode` against the deadline. `poDaemon` starts the child in
  ## its OWN PROCESS GROUP (`posix_spawnattr_setpgroup(.., 0)` in `std/osproc`),
  ## so an expired run is killed with everything it spawned -- `ct
  ## record-test` runs `db-backend-record`, which runs `nargo` -- rather than
  ## leaving a recorder orphaned behind the test.
  inc runCounter
  let outFile = scratch / ("run-" & $runCounter & ".log")
  createDir(scratch)
  let p = startProcess(findExe("sh"),
    args = @["-c", "exec \"$0\" \"$@\" > \"$CT_E2E_OUT\" 2>&1", exe] & args,
    env = (block:
      let e = newStringTable(modeCaseSensitive)
      for k, v in env: e[k] = v
      e["CT_E2E_OUT"] = outFile
      e),
    options = {poDaemon, poParentStreams})
  let deadline = epochTime() + timeoutSeconds.float
  var code = p.peekExitCode()
  while code == -1:
    if epochTime() >= deadline:
      discard posix.kill(-Pid(p.processID), SIGKILL)
      discard p.waitForExit()
      p.close()
      let partial = (if fileExists(outFile): readFile(outFile) else: "")
      removeFile(outFile)
      return ("TIMED OUT after " & $timeoutSeconds & " s: `" & exe & " " &
              args.join(" ") & "` was killed with its process group. " &
              "Output so far:\n" & partial, TimedOutCode)
    sleep(200)
    code = p.peekExitCode()
  p.close()
  let output = (if fileExists(outFile): readFile(outFile) else: "")
  removeFile(outFile)
  (output, code)

proc recordTest(selector, file: string; line: int): tuple[output: string, code: int] =
  ## `ct record-test` exactly as the desktop's main process runs it, in a
  ## scratch `CODETRACER_HOME`, with the `nargo` `nargoBinary` names.
  let env = inheritedEnv()
  env["CODETRACER_HOME"] = scratch / "home"
  env["CODETRACER_NOIR_EXE_PATH"] = nargoBinary()
  runWithDeadline(ctBinary(), @["record-test", selector, file, $line, "1"],
                  env, RecordTimeoutSeconds)

proc recordingId(output: string): string =
  for line in output.splitLines():
    if line.startsWith("recordingId:"):
      result = line["recordingId:".len .. ^1].strip()

proc ctContainers(): int =
  ## Every `.ct` container recorded into the scratch home so far.
  if dirExists(scratch / "home"):
    for path in walkDirRec(scratch / "home"):
      if path.endsWith(".ct"):
        inc result

suite "the run deadline is enforced":

  test "a run past its deadline is killed with what it spawned, and says so":
    ## The guard on `runWithDeadline` itself: without it a hung recorder would
    ## wedge this suite for ever, which is the defect a pipe read to EOF
    ## before `waitForExit(timeout)` had. The command is a shell that starts a
    ## child and waits on it, so "killed with its process group" is checked
    ## and not just "the shell died".
    let marker = "31.4159"
    let started = epochTime()
    let (output, code) = runWithDeadline(findExe("sh"),
      @["-c", "sleep " & marker & " & wait"], inheritedEnv(), 1)
    let elapsed = epochTime() - started
    checkpoint(output)
    check code == TimedOutCode
    check output.startsWith("TIMED OUT after 1 s")
    check elapsed < 10.0
    sleep(300)
    check execProcess("pgrep", args = ["-f", "sleep " & marker],
                      options = {poUsePath}).strip() == ""

suite "ct record-test records a Noir test":

  test "the prerequisites are present":
    checkpoint("ct: " & ctBinary())
    checkpoint("nargo: " & nargoBinary())
    check fileExists(ctBinary())
    check fileExists(nargoBinary())

  test "a passing test records, and ct names the recording":
    let before = ctContainers()
    let (output, code) = recordTest("test_passes", crate / "src" / "main.nr", 9)
    checkpoint(output)
    check code == 0
    check recordingId(output).len > 0
    check ctContainers() == before + 1

  test "the catalog's qualified selector and the bare name both record the nested test":
    for selector in ["tests::test_nested", "test_nested"]:
      let before = ctContainers()
      let (output, code) = recordTest(selector, crate / "src" / "main.nr", 25)
      checkpoint(selector & ": " & output)
      check code == 0
      check recordingId(output).len > 0
      check ctContainers() == before + 1

  test "a failing test still records, up to its failure":
    let (output, code) = recordTest("test_fails", crate / "src" / "main.nr", 15)
    checkpoint(output)
    check code == 0
    check recordingId(output).len > 0

  test "a name that matches no test fails, with nargo's sentence":
    let (output, code) = recordTest("no_such_test", crate / "src" / "main.nr", 1)
    checkpoint(output)
    check code != 0
    check recordingId(output) == ""
    check "`no_such_test` does not match with any test function" in output

  test "a .nr file in no Noir package fails before nargo runs, saying why":
    let (output, code) = recordTest("t", lonely / "alone.nr", 2)
    checkpoint(output)
    check code != 0
    check "is not inside a Noir package" in output

removeDir(scratch)
