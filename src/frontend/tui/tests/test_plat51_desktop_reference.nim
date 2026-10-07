## test_plat51_desktop_reference.nim — PLAT-51, the desktop as the reference
## the terminal and GPUI are held to, read from the REAL Electron app's record
## (`src/tests/visual/answers/plat51-desktop.electron.json`, written by
## `scripts/plat51-capture-electron.sh`) and compared with the shared models
## over the SAME recordings on a real `replay-server`:
##
##   * the desktop shows no Timeline (no tab, no container, nothing in the
##     View menu), and a saved layout that held one opens without it and
##     without an empty tab — the stack keeps Event Log and Terminal Output;
##   * the desktop's list scrubbers span the SAME populations the terminal's
##     and GPUI's do (the Event Log's 70 events, the Call Trace's 603 calls),
##     their end shows the last row, and a press on the track does not move
##     the debugger there either;
##   * the desktop's changed-value accent is the colour the terminal's and
##     GPUI's changed-value roles are bound to, and at every step the desktop
##     measured, it marks EXACTLY the variables the shared `value_changes`
##     model marks at the same tick against the same predecessor.
##
## No mocks: a real engine, real recordings, the desktop's own measurements.

import std/[json, os, sets, strutils, tables, unittest]

import isonim/core/[signals, computation]

import headless_session
import viewmodels/value_changes
import styles/generated/design_tokens

import ../app/theme/roles
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 59

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  AnswersFile = "src/tests/visual/answers/plat51-desktop.electron.json"
  Events = 70     ## `noir_space_ship`'s whole log
  Calls = 603     ## `call_pages`' whole trace

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

let answers =
  if fileExists(AnswersFile): parseJson(readFile(AnswersFile))
  else: newJObject()

suite "PLAT-51: the desktop, measured, as the reference":

  test "the desktop has no Timeline, and a saved layout that held one opens without it":
    require answers.hasKey("eventLog")
    require answers.hasKey("savedLayout")
    let ev = answers["eventLog"]
    ck ev["timelineTabs"].getInt == 0
    ck ev["timelineContainers"].getInt == 0
    ck not ev["menuHasTimeline"].getBool
    var items: seq[string] = @[]
    for it in ev["viewMenuItems"]: items.add it.getStr
    checkpoint("desktop View menu: " & $items)
    ck items.len > 0
    let saved = answers["savedLayout"]
    var tabs: seq[string] = @[]
    for t in saved["tabs"]: tabs.add t.getStr
    checkpoint("saved layout's tabs: " & $tabs)
    ck saved["timelineTabs"].getInt == 0
    ck saved["emptyTabs"].getInt == 0
    ck "EVENT LOG" in tabs
    ck "TERMINAL OUTPUT" in tabs
    ck saved["pageErrors"].len == 0

  test "the desktop's Event Log scrubber spans the engine's whole log":
    require answers.hasKey("eventLog")
    let ev = answers["eventLog"]
    let rec = resolveFixture("noir_space_ship")
    require rec.outcome == foRecorded
    let s = newHeadlessDebugSession(rec.tracePath, findReplayServer())
    defer: s.close()
    discard s.requestAndLoadEventLog(0, 16)
    let store = s.session.store.eventLog
    # The engine's count (the one the terminal and GPUI tracks carry).
    ck store.totalReported.val
    ck store.recordsTotal.val == Events
    ck ev["trackAtStart"]["total"].getInt == store.recordsTotal.val
    let atEnd = ev["trackAtEnd"]
    ck atEnd["first"].getInt + atEnd["visible"].getInt >= Events
    var rowsAtEnd = ""
    for r in ev["rowsAtEnd"]: rowsAtEnd.add r.getStr & "\n"
    checkpoint("desktop rows at the end: " & rowsAtEnd)
    require ev["rowsAtEnd"].len > 0
    # THE LAST ROW THE DESKTOP SHOWS after a press on the track's end is the
    # whole log's LAST event — its content as the engine answers it for index
    # 69 (the row the terminal's and GPUI's own cases find there).
    let last = s.requestAndLoadEventLog(Events - 1, 1)
    require last.len == 1
    let lastContent = last[0].content.strip()
    checkpoint("the log's last event: " & lastContent)
    ck lastContent.len > 0
    ck ev["rowsAtEnd"][^1].getStr.contains(lastContent)
    # The press on the track moved the view; the debugger stayed.
    ck ev["afterEndPress"]["ticks"].getInt == ev["start"]["ticks"].getInt
    ck ev["afterDrag"]["ticks"].getInt == ev["start"]["ticks"].getInt
    # …and a ROW click still moves it.
    ck ev["afterRowClick"]["ticks"].getInt != ev["start"]["ticks"].getInt
    ck ev["pageErrors"].len == 0

  test "the desktop's Call Trace scrubber spans the engine's whole trace":
    require answers.hasKey("calltrace")
    let ct = answers["calltrace"]
    let rec = resolveFixture(pythonSpec("call_pages"))
    require rec.outcome == foRecorded
    let s = newHeadlessDebugSession(rec.tracePath, findReplayServer())
    defer: s.close()
    s.requestAndLoadCalltrace(startIndex = 0, height = 40)
    let total = int(s.session.store.calltrace.totalCallsCount.val)
    ck total == Calls
    ck ct["trackAtStart"]["total"].getInt == total
    let atEnd = ct["trackAtEnd"]
    ck atEnd["first"].getInt + atEnd["visible"].getInt >= Calls
    ck ct["afterEndPress"]["ticks"].getInt == ct["start"]["ticks"].getInt
    ck ct["afterDrag"]["ticks"].getInt == ct["start"]["ticks"].getInt
    ck ct["pageErrors"].len == 0

  test "the changed-value accent is one colour on all three, and marks the same variables":
    require answers.hasKey("changedValues")
    let samples = answers["changedValues"]["samples"]
    require samples.len >= 3
    # THE COLOUR: the desktop's computed colour of `.value-changed` is the
    # token the terminal's and GPUI's changed-value roles are bound to.
    let want = DesignTokenHex[spec(srValueModified).fg][dmDark]
    ck want == DesignTokenHex[dtColorsUiTextInformationPrimaryHover][dmDark]
    var lit = 0
    for smp in samples:
      for c in smp["changed"]:
        ck c["color"].getStr == want
        inc lit
      # An unchanged value keeps the desktop's ordinary value colour.
      if smp["plain"].kind == JString:
        ck smp["plain"].getStr != want
    ck lit > 0
    # THE SET: from the second sample on, each sample's anchor is the one
    # before it (the desktop stepped one line at a time); the shared model,
    # fed the engine's locals at the same two ticks, marks the same names.
    let rec = resolveFixture("calc")
    require rec.outcome == foRecorded
    let s = newHeadlessDebugSession(rec.tracePath, findReplayServer())
    defer: s.close()
    var compared = 0
    for i in 1 ..< samples.len:
      let a = uint64(samples[i - 1]["at"]["ticks"].getInt)
      let b = uint64(samples[i]["at"]["ticks"].getInt)
      var t = initValueTimeline()
      for tick in [a, b]:
        s.gotoTick(tick)
        s.requestAndLoadLocals()
        t.observe(tick, snapshotOf(s.getLocals()))
      var model = t.diffAt(b).modifiedPaths().toHashSet
      var desk = initHashSet[string]()
      for c in samples[i]["changed"]: desk.incl c["name"].getStr
      checkpoint("tick " & $b & ": desktop " & $desk & ", model " & $model)
      ck desk == model
      inc compared
    ck compared == samples.len - 1

suite "PLAT-51 desktop reference: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
