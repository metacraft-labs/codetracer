## M-REC-7 acceptance tests for the on-disk recording folder layout.
##
## Covers the three deliverables in §M-REC-7 of
## ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.status.org``:
##
## 1. Recorder output path uses ``recording_id``.
##    Exercised by simulating ``db_backend_record.record`` /
##    ``storage_and_import.importTrace`` in a fresh ``XDG_DATA_HOME`` and
##    asserting that the resulting folder is named exactly
##    ``<recording_id>`` (the canonical 36-char UUIDv7 form), with no
##    ``trace-`` / ``trace_`` prefix and no ``<int>`` suffix.
##
## 2. ``ct`` frontend resolves a recording by id → folder via the DB row
##    written by the recorder.  The frontend reads ``trace.outputFolder``
##    rather than reconstructing the folder name itself, so the
##    contract under test is: ``trace_index.find(<recording_id>)``
##    returns a row whose ``outputFolder`` ends in the bare UUIDv7.
##
## 3. No surviving ``trace_<int>/`` folder name pattern.  The
##    ``paths.recordingFolder`` helper is the single source of truth
##    for folder-name construction; the test additionally invokes it
##    with a synthetic id and verifies the output shape (no prefix, no
##    suffix, ends in the id).
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/recording_folder_layout_test \
##       src/common/recording_folder_layout_test.nim
##
## Each scenario spawns ``recording_folder_layout_test_helper`` as a
## fresh subprocess with ``XDG_DATA_HOME`` pre-pointed at a tmpdir, so
## that ``trace_index`` re-resolves ``paths.app`` cleanly per run.  This
## mirrors the ``trace_index_test.nim`` pattern; the helper builds once
## and is cached across scenarios.

import std/[os, osproc, streams, strtabs, strutils, unittest, tempfiles]

# ---------------------------------------------------------------------------
# Helper subprocess builder
# ---------------------------------------------------------------------------

let helperSource = currentSourcePath.parentDir /
  "recording_folder_layout_test_helper.nim"

let helperCache = getTempDir() / "ct-recording-folder-layout-helper-cache"

proc compileHelper(): string =
  ## Compile the subprocess helper once and return the binary path.
  ## Returns "" on failure so the test reports the error rather than
  ## crashing on a missing binary.
  removeDir(helperCache)
  createDir(helperCache)
  let bin = helperCache / "recording_folder_layout_test_helper"
  ## Match ``trace_index_test.nim``'s build flags: no SSL since the
  ## helper does not exercise HTTPS, and forced refc GC to stay
  ## compatible with the rest of the codebase's compile invocations.
  let cmd = "nim c --hints:off --warnings:off --mm:refc " &
            "--nimcache:" & quoteShell(helperCache) & " " &
            "--out:" & quoteShell(bin) & " " &
            quoteShell(helperSource)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo "recording_folder_layout_test: helper compile FAILED:"
    echo output
    return ""
  return bin

let helperBin = compileHelper()

proc makeTmpHome(name: string): string =
  ## Fresh tmpdir per scenario so cases stay independent.
  createTempDir("ct-recording-folder-layout-" & name & "-", "")

proc runScenario(bin, scenario, homeDir: string):
    tuple[ok: bool, stdoutStr: string, stderrStr: string] =
  ## Run ``bin`` with ``XDG_DATA_HOME``/``HOME``/``TMPDIR`` pointed at
  ## ``homeDir``.  Splice ``CT_LD_LIBRARY_PATH`` onto ``LD_LIBRARY_PATH``
  ## so SQLite can be dlopen-ed inside the Nix dev-shell — same recipe
  ## as ``trace_index_test.nim``.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["XDG_DATA_HOME"] = homeDir
  env["TMPDIR"] = homeDir
  env["HOME"] = homeDir
  let ctLd = getEnv("CT_LD_LIBRARY_PATH")
  if ctLd.len > 0:
    let existing = getEnv("LD_LIBRARY_PATH")
    env["LD_LIBRARY_PATH"] =
      if existing.len > 0: ctLd & ":" & existing
      else: ctLd

  let p = startProcess(
    bin,
    args = @[scenario],
    env = env,
    options = {})
  defer: p.close()
  let stdoutStr = p.outputStream.readAll()
  let stderrStr = p.errorStream.readAll()
  let code = p.waitForExit()
  (code == 0, stdoutStr, stderrStr)

proc runHelperScenario(scenario, name: string):
    tuple[ok: bool, stdoutStr: string, stderrStr: string] =
  let home = makeTmpHome(name)
  defer: removeDir(home)
  runScenario(helperBin, scenario, home)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M-REC-7 — recording folder is the bare UUIDv7":

  test "helper compiles":
    check helperBin.len > 0

  test "paths.recordingFolder returns <baseDir>/<recording_id> with no prefix":
    ## The folder-name helper is the single source of truth for the
    ## new on-disk layout (parent spec §4).  Assert directly on its
    ## output so the test fails loudly if anyone reintroduces a
    ## ``trace-`` / ``trace_`` prefix in the helper.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "recording-folder-helper", "helper")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "simulated recorder write lands at <traces>/<recording_id>/":
    ## End-to-end deliverable #1: simulate the recorder flow —
    ## newID → recordingFolder → createDir → recordTrace — in a fresh
    ## ``XDG_DATA_HOME`` and assert the on-disk folder name is the bare
    ## UUIDv7.  No ``trace-``/``trace_`` prefix; no integer suffix.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "simulated-recording", "recording")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "ct list-equivalent (trace_index.all) returns the bare-UUID folder":
    ## End-to-end deliverable #2: the frontend resolves recording-id →
    ## folder via ``trace.outputFolder`` (no client-side reconstruction).
    ## The contract under test is that ``trace_index.all`` returns the
    ## same row written by the recorder, with ``outputFolder`` ending
    ## in the bare UUIDv7.  This is what ``ct list`` and the index
    ## webcontents handler iterate over.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "list-finds-bare-uuid", "list")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "ct replay-equivalent (trace_index.find) opens by <recording_id>":
    ## End-to-end deliverable #2 (cont.): ``ct replay <recording_id>``
    ## resolves the id via ``trace_index.find`` → ``trace.outputFolder``.
    ## Assert that find returns the row keyed by the bare UUIDv7 and
    ## that the returned folder is the one created by the simulated
    ## recorder, not a reconstructed ``trace-<id>`` path.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "replay-by-recording-id", "replay")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr
