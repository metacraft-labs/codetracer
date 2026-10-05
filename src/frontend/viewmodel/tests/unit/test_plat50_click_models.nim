## test_plat50_click_models.nim — PLAT-50, the shared half of the click sweep:
## WHAT A CLICK DOES, as the data both native front-ends read
## (`headless_app/pane_clicks`).
##
##   * the INVENTORY — every desktop click behaviour the milestone's table
##     lists, one row each (`K1` … `K56`), every row with a target, gestures,
##     the desktop's behaviour and a state for each native front-end (done,
##     existing, or n/a with the reason the front-end draws no such target);
##   * the WORD UNDER THE POINTER (`callTokenAt`), Monaco's rule, with Rust's
##     `::` paths and their ambiguity;
##   * the CONTEXT MENUS, built from the facts every front-end reads: a tab's
##     (maximised or not) and a docked pane's label's; the editor's on a plain
##     line, on an enabled and a disabled breakpoint, with breakpoints in the
##     file and elsewhere; a call with children, collapsed, a leaf; a call
##     argument; a variable; an inline value — their labels in the desktop's
##     order, a disabled entry with its reason;
##   * an OPEN MENU (`ContextMenuState`): the keyboard starts on the first
##     enabled entry, Up / Down skip disabled ones and wrap, a pointer may rest
##     on a disabled one, choosing a disabled one does nothing and keeps the
##     menu open, choosing an enabled one closes it and answers its action and
##     target;
##   * the EVENT LOG'S ORDER: a header click orders by its column, again
##     reverses it (`EventLogOrder.clickedHeader`).
##
## The desktop's measured labels are asserted against these models in
## `src/frontend/tui/tests/test_plat50_desktop_reference.nim`. Every subject
## here is pure (values in, values out), on both backends (vm-unit and
## vm-unit-js). No mocks.

import std/[sets, strutils, unittest]

import headless_app/layout_model
import headless_app/pane_clicks
import viewmodels/event_log_vm

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 214

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

func rowsWith(state: NativeState; gpui = false): seq[string] =
  ## The ids of every inventory row in `state` for the terminal (or GPUI).
  for b in ClickInventory:
    if (if gpui: b.gpui else: b.terminal) == state:
      result.add b.id

suite "PLAT-50: the click inventory":

  test "every row K1..K56, once, complete":
    var ids = initHashSet[string]()
    for i, b in ClickInventory:
      ck b.id == "K" & $(i + 1)
      ids.incl b.id
    ck ids.len == ClickInventory.len
    ck ClickInventory.len == 56
    for b in ClickInventory:
      if b.target.len == 0 or b.gestures.card == 0 or b.desktop.len == 0:
        checkpoint("incomplete row " & b.id)
        ck false
      # A row the front-ends do not do says why; one an earlier milestone
      # did names it.
      for state in [b.terminal, b.gpui]:
        if state in {nsNotApplicable, nsExisting} and b.note.len == 0:
          checkpoint("row " & b.id & " is " & $state & " without a note")
          ck false

  test "the rows this milestone implements, by front-end":
    let terminal = rowsWith(nsDone)
    let gpui = rowsWith(nsDone, gpui = true)
    # The sweep's rows, on both front-ends: nothing the desktop does on a
    # target either front-end draws is left undone.
    for id in ["K7", "K10", "K11", "K12", "K13", "K14", "K15", "K17", "K18",
               "K19", "K22", "K23", "K24", "K25", "K26", "K27", "K28",
               "K30", "K31", "K33", "K34", "K36", "K37", "K42",
               "K45", "K53"]:
      ck id in terminal
      ck id in gpui
    # The one row only GPUI draws a target for: the Locals / Globals /
    # Watches tabs.
    ck "K29" in gpui and "K29" notin terminal
    ck behaviour("K20").terminal == nsExisting
    # An argument's left press is the row's: the desktop opens no tooltip.
    ck behaviour("K38").terminal == nsExisting
    ck behaviour("K38").gpui == nsExisting
    ck behaviour("K32").terminal == nsNotApplicable
    ck behaviour("K99").id.len == 0
    ck describe(behaviour("K24")).startsWith("K24 Event log: row [click]")

