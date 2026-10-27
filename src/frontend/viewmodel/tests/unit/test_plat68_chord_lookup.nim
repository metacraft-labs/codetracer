## test_plat68_chord_lookup.nim — the chord a display shows for an
## operation (KL-8) answered through one `ChordLookup` is the chord the
## router's own resolution answers, row by row.
##
## `ChordLookup` exists for speed (#784: the desktop's program menu asked for
## every item's chord on every redraw, and each answer copied the router and
## rebuilt every table's trie per chord of every candidate row, blocking the
## window for seconds per move). Speed must not change an answer, so this
## suite states the definition of `chordFor` independently — *the first row
## naming the operation, user rows later-first and then the base, whose
## sequence typed through `route` on a fresh prefix resolves to it* — and
## compares it with ONE lookup reused across every operation, which is how a
## menu uses it. The comparison runs over every base, every catalogued
## operation and every (operation, argument) a row names, across product
## modes, focus paths, pushed layers (find, palette) and user keymaps that
## shadow, remove, bind multi-chord sequences and carry `when` clauses.
##
## ## No mocks
## The shipped bases, router and loader; scope paths written as data, as in
## `test_plat68_layers.nim`.

import std/[sets, unittest]

import ../../editing_core
import ../../keymap/keymap_router
import ../../keymap/layer_stack
import ../../keymap/scope_path
import ../../keymap/operation_catalogue
import ../../keymap/user_keymap

const
  Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                        keyProtocol: kpNative)
  Terminal = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                         keyProtocol: kpKitty)

let
  Window = element(ekWindow, "window")
  Tab = element(ekTab, "tab:1")
  EditorPath = @[Window, Tab, pane("editor"),
                 element(ekEditor, "editor:main.nr")]
  CallTracePath = @[Window, Tab, pane("calltrace"), element(ekRow, "call-7")]
  VariablesPath = @[Window, Tab, pane("state"), element(ekRow, "x")]
  FindPath = EditorPath & @[element(ekOverlay, "find"),
                            element(ekInput, "find-query")]
  PalettePath = @[Window, element(ekOverlay, "palette"),
                  element(ekInput, PaletteQueryInput)]

  UserKeymaps = [
    "",
    # A shadowing row with no `when`, and a removal of a base row.
    """[{"key": "enter", "command": "debugger.step-over"},
        {"key": "f10", "command": "-debugger.step-over"},
        {"key": "ctrl+b", "command": "-layout.toggle-side-panels"}]""",
    # Multi-chord rows (the second chord is typed with a prefix pending),
    # two rows for one sequence, and `when` clauses on both sides.
    """[{"key": "ctrl+k ctrl+j", "command": "debugger.step-into"},
        {"key": "ctrl+alt+j", "command": "debugger.step-over"},
        {"key": "ctrl+alt+j", "command": "debugger.step-into"},
        {"key": "ctrl+alt+u", "command": "list.focus-first",
         "when": "listFocus"},
        {"key": "ctrl+alt+n", "command": "debugger.step-over",
         "when": "!textInputFocus"}]""",
    # `when` clauses on `chordPending` behind a prefix. The second chord is
    # resolved with a prefix pending, so the first row's chord is shown and
    # the second row's never is. Without rows like these the layers seen
    # with a prefix pending answer exactly as the ones seen without, and a
    # lookup that confused the two would pass.
    """[{"key": "ctrl+k ctrl+p", "command": "debugger.step-out",
         "when": "chordPending"},
        {"key": "ctrl+k ctrl+o", "command": "debugger.continue",
         "when": "!chordPending"}]""",
  ]

proc debugFacts(readOnly = true): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: EditorFacts(readOnly: readOnly, mode: emInsert))

proc editFacts(): SessionFacts =
  SessionFacts(product: pmEdit, editor: EditorFacts(mode: emInsert))

proc referenceChordFor(router: KeymapRouter; operation, argument: string;
                       facts: SessionFacts; path: ScopePath;
                       navMode: NavigationMode): string =
  ## The definition, through `route` on a copy of the router per row.
  var candidates: seq[tuple[b: EditingBinding, user: bool]] = @[]
  for i in countdown(router.user.bindings.len - 1, 0):
    candidates.add (router.user.bindings[i], true)
  for b in router.effective.bindings: candidates.add (b, false)
  for (b, user) in candidates:
    if b.operation != operation or b.argument != argument: continue
    var probe = router
    probe.cancelPending()
    var res: EditingResolution
    for c in b.chords:
      res = probe.route(facts, path, navMode, c, 0)
    if res.kind == erOperation and res.operation == operation and
       res.argument == argument:
      return if user: displaySequence(b.chords) else: b.spelling
  ""

proc operationsOf(router: KeymapRouter): seq[tuple[op, arg: string]] =
  ## Every catalogued operation, plus every (operation, argument) a row names.
  var seen = initHashSet[string]()
  template add(o, a: string) =
    if not seen.containsOrIncl(o & "\0" & a): result.add (o, a)
  for o in Catalogue: add(o.name, "")
  for b in router.user.bindings: add(b.operation, b.argument)
  for b in router.effective.bindings: add(b.operation, b.argument)

var compared, shown = 0

proc compareAll(router: KeymapRouter; facts: SessionFacts; path: ScopePath;
                navMode = nmNormal) =
  var lookup = initChordLookup(router, facts, path, navMode)
  for (op, arg) in router.operationsOf:
    let want = router.referenceChordFor(op, arg, facts, path, navMode)
    let got = lookup.chordFor(router, op, arg)
    inc compared
    if want.len > 0: inc shown
    if got != want:
      checkpoint "base " & $router.base & ", " & op & "(" & arg & ") at " &
                 $path.len & "-element path: lookup '" & got &
                 "', reference '" & want & "'"
    check got == want
    # The one-shot wrapper answers the same.
    check router.chordFor(op, facts, path, navMode, arg) == want

# The reference copies the router once per candidate row, which the JS backend
# does by deep copy: the full matrix takes about 80 s on C and about ten
# minutes under node. The JS lane runs the same comparison over the
# read-only debug session in two scopes, which still covers every base, user
# keymap, pushed layer and multi-chord row; the C lane runs it all.
let
  Facts = (when defined(js): @[debugFacts()]
           else: @[debugFacts(), debugFacts(readOnly = false), editFacts()])
  Paths = (when defined(js): @[EditorPath, CallTracePath]
           else: @[EditorPath, CallTracePath, VariablesPath])

suite "ChordLookup answers what the router's resolution answers (KL-8)":
  test "every base, operation, mode, focus, pushed layer and user keymap":
    for base in BaseKeymap:
      # The terminal delivery matters for the modal bases (CodeTracer-TUI
      # §4.2), the desktop one for CUA and Emacs.
      for delivery in (if base.isModal: [Terminal] else: [Desktop]):
        for text in UserKeymaps:
          var r = initKeymapRouter(base, delivery,
                                   user = parseUserKeymap(text))
          for facts in Facts:
            for path in Paths:
              r.compareAll(facts, path)
          if base.isModal:
            # The navigation modes are derived layers under the modal bases.
            for navMode in [nmCommand, nmSearch, nmInspect]:
              r.compareAll(debugFacts(), EditorPath, navMode)
              r.compareAll(debugFacts(), CallTracePath, navMode)
          # The find widget's pushed layer, owned by the editor.
          var withFind = r
          var f = debugFacts()
          f.findWidgetVisible = true
          discard withFind.pushLayer(FindTable, "editor:main.nr", "FIND")
          withFind.compareAll(f, FindPath)
          withFind.compareAll(f, EditorPath)
          # The palette's pushed layer, owned by the window.
          var withPalette = r
          var p = debugFacts()
          p.paletteVisible = true
          discard withPalette.pushLayer(PaletteTable, "window", "PALETTE")
          withPalette.compareAll(p, PalettePath)
    # The comparison must have compared something real: a suite in which no
    # operation has a chord would agree vacuously.
    check compared > (when defined(js): 2_000 else: 5_000)
    check shown > (when defined(js): 500 else: 1_000)
    echo "compared ", compared, " (operation, scope) pairs, ", shown,
         " with a chord"
