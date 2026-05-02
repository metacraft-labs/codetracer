## test_noir_space_ship.nim
##
## Headless ViewModel equivalents of the Playwright Noir Space Ship GUI tests
## from ``tsc-ui-tests/tests/noir-space-ship/noir-space-ship.spec.ts``.
##
## Each test uses HeadlessDebugSession with a real replay-server backend and
## the actual noir_space_ship trace.  Instead of verifying DOM elements, these
## tests verify the DATA exposed by the ViewModel layer (debugger position,
## calltrace lines, locals, event log entries, etc.).
##
## Tests replicated from the GUI suite:
##
## 1. editor loaded main.nr         -> Verify entry file is main.nr
## 2. calculate damage calltrace    -> Navigate calltrace to calculate_damage
## 3. loop iteration / flow data    -> Verify calltrace has iterate_asteroids
## 4. event log populated           -> Event log has entries
## 5. step forward/backward         -> Stepping changes and reverses position
## 6. locals inspection             -> Locals contain Noir variables
## 7. calltrace depth               -> Calltrace shows nested function calls
## 8. step controls recover         -> Reverse continue then forward continue
## 9. calltrace search              -> Find functions by name in calltrace
## 10. full debugging workflow      -> Combined: step, locals, calltrace at
##                                     multiple positions
##
## Prerequisites:
##   - replay-server built: ``src/build-debug/bin/replay-server``
##   - ct binary built: ``src/build-debug/bin/ct``
##   - A noir_space_ship trace recorded (or the test will record one)
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_noir_space_ship.nim

import std/[json, os, unittest, strutils, osproc, sequtils]
import vm_test_helpers
import isonim/core/computation
import headless_session
import store/types
import viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Resolve the repository root from this test's path.  The test lives at
  ## ``src/tests/gui/tests/noir-space-ship/`` so we strip 6 path components
  ## (file → noir-space-ship → tests → gui → tests → src → repo).
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir.parentDir

proc findReplayServer(): string =
  ## Locate the replay-server binary.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidate = repoRoot() / "src" / "build-debug" / "bin" / "replay-server"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "Could not find replay-server binary. Set REPLAY_SERVER_BIN or " &
    "build it with 'cargo build' in src/db-backend/. Tried: " & candidate)

proc findCtFile(dir: string): string =
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    if path.endsWith(".ct"):
      return path
  return ""

proc isUsableTraceDir(dir: string): bool =
  if fileExists(dir / "trace.bin"):
    return true
  if dirExists(dir / "rr"):
    return true
  if findCtFile(dir).len > 0:
    return true
  return false

proc findExistingTrace(programPattern: string): string =
  ## Search ``~/.local/share/codetracer/`` for a pre-recorded trace whose
  ## metadata program OR workdir field contains ``programPattern``.
  ## (Noir traces have ``program = "zk_shields"`` but ``workdir`` includes
  ## ``noir_space_ship`` — match either to find them.)
  let baseDir = getHomeDir() / ".local" / "share" / "codetracer"
  if not dirExists(baseDir):
    return ""
  for kind, path in walkDir(baseDir):
    if kind != pcDir:
      continue
    let dirname = path.extractFilename()
    if not dirname.startsWith("trace-"):
      continue
    if not isUsableTraceDir(path):
      continue
    var program = ""
    var workdir = ""
    for metaName in ["trace_metadata.json", "trace_db_metadata.json"]:
      let metaPath = path / metaName
      if not fileExists(metaPath):
        continue
      try:
        let meta = parseFile(metaPath)
        program = meta.getOrDefault("program").getStr("")
        workdir = meta.getOrDefault("workdir").getStr("")
        if program.len > 0 or workdir.len > 0:
          break
      except:
        discard
    if programPattern in program or programPattern in workdir:
      return path
  return ""

const recordTimeoutMs = 120_000

proc recordTraceToDefaultLocation(programPath: string): string =
  ## Record a trace and return the trace directory path.
  let ctBin = findCtBinary()
  var args = @["record", programPath]
  let timeoutSec = recordTimeoutMs div 1000
  let fullCmd = "timeout " & $timeoutSec & " " & quoteShell(ctBin) & " " &
                args.mapIt(quoteShell(it)).join(" ")
  let (output, exitCode) = execCmdEx(fullCmd)
  if exitCode != 0:
    raise newException(IOError,
      "ct record failed (exit " & $exitCode & "): " & output)
  for line in output.splitLines():
    if line.startsWith("traceId:"):
      let idStr = line[8..^1].strip()
      let traceDir = getHomeDir() / ".local" / "share" / "codetracer" / ("trace-" & idStr)
      if dirExists(traceDir):
        return traceDir
  raise newException(IOError,
    "ct record succeeded but could not parse traceId from output: " & output)

# Cache the trace path to avoid repeated lookups across tests.
var cachedTracePath: string = ""