suite "PLAT-50: the word under the pointer (`callTokenAt`)":

  test "the word a column is in, or ends; none on a separator":
    let line = "    return apply_op(symbol, left, right)"
    ck callTokenAt(line, 12).token == "apply_op"      # the `a`
    ck callTokenAt(line, 19).token == "apply_op"      # the last `p`
    ck callTokenAt(line, 20).token == "apply_op"      # the `(` after it
    ck callTokenAt(line, 5).token == "return"
    ck callTokenAt(line, 2).token == ""               # indentation
    ck callTokenAt(line, 0).token == ""
    ck callTokenAt(line, 200).token == ""             # past the line
    ck callTokenAt("", 1).token == ""

  test "Rust widens over `::` and refuses an ambiguous path":
    ck callTokenAt("let v = std::cmp::max(a, b);", 19, rust = true).token ==
      "std::cmp::max"
    let twice = callTokenAt("f(g(1), g(2));", 3, rust = true)
    ck twice.token == "" and twice.error == "Multiple calls of 'g'"
    # Not Rust: no widening, no ambiguity rule.
    ck callTokenAt("f(g(1), g(2));", 3).token == "g"

suite "PLAT-50: the context menus are the desktop's":

  test "a tab's menu, and a docked pane's label's":
    let m = tabContextMenu(paneVcs, maximised = false)
    ck m.labels == @["Pin to Left", "Pin to Bottom", "Pin to Right", "Close",
                     MaximiseLabel]
    ck m.target.pane == paneVcs
    ck tabContextMenu(paneVcs, maximised = true).labels[^1] == MinimiseLabel
    for e in m.entries:
      ck e.enabled
    ck m.entries[0].action == caPinLeft and m.entries[3].action == caClosePane
    # `ui/auto_hide`'s strip menu: every OTHER edge, Unpin, Close.
    let bottom = dockLabelContextMenu(paneBuildOutput, leBottom)
    ck bottom.labels == @["Pin to Left", "Pin to Right", UnpinLabel, "Close"]
    ck bottom.target.edge == leBottom and bottom.target.pane == paneBuildOutput
    ck bottom.entries[2].action == caUnpin
    ck dockLabelContextMenu(paneVcs, leLeft).labels ==
      @["Pin to Bottom", "Pin to Right", UnpinLabel, "Close"]

  test "the editor's menu on a plain line: every entry enabled":
    let m = editorTextContextMenu("/a/main.py", 31,
                                  lineText = "    return left + right",
                                  column = 12, token = "left")
    ck m.labels == @["Copy", "Find", "Jump to line", "Run to Cursor",
                     "Jump backward to line", "Jump to call",
                     "Jump forward to call", "Jump backward to call",
                     "Add breakpoint", "Add tracepoint"]
    ck m.target.line == 31 and m.target.path == "/a/main.py"
    ck m.target.token == "left" and m.target.column == 12
    ck m.target.text == "    return left + right"
    for e in m.entries:
      ck e.enabled
    ck m.entries[3].hint == "CTRL+F10"
    ck m.entries[3].action == caRunToCursor
    ck m.entries[4].action == caJumpBackwardToLine
    ck m.entries[5].action == caJumpToCall
    ck m.entries[8].action == caAddBreakpoint
    ck m.entries[9].action == caAddTracepoint

  test "the editor's menu on a breakpoint's line":
    let on = editorTextContextMenu("p", 31, breakpoint = lbEnabled,
                                   fileHasBreakpoints = true,
                                   anyBreakpoints = true)
    ck on.labels[8 .. ^1] == @["Disable breakpoint", "Delete breakpoint",
                               "Delete breakpoints in file",
                               "Delete ALL breakpoints", "Add tracepoint"]
    let off = editorTextContextMenu("p", 31, breakpoint = lbDisabled,
                                    fileHasBreakpoints = true,
                                    anyBreakpoints = true)
    ck off.labels[8] == "Enable breakpoint"
    ck off.entries[8].action == caEnableBreakpoint
    ck on.entries[8].action == caDisableBreakpoint
    ck on.entries[9].action == caDeleteBreakpoint
    ck on.entries[10].action == caDeleteBreakpointsInFile
    ck on.entries[11].action == caDeleteAllBreakpoints
    let elsewhere = editorTextContextMenu("p", 31, breakpoint = lbNone,
                                          anyBreakpoints = true)
    ck elsewhere.labels[8 .. ^1] == @["Add breakpoint",
                                      "Delete ALL breakpoints",
                                      "Add tracepoint"]

  test "a call's menu: its children":
    let expanded = callTraceContextMenu(3, hasChildren = true,
                                        expanded = true)
    ck expanded.labels == @[CollapseCallChildrenLabel]
    ck expanded.entries[0].enabled
    ck expanded.entries[0].action == caToggleCallChildren
    ck expanded.target.index == 3
    ck callTraceContextMenu(3, true, false).labels == @[ExpandCallChildrenLabel]
    let leaf = callTraceContextMenu(4, false, false)
    ck not leaf.entries[0].enabled and leaf.entries[0].reason.len > 0
    ck leaf.labels == @[ExpandCallChildrenLabel]

  test "an argument's, a variable's and an inline value's menus":
    let a = callArgumentContextMenu(4, "left", "2")
    ck a.labels == @[AddValueToScratchpadLabel]
    ck a.target.expression == "left" and a.target.text == "2" and
       a.target.index == 4
    ck a.target.scratchpadSamplesOf(caAddValueToScratchpad) == @[("left", "2")]
    let v = variablesContextMenu("@Local.EXPRESSION")
    ck v.labels == @["Toggle value history", "Show value origin"]
    ck v.entries[0].enabled and v.entries[1].enabled
    ck v.entries[1].hint == "Ctrl+Shift+O"
    ck v.entries[0].action == caToggleValueHistory
    ck v.target.path == "@Local.EXPRESSION"
    let f = flowValueContextMenu("p", 31, "left", "2",
                                 @[("left", "2"), ("right", "3")])
    ck f.labels == @[JumpToValueLabel, AddValueToScratchpadLabel,
                     AddAllValuesToScratchpadLabel]
    ck f.entries[1].hint == "CTRL+<click on value>"
    ck f.target.scratchpadSamplesOf(caAddAllValuesToScratchpad) ==
      @[("left", "2"), ("right", "3")]
    ck f.target.scratchpadSamplesOf(caAddValueToScratchpad) == @[("left", "2")]
    ck f.target.scratchpadSamplesOf(caCopy).len == 0

