## test_plat70e_origin_keys_vm.nim — PLAT-70 Part E (Variable-State-Pane.md
## § Value origin from the keyboard; Value-Origin-Tracking.md §13.0): the
## Variables pane from the keyboard, in the shared ViewModel every native
## front-end applies — on the C and the JS backend (vm-unit and vm-unit-js).
##
## * **The hops as rows** (`originHopRows`): the line drawn, the tick `Enter`
##   seeks to and the operands come from ONE hop of the engine's chain, so
##   the text and the seek target cannot disagree; a hop naming no recorded
##   step is skipped.
## * **The cursor rule** (`stateKey`): `Down` from a variable whose chain is
##   open moves onto its first hop, the hops are stops like the variables,
##   `Enter` on a hop seeks, `→` / `←` show and hide its operands (and `←`
##   on a hop goes to its variable), `Escape` on a hop closes the chain and
##   returns to the variable, `Escape` on a variable is not the pane's, and
##   `variables.show-value-origin` toggles the focused variable's chain from
##   a hop as from the variable.
## * **The data**: the shipped CUA, Emacs, Vim and Kakoune keymaps resolve
##   `Ctrl+Shift+O` / `g o` to `variables.show-value-origin` in the
##   Variables pane only, the application key `Menu` (CUA / Vim / Kakoune:
##   the context menu; Emacs: `M-x`) and CUA's `Ctrl+K Shift+F10` in Debug
##   mode; the terminal's and the desktop's decoders name `Menu`.
##
## ## No mocks
## Pure functions and the shipped keymap data over values written here; the
## chain is the engine's wire shape (`OriginChain`), built as a value.

import std/[strutils, unittest]

import ../../editing_core
import ../../viewmodels/origin_chain_types
import ../../viewmodels/state_pane_keys
import ../../keymap/keymap_router
import ../../keymap/scope_path
import ../../../../common/[key_names, key_event_names]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 73

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

func hop(tick: uint64; path: string; line: int; target, source: string;
         operands: seq[(string, string)] = @[]): OriginHop =
  result = OriginHop(kind: okTrivialCopy, targetExpr: target,
                     sourceExpr: source,
                     location: OriginLocation(path: path, line: line,
                                              rrTicks: tick))
  for (n, v) in operands:
    result.operandSnapshots.add OperandSnapshot(name: n, value: v)

let chain = OriginChain(queryVariable: "total", hops: @[
  hop(219, "/src/app/main.py", 12, "total", "a + b",
      @[("a", "10"), ("b", "32")]),
  hop(0, "", 0, "x", "y"),                     # names no recorded step
  hop(118, "/src/shared/helpers.py", 6, "a", "10")])

suite "PLAT-70 Part E: an origin chain's hops as rows":

  test "one hop is one row: its text, its seek target and its operands":
    let rows = chain.originHopRows
    ck rows.len == 2
    ck rows[0].tick == 219
    ck rows[0].path == "/src/app/main.py" and rows[0].line == 12
    ck rows[0].text.startsWith("tick 219  ")
    ck rows[0].text.endsWith("total <- a + b  main.py:12")
    ck rows[0].operands == @["a = 10", "b = 32"]
    ck rows[1].tick == 118
    ck rows[1].text.endsWith("a <- 10  helpers.py:6")
    ck rows[1].operands.len == 0

  test "an empty chain has no rows":
    ck OriginChain().originHopRows.len == 0

func pane(chainOpen = true; operandsOpen = false): seq[StateKeyRow] =
  ## `x` (closed tree), `total` with its chain's two hops under it, a note,
  ## then `y` (expanded).
  result.add StateKeyRow(kind: srkVariable, path: "@L.x", hop: -1,
                         expandable: true, expanded: false)
  result.add StateKeyRow(kind: srkVariable, path: "@L.total", hop: -1,
                         chainOpen: chainOpen)
  if chainOpen:
    result.add StateKeyRow(kind: srkHop, path: "@L.total", hop: 0, tick: 219,
                           hasOperands: true, operandsOpen: operandsOpen)
    result.add StateKeyRow(kind: srkHop, path: "@L.total", hop: 1, tick: 118)
  result.add StateKeyRow(kind: srkOther, path: "@L.total", hop: -1)
  result.add StateKeyRow(kind: srkVariable, path: "@L.y", hop: -1,
                         expandable: true, expanded: true)

