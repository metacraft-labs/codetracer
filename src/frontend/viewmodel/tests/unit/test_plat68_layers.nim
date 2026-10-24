## test_plat68_layers.nim — PLAT-68 Phase B: the shared half of every
## front-end's key routing, on C and JS.
##
## Base-Keymaps-And-Layer-Stack.md §4 (context keys and `when`), §5 (the
## layer stack, precedence, the one resolver) and §3.4 / §3.5 (the user
## layer): the laws the milestone names — KL-1 the base partition, KL-2 the
## catalogue coverage, KL-5 the stack discipline over generated sequences
## against a reference model, KL-7 the loader's closed error set with one
## planted row per kind, KL-11 VS Code's precedence through input, and the
## `when` exactness law — plus the behaviours the real-stack suites then
## drive through each front-end: the letters (OQ-1), `F12` only in Debug
## mode, the find widget's layer, the pending prefix's timeout per base and
## the status line's label.
##
## ## No mocks
## The shipped bases, the shipped router and the shipped loader, driven with
## canonical key names (what each front-end's decoder produces). Scope paths
## are written as the data they are (`scope_path` is all the resolver knows
## about focus); the per-front-end PRODUCERS of those paths are graded by the
## DIFF-13 differential (`test_plat68_differential.nim`) and the real-stack
## suites, not here.

import std/[algorithm, random, sequtils, strutils, unittest]

import ../../editing_core
import ../../keymap/keymap_router
import ../../keymap/layer_stack
import ../../keymap/scope_path
import ../../keymap/operation_catalogue
import ../../keymap/binding_sets
import ../../keymap/user_keymap

import headless_app/layout_model

# ---------------------------------------------------------------------------
# KL-2 beyond the editor: a base covers every catalogued operation of every
# table it binds or files
# ---------------------------------------------------------------------------

type
  TableCoverage = object
    ## One base's claim over the catalogue (`operation_catalogue`):
    ## `covered` are bound somewhere in the base, `filed` are not, each with
    ## the base's reason. `covered + filed == catalogue`, disjoint — by
    ## construction for the data bases, which is why the oracle suites grade
    ## the ROWS and this only states the claim.
    covered: seq[string]
    filed: seq[tuple[operation, reason: string]]

func filedReasonOf(base: BaseKeymap): string =
  case base
  of bkCua: "VS Code 1.105.0 has no default chord for this operation and " &
            "CodeTracer's desktop none either (CUA-Keymap.md §6)"
  of bkEmacs: "GNU Emacs has no key for this operation (Emacs-Keymap.md §4)"
  of bkVim, bkKakoune: "not in CodeTracer-TUI.md §4.2, the navigation " &
                       "table the modal bases share"

proc catalogueCoverage(def: KeymapDefinition): TableCoverage =
  ## Every catalogued operation, covered (some row of this base names it)
  ## or filed.
  for o in Catalogue:
    var bound = false
    for b in def.keymap.bindings:
      if b.operation == o.name:
        bound = true
        break
    if bound: result.covered.add o.name
    else: result.filed.add (o.name, filedReasonOf(def.model))

const ExpectedAssertions = 159

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Linux = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                      keyProtocol: kpKitty)
  Legacy = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                       keyProtocol: kpLegacy)
  Gpui = KeyDelivery(frontEnd: feGpui, platform: pkLinux,
                     keyProtocol: kpNative)

let
  Window = element(ekWindow, "window")
  Tab = element(ekTab, "tab:1")
  EditorPath = @[Window, Tab, pane("editor"),
                 element(ekEditor, "editor:main.nr")]
  CallTracePath = @[Window, Tab, pane("calltrace"),
                    element(ekRow, "call-7")]
  VariablesPath = @[Window, Tab, pane("state"), element(ekRow, "x")]
  FindPath = EditorPath & @[element(ekOverlay, "find"),
                            element(ekInput, "find-query")]

proc debugFacts(readOnly = true): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: EditorFacts(readOnly: readOnly, mode: emInsert))

proc editFacts(): SessionFacts =
  SessionFacts(product: pmEdit, editor: EditorFacts(mode: emInsert))

proc pressAt(r: var KeymapRouter; facts: SessionFacts; path: ScopePath;
             navMode: NavigationMode; now: int64;
             keys: varargs[string]): EditingResolution =
  var t = now
  for k in keys:
    result = r.route(facts, path, navMode, k, t)
    t += 10

proc press(r: var KeymapRouter; facts: SessionFacts; path: ScopePath;
           keys: varargs[string]): EditingResolution =
  r.pressAt(facts, path, nmNormal, 1_000, keys)

proc op(res: EditingResolution): string =
  case res.kind
  of erOperation:
    if res.argument.len > 0: res.operation & "(" & res.argument & ")"
    else: res.operation
  of erCharacter: "char:" & res.character
  of erPending: "pending:" & res.pending.chords.join(" ")
  of erNothing: "nothing:" & $res.reason

suite "KL-1 / KL-2: the bases and the catalogue":
  test "the base partition is the enum, both directions":
    ck selectableKeymapNames() == @["cua", "emacs", "vim", "kakoune"]
    for b in BaseKeymap:
      ck selectKeymap($b).ok
    ck not selectKeymap("default").ok

  test "every base loads, and covers or files every catalogued operation":
    for b in BaseKeymap:
      let def = keymapOf(b)
      let cov = catalogueCoverage(def)
      ck cov.covered.len + cov.filed.len == Catalogue.len
      ck cov.covered.allIt(it notin cov.filed.mapIt(it.operation))
      checkpoint($b & ": " & $cov.covered.len & " covered")
      ck cov.covered.len > 0

  test "the scope path's pane kinds are the layout model's, both directions":
    var names: seq[string] = @[]
    for k in PaneKind: names.add $k
    ck @PaneKinds == names

suite "§4: context keys and `when`":
  test "contextKeysOf derives every focus key from the path":
    var r = initKeymapRouter(bkCua, Linux)
    let ro = r.contextFor(debugFacts(), EditorPath)
    ck ro.values[ckEditorFocus] == "true"
    ck ro.values[ckEditorTextFocus] == "true"
    ck ro.values[ckEditorReadOnly] == "true"
    ck ro.values[ckTextInputFocus] == "false"
    ck ro.values[ckPaneKind] == "editor"
    let list = r.contextFor(debugFacts(), CallTracePath)
    ck list.values[ckListFocus] == "true"
    ck list.values[ckTreeFocus] == "false"
    ck list.values[ckEditorFocus] == "false"
    ck list.values[ckElementKind] == "row"
    let tree = r.contextFor(debugFacts(), VariablesPath)
    ck tree.values[ckTreeFocus] == "true"
    ck tree.values[ckPaneKind] == "state"
    let find = r.contextFor(debugFacts(), FindPath)
    ck find.values[ckFindInputFocus] == "true"
    ck find.values[ckTextInputFocus] == "true"
    ck find.values[ckEditorFocus] == "true"
    ck find.values[ckEditorTextFocus] == "false"

  test "every assignment contextKeysOf produces is coherent (soundness)":
    var paths = @[EditorPath, CallTracePath, VariablesPath, FindPath,
                  @[Window], @[Window, Tab, pane("eventLog")],
                  EditorPath & @[element(ekOverlay, "find"),
                                 element(ekInput, "replace-query")]]
    var incoherent = 0
    var seen = 0
    for p in paths:
      for ro in [false, true]:
        for modal in [false, true]:
          for mode in [emNormal, emInsert]:
            var f = debugFacts(ro)
            f.modalBase = modal
            f.editor.mode = mode
            let c = contextKeysOf(f, p, Linux)
            inc seen
            if not coherent(c): inc incoherent
    ck seen == 56
    ck incoherent == 0

  test "`when` exactness: the overlap check finds exactly the planted pairs":
    proc w(t: string): WhenExpr = parseWhen(t).expr
    let planted = [
      ("findInputFocus", "replaceInputFocus", false),
      ("findInputFocus", "textInputFocus", true),
      ("listFocus", "editorFocus", false),
      ("treeFocus", "!listFocus", false),
      ("editorTextFocus && !editorReadOnly", "editorReadOnly", false),
      ("productMode == debug", "productMode == edit", false),
      ("productMode == debug", "!editorFocus", true),
      ("keyProtocol == legacy", "keyProtocol != kitty", true),
    ]
    for (a, b, overlap) in planted:
      checkpoint(a & " / " & b)
      ck canBothHold(w(a), w(b)) == overlap

  test "an unknown context key is a load error, not false":
    ck not parseWhen("editorFocuss").ok
    ck parseWhen("editorFocuss").message.startsWith("unknown context key")

suite "KL-5: the layer stack, against a reference model":
  test "generated push / pop / mismatched pop / unmount sequences":
    var rng = initRand(68)
    var mismatchedRefused = 0
    var unmountedPops = 0
    for trial in 0 ..< 200:
      var s = initLayerStack()
      var model: seq[(int, string)] = @[]      # (token, owner), oldest first
      for step in 0 ..< 30:
        case rng.rand(3)
        of 0, 1:
          let owner = ["editor", "calltrace", "window"][rng.rand(2)]
          let (n, t) = s.push("find", owner, "FIND")
          s = n
          model.add (int(t), owner)
        of 2:
          if model.len == 0: continue
          let pick = model[rng.rand(model.len - 1)]
          let res = s.pop(LayerToken(pick[0]))
          if pick == model[^1]:
            model.setLen(model.len - 1)
          else:
            if res.outcome == poNotOnTop: inc mismatchedRefused
          s = res.stack
        else:
          let owner = ["editor", "calltrace", "window"][rng.rand(2)]
          let (n, popped) = s.unmount(owner)
          s = n
          let before = model.len
          model = model.filterIt(it[1] != owner)
          unmountedPops += before - model.len
          if popped.len != before - model.len:
            ck false
        if s.layers.mapIt((int(it.token), it.owner)) != model:
          ck false
    ck mismatchedRefused > 0
    ck unmountedPops > 0

  test "a mismatched pop changes nothing and says why":
    var s = initLayerStack()
    let (s1, a) = s.push("find", "editor", "FIND")
    let (s2, b) = s1.push("palette", "window", "PALETTE")
    let res = s2.pop(a)
    ck res.outcome == poNotOnTop
    ck res.stack == s2
    ck res.top == b
    ck s2.pop(LayerToken(999)).outcome == poUnknown

  test "a layer is active only while its owner is on the scope path":
    var s = initLayerStack()
    let (s1, _) = s.push("find", "editor:main.nr", "FIND")
    ck s1.activeLayers(EditorPath).len == 1
    ck s1.activeLayers(CallTracePath).len == 0
    ck s1.topLabel(CallTracePath) == ""
    ck s1.topLabel(EditorPath) == "FIND"