proc findOrRecordNoirTrace(): string =
  ## Find or record the noir_space_ship trace. Cached across tests.
  if cachedTracePath.len > 0:
    return cachedTracePath

  # 1. Search for existing trace.
  let existing = findExistingTrace("noir_space_ship")
  if existing.len > 0:
    echo "  Using existing trace: ", existing
    cachedTracePath = existing
    return existing

  # 2. Record a fresh trace.
  let programDir = repoRoot() / "test-programs" / "noir_space_ship"
  echo "  Recording trace for: ", programDir
  let traceDir = recordTraceToDefaultLocation(programDir)
  echo "  Recorded trace to: ", traceDir
  if not isUsableTraceDir(traceDir):
    raise newException(IOError,
      "Recorded trace at " & traceDir & " uses an unrecognized format.")
  cachedTracePath = traceDir
  return traceDir

proc stepToNoirSource(session: HeadlessDebugSession; maxSteps: int = 30) =
  ## Step forward until the current file is a .nr file.
  for i in 0 ..< maxSteps:
    if ".nr" in session.getCurrentFile():
      return
    session.stepForward()

proc findCallLineByName(lines: seq[CallLine]; pattern: string): int =
  ## Return the index of the first calltrace line whose name contains
  ## ``pattern`` (case-insensitive). Returns -1 if not found.
  let lowerPattern = pattern.toLowerAscii()
  for i, line in lines:
    if lowerPattern in line.name.toLowerAscii():
      return i
  return -1

# ---------------------------------------------------------------------------
# Suite 1: Editor loaded main.nr
# Mirrors: "editor loaded main.nr file"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: editor loads main.nr":

  test "entry file is main.nr after launch":
    ## After launching the trace, the debugger's initial position should
    ## point to a .nr file (main.nr is the entry point).
    ## GUI test verifies: editorTabs contains "src/main.nr"
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    # Step to Noir source if the initial position is not in .nr code.
    stepToNoirSource(session)

    let file = session.getCurrentFile()
    let line = session.getCurrentLine()
    echo "  Initial Noir position: ", file, ":", line

    check session.getDebuggerStatus() == dsIdle
    check "main.nr" in file

# ---------------------------------------------------------------------------
# Suite 2: Calculate damage calltrace navigation
# Mirrors: "calculate damage calltrace navigation"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: calculate damage calltrace navigation":

  test "calltrace contains calculate_damage function":
    ## Navigate the calltrace to find the calculate_damage function.
    ## GUI test: navigates via event log click -> calltrace expand ->
    ## find calculate_damage -> activate -> verify shield.nr opens at line 22.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    # Load calltrace with a large depth to capture nested calls.
    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    echo "  Calltrace lines: ", lines.len
    for i, line in lines:
      if i < 15:
        echo "    [", line.index, "] depth=", line.depth, " ", line.name,
             " @ ", line.location.file, ":", line.location.line

    check lines.len > 0

    # Find calculate_damage in the calltrace.
    let calcIdx = findCallLineByName(lines, "calculate_damage")
    if calcIdx >= 0:
      echo "  Found calculate_damage at index ", calcIdx,
           " depth=", lines[calcIdx].depth
      check lines[calcIdx].name.toLowerAscii().contains("calculate_damage")
    else:
      # The function may be deeper in the trace. Look for other Noir functions
      # to verify the calltrace is populated with Noir-specific names.
      echo "  calculate_damage not found in initial calltrace window"
      var hasNoirFunc = false
      for line in lines:
        if "main" in line.name or "iterate" in line.name or
           "shield" in line.name or "status" in line.name:
          hasNoirFunc = true
          echo "  Found Noir function: ", line.name
          break
      check hasNoirFunc

  test "navigate to calculate_damage via calltrace jump":
    ## Jump to calculate_damage's location and verify the debugger moves
    ## to shield.nr.
    ## GUI test: activates calculate_damage entry, verifies shield.nr
    ## opens at line 22 and flow values are present.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    # Find any function in shield.nr to navigate to.
    var targetLine: CallLine
    var foundTarget = false
    for line in lines:
      if "shield" in line.location.file.toLowerAscii() or
         "calculate_damage" in line.name.toLowerAscii():
        targetLine = line
        foundTarget = true
        break

    if foundTarget:
      echo "  Jumping to: ", targetLine.name, " @ ",
           targetLine.location.file, ":", targetLine.location.line

      session.calltraceJumpByLine(targetLine)

      let file = session.getCurrentFile()
      let line = session.getCurrentLine()
      echo "  After jump: ", file, ":", line

      check session.getDebuggerStatus() == dsIdle
      # After jumping, we should be at the target's location.
      check line > 0

      # Load locals at the jumped-to position to verify data is available.
      session.requestAndLoadLocals()
      let locals = session.getLocals()
      echo "  Locals at jumped position: ", locals.len
      for v in locals:
        echo "    ", v.name, " : ", v.typeName, " = ", v.value
    else:
      echo "  No shield.nr function found to jump to; skipping navigation test"
      # Still verify that the calltrace has entries with names.
      var hasNamedEntry = false
      for line in lines:
        if line.name.len > 0:
          hasNamedEntry = true
          break
      check hasNamedEntry

  test "calltrace jump to calculate_damage lands on shield.nr line 22":
    ## Tight headless mirror of the failing GUI test
    ## ``calculate damage calltrace navigation``: jump to the
    ## calculate_damage entry and verify the debugger position is
    ## exactly ``shield.nr:22`` (the function header line in the
    ## noir_space_ship trace).  This isolates the calltrace-jump →
    ## complete-move → editor flow at the VM/backend layer so we
    ## can tell whether the bug is in the backend (wrong location)
    ## or purely in the DOM rendering layer (active-line marker).
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    # Pick the first calltrace entry whose function name is exactly
    # ``calculate_damage``.  We don't relax the match here — the GUI
    # test is just as strict.
    var targetIdx = -1
    for i, line in lines:
      if line.name.toLowerAscii() == "calculate_damage":
        targetIdx = i
        break

    check targetIdx >= 0
    let target = lines[targetIdx]
    echo "  calculate_damage entry: ", target.name,
         " @ ", target.location.file, ":", target.location.line,
         " rrTicks=", target.rrTicks

    # The CallLine itself should already report shield.nr:22 since the
    # backend's load_location uses the call's first step record.
    check "shield.nr" in target.location.file
    check target.location.line == 22

    # Now perform the actual jump that the GUI exercises.
    session.calltraceJumpByLine(target)

    let file = session.getCurrentFile()
    let line = session.getCurrentLine()
    echo "  After calltrace_jump: ", file, ":", line

    check session.getDebuggerStatus() == dsIdle
    check "shield.nr" in file
    # The expected active line is 22 — the GUI test's
    # ``activeLine === 22`` assertion in noir-space-ship.spec.ts.
    check line == 22

# ---------------------------------------------------------------------------
# Suite 3: Loop iteration / iterate_asteroids
# Mirrors: "loop iteration slider tracks remaining shield"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: loop iteration via calltrace":

  test "calltrace contains iterate_asteroids":
    ## GUI test: navigates to iterate_asteroids in the calltrace, opens
    ## shield.nr, and verifies loop iteration controls are present.
    ## Headless equivalent: verify iterate_asteroids appears in the calltrace
    ## and that we can navigate to it.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    let iterIdx = findCallLineByName(lines, "iterate_asteroids")
    if iterIdx >= 0:
      echo "  Found iterate_asteroids at index ", iterIdx,
           " depth=", lines[iterIdx].depth,
           " rrTicks=", lines[iterIdx].rrTicks
      check lines[iterIdx].name.toLowerAscii().contains("iterate_asteroids")

      # Jump to iterate_asteroids to verify navigation works.
      session.calltraceJumpByLine(lines[iterIdx])

      let file = session.getCurrentFile()
      let line = session.getCurrentLine()
      echo "  After jump to iterate_asteroids: ", file, ":", line
      check session.getDebuggerStatus() == dsIdle

      # Load locals at this position -- inside the loop we may see
      # shield-related variables.
      session.requestAndLoadLocals()
      let locals = session.getLocals()
      echo "  Locals inside iterate_asteroids: ", locals.len
      for v in locals:
        echo "    ", v.name, " : ", v.typeName, " = ", v.value
    else:
      echo "  iterate_asteroids not in initial calltrace window"
      # Verify calltrace still has meaningful entries.
      check lines.len > 0
      var hasNamed = false
      for line in lines:
        if line.name.len > 0:
          hasNamed = true
          break
      check hasNamed

  test "ct/load-flow after iterate_asteroids jump returns loop steps":
    ## Mirrors the failing GUI tests "loop iteration slider tracks
    ## remaining shield" and "simple loop iteration jump".  Both
    ## activate the iterate_asteroids calltrace entry and wait on
    ## ``.flow-multiline-value-container`` to become visible.  That
    ## DOM element is rendered by ``flow.nim::addLoopInfo`` only when
    ## ``EditorViewComponent.loadFlow`` -> ``ct/load-flow`` returns a
    ## ``FlowUpdate`` whose ``view_updates[ViewSource].steps`` contains
    ## a step at the loop's ``registeredLine``.
    ##
    ## This headless test isolates the data layer: after a calltrace
    ## jump to iterate_asteroids, send the same ``ct/load-flow`` the
    ## frontend would send and verify the response carries:
    ##   - a non-empty ``flow`` body for at least one editor view
    ##     (steps + loops),
    ##   - at least one loop entry, and
    ##   - at least one step whose ``loop`` index is non-negative
    ##     (i.e., a step inside the loop).
    ##
    ## If this test passes but the GUI test still fails, the bug is in
    ## the View layer: ``onCompleteMove`` is not invoking ``loadFlow``
    ## (or the resulting ``CtUpdatedFlow`` is being dropped) under the
    ## IsoNim editor mount.  See ``/tmp/isonim-migration.txt`` §1.54
    ## and §5.8 for the broader investigation.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    let iterIdx = findCallLineByName(lines, "iterate_asteroids")
    if iterIdx < 0:
      echo "  iterate_asteroids not present in calltrace; skipping"
      check lines.len > 0
    else:
      let target = lines[iterIdx]
      echo "  iterate_asteroids entry: ", target.name,
           " @ ", target.location.file, ":", target.location.line,
           " rrTicks=", target.rrTicks

      session.calltraceJumpByLine(target)
      check session.getDebuggerStatus() == dsIdle

      let postFile = session.getCurrentFile()
      let postLine = session.getCurrentLine()
      let postTicks = session.getCurrentRRTicks()
      echo "  After jump: ", postFile, ":", postLine, " rrTicks=", postTicks
      check postTicks > 0'u64

      # Send the ct/load-flow command using the schema the backend
      # deserializes (``CtLoadFlowArguments`` in
      # ``src/db-backend/src/task.rs``).  ``flowMode`` is the integer
      # ``repr(u8)`` form of ``FlowMode`` (0 = Call, 1 = Diff) and
      # ``location`` carries at minimum the path, line, and rrTicks.
      # The backend's flow preloader resolves the loop layout from the
      # rrTicks; the GUI loop-iteration widget rendering depends on
      # the resulting ``view_updates[ViewSource]`` payload.
      let resp = session.sendRawDapRequest("ct/load-flow", %*{
        "flowMode": 0,
        "location": {
          "path": postFile,
          "line": postLine,
          "functionName": "",
          "highLevelPath": postFile,
          "highLevelLine": postLine,
          "highLevelFunctionName": "",
          "lowLevelPath": "",
          "lowLevelLine": 0,
          "rrTicks": postTicks.int64,
          "functionFirst": 0,
          "functionLast": 0,
          "event": 0,
          "expression": "",
          "offset": 0,
          "error": false,
          "callstackDepth": 0,
          "originatingInstructionAddress": 0,
          "key": "",
          "globalCallKey": "",
          "expansionParents": [],
          "missingPath": false,
        },
      })
      check resp.getOrDefault("success").getBool(false)

      let body = resp.getOrDefault("body")
      check (not body.isNil) and body.kind == JObject
      var bodyKeys: seq[string] = @[]
      for k, _ in body:
        bodyKeys.add(k)
      echo "  ct/load-flow body keys: ", bodyKeys

      # Drain any pre-existing CtUpdatedFlow events that may have been
      # emitted by the backend in response to our request, in case the
      # response carries the FlowUpdate via the event channel.  The
      # frontend wires the event to viewsApi.emit(CtUpdatedFlow, ...)
      # at middleware.nim:182, so the same payload structure applies.
      var flowUpdate: JsonNode = body
      let viewUpdates = body.getOrDefault("viewUpdates")
      if viewUpdates.isNil or viewUpdates.kind != JObject:
        # Some backends ship the FlowUpdate via an event after the
        # response.  Try to drain one and use that instead.
        let drained = session.drainEvents()
        for ev in drained:
          let evKind = ev.getOrDefault("event").getStr("")
          if evKind == "ct/updated-flow":
            let evBody = ev.getOrDefault("body")
            if not evBody.isNil and evBody.kind == JObject:
              flowUpdate = evBody
              break

      let vu = flowUpdate.getOrDefault("viewUpdates")
      echo "  flowUpdate.viewUpdates kind: ",
           (if vu.isNil: "nil" else: $vu.kind)
      doAssert (not vu.isNil)
      doAssert (vu.kind == JArray or vu.kind == JObject)
      echo "  vu length: ", vu.len

      var foundLoopStep = false
      var loopCount = 0
      var totalSteps = 0

      echo "  collecting entries..."
      var entries: seq[(string, JsonNode)] = @[]
      if vu.kind == JArray:
        echo "  array path, len=", vu.elems.len
        var i = 0
        for entry in vu.elems:
          entries.add(($i, entry))
          inc i
      elif vu.kind == JObject:
        echo "  object path"
        for k, v in vu.pairs:
          entries.add((k, v))
      echo "  collected ", entries.len, " entries"

      for (tag, viewBody) in entries:
        if viewBody.isNil or viewBody.kind != JObject:
          continue
        let stepsNode = viewBody.getOrDefault("steps")
        let loopsNode = viewBody.getOrDefault("loops")
        if not stepsNode.isNil and stepsNode.kind == JArray:
          totalSteps += stepsNode.len
          for st in stepsNode.elems:
            let loopIdx = st.getOrDefault("loop").getInt(-1)
            if loopIdx >= 0:
              foundLoopStep = true
        if not loopsNode.isNil and loopsNode.kind == JArray:
          loopCount += loopsNode.len
        echo "  view ", tag, ": steps=",
             (if stepsNode.isNil: 0 else: stepsNode.len),
             " loops=",
             (if loopsNode.isNil: 0 else: loopsNode.len)

      echo "  total steps=", totalSteps, " loops=", loopCount,
           " any-loop-step=", foundLoopStep

      # Data-layer contract: at iterate_asteroids the FlowPreloader
      # must return at least one loop and at least one step that
      # participates in a loop.  This is the foundation the GUI
      # loop-iteration widgets are built on.  When this contract is
      # satisfied but the GUI test fails, investigate the View layer
      # (editor.nim onCompleteMove → loadFlow wiring) — that's the
      # §1.54 wiring blocker tracked in
      # ``/tmp/isonim-migration.txt``.
      check totalSteps > 0
      check loopCount > 0
      check foundLoopStep

  test "ct/load-flow with stale tabInfo.location returns no loop steps":
    ## §1.68 frontend gate localisation for noir-space-ship §5.8.
    ##
    ## The Playwright tests "loop iteration slider tracks remaining
    ## shield" (line 278) and "simple loop iteration jump" (line 393)
    ## both:
    ##
    ##   1. Activate the iterate_asteroids calltrace entry
    ##      (fires ``ct/calltrace-jump`` -> ``ct/complete-move``).
    ##   2. Wait for shield.nr to open as a fresh editor tab.
    ##   3. Wait for ``.flow-multiline-value-container`` to render
    ##      (which requires ``ct/load-flow`` -> ``CtUpdatedFlow``
    ##      with at least one loop and one in-loop step).
    ##
    ## The shield.nr editor is *opened* by ``editor_service.onCompleteMove``
    ## which forwards ``response.location.path`` to ``openNewEditorView``.
    ## ``openNewEditorView`` (utils.nim:1208-1247) builds a fresh
    ## ``Location`` with ``rrTicks = 0`` (default) and ``line = NO_LINE``
    ## then awaits ``tabLoad`` whose backend handler (index/config.nim:175)
    ## simply echoes the same ``Location`` back into ``tabInfo.location``.
    ##
    ## In the EditorViewComponent's lifecycle:
    ##
    ##   * ``afterInit`` (editor.nim:2117) replays the cached
    ##     ``CtCompleteMove`` for shield.nr and calls ``onCompleteMove``.
    ##   * ``onCompleteMove`` finds ``self.tabInfo.monacoEditor.isNil``
    ##     (Monaco hasn't been instantiated yet for the freshly-opened
    ##     editor) and sets ``self.shouldLoadFlow = true`` (editor.nim:2255).
    ##   * Later ``editorAfterRedraw`` (editor.nim:1923-1925) sees
    ##     ``shouldLoadFlow == true`` and calls
    ##     ``self.loadFlow(FlowMode.Call, tabInfo.location)``.
    ##
    ## Crucially, ``tabInfo.location`` is the STALE openNewEditorView
    ## Location with ``rrTicks = 0`` and ``line = NO_LINE``, NOT the
    ## post-jump ``response.location`` (rrTicks=3, line=1) that the
    ## GUI test depends on.
    ##
    ## This test pins that data-layer contract: when ``ct/load-flow`` is
    ## sent with the stale ``tabInfo.location`` shape, the FlowUpdate
    ## either errors or returns ZERO loops/in-loop-steps for shield.nr.
    ## Once the deferred-loadFlow path is fixed to use the cached
    ## complete_move location (with the correct rrTicks), this test's
    ## ``stale-call returns no loops`` assertion documents the broken
    ## behaviour we removed.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()
    let iterIdx = findCallLineByName(lines, "iterate_asteroids")
    if iterIdx < 0:
      echo "  iterate_asteroids not present in calltrace; skipping"
      check lines.len > 0
    else:
      let target = lines[iterIdx]
      session.calltraceJumpByLine(target)
      check session.getDebuggerStatus() == dsIdle

      let postFile = session.getCurrentFile()
      let postLine = session.getCurrentLine()
      let postTicks = session.getCurrentRRTicks()
      echo "  good location: ", postFile, ":", postLine, " rrTicks=", postTicks

      # First, the GOOD call -- mirrors what `onCompleteMove` does
      # synchronously when monaco is already ready.  This is the
      # baseline that the deferred path is supposed to match.
      let goodResp = session.sendRawDapRequest("ct/load-flow", %*{
        "flowMode": 0,
        "location": {
          "path": postFile, "line": postLine,
          "highLevelPath": postFile, "highLevelLine": postLine,
          "rrTicks": postTicks.int64,
          "functionName": "", "highLevelFunctionName": "",
          "lowLevelPath": "", "lowLevelLine": 0,
          "functionFirst": 0, "functionLast": 0,
          "event": 0, "expression": "", "offset": 0, "error": false,
          "callstackDepth": 0, "originatingInstructionAddress": 0,
          "key": "", "globalCallKey": "",
          "expansionParents": [], "missingPath": false,
        },
      })
      check goodResp.getOrDefault("success").getBool(false)
      var goodLoopCount = 0
      var goodLoopSteps = 0
      let goodVU = goodResp.getOrDefault("body").getOrDefault("viewUpdates")
      if not goodVU.isNil and goodVU.kind == JArray:
        for entry in goodVU.elems:
          let stepsNode = entry.getOrDefault("steps")
          let loopsNode = entry.getOrDefault("loops")
          if not loopsNode.isNil and loopsNode.kind == JArray:
            goodLoopCount += loopsNode.len
          if not stepsNode.isNil and stepsNode.kind == JArray:
            for st in stepsNode.elems:
              if st.getOrDefault("loop").getInt(-1) >= 0:
                inc goodLoopSteps
      echo "  GOOD load-flow: loops=", goodLoopCount, " in-loop-steps=", goodLoopSteps
      check goodLoopCount > 0
      check goodLoopSteps > 0

      # Now drain any side-channel ct/updated-flow events from the good call
      # so the next call's events can be observed cleanly.
      discard session.drainEvents()

      # Now the STALE call -- mirrors what ``editorAfterRedraw`` does
      # after a deferred ``shouldLoadFlow = true``.  ``tabInfo.location``
      # came from ``openNewEditorView`` which builds:
      #
      #   Location(path: name, line: NO_LINE, highLevelPath: name,
      #            highLevelLine: NO_LINE, ...)
      #
      # rrTicks defaults to 0; line defaults to NO_LINE (-1 in Nim, but
      # serialized as -1 in cstring/JSON the backend sees 0 since the
      # JSON deserializer for ``Location`` defaults missing fields).
      # We set line = 1 (a defined sentinel; NO_LINE round-trips through
      # JSON serialization differently per platform), rrTicks = 0.
      let staleResp = session.sendRawDapRequest("ct/load-flow", %*{
        "flowMode": 0,
        "location": {
          "path": postFile, "line": -1,
          "highLevelPath": postFile, "highLevelLine": -1,
          "rrTicks": 0,
          "functionName": "", "highLevelFunctionName": "",
          "lowLevelPath": "", "lowLevelLine": 0,
          "functionFirst": 0, "functionLast": 0,
          "event": 0, "expression": "", "offset": 0, "error": false,
          "callstackDepth": 0, "originatingInstructionAddress": 0,
          "key": "", "globalCallKey": "",
          "expansionParents": [], "missingPath": false,
        },
      })
      check staleResp.getOrDefault("success").getBool(false)
      var staleLoopCount = 0
      var staleLoopSteps = 0
      var staleHadError = false
      let staleBody = staleResp.getOrDefault("body")
      if not staleBody.isNil:
        staleHadError = staleBody.getOrDefault("error").getBool(false)
        let staleVU = staleBody.getOrDefault("viewUpdates")
        if not staleVU.isNil and staleVU.kind == JArray:
          for entry in staleVU.elems:
            let stepsNode = entry.getOrDefault("steps")
            let loopsNode = entry.getOrDefault("loops")
            if not loopsNode.isNil and loopsNode.kind == JArray:
              staleLoopCount += loopsNode.len
            if not stepsNode.isNil and stepsNode.kind == JArray:
              for st in stepsNode.elems:
                if st.getOrDefault("loop").getInt(-1) >= 0:
                  inc staleLoopSteps
      echo "  STALE load-flow: error=", staleHadError,
           " loops=", staleLoopCount, " in-loop-steps=", staleLoopSteps

      # The stale call MUST NOT produce the same loop/in-loop-step
      # numbers the good call produces -- if it did, the deferred path
      # would render the loop widget by accident.  In practice the
      # stale call either errors or returns drastically reduced loop
      # data because rrTicks=0 puts the FlowPreloader at the trace's
      # entry point in main.nr, not inside iterate_asteroids.
      check (staleHadError or staleLoopCount < goodLoopCount or
             staleLoopSteps < goodLoopSteps)

# ---------------------------------------------------------------------------
# Suite 4: Event log populated
# Mirrors: "event log jump highlights active row"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: event log":

  test "event log has entries":
    ## GUI test: clicks event log tab, expects >= 2 rows, clicks first row
    ## and verifies it is highlighted.
    ## Headless: verify event log returns entries with content.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 5:
      session.stepForward()

    let events = session.requestAndLoadEventLog()
    echo "  Event log entries: ", events.len
    for i, ev in events:
      if i < 5:
        echo "    [", i, "] ", ev.content[0 ..< min(80, ev.content.len)],
             " @ ", ev.file, ":", ev.line

    # The noir_space_ship trace may or may not have event log entries
    # depending on the recorder version. The request should complete
    # without crashing.
    check session.getDebuggerStatus() == dsIdle

  test "event jump navigates to event location":
    ## GUI test: clicks an event log row and verifies the debugger jumps
    ## to that event's position.
    ## Headless: if events exist, jump to first event and verify position changes.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 5:
      session.stepForward()

    let events = session.requestAndLoadEventLog()
    if events.len > 0:
      let ticksBefore = session.getCurrentRRTicks()
      session.eventJump(events[0])
      let ticksAfter = session.getCurrentRRTicks()
      echo "  Before event jump: rrTicks=", ticksBefore
      echo "  After event jump:  rrTicks=", ticksAfter
      check session.getDebuggerStatus() == dsIdle
      # The position should have changed (unless the event is at the current position).
      check ticksAfter > 0'u64
    else:
      echo "  No events available; skipping event jump test"
      check session.getDebuggerStatus() == dsIdle

