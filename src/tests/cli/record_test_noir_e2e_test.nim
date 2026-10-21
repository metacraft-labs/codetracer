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

import std/[os, osproc, streams, strtabs, strutils, unittest]

const RecordTimeoutSeconds = 600

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

proc recordTest(selector, file: string; line: int): tuple[output: string, code: int] =
  ## `ct record-test` exactly as the desktop's main process runs it, in a
  ## scratch `CODETRACER_HOME`, with the `nargo` `nargoBinary` names.
  let env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["CODETRACER_HOME"] = scratch / "home"
  env["CODETRACER_NOIR_EXE_PATH"] = nargoBinary()
  let p = startProcess(ctBinary(),
    args = @["record-test", selector, file, $line, "1"],
    env = env, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit(RecordTimeoutSeconds * 1000)
  p.close()
  (output, code)

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