suite "CUA in Debug mode: the desktop's F-keys and the letters (OQ-1)":
  test "F10 steps in Debug mode and is a key the editor does not take in Edit":
    var r = initKeymapRouter(bkCua, Linux)
    ck r.press(debugFacts(), EditorPath, "F10").op == "debugger.step-over"
    ck r.press(debugFacts(), CallTracePath, "F10").op == "debugger.step-over"
    # In Edit mode F12 is inert AND SAYS SO (Mode-Transitions §8.1): the
    # operation it runs in Debug mode, the session it needs, the switch.
    let inert = r.press(editFacts(), EditorPath, "F12")
    ck inert.op == "nothing:disabled-operation"
    let note = r.inertNote(inert, editFacts(), EditorPath, nmNormal)
    checkpoint(note)
    ck note.contains("debugger.step-out") and note.contains("replay session")
    ck note.contains("Ctrl+F5 switches")
    ck r.press(debugFacts(), EditorPath, "F12").op == "debugger.step-out"
    # A key merely unbound here — its operation reachable by another key —
    # is just unbound: the menu opens in Debug mode too (`` Alt+` ``).
    let user = parseUserKeymap("""[
      { "key": "f10", "command": "-debugger.step-over" } ]""")
    var u = initKeymapRouter(bkCua, Linux, user = user)
    ck u.press(debugFacts(), EditorPath, "F10").op == "nothing:unbound"

  test "letters step in the read-only editor and in a list, and type once writable":
    var r = initKeymapRouter(bkCua, Linux)
    ck r.press(debugFacts(), EditorPath, "n").op == "debugger.step-over"
    ck r.press(debugFacts(), EditorPath, "p").op == "debugger.reverse-step-over"
    ck r.press(debugFacts(), CallTracePath, "n").op == "debugger.step-over"
    ck r.press(debugFacts(readOnly = false), EditorPath, "n").op == "char:n"
    ck r.press(debugFacts(), FindPath, "n").op == "char:n"
    ck r.press(debugFacts(), EditorPath, "r", "f").op ==
      "debugger.reverse-step-out"
    ck r.press(debugFacts(), EditorPath, "g", "g").op == "debugger.jump-to-start"
    ck r.press(debugFacts(), EditorPath, "G").op == "debugger.jump-to-end"
    ck r.press(debugFacts(), VariablesPath, "x").op == "variables.toggle-hex-dec"
    ck r.press(debugFacts(), EditorPath, "x").op == "nothing:unbound"
    ck r.press(editFacts(), EditorPath, "n").op == "char:n"

  test "Enter on the read-only editor opens the tracepoint editor; writable it is a newline":
    var r = initKeymapRouter(bkCua, Linux)
    ck r.press(debugFacts(), EditorPath, "Enter").op == "editor.toggle-tracepoint"
    ck r.press(debugFacts(readOnly = false), EditorPath, "Enter").op ==
      "insert-newline-and-indent"
    ck r.press(debugFacts(), CallTracePath, "Enter").op == "list.activate"

  test "Enter opens the tracepoint editor under every base, and only in Debug mode":
    # Base-Keymaps-And-Layer-Stack.md §3.2: the gesture is the desktop's, so
    # no base may leave it unbound (Emacs) or to §4.2's tree expansion (Vim,
    # Kakoune) in the read-only editor.
    for base in BaseKeymap:
      var r = initKeymapRouter(base, Linux)
      checkpoint($base)
      ck r.press(debugFacts(), EditorPath, "Enter").op == "editor.toggle-tracepoint"
      ck r.press(editFacts(), EditorPath, "Enter").op != "editor.toggle-tracepoint"

  test "selection and copy work in the read-only editor; edits are not bound":
    var r = initKeymapRouter(bkCua, Linux)
    ck r.press(debugFacts(), EditorPath, "Shift+Right").op == "extend-char-right"
    ck r.press(debugFacts(), EditorPath, "Ctrl+Shift+Right").op ==
      "extend-group-right"
    ck r.press(debugFacts(), EditorPath, "Shift+End").op == "extend-line-end"
    ck r.press(debugFacts(), EditorPath, "Shift+PageDown").op ==
      "extend-page-down"
    ck r.press(debugFacts(), EditorPath, "Ctrl+a").op == "select-all"
    ck r.press(debugFacts(), EditorPath, "Ctrl+c").op == "clipboard-copy"
    ck r.press(debugFacts(), EditorPath, "Ctrl+v").op == "nothing:unbound"
    ck r.press(debugFacts(), CallTracePath, "Ctrl+c").op == "list.copy"

suite "the find widget's layer (§5.3)":
  test "Escape closes find only while its owner is on the path":
    var r = initKeymapRouter(bkCua, Linux)
    var f = debugFacts()
    f.findWidgetVisible = true
    discard r.pushLayer(FindTable, "editor:main.nr", "FIND")
    ck r.press(f, FindPath, "Esc").op == "find.close"
    ck r.press(f, CallTracePath, "Esc").op == "list.clear-selection"
    ck r.press(f, EditorPath, "Esc").op == "find.close"
    ck r.statusLabel(EditorPath, nmNormal) == "FIND"
    ck r.statusLabel(CallTracePath, nmNormal) == "CUA"

  test "a find field's Alt+C toggles case; its letters are text":
    var r = initKeymapRouter(bkCua, Linux)
    var f = debugFacts()
    f.findWidgetVisible = true
    discard r.pushLayer(FindTable, "editor:main.nr", "FIND")
    ck r.press(f, FindPath, "Alt+c").op == "find.toggle-case"
    ck r.press(f, FindPath, "c").op == "char:c"
    ck r.press(f, FindPath, "Enter").op == "find.next"

  test "a focused field's own row with a true `when` takes its character":
    # §5.6, THE TEXT-ENTRY SHADOW: in a text field a character is text —
    # unless a row of the focused element's own layer (here the pushed find
    # layer) binds it under a `when` that holds. An unconditional row there
    # is no reason to stop typing, and a row further out (the global
    # table's) is never asked before the character.
    let uk = parseUserKeymap("""[
      {"key": "c", "command": "find.toggle-case", "when": "findWidgetVisible"},
      {"key": "w", "command": "find.toggle-whole-word"}]""")
    var r = initKeymapRouter(bkCua, Linux, user = uk)
    var f = debugFacts()
    f.findWidgetVisible = true
    discard r.pushLayer(FindTable, "editor:main.nr", "FIND")
    ck r.press(f, FindPath, "c").op == "find.toggle-case"
    ck r.press(f, FindPath, "w").op == "char:w"
    ck r.press(f, FindPath, "n").op == "char:n"

  test "closing the owner pops its layer":
    var r = initKeymapRouter(bkCua, Linux)
    discard r.pushLayer(FindTable, "editor:main.nr", "FIND")
    let popped = r.unmountOwner("editor:main.nr")
    ck popped.len == 1
    ck r.stack.layers.len == 0