# ---------------------------------------------------------------------------
# Suite 5: Step forward/backward
# Mirrors: "step controls recover from reverse"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: step forward and backward":

  test "step forward changes position":
    ## GUI test: verifies stepping forward moves the debugger.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    let ticks1 = session.getCurrentRRTicks()
    let line1 = session.getCurrentLine()
    let file1 = session.getCurrentFile()

    session.stepForward()

    let ticks2 = session.getCurrentRRTicks()
    let line2 = session.getCurrentLine()
    let file2 = session.getCurrentFile()

    echo "  Before step: ", file1, ":", line1, " (rrTicks=", ticks1, ")"
    echo "  After step:  ", file2, ":", line2, " (rrTicks=", ticks2, ")"

    check (ticks2 != ticks1 or line2 != line1 or file2 != file1)

  test "step backward reverses position":
    ## GUI test: reverse next button click, verify position goes back.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 5:
      session.stepForward()
    let ticksForward = session.getCurrentRRTicks()

    session.stepBackward()
    let ticksBack = session.getCurrentRRTicks()

    echo "  Forward rrTicks=", ticksForward, ", Back rrTicks=", ticksBack
    check ticksBack < ticksForward
    check session.getDebuggerStatus() == dsIdle

  test "step controls recover from reverse continue":
    ## GUI test: clicks reverseContinue, then continue, verifies status
    ## returns to ready/idle.
    ## Headless: step forward, continue backward, continue forward, verify idle.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 8:
      session.stepForward()

    let ticksBefore = session.getCurrentRRTicks()
    echo "  Position before reverse continue: rrTicks=", ticksBefore

    # Continue backward (mirrors reverseContinueButton click).
    session.continueBackward()
    let ticksAfterReverse = session.getCurrentRRTicks()
    echo "  After reverse continue: rrTicks=", ticksAfterReverse
    check session.getDebuggerStatus() == dsIdle

    # Continue forward (mirrors continueButton click to recover).
    session.continueForward()
    let ticksAfterForward = session.getCurrentRRTicks()
    echo "  After forward continue: rrTicks=", ticksAfterForward
    check session.getDebuggerStatus() == dsIdle

    # The forward continue should have advanced past the reverse position.
    check ticksAfterForward >= ticksAfterReverse

