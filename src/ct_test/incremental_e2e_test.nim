## M18 — `ct test --incremental` performs trace-based incremental selection
## standalone, validated END-TO-END against a LIVE Python recording.
##
## NO hand-crafted trace, NO `unittest.skip`. The test writes a real 4-function
## Python program (`used_a`, `used_b`, `used_c` executed via `main`; `unused_d`
## defined but never called), drives the SAME standalone `decideIncremental`
## path the `ct test --incremental` CLI uses (record a live CTFS `.ct` baseline
## with the PRODUCTION maturin/PyO3 recorder, extract the executed set, decide
## skip-vs-rerun against the CURRENT source), and asserts the §16.7 decisions:
##
##   * first invocation (no baseline) ⇒ `idRunFresh` ("run fresh baseline");
##   * a no-op re-run (program unchanged) ⇒ `idSkipUnchanged` (SKIP);
##   * editing an EXECUTED function ⇒ `idRerunChanged` naming exactly that
##     function (RE-RUN); and
##   * editing the UNEXECUTED `unused_d` ⇒ `idSkipUnchanged` (SKIP) — function-
##     level, not file-level, precision over one shared live source file.
##
## Every decision is made from a REAL, freshly-recorded CTFS bundle read via
## `ct-print --json-events`. This mirrors `reprobuild/.../tests/t_live_python.nim`
## but exercises CodeTracer's OWN vendored engine + the M18 CLI core.
##
## # Provisioning (build once, reuse — NO silent skips)
##
## The recorder is built at most once by the CLI's `ensurePythonRecorderBuilt`
## (cached by its on-disk native extension + the `.venv` interpreter). `ct-print`
## is resolved via `$CT_PRINT` / PATH / the known build path
## `/tmp/ctprint_build/ct-print`. The production Python recorder builds and
## records on this host (arm64 macOS), so this test MUST pass here; a genuine
## recorder gate FAILS LOUDLY with the captured diagnostic, never `skip`.

import std/[unittest, os, strutils]

import incremental_cli
import incremental/engine

const
  # The 4-function program. used_a/used_b/used_c are executed (called from main);
  # unused_d is defined but never called, so the recorder never emits it as a
  # called function — it is absent from the live trace's executed set.
  pythonProgram = """def used_a(x):
    return x + 1

def used_b(x):
    return x * 2

def used_c(x):
    return x - 3

def unused_d(x):
    return x - 99

def main():
    print(used_a(2) + used_b(3) + used_c(4))

main()
"""

proc workspaceForTest(): string =
  ## The workspace dir holding codetracer + the recorder siblings. The test runs
  ## from inside the codetracer checkout; the recorders are siblings two levels
  ## up from `src/ct_test`. Prefer the env override the harness already honours.
  let override = getEnv("CODETRACER_WORKSPACE_ROOT")
  if override.len > 0:
    return override
  # src/ct_test/<this file> -> codetracer repo root -> workspace root.
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  repoRoot.parentDir

proc writeProgram(path, body: string) =
  createDir(path.parentDir)
  writeFile(path, body)

proc editPyFunctionBody(progPath, funcName, newBodyLine: string) =
  ## Replace the single indented body line of `def <funcName>(...)` in `progPath`
  ## (each function's body is the one `return ...` line below its `def`).
  var lines = readFile(progPath).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("def " & funcName) and i + 1 < lines.len:
      lines[i+1] = newBodyLine
      writeFile(progPath, lines.join("\n"))
      return
  doAssert false, "function not found in python program: " & funcName

suite "M18 ct test --incremental (live Python)":

  test "incremental_selection_decides_end_to_end":
    let ws = workspaceForTest()
    # A stable program path: the recorder records its ABSOLUTE path, and with
    # sourceRoot="/" the engine resolves that recorded path back to THIS file, so
    # an in-place edit is what `decide` re-hashes (the real watch-cycle scenario).
    let progDir = getTempDir() / ("ct_m18_incr_" & $getCurrentProcessId())
    if dirExists(progDir): removeDir(progDir)
    let progPath = progDir / "prog.py"
    writeProgram(progPath, pythonProgram)
    let cachePath = progDir / "cache.json"

    proc args(): IncrementalArgs =
      IncrementalArgs(
        language: ilPython,
        program: progPath,
        sourceRoot: "/",         # recorded absolute path resolves to progPath
        cachePath: cachePath,
        testId: "prog.py")

    # --- (0) first invocation: no baseline ⇒ record fresh -----------------------
    let r0 = decideIncremental(args(), ws)
    # The production Python recorder builds + records on this host: a gate here is
    # a HARD failure (never a silent skip), surfacing the exact captured output.
    if r0.kind == irkGated:
      checkpoint("Python live recording gated unexpectedly:\n" & r0.message)
    require r0.kind == irkDecided
    check r0.decision.kind == idRunFresh
    checkpoint("(0) " & r0.report)

    # --- (a) no-op re-run: unchanged program ⇒ SKIP ----------------------------
    let rA = decideIncremental(args(), ws)
    require rA.kind == irkDecided
    if rA.decision.kind != idSkipUnchanged:
      checkpoint("(a) expected SKIP, got: " & rA.report)
    check rA.decision.kind == idSkipUnchanged
    checkpoint("(a) " & rA.report)

    # --- (b) edit an EXECUTED function (used_b) ⇒ RE-RUN naming it --------------
    # used_b IS executed, so editing its body changes the executed set's deep hash
    # and the engine must re-run, naming used_b. used_a/used_c (also executed,
    # unedited) must NOT be listed — function-level precision over a REAL bundle.
    editPyFunctionBody(progPath, "used_b", "    return x * 2000")
    let rB = decideIncremental(args(), ws)
    require rB.kind == irkDecided
    if rB.decision.kind != idRerunChanged:
      checkpoint("(b) expected RERUN, got: " & rB.report)
    check rB.decision.kind == idRerunChanged
    check "used_b" in rB.decision.changedFuncs
    check "used_a" notin rB.decision.changedFuncs
    check "used_c" notin rB.decision.changedFuncs
    checkpoint("(b) " & rB.report)

    # The re-run re-recorded the baseline against the edited source, so the next
    # no-op re-run SKIPs again (the cache now tracks the edited body's hash).
    let rB2 = decideIncremental(args(), ws)
    require rB2.kind == irkDecided
    check rB2.decision.kind == idSkipUnchanged
    checkpoint("(b2) " & rB2.report)

    # --- (c) edit the UNEXECUTED unused_d ⇒ still SKIP --------------------------
    # unused_d is never called, so it is absent from the live executed set; its
    # body sits OUTSIDE every executed function's extracted body (the indentation
    # extractor stops each function at the next sibling-indent `def`), so no
    # executed function's hash changes.
    editPyFunctionBody(progPath, "unused_d", "    return x - 123456")
    let rC = decideIncremental(args(), ws)
    require rC.kind == irkDecided
    if rC.decision.kind != idSkipUnchanged:
      checkpoint("(c) expected SKIP, got: " & rC.report)
    check rC.decision.kind == idSkipUnchanged
    checkpoint("(c) " & rC.report)

    removeDir(progDir)