suite "PLAT-50: an open menu":

  test "it opens on the first enabled entry; Up and Down skip disabled ones":
    var s: ContextMenuState
    ck not s.open
    s.openAt(editorTextContextMenu("p", 5), 10, 20)
    ck s.open and s.anchorRow == 10 and s.anchorCol == 20
    ck s.selected == 0                        # Copy
    s.move(-1)
    ck s.selected == 9                        # wraps to Add tracepoint
    # A menu with a disabled entry between enabled ones (built here: no
    # desktop menu has one now, but the open menu must skip it).
    var mixed: ContextMenuState
    mixed.openAt(ContextMenuModel(entries: @[
      ContextMenuEntry(label: "a", action: caCopy, enabled: false),
      ContextMenuEntry(label: "b", action: caFind, enabled: true),
      ContextMenuEntry(label: "c", action: caCopy, enabled: false),
      ContextMenuEntry(label: "d", action: caFind, enabled: true)]), 0, 0)
    ck mixed.selected == 1                    # the first entry is disabled
    mixed.move(1)
    ck mixed.selected == 3                    # "c" skipped
    mixed.move(1)
    ck mixed.selected == 1                    # wraps, skipping "a"
    var leaf: ContextMenuState
    leaf.openAt(callTraceContextMenu(4, false, false), 0, 0)
    ck leaf.selected == -1                    # nothing enabled

  test "choosing: a disabled entry keeps the menu, an enabled one closes it":
    var s: ContextMenuState
    s.openAt(callTraceContextMenu(7, false, false), 3, 4)
    s.hover(0)
    ck s.selected == 0
    let none = s.choose(-1)
    ck not none.chosen and s.open
    ck none.target.index == 7
    ck not s.choose(0).chosen and s.open      # the disabled toggle
    s.openAt(callTraceContextMenu(7, true, true), 3, 4)
    let toggle = s.choose(0)
    ck toggle.chosen and toggle.action == caToggleCallChildren
    ck toggle.target.index == 7 and toggle.target.pane == paneCalltrace
    ck not s.open and s.selected == -1
    ck not s.choose(0).chosen               # closed: nothing to choose
    s.openAt(tabContextMenu(paneState, false), 1, 1)
    let byKey = s.choose(-1)
    ck byKey.chosen and byKey.action == caPinLeft
    s.openAt(tabContextMenu(paneState, false), 1, 1)
    ck not s.choose(99).chosen and s.open
    s.close()
    ck not s.open

suite "PLAT-50: the event log's order (K26)":

  test "a header click orders by its column; again reverses it":
    ck RecordedEventOrder == EventLogOrder(column: elcTick, ascending: true)
    let byOutput = RecordedEventOrder.clickedHeader(elcOutput)
    ck byOutput == EventLogOrder(column: elcOutput, ascending: true)
    ck byOutput.clickedHeader(elcOutput) ==
      EventLogOrder(column: elcOutput, ascending: false)
    ck byOutput.clickedHeader(elcOutput).clickedHeader(elcOutput) == byOutput
    # The tick column, clicked, reverses the recorded order.
    ck RecordedEventOrder.clickedHeader(elcTick) ==
      EventLogOrder(column: elcTick, ascending: false)
    ck byOutput.clickedHeader(elcIndex).ascending

suite "PLAT-50 click models: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
