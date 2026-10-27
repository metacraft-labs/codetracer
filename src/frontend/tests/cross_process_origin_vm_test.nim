## Cross-process origin — headless ViewModel test.
##
## The headless-first policy in
## `codetracer-specs/Testing/Testing-Guidelines.md` requires every GUI
## test to have a ViewModel counterpart, so that a failing GUI test can
## be localised to either the view layer or the state layer in
## milliseconds instead of minutes.
##
## This is the counterpart to
## `src/tests/gui/tests/value-origin/cross-tracer-three-recording.spec.ts`.
## It asserts the state a three-recording session puts the view models
## into:
##
##   * `SessionViewModel.processTree` lists all three recordings,
##   * `OriginChainVM.activeChain` carries one `CrossProcessSpan` per
##     recording the chain visits,
##   * clicking a hop that belongs to another recording rotates
##     `activeProcessRecordingId`.
##
## Like `value_origin_test.nim`, the chain is **not** hand-written: it
## is produced by a real `ct/originChain` request against the real
## three-recording demo session, dumped to JSON by the Rust helper
## `origin_chain_dump_helper.rs`, and parsed here with the production
## `parseOriginChain`. Hand-authoring the chain would make this test
## agree with itself rather than with the backend.
##
## Compile + run:
##   nim c -r src/frontend/tests/cross_process_origin_vm_test.nim

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

import isonim/core/[signals, owner]

import ../viewmodel/backend/[backend_service, mock_backend]
import ../viewmodel/session_vm
import ../viewmodel/viewmodels/[origin_chain_types, origin_chain_vm]

const
  ScenarioName = "cross_process_three_trace"
  DumpHelperTest = "origin_chain_dump_helper"