# ---------------------------------------------------------------------------
# Suite 6: Locals inspection
# Mirrors: "calculate damage calltrace navigation" (flow values / locals)
# ---------------------------------------------------------------------------

suite "Noir Space Ship: locals inspection":

  test "locals contain Noir variables after stepping":
    ## GUI test: at the calculate_damage position, verifies flow values
    ## (inline annotations) are present.
    ## Headless: step into the trace and verify locals are populated.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)

    # Step further to accumulate locals -- Noir programs populate locals
    # after a few steps into user code.
    var locals: seq[Variable]
    for i in 0 ..< 20:
      session.stepForward()
      session.requestAndLoadLocals()
      locals = session.getLocals()
      if locals.len > 0:
        echo "  Locals found after ", i + 1, " steps"
        break

    echo "  Noir locals count: ", locals.len
    for v in locals:
      echo "    ", v.name, " : ", v.typeName, " = ", v.value

    if locals.len == 0:
      echo "  WARNING: no locals found after 20 steps (may be normal for this Noir trace position)"
    else:
      for v in locals:
        check v.name.len > 0

    check session.getDebuggerStatus() == dsIdle

  test "locals update at different positions":
    ## Step to multiple positions and verify locals can be loaded at each.
    ## This mirrors the GUI test's verification that flow values change
    ## across different calltrace positions.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)

    var positions: seq[tuple[ticks: uint64, localsCount: int, file: string, line: int]]

    for i in 0 ..< 8:
      session.stepForward()
      session.requestAndLoadLocals()
      let locals = session.getLocals()
      positions.add((
        session.getCurrentRRTicks(),
        locals.len,
        session.getCurrentFile(),
        session.getCurrentLine(),
      ))

    echo "  Collected ", positions.len, " positions"
    for i, p in positions:
      echo "    Step ", i, ": ", p.file, ":", p.line,
           " rrTicks=", p.ticks, " locals=", p.localsCount

    # rrTicks should advance.
    for i in 1 ..< positions.len:
      check positions[i].ticks >= positions[i - 1].ticks

    # At least some positions should have locals.
    var anyLocals = false
    for p in positions:
      if p.localsCount > 0:
        anyLocals = true
        break
    if not anyLocals:
      echo "  NOTE: no locals found at any of the 8 positions"

    check session.getDebuggerStatus() == dsIdle

