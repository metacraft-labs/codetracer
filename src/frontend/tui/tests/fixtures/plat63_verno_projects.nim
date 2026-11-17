## fixtures/plat63_verno_projects.nim — PLAT-63: the Noir packages and the
## recorded Verno runs every Verification suite drives, on every front-end.
##
## A library the suites import, not a suite.
##
## TWO PACKAGES, each a real Noir package on a real filesystem with its own
## `.vscode/tasks.json` declaring the Verno action the way
## `test-programs/noir_verification_failing` declares it (Noir-Studio.md
## §9.3: the project's own task, run verbatim):
##
## * `typeerr` — `main` returns a `Field` where it promised a `u32`. Its run
##   is the VN-M4 corpus' `pipeline_error_type_mismatch` pair: the verifier's
##   printed output (`../../../viewmodel/tests/fixtures/verno/
##   pipeline_error_type_mismatch.txt`) and the payload the same real run
##   wrote (`.../payload/pipeline_error_type_mismatch.json`), both recorded
##   from a real `verno` on `v1.0.0-beta.26` (see that corpus' PROVENANCE).
##   Its source is the corpus' "throwaway package", restored from the lines
##   the recorded output quotes (`fn main(x: u32) -> pub u32 {`, `let y:
##   Field = x;`, `y`) — so the located findings land on the text they quote.
## * `verus_post_failure` — Verno's own `test_programs/formal_verify_failure/
##   verus_post_failure/src/main.nr` (two false postconditions), byte for
##   byte. Its payload is `counterexample/verno_end_to_end_macos.json`, the
##   one document nobody authored any part of (a real `verno` → `venir` →
##   z3 run): its counterexamples are steppable. That run's printed output
##   was not kept, so the text tier replays `failed_obligation_assertion.txt`
##   — the pairing VN-M5's own suite drives (`test_counterexample_session.
##   vmWith`), whose one finding names a file this package does not have.
##
## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK. `verno` cannot be built on
## this machine (VN-M4/VN-M5: `venir` needs `rustc-dev` for a pinned
## toolchain and the package set no longer fetches). So the `verno` on the
## suites' PATH is a script that REPLAYS one recorded run: it prints the
## recorded output, exits with the recorded code, and writes the recorded
## payload where the real one writes it (`target/verno-report.json`). The one
## edit is the run's two timestamps, stamped with the time it runs: the
## consumer refuses a report that predates its run (Verification-Payload-
## Contract-v1 §7), which is exactly the rule a replay must not be allowed
## to bypass. Everything downstream is the product's: the task file read,
## the action recognised, the process launched and polled
## (`runquota_process`), the output classified, the report found by the
## discovery convention, decoded, checked for staleness and agreement, and
## attached.

import std/[os, strutils]

const
  VernoFixtureDir = currentSourcePath().parentDir() / ".." / ".." / ".." /
                    "viewmodel" / "tests" / "fixtures" / "verno"
  TypeErrOutput* = staticRead(VernoFixtureDir / "pipeline_error_type_mismatch.txt")
  TypeErrPayload* =
    staticRead(VernoFixtureDir / "payload" / "pipeline_error_type_mismatch.json")
  AssertionOutput* = staticRead(VernoFixtureDir / "failed_obligation_assertion.txt")
  EndToEndPayload* =
    staticRead(VernoFixtureDir / "counterexample" / "verno_end_to_end_macos.json")

  TypeErrSource* = "fn main(x: u32) -> pub u32 {\n" &
                   "    let y: Field = x;\n" &
                   "    y\n" &
                   "}\n"
    ## Lines 1-3 are the lines the recorded output quotes at `1:24`, `2:20`
    ## and `3:5`.

  VerusPostFailureSource* = """// Ported from Verus `examples/basic_failure.rs`
#['ensures(result == 1)]
fn fail_post_expr() -> u32 {
    0
}

#['ensures(*state == 1)]
fn fail_post_stmt(state: &mut u32) {
    *state = 0;
}

fn main() -> pub u32 {
    let mut value = 5;
    fail_post_stmt(&mut value);
    fail_post_expr();
    0
}
"""
    ## Verno `test_programs/formal_verify_failure/verus_post_failure/src/
    ## main.nr`, byte for byte: its obligations are at `2:12` and `7:12`.

  VernoTaskLabel* = "Verify with Verno"
  VernoArgs* = ["--program-dir", ".", "formal-verify", "--", "--rlimit", "60"]
  VernoCommandLine* = "verno --program-dir . formal-verify -- --rlimit 60"

  TypeErrExpectedRows* = [
    ## The findings as every front-end words them (kind, title, message,
    ## location), in the order the pane lists them.
    ("pipeline error", "typeerr/src/main.nr:2",
     "Expected type Field, found type u32", "typeerr/src/main.nr:2:20"),
    ("pipeline error", "typeerr/src/main.nr:1",
     "expected type u32, found type Field", "typeerr/src/main.nr:1:24")]

