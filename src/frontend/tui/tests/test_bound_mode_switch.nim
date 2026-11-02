## test_bound_mode_switch.nim — Mode-Transitions.md §4 and §6, Tier 1. **With a
## layout binding enabled, `Ctrl+F5` swaps the binding's arrangement, so what
## is drawn and what a click hits are one tree in both modes, after any number
## of switches.**
##
## ## THE DEFECT THIS SUITE IS WRITTEN AGAINST
##
## The terminal keeps two things that each decide an arrangement: the LAYOUT
## BINDING (PLAT-6) — the tree a click is hit-tested against, the tree a
## gesture changes — and the MODE REGISTER (PLAT-16, `views/shell.ModeRegister`)
## — one tree per product mode, filled by `Ctrl+F5`. Until codetracer-pm issue
## 2026-10-21's fix, the toggle stored and restored only the register, and
## `tui_app.shellModel` drew the register's tree whenever it held one for the
## current mode. With a binding enabled that split the screen from the
## hit-test (measured at 200x50 before the fix):
##
##   * the replay loop toggled into Edit mode DREW
##     `[fileTree, editor, buildOutput, constraints]` and Debug's four footer
##     panels, and HIT-TESTED `[fileTree, editor, state, calltrace, eventLog]`:
##     a click on the drawn VCS tab answered `activateTab(vcs) applied` and the
##     screen did not move;
##   * after one round trip in either loop the register's cell was a SNAPSHOT
##     of the binding's tree (`layout_model.apply` never mutates), so every
##     later gesture changed the hit-test and not the screen — in `ct edit`,
##     Edit → Debug → Edit left the VCS tab unchoosable again.
##
## The cases below are §9's `Mode.ToggleRoundTrip`, `Mode.ThreeRoundTrips`,
## `Mode.NestedTabSelectableAtStart` and `Mode.LayoutPersisted` (its terminal
## half, see the last case) for a BOUND runtime, plus the two consequences the
## swap has for the replay session: the Debug session slot and the terminal's
## layout document hold the Debug arrangement, and an Edit-mode gesture or an
## exit in Edit mode must not put Edit's there.
##
## Every case compares the DRAWN projection (`shellModel`'s tree, projected
## exactly as `runtime.rebuildFocus` projects it) with the HIT-TESTED one
## (`layoutGeometry`, what `routeMouseReport` resolves a click against). Either
## one alone could be right while the user's click lands somewhere else.
##
## ## No mocks
##
## The runtime, keymap, binding, register and layout model are the product's
## own; clicks are SGR-1006 reports through `handleToken`; `Ctrl+F5` is
## `CSI 15 ; 5 ~`. The session-slot and persistence case opens the real
## `calc` recording under a real `replay-server`, as
## `test_plat48_top_bar.nim`'s M76 cases do, and writes the real document
## through `host/layout_store` into a scratch directory.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc` cannot
## see `testStatusIMPL`. Helpers here return values and call `check` nowhere.

import std/[json, os, strutils, tempfiles, unittest]

import codetracer_embed
import headless_app/layout_model

import ../app/runtime
import ../app/theme/capabilities
import ../host/layout_store
import ../host/tui_session
from backend/stdio_backend import toBackendService
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 86

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  CtrlF5 = "\x1b[15;5~"
    ## `CSI <code> ; <modifier> ~`, F5 is 15 and Ctrl is modifier 5.
    ## https://invisible-island.net/xterm/ctlseqs/ctlseqs.html

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc replayRuntime(): TuiRuntime =
  ## `main.interactive`'s shape: Debug mode, a binding.
  result = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
  discard result.enableLayoutBinding()

proc editRuntime(): TuiRuntime =
  ## `main.editInteractive`'s shape: Edit mode set before the runtime, a
  ## binding, no session.
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  result = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.enableLayoutBinding()

proc sgr(row, col: int; pressed: bool): string =
  ## One SGR-1006 report; one-based on the wire.
  "\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & (if pressed: "M" else: "m")

proc drawn(rt: TuiRuntime): seq[PaneKind] =
  ## The panes the FRAME projects.
  let m = rt.app.shellModel(rt.width, rt.height)
  for r in projectLayout(m.layout, bodyArea(rt.width, rt.height)).regions:
    result.add r.pane