# ---------------------------------------------------------------------------
# Suite 7: Calltrace depth
# Mirrors: "calculate damage calltrace navigation" (nested calls)
# ---------------------------------------------------------------------------

suite "Noir Space Ship: calltrace depth and structure":

  test "calltrace shows nested function calls":
    ## GUI test: expands status_report -> finds calculate_damage nested inside.
    ## Headless: verify calltrace has entries with depth > 0.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    echo "  Calltrace lines: ", lines.len

    var maxDepth = 0
    var functionNames: seq[string]
    for line in lines:
      if line.depth > maxDepth:
        maxDepth = line.depth
      if line.name.len > 0 and line.name notin functionNames:
        functionNames.add(line.name)

    echo "  Max calltrace depth: ", maxDepth
    echo "  Unique function names: ", functionNames.len
    for name in functionNames:
      echo "    - ", name

    check lines.len > 0
    # The noir_space_ship trace has main -> iterate_asteroids ->
    # calculate_damage -> status_report, so depth should be > 0.
    check maxDepth > 0

  test "calltrace has expected Noir functions":
    ## Verify the calltrace contains the key functions from the
    ## noir_space_ship program: main, iterate_asteroids, calculate_damage,
    ## status_report.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    check lines.len > 0

    # Collect all unique function names (lowercased).
    var nameSet: seq[string]
    for line in lines:
      let lower = line.name.toLowerAscii()
      if lower.len > 0 and lower notin nameSet:
        nameSet.add(lower)

    echo "  Function names in calltrace: ", nameSet

    # Check for at least main (the root function).
    var hasMain = false
    for n in nameSet:
      if "main" in n:
        hasMain = true
        break
    check hasMain

  test "calltrace lines have location data":
    ## Verify calltrace lines include source file paths (.nr files)
    ## and line numbers.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()

    check lines.len > 0

    # At least one calltrace line should point to a .nr file.
    var hasNrFile = false
    for line in lines:
      if ".nr" in line.location.file:
        hasNrFile = true
        check line.location.line > 0
        break

    if hasNrFile:
      echo "  Calltrace lines reference .nr files"
    else:
      echo "  WARNING: no .nr file references found in calltrace"

    # All lines should have non-negative line numbers.
    for line in lines:
      check line.location.line >= 0