let onTotal = variableCursor("@L.total")
let onHop0 = StateCursor(path: "@L.total", hop: 0)
let onHop1 = StateCursor(path: "@L.total", hop: 1)

suite "PLAT-70 Part E: the cursor over variables and hops (§13.0)":

  test "Down from a variable whose chain is open is its first hop":
    let e = stateKey(pane(), onTotal, "list.focus-next")
    ck e.kind == skeMoved
    ck e.cursor == onHop0
    ck stateKey(pane(), onHop0, "list.focus-next").cursor == onHop1
    # The note is passed over: the next stop after the last hop is `y`.
    ck stateKey(pane(), onHop1, "list.focus-next").cursor ==
       variableCursor("@L.y")
    ck stateKey(pane(), onHop0, "list.focus-previous").cursor == onTotal

  test "with the chain closed, Down goes to the next variable":
    ck stateKey(pane(chainOpen = false), onTotal, "list.focus-next").cursor ==
       variableCursor("@L.y")

  test "the ends, the pages, and no cursor yet":
    ck stateKey(pane(), onHop0, "list.focus-first").cursor ==
       variableCursor("@L.x")
    ck stateKey(pane(), onHop0, "list.focus-last").cursor ==
       variableCursor("@L.y")
    ck stateKey(pane(), variableCursor("@L.x"), "list.focus-page-down",
                page = 2).cursor == onHop0
    ck stateKey(pane(), variableCursor("@L.y"), "list.focus-next").kind ==
       skeNone
    ck stateKey(pane(), variableCursor(""), "list.focus-next").cursor ==
       variableCursor("@L.x")

  test "Enter on a hop seeks to its tick; on a variable it opens it":
    let e = stateKey(pane(), onHop1, "list.activate")
    ck e.kind == skeSeek
    ck e.tick == 118
    ck e.cursor == onHop1
    let v = stateKey(pane(), variableCursor("@L.x"), "list.activate")
    ck v.kind == skeExpand and v.path == "@L.x"
    ck stateKey(pane(), variableCursor("@L.y"), "list.activate").kind ==
       skeCollapse

  test "Right / Left show and hide a hop's operands; Left goes to the variable":
    let r = stateKey(pane(), onHop0, "list.expand")
    ck r.kind == skeToggleOperands and r.path == "@L.total" and r.hop == 0
    ck stateKey(pane(operandsOpen = true), onHop0, "list.expand").kind ==
       skeNone
    let l = stateKey(pane(operandsOpen = true), onHop0, "list.collapse")
    ck l.kind == skeToggleOperands
    let up = stateKey(pane(), onHop1, "list.collapse")
    ck up.kind == skeMoved and up.cursor == onTotal
    # A hop with no operands: `→` does nothing.
    ck stateKey(pane(), onHop1, "list.expand").kind == skeNone

  test "Escape on a hop closes the chain and returns to the variable":
    let e = stateKey(pane(), onHop1, "list.clear-selection")
    ck e.kind == skeCloseChain
    ck e.path == "@L.total"
    ck e.cursor == onTotal
    # On a variable it is not the pane's.
    ck stateKey(pane(), onTotal, "list.clear-selection").kind == skeUnhandled

  test "Show Value Origin toggles the focused variable's chain":
    let fromVar = stateKey(pane(chainOpen = false), onTotal,
                           ShowValueOriginOperation)
    ck fromVar.kind == skeToggleChain and fromVar.path == "@L.total"
    let fromHop = stateKey(pane(), onHop1, ShowValueOriginOperation)
    ck fromHop.kind == skeToggleChain and fromHop.cursor == onTotal
    ck stateKey(pane(), variableCursor(""), ShowValueOriginOperation).kind ==
       skeNone

  test "a cursor on a hop that is no longer listed has no row":
    ck pane(chainOpen = false).cursorIndex(onHop0) == -1
    ck stateKey(pane(chainOpen = false), onHop0, "list.activate").kind ==
       skeUnhandled

  test "operandKey":
    ck operandKey("@L.total", 0) == "@L.total#0"
    ck operandKey("@L.total", 0) != operandKey("@L.total", 1)