suite "the pending prefix and the status line":
  test "CUA waits on Ctrl+K forever; Vim times out at 1000 ms":
    var r = initKeymapRouter(bkCua, Linux)
    ck r.pressAt(editFacts(), CallTracePath, nmNormal, 0, "Ctrl+k").kind == erPending
    ck r.statusLabel(CallTracePath, nmNormal) == "Ctrl+k…"
    ck r.pressAt(editFacts(), CallTracePath, nmNormal, 60_000, "Ctrl+s").op ==
      "help.keyboard-shortcuts"
    var v = initKeymapRouter(bkVim, Linux)
    ck v.pressAt(debugFacts(), CallTracePath, nmNormal, 0, "g").kind == erPending
    ck v.pressAt(debugFacts(), CallTracePath, nmNormal, 1_000, "g").op ==
      "debugger.jump-to-start"
    discard v.pressAt(debugFacts(), CallTracePath, nmNormal, 0, "g")
    let late = v.pressAt(debugFacts(), CallTracePath, nmNormal, 1_001, "g")
    ck late.timedOut
    ck late.kind == erPending

  test "the label is the base under CUA and Emacs, the mode under Vim":
    var c = initKeymapRouter(bkCua, Linux)
    ck c.statusLabel(EditorPath, nmNormal) == "CUA"
    var e = initKeymapRouter(bkEmacs, Linux)
    ck e.statusLabel(EditorPath, nmNormal) == "EMACS"
    var v = initKeymapRouter(bkVim, Linux)
    ck v.statusLabel(EditorPath, nmNormal) == "NORMAL"
    ck v.statusLabel(EditorPath, nmCommand) == "COMMAND"

suite "KL-7: the user layer's closed error set":
  test "one planted row per kind, each reported with its index":
    let text = """[
      { "key": "ctrl+alt+n", "command": "debugger.step-over" },
      { "key": "f10", "command": "debugger.step-ovr" },
      { "key": "f10", "command": "debugger.step-over", "when": "editorFocuss" },
      { "key": "f10", "command": "debugger.step-over", "when": "editorFocus &&" },
      { "key": "ctrl+nothing", "command": "debugger.step-over" },
      { "key": "f10", "command": "debugger.step-over", "base": "nano" },
      { "include": "stepping:fancy" },
      { "key": "ctrl+shift+k", "command": "editor.delete-line" },
      7
    ]"""
    let uk = parseUserKeymap(text)
    var r = initKeymapRouter(bkCua, Legacy, user = uk)
    let kinds = r.errors.mapIt(it.kind)
    ck uk.total == 9
    ck kinds.sorted == @[ueBadJson, ueUnknownCommand, ueUnknownContextKey,
                         ueMalformedWhen, ueMalformedKey, ueUnknownBase,
                         ueUnknownInclude, ueUndeliverable].sorted
    ck r.errors.mapIt(it.index).sorted == @[1, 2, 3, 4, 5, 6, 7, 8]
    ck r.user.bindings.len == 1
    ck parseUserKeymap("[").errors[0].kind == ueBadJson
    ck parseUserKeymap("[").errors[0].index == -1

  test "JSONC: comments and trailing commas, as VS Code writes them":
    let uk = parseUserKeymap("""// my keys
      [ { "key": "ctrl+alt+n", /* step */ "command": "debugger.step-over", }, ]""")
    ck uk.errors.len == 0
    ck uk.rows.len == 1

suite "KL-11: VS Code's precedence, through input":
  test "a user row with no `when` takes Enter from the call trace's base row":
    # FIRST, IN ONE TABLE: a user row of the list table over the list
    # table's own base row (`Ctrl+F`, `list.filter`). Every precedence rule
    # ever drafted agrees here — source first, or scope first — except one
    # that puts the BASE before the user; so this line names that defect,
    # and the cross-scope line after it names the other one (§5.1: the
    # first draft compared the scope before the source, which a same-table
    # pair cannot tell apart).
    let same = parseUserKeymap("""[{"key": "ctrl+f", "command": "list.focus-first"}]""")
    var s = initKeymapRouter(bkCua, Linux, user = same)
    ck s.press(debugFacts(), CallTracePath, "Ctrl+f").op == "list.focus-first"
    let uk = parseUserKeymap("""[{"key": "enter", "command": "debugger.step-over"}]""")
    var r = initKeymapRouter(bkCua, Linux, user = uk)
    # ACROSS SCOPES: a user GLOBAL row over the call trace's base LIST row.
    # Source before scope (VS Code's rule) gives the user's; scope before
    # source (the withdrawn draft) would give `list.activate`.
    ck r.press(debugFacts(), CallTracePath, "Enter").op == "debugger.step-over"
    # The load report counts the shadow (§5.6: "listed in the load report").
    ck r.shadows.len > 0 and
      r.loadSummary.endsWith(", " & $r.shadows.len & " shadow(s)")
    ck r.shadows.anyIt(it.shadowedOperation == "list.activate" and
                       it.shadowedTable == ListTable)
    let shown = r.shortcutReference(debugFacts(), CallTracePath, nmNormal)
    ck shown.anyIt(it.operation == "list.activate" and
                   it.shadowedBy == "your row 1")

  test "two user rows for one chord in one scope: the later fires, in both orders":
    let a = """{"key": "ctrl+alt+j", "command": "debugger.step-over"}"""
    let b = """{"key": "ctrl+alt+j", "command": "debugger.step-into"}"""
    var r1 = initKeymapRouter(bkCua, Linux,
                              user = parseUserKeymap("[" & a & "," & b & "]"))
    var r2 = initKeymapRouter(bkCua, Linux,
                              user = parseUserKeymap("[" & b & "," & a & "]"))
    ck r1.press(debugFacts(), CallTracePath, "Ctrl+Alt+j").op ==
      "debugger.step-into"
    ck r2.press(debugFacts(), CallTracePath, "Ctrl+Alt+j").op ==
      "debugger.step-over"
    ck r1.shadows.anyIt(it.shadowedSource == lsUser and it.shadowedIndex == 0)

  test "inside the user layer the inner scope goes first":
    let uk = parseUserKeymap("""[
      {"key": "ctrl+alt+u", "command": "list.focus-first"},
      {"key": "ctrl+alt+u", "command": "debugger.step-over"}]""")
    var r = initKeymapRouter(bkCua, Linux, user = uk)
    ck r.press(debugFacts(), CallTracePath, "Ctrl+Alt+u").op == "list.focus-first"
    ck r.press(debugFacts(), EditorPath, "Ctrl+Alt+u").op == "debugger.step-over"

  test "inside a base the inner scope goes first":
    # `Shift+Alt+I` is the editor's (`add-cursor-at-each-line-of-selection`,
    # the editor table, `editorTextFocus`) and, in Debug mode, the window's
    # (`flow.set-inline`, the global table): in the Debug editor both rows
    # hold, and the inner one answers.
    var r = initKeymapRouter(bkCua, Linux)
    ck r.press(debugFacts(), EditorPath, "Shift+Alt+i").op ==
      "add-cursor-at-each-line-of-selection"
    # The control: where no editor is on the path the global row is live, so
    # the line above is a choice between two rows that both hold.
    ck r.press(debugFacts(), CallTracePath, "Shift+Alt+i").op ==
      "flow.set-inline"

  test "a removal takes the base row out; the chord is then the next layer's":
    let uk = parseUserKeymap("""[{"key": "ctrl+b", "command": "-layout.toggle-side-panels"}]""")
    var r = initKeymapRouter(bkCua, Gpui, user = uk)
    ck r.removed == 1
    ck r.press(debugFacts(), CallTracePath, "Ctrl+b").op == "nothing:unbound"

  test "a rebinding is what every display shows (KL-8)":
    var plain = initKeymapRouter(bkCua, Gpui)
    ck plain.chordFor("debugger.step-over", debugFacts(), EditorPath,
                      nmNormal) == "F10"
    let uk = parseUserKeymap("""[{"key": "ctrl+alt+n", "command": "debugger.step-over"},
                                 {"key": "f10", "command": "-debugger.step-over"}]""")
    var r = initKeymapRouter(bkCua, Gpui, user = uk)
    # In the display spelling, whatever case the user wrote it in.
    ck r.chordFor("debugger.step-over", debugFacts(), EditorPath,
                  nmNormal) == "Ctrl+Alt+N"

  test "an include brings a preset's rows, as rows of the user layer":
    let uk = parseUserKeymap("""[{"include": "stepping:chorded"}]""")
    var r = initKeymapRouter(bkCua, Gpui, user = uk)
    ck r.press(debugFacts(), EditorPath, "F10").op == "nothing:unbound"
    ck r.press(debugFacts(), EditorPath, "Ctrl+Alt+o").op == "debugger.step-over"
    ck bindingSetIndex("stepping:none") >= 0