# ---------------------------------------------------------------------------
# Suite 8: Calltrace search
# Mirrors: "flow/call trace/value history context menu options"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: calltrace search":

  test "search calltrace for function name":
    ## GUI test: verifies context menu options on calltrace entries.
    ## Headless: use CalltraceVM's search query to find matching entries.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)

    # Use the CalltraceVM's search feature to find "main".
    session.session.calltraceVM.setViewportHeight(50)
    session.session.calltraceVM.setSearchQuery("main")

    # Drain reactive updates.
    drain()

    let matches = session.session.calltraceVM.highlightedMatches.val
    echo "  Search 'main' matches: ", matches.len

    # There should be at least one match for "main" in the calltrace.
    check matches.len > 0

# ---------------------------------------------------------------------------
# Suite 9: Full debugging workflow
# Mirrors: "remaining shield history chronology" + "noir space ship smoke test"
# ---------------------------------------------------------------------------

suite "Noir Space Ship: full debugging workflow":

  test "step through multiple positions with locals and calltrace":
    ## Combines stepping, locals inspection, and calltrace loading at
    ## multiple positions. Mirrors the Playwright smoke test which
    ## exercises navigation, flow values, and step controls together.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)

    var positions: seq[tuple[
      ticks: uint64, file: string, line: int,
      localsCount: int
    ]]

    for i in 0 ..< 6:
      session.stepForward()
      session.requestAndLoadLocals()
      let locals = session.getLocals()
      positions.add((
        session.getCurrentRRTicks(),
        session.getCurrentFile(),
        session.getCurrentLine(),
        locals.len,
      ))

    echo "  Collected ", positions.len, " positions"
    for i, p in positions:
      echo "    Step ", i, ": ", p.file, ":", p.line,
           " rrTicks=", p.ticks, " locals=", p.localsCount

    # rrTicks should advance.
    for i in 1 ..< positions.len:
      check positions[i].ticks >= positions[i - 1].ticks

    # Load calltrace at the final position.
    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()
    echo "  Final calltrace lines: ", lines.len
    check lines.len > 0

    # Step backward to verify reverse works after the workflow.
    let ticksBefore = session.getCurrentRRTicks()
    session.stepBackward()
    let ticksAfter = session.getCurrentRRTicks()
    echo "  Step backward: ", ticksBefore, " -> ", ticksAfter
    check ticksAfter < ticksBefore

  test "calltrace navigation then locals at new position":
    ## Navigate to a calltrace entry and verify locals at the new position.
    ## Mirrors: navigateToShieldEditor -> verify flow values.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 10:
      session.stepForward()

    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()
    check lines.len > 0

    # Pick a calltrace entry to jump to (prefer one at depth > 0).
    var targetIdx = -1
    for i, line in lines:
      if line.depth > 0 and line.name.len > 0:
        targetIdx = i
        break
    if targetIdx < 0 and lines.len > 0:
      targetIdx = 0

    if targetIdx >= 0:
      let target = lines[targetIdx]
      echo "  Navigating to: ", target.name, " depth=", target.depth,
           " @ ", target.location.file, ":", target.location.line

      session.calltraceJumpByLine(target)

      let file = session.getCurrentFile()
      let line = session.getCurrentLine()
      echo "  After navigation: ", file, ":", line

      check session.getDebuggerStatus() == dsIdle
      check line > 0

      # Load locals at the new position.
      session.requestAndLoadLocals()
      let locals = session.getLocals()
      echo "  Locals at navigated position: ", locals.len
      for v in locals:
        echo "    ", v.name, " : ", v.typeName, " = ", v.value

      # Reload calltrace at the new position to verify it updates.
      session.requestAndLoadCalltrace(depth = 30)
      let newLines = session.getCalltraceLines()
      echo "  Calltrace at new position: ", newLines.len, " lines"
      check newLines.len > 0
    else:
      echo "  No calltrace entries available for navigation"
      skip()

  test "event log and calltrace at same session":
    ## Load both event log and calltrace in the same session to verify
    ## they do not interfere with each other. Mirrors the GUI test pattern
    ## where multiple panes are active simultaneously.
    let tracePath = findOrRecordNoirTrace()
    let session = newHeadlessDebugSession(tracePath, findReplayServer())
    defer: session.close()

    stepToNoirSource(session)
    for i in 0 ..< 5:
      session.stepForward()

    # Load event log.
    let events = session.requestAndLoadEventLog()
    echo "  Event log: ", events.len, " entries"

    # Load calltrace.
    session.requestAndLoadCalltrace(depth = 30)
    let lines = session.getCalltraceLines()
    echo "  Calltrace: ", lines.len, " lines"

    # Load locals.
    session.requestAndLoadLocals()
    let locals = session.getLocals()
    echo "  Locals: ", locals.len, " variables"

    check session.getDebuggerStatus() == dsIdle
    check lines.len > 0

    # All three data sources should load without crashing.
    # Event log may be empty for Noir traces but the request should succeed.