proc repoRoot(): string =
  ## `<repo>/src/frontend/tests/<this file>` → `<repo>`.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc runDumpHelper(outDir: string): tuple[ok: bool, output: string] =
  ## Drive the Rust helper that produces the chain dump.
  ##
  ## Shelling out keeps one implementation of "ask the backend for a
  ## cross-process chain" — the helper uses the same DAP client the
  ## headless DAP test uses — rather than reimplementing the session
  ## launch in Nim and risking the two drifting apart.
  let dbBackend = repoRoot() / "src" / "db-backend"
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["ORIGIN_DUMP_OUT_DIR"] = outDir
  let process = startProcess(
    "cargo",
    workingDir = dbBackend,
    args = ["test", "--test", DumpHelperTest, "--", "--ignored", "--nocapture"],
    env = env,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  (code == 0, output)

const
  ## The lane runner (`ci/lib/run-nim-test-lane.sh`) shows a failing case
  ## as the 25 lines BEFORE its `[FAILED]` marker, and `checkpoint` prints
  ## the reason inside that window. The helper's raw output is a whole
  ## `cargo test` run — compile progress, the materialiser's progress, the
  ## libtest summary — so checkpointing all of it left only its tail in the
  ## lane report, and the one line that said WHY (the materialiser's
  ## "missing prerequisites" list) was cut off every time. The summary is
  ## kept under that window; the full output goes to a log file it names.
  MaxSummaryLines = 18
  FallbackTailLines = 10
  ## Non-empty lines kept from just before the panic when the output has no
  ## `materialize-recording:` line. The harness inherits the materialiser's
  ## stderr and panics right after it exits, so whatever stopped it — a
  ## diagnostic from a script it sources (`js-recorder-path.sh` prints one
  ## without the prefix), or the tail of a failed `regenerate.sh` — is what
  ## precedes the panic, and the panic message itself points "above".
  PanicContextLines = 8

proc summarizeHelperFailure*(output, logPath: string): string =
  ## Reduce the dump helper's output to the lines that explain a failure:
  ##
  ##   * every `materialize-recording:` line, with the indented `- …`
  ##     prerequisite lines that follow it (scripts/materialize-recording.sh
  ##     prints its "cannot record … missing prerequisites:" list that way);
  ##     when there is none, the `PanicContextLines` non-empty lines before
  ##     the first panic instead,
  ##   * the `panicked at` line and the message line after it,
  ##   * the last libtest `test result:` line.
  ##
  ## When none of those is present (cargo failed to compile the helper, say)
  ## the last lines of the output stand in for them. The result always ends
  ## by naming `logPath`, where the caller saved the complete output.
  let lines = output.splitLines()
  var kept: seq[string] = @[]
  var testResult = ""
  var sawMaterialiser = false
  var firstPanic = -1      # index into `lines`
  var firstPanicKept = -1  # index into `kept`
  var i = 0
  while i < lines.len:
    let line = lines[i]
    let stripped = line.strip()
    if stripped.startsWith("materialize-recording:"):
      sawMaterialiser = true
      kept.add(stripped)
      var j = i + 1
      while j < lines.len and lines[j].strip().startsWith("- ") and
          lines[j].len > 0 and lines[j][0] in {' ', '\t'}:
        kept.add(lines[j].strip(leading = false))
        inc j
      i = j
      continue
    if "panicked at" in line:
      if firstPanic < 0:
        firstPanic = i
        firstPanicKept = kept.len
      kept.add(stripped)
      if i + 1 < lines.len and lines[i + 1].strip().len > 0:
        kept.add(lines[i + 1].strip())
        inc i
    elif stripped.startsWith("test result:"):
      testResult = stripped
    inc i
  if not sawMaterialiser and firstPanic >= 0:
    var context: seq[string] = @[]
    var k = firstPanic - 1
    while k >= 0 and context.len < PanicContextLines:
      if lines[k].strip().len > 0:
        context.insert(lines[k].strip(leading = false), 0)
      dec k
    for n, line in context:
      kept.insert(line, firstPanicKept + n)
  if testResult.len > 0:
    kept.add(testResult)
  if kept.len == 0:
    var nonEmpty: seq[string] = @[]
    for line in lines:
      if line.strip().len > 0:
        nonEmpty.add(line)
    kept = nonEmpty[max(0, nonEmpty.len - FallbackTailLines) .. ^1]
  if kept.len > MaxSummaryLines:
    let dropped = kept.len - MaxSummaryLines
    kept.setLen(MaxSummaryLines)
    kept.add("… " & $dropped & " more line(s)")
  kept.add("full helper output: " & logPath)
  kept.join("\n")

suite "Cross-process origin — dump helper failure report":
  ## Pure: no helper, no recording. Pins that a failing helper's reason
  ## survives the lane runner's 25-line window (see `MaxSummaryLines`).

  # The shape of a real failure on an unprovisioned host (codetracer-pm
  # issues/2026-10-21-test-frontend-units-does-not-provision-the-three-
  # trace-recording-its-cross-process-suite-needs.md): cargo's compile
  # chatter, the materialiser's list, the panic, then libtest's tail.
  proc unprovisionedOutput(): string =
    var parts: seq[string] = @[]
    for n in 1 .. 60:
      parts.add("   Compiling crate-" & $n & " v0.1.0")
    parts.add("running 4 tests")
    parts.add("materialize-recording: cannot record 'cross-process-three-trace' — missing prerequisites:")
    parts.add("    - ct-instrument not found (cargo build --release -p ct-instrument-cli in /ws/codetracer-wasm-instrumenter)")
    parts.add("    - session-manager not built (cargo build in /ws/codetracer/src/backend-manager)")
    parts.add("    - codetracer-js-recorder is not built (/ws/codetracer-js-recorder/packages/cli/dist/index.js; run 'just build' there)")
    parts.add("")
    parts.add("These recordings are produced from the current tree, not committed, so")
    parts.add("there is nothing to fall back to and no result that would mean anything.")
    parts.add("")
    parts.add("thread 'dump_cross_process_three_trace' panicked at tests/test_harness/mod.rs:5474:5:")
    parts.add("could not produce the `cross-process-three-trace` recording from this tree (exit status: 1)")
    parts.add("note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace")
    for n in 1 .. 30:
      parts.add("test dump_python_" & $n & " ... ok")
    parts.add("failures:")
    parts.add("    dump_cross_process_three_trace")
    parts.add("test result: FAILED. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out")
    parts.join("\n")

  test "the materialiser's missing-prerequisite list is kept, within the lane window":
    let summary = summarizeHelperFailure(unprovisionedOutput(), "/tmp/out/helper.log")
    let lines = summary.splitLines()
    check lines.len <= MaxSummaryLines + 2
    check lines.len < 25
    check "materialize-recording: cannot record 'cross-process-three-trace' — missing prerequisites:" in lines
    check "    - ct-instrument not found (cargo build --release -p ct-instrument-cli in /ws/codetracer-wasm-instrumenter)" in lines
    check "    - session-manager not built (cargo build in /ws/codetracer/src/backend-manager)" in lines
    check "    - codetracer-js-recorder is not built (/ws/codetracer-js-recorder/packages/cli/dist/index.js; run 'just build' there)" in lines
    check "thread 'dump_cross_process_three_trace' panicked at tests/test_harness/mod.rs:5474:5:" in lines
    check "could not produce the `cross-process-three-trace` recording from this tree (exit status: 1)" in lines
    check "test result: FAILED. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out" in lines
    check lines[^1] == "full helper output: /tmp/out/helper.log"
    check "Compiling" notin summary

  test "output with nothing recognisable falls back to its last lines":
    var parts: seq[string] = @[]
    for n in 1 .. 40:
      parts.add("error[E0425]: line " & $n)
    let lines = summarizeHelperFailure(parts.join("\n"), "/x.log").splitLines()
    check lines.len == FallbackTailLines + 1
    check lines[0] == "error[E0425]: line 31"
    check lines[^2] == "error[E0425]: line 40"
    check lines[^1] == "full helper output: /x.log"

  test "an overlong report is capped and says how much it dropped":
    var parts: seq[string] = @["materialize-recording: cannot record 'x' — missing prerequisites:"]
    for n in 1 .. 40:
      parts.add("    - tool-" & $n & " missing")
    let lines = summarizeHelperFailure(parts.join("\n"), "/x.log").splitLines()
    check lines.len == MaxSummaryLines + 2
    check lines[^2] == "… 23 more line(s)"
    check lines[^1] == "full helper output: /x.log"

  test "a diagnostic without the materialiser's prefix is kept from before the panic":
    # The shape measured with CODETRACER_JS_RECORDER_PATH pointing at a
    # missing file: scripts/js-recorder-path.sh refuses it without the
    # `materialize-recording:` prefix, and the first version of this summary
    # kept only the panic, which says "the diagnostic above".
    var parts: seq[string] = @[]
    for n in 1 .. 40:
      parts.add("warning: crate-" & $n & ": unused parameter")
    parts.add("running 4 tests")
    parts.add("CODETRACER_JS_RECORDER_PATH must name the CLI file <repo>/packages/cli/dist/index.js: /nope/index.js")
    parts.add("")
    parts.add("thread 'dump_cross_process_three_trace' (42) panicked at tests/test_harness/mod.rs:5474:5:")
    parts.add("could not produce the `cross-process-three-trace` recording from this tree (exit status: 1)")
    parts.add("test result: FAILED. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out")
    let lines = summarizeHelperFailure(parts.join("\n"), "/x.log").splitLines()
    check lines.len < 25
    check "CODETRACER_JS_RECORDER_PATH must name the CLI file <repo>/packages/cli/dist/index.js: /nope/index.js" in lines
    let diag = lines.find("CODETRACER_JS_RECORDER_PATH must name the CLI file <repo>/packages/cli/dist/index.js: /nope/index.js")
    let panic = lines.find("thread 'dump_cross_process_three_trace' (42) panicked at tests/test_harness/mod.rs:5474:5:")
    check diag >= 0 and panic > diag
    check lines.len == PanicContextLines + 2 + 1 + 1
    check lines[^1] == "full helper output: /x.log"

suite "Cross-process origin — ViewModel":
  var chainJson: JsonNode = nil
  var failReason = ""

  setup:
    if chainJson.isNil and failReason.len == 0:
      let outDir = getTempDir() / "ct-cross-process-vm-" & $getCurrentProcessId()
      createDir(outDir)
      let (ok, output) = runDumpHelper(outDir)
      let jsonPath = outDir / (ScenarioName & ".json")
      if fileExists(jsonPath):
        chainJson = parseFile(jsonPath)
      elif not ok:
        # The whole output goes to a file; the checkpoint carries only the
        # lines that say why, so they survive the lane runner's window.
        var logPath = outDir / "dump-helper-output.log"
        try:
          writeFile(logPath, output)
        except IOError as e:
          # Say so rather than name a file that does not exist; the
          # summary below is then the only record of the output.
          logPath = "(not saved: writing " & logPath & " failed: " &
            e.msg & ")"
        failReason = "the origin-chain dump helper failed:\n" &
          summarizeHelperFailure(output, logPath)
      else:
        failReason = "the dump helper produced no chain and reported success"

  test "the process tree lists all three recordings":
    # Independent of the chain dump: this is the session shape the
    # renderer's process tree binds to.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.applyListProcessesResponse(%*{
        "processes": [
          {"recordingId": "fe-js", "role": "frontend-js",
           "displayName": "frontend", "defaultThreadPrefix": "fe",
           "threadCount": 1},
          {"recordingId": "fe-wasm", "role": "frontend-wasm",
           "displayName": "frontend-wasm", "defaultThreadPrefix": "wasm",
           "threadCount": 1},
          {"recordingId": "be", "role": "backend",
           "displayName": "backend", "defaultThreadPrefix": "be",
           "threadCount": 1},
        ]
      })
      let entries = session.processTree.entries.val
      check entries.len == 3
      check entries[0].role == "frontend-js"
      check entries[1].role == "frontend-wasm"
      check entries[2].role == "backend"
      # The first entry is selected automatically so panels have a
      # recording to render before the user clicks anything.
      check session.activeProcessRecordingId.val == "fe-js"

  test "the real chain carries one span per recording it visits":
    # No skip. The demo is RECORDED by the dump helper when it runs
    # (`scripts/materialize-recording.sh`), so a helper that could not
    # deliver a chain means the recording pipeline is broken, not that
    # this machine is under-provisioned. Skipping here is what let this
    # counterpart assert nothing at all while the GUI spec it localises
    # went on being the campaign's only real evidence.
    if failReason.len > 0:
      checkpoint(failReason)
      fail()
    else:
      let chain = parseOriginChain(chainJson)
      check chain.crossProcessSpans.len >= 2
      var roles: seq[string] = @[]
      for span in chain.crossProcessSpans:
        roles.add(span.role)
      # The walk starts in the recording the query targeted.
      check roles[0] == "backend"
      check "frontend-js" in roles

  test "every span indexes a valid hop range or is a marked placeholder":
    # No skip. The demo is RECORDED by the dump helper when it runs
    # (`scripts/materialize-recording.sh`), so a helper that could not
    # deliver a chain means the recording pipeline is broken, not that
    # this machine is under-provisioned. Skipping here is what let this
    # counterpart assert nothing at all while the GUI spec it localises
    # went on being the campaign's only real evidence.
    if failReason.len > 0:
      checkpoint(failReason)
      fail()
    else:
      let chain = parseOriginChain(chainJson)
      # A span whose hop range is inverted or runs off the end of the
      # chain would make a renderer that slices `hops[first..last]`
      # either crash or draw the wrong hops.
      #
      # A span with no hops of its own is legitimate: the walk really
      # did cross into that recording, but the sending side had nothing
      # further to say (a recording without value capture, say). The
      # convention for that is `first == last == hops.len` — the
      # breadcrumb chip still renders and still switches the active
      # recording, it just has no hop to scroll to.
      for span in chain.crossProcessSpans:
        check span.recordingId.len > 0
        check span.firstHopIndex.int <= span.lastHopIndex.int
        if span.firstHopIndex.int >= chain.hops.len:
          check span.firstHopIndex.int == chain.hops.len
          check span.lastHopIndex.int == chain.hops.len
        else:
          check span.lastHopIndex.int < chain.hops.len

  test "clicking a sibling hop rotates the active recording":
    # No skip. The demo is RECORDED by the dump helper when it runs
    # (`scripts/materialize-recording.sh`), so a helper that could not
    # deliver a chain means the recording pipeline is broken, not that
    # this machine is under-provisioned. Skipping here is what let this
    # counterpart assert nothing at all while the GUI spec it localises
    # went on being the campaign's only real evidence.
    if failReason.len > 0:
      checkpoint(failReason)
      fail()
    else:
      createRoot proc(dispose: proc()) =
        let chain = parseOriginChain(chainJson)
        let mock = newMockBackendService(autoRespond = true)
        let session = createSessionVM(mock.toBackendService())

        var entries: seq[ProcessTreeEntry] = @[]
        for span in chain.crossProcessSpans:
          entries.add(ProcessTreeEntry(
            recordingId: span.recordingId,
            role: span.role,
            displayName: span.role,
            defaultThreadPrefix: span.role,
            threadCount: 1,
          ))
        session.setProcessTree(entries)

        let startingRecording = session.activeProcessRecordingId.val
        check startingRecording.len > 0

        # Find a span belonging to a different recording — that is the
        # breadcrumb chip the user clicks to follow the value across the
        # boundary.
        var target = ""
        for span in chain.crossProcessSpans:
          if span.recordingId != startingRecording:
            target = span.recordingId
            break
        check target.len > 0

        session.onSwitchProcess(target)
        check session.activeProcessRecordingId.val == target
        # The per-recording StateVM alias must rotate too, otherwise the
        # editor and state panes keep rendering the previous recording's
        # position while the process tree claims otherwise.
        check not session.stateVM.isNil