type
  VernoRun* = object
    root*: string
      ## The package (the window's project).
    bin*: string
      ## The directory whose `verno` replays the run; put it first on PATH.

proc tasksJson(): string =
  var args = ""
  for i, a in VernoArgs:
    if i > 0: args.add ", "
    args.add "\"" & a & "\""
  "{\n  \"version\": \"2.0.0\",\n  \"tasks\": [\n    {\n" &
    "      \"label\": \"" & VernoTaskLabel & "\",\n" &
    "      \"type\": \"shell\",\n      \"command\": \"verno\",\n" &
    "      \"args\": [" & args & "],\n      \"group\": \"test\"\n" &
    "    }\n  ]\n}\n"

proc writeStandIn(bin, output, payload: string; exitCode: int) =
  ## The replaying `verno` (see the header).
  createDir(bin)
  writeFile(bin / "recorded-output.txt", output)
  writeFile(bin / "recorded-payload.json", payload)
  let script = bin / "verno"
  writeFile(script, "#!/bin/sh\n" &
    "# The recorded run (PLAT-63 fixtures): its output, its report (stamped\n" &
    "# with this run's time), its exit code.\n" &
    "here=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n" &
    "now=$(date +%s%3N)\n" &
    "mkdir -p target\n" &
    "sed -E \"s/\\\"(started|finished)_at_unix_ms\\\": *[0-9]+/\\\"\\1_at_unix_ms\\\": $now/\" " &
    "\"$here/recorded-payload.json\" > target/verno-report.json\n" &
    "cat \"$here/recorded-output.txt\"\n" &
    "# A suite that needs a run still in flight (to watch it live, to Stop\n" &
    "# it) leaves a `hold` file beside this script; the run then waits.\n" &
    "if [ -e \"$here/hold\" ]; then sleep 60; fi\n" &
    "exit " & $exitCode & "\n")
  setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec,
                              fpGroupRead, fpGroupExec, fpOthersRead,
                              fpOthersExec})

proc writePackage(root, name, source: string) =
  createDir(root / "src")
  createDir(root / ".vscode")
  writeFile(root / "Nargo.toml", "[package]\nname = \"" & name &
    "\"\ntype = \"bin\"\nauthors = [\"\"]\n\n[dependencies]\n")
  writeFile(root / "src" / "main.nr", source)
  writeFile(root / ".vscode" / "tasks.json", tasksJson())

proc scratchDir(tag: string): string =
  result = getTempDir() / "ct-plat63-" & tag & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc writeTypeErrRun*(): VernoRun =
  ## The `typeerr` package and its recorded pipeline-error run.
  let base = scratchDir("typeerr")
  result.root = base / "typeerr"
  writePackage(result.root, "typeerr", TypeErrSource)
  result.bin = base / "bin"
  writeStandIn(result.bin, TypeErrOutput, TypeErrPayload, 1)

proc writeCounterexampleRun*(): VernoRun =
  ## The `verus_post_failure` package and its run with a steppable
  ## counterexample.
  let base = scratchDir("cx")
  result.root = base / "verus_post_failure"
  writePackage(result.root, "verus_post_failure", VerusPostFailureSource)
  result.bin = base / "bin"
  writeStandIn(result.bin, AssertionOutput, EndToEndPayload, 1)

proc withVernoOnPath*(run: VernoRun) =
  ## Put the run's `verno` first on PATH (for this process and its children).
  let path = getEnv("PATH")
  if not path.startsWith(run.bin & ":"):
    putEnv("PATH", run.bin & ":" & path)

proc removeRun*(run: VernoRun) =
  removeDir(run.root.parentDir)

proc lineOf*(source: string; line: int): string =
  ## Line `line` (1-based) of `source`.
  let lines = source.splitLines
  if line >= 1 and line <= lines.len: lines[line - 1] else: ""

when isMainModule:
  # The desktop's suite (`src/tests/gui/tests/verification-pane/
  # desktop_verno_run.spec.ts`) writes its package and its replaying `verno`
  # through this same code, so every front-end runs the same recorded run:
  # `plat63_verno_projects typeerr|cx` prints the package root and the
  # replay's directory, one per line.
  let run =
    if paramCount() >= 1 and paramStr(1) == "cx": writeCounterexampleRun()
    else: writeTypeErrRun()
  echo run.root
  echo run.bin