const
  Terminal = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                         keyProtocol: kpKitty)
  Legacy = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                       keyProtocol: kpLegacy)
  Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                        keyProtocol: kpNative)

let
  Window = element(ekWindow, "window")
  Tab = element(ekTab, "tab:1")
  StatePath = @[Window, Tab, pane("state"), element(ekRow, "row:total")]
  CallsPath = @[Window, Tab, pane("calltrace"), element(ekRow, "call-7")]
  EditorPath = @[Window, Tab, pane("editor"), element(ekEditor, "editor:a.py")]

proc debugFacts(): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: EditorFacts(readOnly: true, mode: emInsert))

proc editFacts(): SessionFacts =
  SessionFacts(product: pmEdit, editor: EditorFacts(mode: emInsert))

proc answer(base: BaseKeymap; delivery: KeyDelivery; facts: SessionFacts;
            path: ScopePath; keys: varargs[string]): string =
  ## What the shipped data answers for `keys` pressed in order.
  var r = initKeymapRouter(base, delivery)
  var t = 1_000'i64
  for k in keys:
    result = describeResolution(r.route(facts, path, nmNormal, k, t))
    t += 10

let CtrlShiftO = normalizeChord("Ctrl+Shift+O")
let ShiftF10 = normalizeChord("Shift+F10")
const Show = "operation variables.show-value-origin"
const Menu = "operation context-menu.open"

suite "PLAT-70 Part E: the shipped chords":

  test "CUA and Emacs: Ctrl+Shift+O on a variable shows its origin":
    for base in [bkCua, bkEmacs]:
      checkpoint($base)
      ck answer(base, Terminal, debugFacts(), StatePath, CtrlShiftO) == Show
      ck answer(base, Desktop, debugFacts(), StatePath, CtrlShiftO) == Show
      # Not in another list: the operation is the Variables pane's.
      ck answer(base, Desktop, debugFacts(), CallsPath, CtrlShiftO) != Show
    # The editor keeps the walk under CUA (§3.9).
    ck answer(bkCua, Desktop, debugFacts(), EditorPath, CtrlShiftO) ==
       "operation editor.jump-to-value-origin"

  test "Vim and Kakoune: g o in the Variables pane; o and Shift+O walk":
    for base in [bkVim, bkKakoune]:
      checkpoint($base)
      ck answer(base, Terminal, debugFacts(), StatePath, "g", "o") == Show
      ck answer(base, Terminal, debugFacts(), StatePath, "o") ==
         "operation editor.jump-to-value-origin"
      ck answer(base, Terminal, debugFacts(), StatePath, "O") ==
         "operation debugger.reverse-origin"
      ck answer(base, Terminal, debugFacts(), CallsPath, "g", "o") != Show

  test "the application key opens the row menu, in every mode":
    for base in [bkCua, bkVim, bkKakoune]:
      checkpoint($base)
      ck answer(base, Terminal, debugFacts(), StatePath, "Menu") == Menu
      ck answer(base, Desktop, debugFacts(), StatePath, "Menu") == Menu
    ck answer(bkCua, Desktop, editFacts(), EditorPath, "Menu") == Menu
    # Emacs: `<menu>` is `M-x`.
    ck answer(bkEmacs, Terminal, debugFacts(), StatePath, "Menu") ==
       "operation palette.open-commands"

  test "CUA in Debug mode: Ctrl+K Shift+F10, and Shift+F10 stays reverse step over":
    ck answer(bkCua, Legacy, debugFacts(), StatePath, normalizeChord("Ctrl+K"), ShiftF10) ==
       Menu
    ck answer(bkCua, Legacy, debugFacts(), StatePath, ShiftF10) ==
       "operation debugger.reverse-step-over"
    ck answer(bkCua, Desktop, editFacts(), EditorPath, ShiftF10) == Menu

  test "the decoders name the application key":
    ck keyName("\e[29~") == "Menu"
    ck keyName("\e[57363u") == "Menu"
    ck legacyEncodable("Menu")
    ck canonicalKeyOfDom("ContextMenu", "ContextMenu", false, false, false,
                         false) == "Menu"
    ck normalizeChord("Menu") == "Menu"

  test "assertion count":
    check countedAssertions == ExpectedAssertions