proc hit(rt: TuiRuntime): seq[PaneKind] =
  ## The panes a CLICK is resolved against.
  for r in rt.layoutGeometry().projection.regions:
    result.add r.pane

proc drawnDocked(rt: TuiRuntime): int =
  rt.app.shellModel(rt.width, rt.height).docked.len

proc clickTab(rt: TuiRuntime; tab: string): bool =
  ## Click the tab titled `tab` where the FRAME draws it. False when no drawn
  ## stack has such a tab.
  let m = rt.app.shellModel(rt.width, rt.height)
  for r in projectLayout(m.layout, bodyArea(rt.width, rt.height)).regions:
    let at = r.tabs.find(tab)
    if r.tabs.len >= 2 and at >= 0:
      let col = r.area.col + tabSpans(r.tabs, r.activeTab)[at].startCol + 1
      discard rt.handleToken(sgr(r.area.row, col, true), 0'i64)
      discard rt.handleToken(sgr(r.area.row, col, false), 0'i64)
      return true
  false

proc toggle(rt: TuiRuntime) =
  discard rt.handleToken(CtrlF5, 0'i64)

proc rows(rt: TuiRuntime): seq[string] =
  ## Every row but the status row, which carries the switch's notice.
  let all = rt.shellScreenOf().rows
  all[0 ..< ^1]

proc arrangement(rt: TuiRuntime): string =
  ## The bound arrangement as its saved document — tree, active tabs, docked.
  $saveLayout(rt.app.layoutBinding.layout)

suite "Mode-Transitions §4/§6: a bound runtime swaps the binding's arrangement":

  test "replay loop: Debug -> Edit draws Edit's arrangement, and a VCS click moves it":
    let rt = replayRuntime()
    ck rt.drawnDocked() == 4          # Debug's footer, the control
    rt.toggle()
    ck rt.app.modes.product == pmEdit
    checkpoint("drawn " & $rt.drawn() & " hit " & $rt.hit())
    ck rt.drawn() == rt.hit()
    ck paneBuildOutput in rt.drawn()
    ck paneCalltrace notin rt.drawn()
    # Edit mode's footer: the desktop's, less the BUILD pane its tree places
    # (PLAT-55) — PROBLEMS, FIND IN FILES, REQUESTS.
    ck rt.drawnDocked() == 3
    ck rt.clickTab("VCS")
    ck paneVcs in rt.drawn()
    ck paneFileTree notin rt.drawn()
    ck rt.drawn() == rt.hit()
    # The binding is the Edit mode's now: a reset returns to Edit's default.
    ck rt.app.layoutBinding.product == pmEdit

  test "ct edit: Edit -> Debug -> Edit restores the arrangement left, and clicks still work":
    let rt = editRuntime()
    ck rt.clickTab("VCS")
    ck paneVcs in rt.drawn()
    rt.toggle()
    ck rt.app.modes.product == pmDebug
    ck rt.drawn() == rt.hit()
    ck paneCalltrace in rt.drawn()
    ck rt.drawnDocked() == 4
    ck rt.app.layoutBinding.product == pmDebug
    rt.toggle()
    ck rt.app.modes.product == pmEdit
    # THE ARRANGEMENT THE USER LEFT, VCS tab in front (§4 requirement 1).
    ck paneVcs in rt.drawn()
    ck rt.drawn() == rt.hit()
    # …and the gestures still reach the screen (§4.6, after a switch).
    ck rt.clickTab("Files")
    ck paneFileTree in rt.drawn()
    ck paneVcs notin rt.drawn()
    ck rt.clickTab("VCS")
    ck paneVcs in rt.drawn()
    ck rt.drawn() == rt.hit()

  test "three round trips are identical (Mode.ThreeRoundTrips), from either start":
    for start in [pmEdit, pmDebug]:
      let rt = if start == pmEdit: editRuntime() else: replayRuntime()
      # A gesture in each mode, so both cells are the user's, not defaults.
      ck rt.clickTab("VCS")
      rt.toggle()
      ck rt.clickTab("VCS")
      rt.toggle()
      let firstRows = rt.rows()
      let firstDoc = rt.arrangement()
      rt.toggle()
      let otherRows = rt.rows()
      let otherDoc = rt.arrangement()
      for trip in 1 .. 3:
        rt.toggle()
        ck rt.app.modes.product == start
        ck rt.rows() == firstRows
        ck rt.arrangement() == firstDoc
        rt.toggle()
        ck rt.rows() == otherRows
        ck rt.arrangement() == otherDoc
      # An undo cannot cross a switch: the entering mode starts a history.
      discard rt.app.layoutBinding.undoLayout()
      ck rt.drawn() == rt.hit()

  test "the session slot and the document keep the Debug arrangement through Edit mode":
    let calc = resolveFixture("calc")
    if calc.outcome != foRecorded:
      checkpoint(calc.detail)
    ck calc.outcome == foRecorded
    let dir = createTempDir("bound-mode-switch-", "")
    let document = dir / "tui-layout.json"
    let rt = replayRuntime()
    let s = openTuiSession(calc.tracePath, viewportHeight = 42)
    s.header(rt)
    s.learnExtent()
    s.refresh(rt)
    discard rt.app.shell.openSession(s.session.backend.toBackendService(),
                                     title = rt.app.traceName,
                                     layout = rt.app.layoutBinding.layout,
                                     adopt = s.session.sdk)
    # The replay loop's persistence, as `main.interactive` wires it: the
    # document bound, every committed change written through.
    rt.bindLayoutDocument(document)
    rt.layoutCommitted = proc(rt: TuiRuntime) =
      discard persistLayoutForSession(rt)
    # A DEBUG-MODE GESTURE, written through and onto the session's slot. Not
    # on the Files/VCS stack: Edit mode's gesture below is a VCS click on the
    # same cells, and a toggle that left the click hit-testing Debug's tree
    # would then move Debug's VCS tab, which this case must see.
    ck rt.clickTab("Terminal Output")
    ck fileExists(document)
    let debugDoc = readFile(document)
    let debugArrangement = rt.arrangement()
    let slotBefore = $saveLayout(rt.app.shell.activeSlot().layout)
    ck slotBefore == debugArrangement
    let debugRows = rt.rows()

    # INTO EDIT MODE, and an Edit-mode gesture.
    rt.toggle()
    ck rt.app.modes.product == pmEdit
    ck rt.clickTab("VCS")
    ck rt.app.layoutBinding.userModified
    # Neither the slot nor the document is Edit's.
    ck $saveLayout(rt.app.shell.activeSlot().layout) == slotBefore
    ck readFile(document) == debugDoc
    # …and what the host writes onto a slot it leaves or opens from here
    # (`main.showSession`, the recording opener) is the Debug arrangement too.
    ck $saveLayout(rt.debugArrangementOf()) == debugArrangement
    # AN EXIT WHILE IN EDIT MODE saves the DEBUG arrangement, the one the
    # document holds — never Edit's.
    let plan = rt.layoutPersistPlanOf()
    ck plan.intent == lpiWrite
    ck parseJson(plan.text) == parseJson(debugArrangement)
    let saved = persistLayoutForSession(rt)
    ck saved.outcome == lpoWritten
    ck parseJson(readFile(document)) == parseJson(debugArrangement)

    # BACK IN DEBUG MODE: the arrangement as it was left.
    rt.toggle()
    ck rt.app.modes.product == pmDebug
    ck rt.arrangement() == debugArrangement
    ck rt.rows()[1 ..< ^1] == debugRows[1 ..< ^1]
    ck rt.drawn() == rt.hit()

    # AN UNTOUCHED DEBUG ARRANGEMENT, left for Edit mode and exited from
    # there, removes the document as an untouched Debug session does.
    discard rt.app.layoutBinding.resetToProfile()
    discard persistLayoutForSession(rt)
    ck not fileExists(document)
    rt.toggle()
    ck rt.clickTab("Files")
    ck rt.layoutPersistPlanOf().intent == lpiRemove
    ck not fileExists(document)
    discard persistLayoutForSession(rt)
    ck not fileExists(document)
    s.close()
    removeDir(dir)

  test "assertion count":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