suite "the web studio's Run and Export (CUA-Keymap.md §3.7)":
  test "Ctrl+Enter runs and Ctrl+Shift+E exports on the web; VS Code's rows elsewhere":
    const
      Web = KeyDelivery(frontEnd: feWeb, platform: pkLinux, keyProtocol: kpNative)
      Desk = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                         keyProtocol: kpNative)
    var w = initKeymapRouter(bkCua, Web)
    var d = initKeymapRouter(bkCua, Desk)
    ck w.press(editFacts(), EditorPath, "Ctrl+Enter").op == "build.run-program"
    ck w.press(editFacts(), CallTracePath, "Ctrl+Enter").op == "build.run-program"
    ck w.press(editFacts(), EditorPath, "Ctrl+Shift+e").op == "project.export"
    ck d.press(editFacts(), EditorPath, "Ctrl+Enter").op == "open-line-below"
    ck d.press(editFacts(), EditorPath, "Ctrl+Shift+e").op ==
       "layout.focus-pane(file-tree)"
    # `Alt+1`, the desktop's low-level code view (§5), on both — and not on
    # the terminal, which has no such view.
    ck d.press(debugFacts(), EditorPath, "Alt+1").op == "view.low-level-code"
    ck w.press(debugFacts(), EditorPath, "Alt+1").op == "view.low-level-code"
    var t = initKeymapRouter(bkCua, Linux)
    ck t.press(debugFacts(), EditorPath, "Alt+1").op != "view.low-level-code"

suite "the modal bases: derived layers (§5.5)":
  test "§4.2 under Vim: the navigation table follows the modal state":
    var v = initKeymapRouter(bkVim, Linux)
    ck v.press(debugFacts(), EditorPath, "n").op == "debugger.step-over"
    ck v.press(debugFacts(), EditorPath, "j").op == "editor.scroll-line-down"
    ck v.press(debugFacts(), EditorPath, "Tab").op == "layout.focus-next-pane"
    ck v.pressAt(debugFacts(), EditorPath, nmSearch, 1_000, "n").op == "find.next"
    ck v.press(debugFacts(), EditorPath, "q").op == "app.quit"

  test "Vim's editor table holds in a writable buffer, by its own mode":
    var v = initKeymapRouter(bkVim, Linux)
    var f = editFacts()
    f.editor.mode = emNormal
    ck v.press(f, EditorPath, "j").op == "move-line-down"
    f.editor.mode = emInsert
    ck v.press(f, EditorPath, "j").op == "char:j"

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
