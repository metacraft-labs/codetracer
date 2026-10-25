## test_plat70c_find_vm.nim — PLAT-70 Part C (Find-And-Incremental-Search.md
## §2 – §4): the one matcher, the one pattern store, the find session every
## base drives, the word-under-the-caret launchers as compositions, and each
## base's rows — on the C and the JS backend (vm-unit and vm-unit-js).
##
## What is graded, by the spec's invariants:
##
## * **FS-1, one matcher**: `matchesOf` answers the session's highlights,
##   `search-next` / `search-prev`, the multi-cursor matches and the closed
##   walk — each compared here with `matchesOf` itself, case and whole word
##   included; the source gate is `ci/test/plat70c-one-matcher.sh`.
## * **FS-2, one pattern store**: after a session closes the pattern is
##   `EditorState.search.pattern` and the session holds nothing
##   (`FindVM() == default`), and `n` / `F3` walk it.
## * **FS-3**: a query typed one character at a time highlights exactly
##   `matchesOf`'s spans after every key and selects the first at or after
##   the ORIGIN, forward and backward — and deleting a character moves back
##   toward the origin, which a session that searched on from its previous
##   match would not do.
## * **FS-4 / FS-5**: cancel restores every range of the selection and both
##   scroll offsets exactly after a walk that wrapped, mapped through an edit
##   made meanwhile; accept keeps the match.
## * **FS-6**: every macro row equals its steps run one by one, on a corpus
##   of caret positions (word start, middle, end, between words, on
##   punctuation, on a wide glyph).
## * the per-base rows of CUA-Keymap §3.5, Emacs-Keymap §3.9 / §3.6 and the
##   modal bases' find layer, resolved through the shipped router.
##
## ## No mocks
## The shipped editing core, vocabulary, bases and router, over documents
## written as data. Nothing is stood in for.

import std/[strutils, tables, unittest]

import ../../editing_core
import ../../viewmodels/find_vm
import ../../keymap/keymap_router
import ../../keymap/layer_stack
import ../../keymap/scope_path
import ../../keymap/operation_catalogue

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 926

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Linux = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                      keyProtocol: kpKitty)
  Source = "def foo():\n" &
           "    foo_bar = foo + 1\n" &
           "    return Foo\n" &
           "foo\n" &
           "café foo, foobar; foo\n"

let
  Window = element(ekWindow, "window")
  Tab = element(ekTab, "tab:1")
  EditorPath = @[Window, Tab, pane("editor"),
                 element(ekEditor, "editor:main.py")]
  FindPath = EditorPath & @[element(ekOverlay, "find"),
                            element(ekInput, "find-query")]

proc docOf(model: BaseKeymap; text = Source): EditingDocument =
  initEditingDocument("main.py", text, model)

proc at(d: var EditingDocument; line, column: int) =
  d.moveCaretTo(line, column)

proc spansOf(f: FindVM): seq[MatchSpan] = f.matches

proc selected(d: EditingDocument): tuple[a, b: int] =
  let m = d.state.selection.mainRange
  (m.rangeFrom, m.rangeTo)

# ---------------------------------------------------------------------------

suite "the one matcher (FS-1)":
  test "literal, case-folded, whole word, non-overlapping, at rune starts":
    let insensitive = MatchOptions(caseSensitive: false)
    let sensitive = MatchOptions(caseSensitive: true)
    let word = MatchOptions(caseSensitive: true, wholeWord: true)
    ck matchesOf(Source, "foo", sensitive).len == 7
    ck matchesOf(Source, "foo", insensitive).len == 8   # + `Foo`
    # Whole word: not `foo_bar`, not `foobar`.
    ck matchesOf(Source, "foo", word).len == 5
    ck matchesOf("aaaa", "aa", sensitive) ==
         @[MatchSpan(a: 0, b: 2), MatchSpan(a: 2, b: 4)]
    # Unicode simple case folding on a non-ASCII pattern.
    ck matchesOf("ΣΙΣ σισ", "σισ", insensitive).len == 2
    ck matchesOf("CAFÉ café", "café", insensitive).len == 2
    ck matchesOf("x", "", sensitive).len == 0

  test "the cap is 19 999 and the walk is not bounded by it":
    var big = ""
    for i in 0 ..< 20_500: big.add "ab "
    let opts = MatchOptions(caseSensitive: true)
    ck matchesOf(big, "ab", opts).len == MatchesLimit
    let past = nextMatchOf(big, "ab", opts, 3 * 20_100, forward = true)
    ck past.found and past.span.a == 3 * 20_100
    var d = docOf(bkCua, big)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "ab")
    ck f.capped
    ck f.countText(d) == "1 of 19999+"
    d.at(0, 3 * 20_200)
    discard f.cancel(d)

  test "search-next, the closed walk and the multi-cursor commands use it":
    var d = docOf(bkCua)
    d.state.search.pattern = "FOO"
    d.state.search.options = MatchOptions(caseSensitive: false)
    d.at(0, 0)
    var seen: seq[int] = @[]
    for _ in 0 ..< 9:
      discard d.applyNamed("move-search-next", OpArgs(), 0)
      seen.add d.state.selection.mainRange.head
    var want: seq[int] = @[]
    for m in matchesOf(Source, "FOO", d.state.search.options): want.add m.a
    ck want.len == 8
    ck seen[0 ..< 8] == want
    ck seen[8] == want[0]                     # wrapped
    var c = docOf(bkCua)
    c.selectSpan(4, 7)                        # `foo`
    discard c.applyNamed("select-all-matches", OpArgs(), 0)
    ck c.state.selection.rangeCount ==
         matchesOf(Source, "foo", MatchOptions(caseSensitive: true)).len

suite "the session (§3)":
  test "typing highlights matchesOf after every key, from the origin (FS-3)":
    for backward in [false, true]:
      var d = docOf(bkCua)
      d.at(2, 4)                                     # `return`
      let origin = d.state.selection.mainRange.head
      var f: FindVM
      discard f.openFind(d, bkCua, "e", backward, fsNone, 1, 0)
      var typed = ""
      for ch in "foo":
        typed.add ch
        discard f.typeText(d, $ch)
        ck f.spansOf == matchesOf(Source, typed, d.state.search.options)
        ck d.state.search.pattern == typed
        let w = nextMatchOf(Source, typed, d.state.search.options, origin,
                            forward = not backward)
        ck d.selected == (w.span.a, w.span.b)
      discard f.cancel(d)

  test "a deleted character moves back toward the origin, not on":
    var d = docOf(bkCua)
    d.at(0, 0)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    discard f.step(d, true)
    discard f.step(d, true)                         # third `foo`
    discard f.setQuery(d, "foo_")                   # one match only
    discard f.deleteBackward(d)                     # back to `foo`
    ck d.selected == (4, 7)                         # the first, not the fourth
    discard f.cancel(d)

  test "accept keeps the match; the pattern outlives the session (FS-2, FS-5)":
    var d = docOf(bkCua)
    d.at(0, 0)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "return")
    let kept = d.selected
    discard f.accept(d)
    ck not f.open
    ck f == FindVM()
    ck d.selected == kept
    ck d.state.search.pattern == "return"
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    discard f.accept(d)
    d.at(0, 0)
    let walked = walkClosed(d, bkCua, next = true)
    ck walked.message == ""
    ck d.selected == (4, 7)

  test "cancel restores every range and both offsets exactly (FS-4)":
    var d = docOf(bkCua)
    d.state.selection = editorSelection([spanRange(0, 3), caret(20)], 1)
    let before = d.state.selection
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 7, 5)
    discard f.setQuery(d, "foo")
    for _ in 0 ..< 10: discard f.step(d, true)      # wraps
    for _ in 0 ..< 3: discard f.step(d, false)
    let r = f.cancel(d)
    ck d.state.selection == before
    ck r.top == 7 and r.leftCol == 5
    ck d.state.search.pattern == "foo"

  test "cancel maps the origin through an edit made while the session was open":
    var d = docOf(bkCua)
    d.at(3, 0)                                      # the lone `foo`
    let caretAt = d.state.selection.mainRange.head
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "def")
    d.selectSpan(0, 0)
    discard d.applyNamed("insert-text", OpArgs(text: "## "), 0)
    discard f.cancel(d)
    ck d.state.selection.mainRange.head == caretAt + 3

  test "with no match the count says so and the caret returns to the origin":
    var d = docOf(bkCua)
    d.at(1, 2)
    let origin = d.state.selection
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "zzz")
    ck f.countText(d) == NoMatchesText
    ck d.state.selection == origin
    discard f.cancel(d)

  test "the count, the wrap and the toggles":
    var d = docOf(bkCua)
    d.at(4, 0)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    ck f.countText(d).endsWith(" of 8")
    for _ in 0 ..< 3: discard f.step(d, true)
    ck f.wrapped
    ck f.wrapText == WrappedForwardText
    discard f.toggleCase(d)
    ck f.countText(d).endsWith(" of 7")
    discard f.toggleWholeWord(d)
    ck f.countText(d).endsWith(" of 5")
    discard f.cancel(d)

  test "the marks of a window are the matches on its lines, current flagged":
    var d = docOf(bkCua)
    d.at(0, 0)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    let marks = f.marksInWindow(d, 2, 2)
    ck marks.len == 3
    ck marks[0] == FindMark(line: 2, fromColumn: 5, toColumn: 8, current: false)
    var currents = 0
    for m in f.marksInWindow(d, 1, 5):
      if m.current: inc currents
    ck currents == 1
    discard f.cancel(d)

suite "seeding (§4.1)":
  test "a one-line selection, else the word, else the last pattern":
    var d = docOf(bkCua)
    d.selectSpan(15, 22)                            # `foo_bar`... from `_`
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsSelectionOrWord, 1, 0)
    ck f.field == Source[15 ..< 22]
    ck f.fieldSelected
    discard f.cancel(d)
    d.at(2, 6)                                      # in `return`
    discard f.openFind(d, bkCua, "e", false, fsSelectionOrWord, 1, 0)
    ck f.field == "return"
    discard f.accept(d)
    d.selectSpan(0, 20)                             # two lines
    discard f.openFind(d, bkCua, "e", false, fsSelectionOrWord, 1, 0)
    ck f.field == "return"
    ck d.selected == (0, 20)                        # opening does not move
    discard f.cancel(d)

  test "a typed character replaces a selected seed":
    var d = docOf(bkCua)
    d.at(2, 6)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsSelectionOrWord, 1, 0)
    discard f.typeText(d, "F")
    ck f.field == "F"
    discard f.cancel(d)

suite "the launchers are their compositions (FS-6)":
  proc corpus(text: string): seq[int] =
    ## Caret offsets: every byte that starts a rune (word starts, middles,
    ## ends, between words, punctuation, the wide glyph's first byte).
    for i in 0 ..< text.len:
      if (ord(text[i]) and 0xC0) != 0x80: result.add i

  const Wide = "x 漢字 foo 漢字 bar, foo! 漢字\n"

  for (model, id) in [(bkVim, VimStarMacro), (bkVim, VimHashMacro),
                      (bkVim, VimGStarMacro), (bkVim, VimGHashMacro)]:
    test "Vim " & id & " equals its steps":
      var steps: seq[string]
      for m in VimMacros:
        if m.id == id: steps = m.steps
      ck steps.len == 6
      for text in [Source, Wide]:
        for caretAt in corpus(text):
          var row = docOf(model, text)
          row.selectSpan(caretAt, caretAt)
          var one = row
          discard row.applyNamed("replay-macro", OpArgs(id: id), 0)
          for s in steps: discard one.applyNamed(s, OpArgs(), 0)
          ck row.state.selection == one.state.selection
          ck row.state.search == one.state.search

  test "Vim `*` is whole word, `g*` is not, `#` goes back":
    var d = docOf(bkVim, "foo foobar x foo\nfoo\n")
    d.at(0, 1)
    discard d.applyNamed("replay-macro", OpArgs(id: VimStarMacro), 0)
    ck d.state.selection.mainRange.head == 13
    discard d.applyNamed("move-search-next", OpArgs(), 0)
    ck d.state.selection.mainRange.head == 17
    discard d.applyNamed("replay-macro", OpArgs(id: VimHashMacro), 0)
    ck d.state.selection.mainRange.head == 13
    d.at(0, 1)
    discard d.applyNamed("replay-macro", OpArgs(id: VimGStarMacro), 0)
    ck d.state.selection.mainRange.head == 4       # inside `foobar`

  test "CUA Ctrl+F3: the word whole-word, a selection literally":
    var d = docOf(bkCua, "foo foobar x foo\n")
    d.at(0, 1)
    ck nextSelectionMatch(d, false, 0).message == ""
    ck d.selected == (13, 16)
    ck d.state.search.options.wholeWord
    d.selectSpan(0, 3)
    discard nextSelectionMatch(d, false, 0)
    ck d.selected == (4, 7)                        # `foo` of `foobar`
    ck not d.state.search.options.wholeWord
    discard nextSelectionMatch(d, true, 0)
    ck d.selected == (0, 3)

  test "Kakoune `*` adds boundaries only to a word; `Alt+*` never":
    var d = docOf(bkKakoune, "foo foobar foo-\n")
    d.selectSpan(0, 3)
    discard d.applyNamed("search-selection-whole-word", OpArgs(), 0)
    ck d.state.search.options.wholeWord
    d.selectSpan(11, 15)                           # `foo-`
    discard d.applyNamed("search-selection-whole-word", OpArgs(), 0)
    ck not d.state.search.options.wholeWord
    d.selectSpan(0, 3)
    discard d.applyNamed("search-selection", OpArgs(), 0)
    ck not d.state.search.options.wholeWord

suite "Emacs isearch (§4.5)":
  test "smart case, C-w twice, C-g restores":
    var d = docOf(bkEmacs)
    d.at(1, 4)                                     # `foo_bar`
    let origin = d.state.selection
    var f: FindVM
    discard f.openFind(d, bkEmacs, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    ck not d.state.search.options.caseSensitive
    discard f.setQuery(d, "Foo")
    ck d.state.search.options.caseSensitive
    discard f.setQuery(d, "")
    discard f.yankWord(d)
    ck f.field == "foo_bar"
    discard f.yankWord(d)
    ck f.field == "foo_bar = foo"
    ck d.selected == (15, 28)
    discard f.cancel(d)
    ck d.state.selection == origin

  test "C-w pulls from the end of the current MATCH, not from the caret":
    # The caret moved away while the field is open (a press in the text,
    # Base-Keymaps §5.4: focus moving away does not pop the layer): the
    # next word still comes from the match's end.
    var d = docOf(bkEmacs)
    d.at(0, 0)
    var f: FindVM
    discard f.openFind(d, bkEmacs, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "def")
    ck d.selected == (0, 3)
    d.at(1, 4)
    discard f.yankWord(d)
    ck f.field == "def foo"
    discard f.cancel(d)

  test "M-s . opens on the symbol at the caret, its next occurrence current":
    var d = docOf(bkEmacs, "foo foobar foo\n")
    d.at(0, 1)
    var f: FindVM
    discard f.openSymbolAtCaret(d, bkEmacs, "e", 1, 0)
    ck f.field == "foo"
    ck d.state.search.options.wholeWord
    ck d.selected == (11, 14)
    discard f.accept(d)
    ck d.selected == (11, 14)

  test "an empty field's step reuses the last pattern (C-s C-s)":
    var d = docOf(bkEmacs)
    d.state.search.pattern = "return"
    var f: FindVM
    discard f.openFind(d, bkEmacs, "e", false, fsNone, 1, 0)
    discard f.step(d, true)
    ck f.field == "return"
    discard f.accept(d)

suite "Vim's prompt":
  test "`/foo Escape` restores, the previous pattern stays; `/` Enter reuses it":
    var d = docOf(bkVim)
    d.state.search.pattern = "return"
    d.at(0, 0)
    var f: FindVM
    discard f.openFind(d, bkVim, "e", false, fsNone, 1, 0)
    discard f.cancel(d)
    ck d.state.search.pattern == "return"
    discard f.openFind(d, bkVim, "e", false, fsNone, 1, 0)
    discard f.accept(d)
    ck d.state.selection.mainRange.head == Source.find("return")
    discard f.openFind(d, bkVim, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    ck d.state.selection.mainRange.isEmpty          # the caret, Vim's way
    discard f.accept(d)
    let walked = walkClosed(d, bkVim, next = true)
    ck walked.message == ""

suite "the rows, through the shipped router":
  proc findRouter(model: BaseKeymap): KeymapRouter =
    result = initKeymapRouter(model, Linux)
    discard result.pushLayer(FindTable, "editor:main.py", "FIND")

  proc facts(find: bool; edit = false): SessionFacts =
    SessionFacts(product: (if edit: pmEdit else: pmDebug), replayLoaded: true,
                 findWidgetVisible: find,
                 editor: EditorFacts(readOnly: not edit, mode: emInsert))

  proc opOf(res: EditingResolution): string =
    if res.kind != erOperation: return "<" & $res.kind & ">"
    if res.argument.len > 0: res.operation & "(" & res.argument & ")"
    else: res.operation

  test "CUA: Escape keeps (find.close), Enter walks, Ctrl+F3 launches":
    var r = findRouter(bkCua)
    ck r.route(facts(true), FindPath, nmNormal, "Esc", 0).opOf == "find.close"
    ck r.route(facts(true), FindPath, nmNormal, "Enter", 0).opOf == "find.next"
    var e = initKeymapRouter(bkCua, Linux)
    ck e.route(facts(false), EditorPath, nmNormal, "Ctrl+F3", 0).opOf ==
         "find.next-selection-match"
    ck e.route(facts(false), EditorPath, nmNormal, "Ctrl+Shift+F3", 0).opOf ==
         "find.previous-selection-match"

  test "Emacs: Enter accepts, C-g cancels, C-w pulls, M-s . launches":
    var r = findRouter(bkEmacs)
    ck r.route(facts(true), FindPath, nmNormal, "Enter", 0).opOf == "find.accept"
    ck r.route(facts(true), FindPath, nmNormal, "Ctrl+g", 0).opOf == "find.cancel"
    ck r.route(facts(true), FindPath, nmNormal, "Ctrl+w", 0).opOf ==
         "find.yank-word"
    var e = initKeymapRouter(bkEmacs, Linux)
    discard e.route(facts(false), EditorPath, nmNormal, "Alt+s", 0)
    ck e.route(facts(false), EditorPath, nmNormal, ".", 10).opOf ==
         "find.open-symbol-at-caret"
    # Outside the isearch layer C-w is still kill-region.
    var k = initKeymapRouter(bkEmacs, Linux)
    ck k.route(facts(false, edit = true), EditorPath, nmNormal, "Ctrl+w",
               0).opOf == "kill-region"

  test "Vim and Kakoune: Enter accepts and Escape cancels in the find layer":
    for model in [bkVim, bkKakoune]:
      var r = findRouter(model)
      ck r.route(facts(true), FindPath, nmSearch, "Enter", 0).opOf ==
           "find.accept"
      ck r.route(facts(true), FindPath, nmSearch, "Esc", 0).opOf ==
           "find.cancel"

  test "Vim's `*` / `#` / `g*` / `g#` are macro rows; `/` opens the session":
    let km = keymapOf(bkVim).keymap
    var stars: seq[string] = @[]
    var slash: seq[string] = @[]
    for b in km.bindings:
      if b.chords == @["*"] or b.chords == @["#"] or
         b.chords == @["g", "*"] or b.chords == @["g", "#"]:
        stars.add b.operation & ":" & b.args.id
      if b.chords == @["/"]: slash.add b.operation
    ck stars.len == 5
    for s in stars: ck s.startsWith("replay-macro:base:vim-")
    ck slash.len > 0
    for o in slash: ck o == "find.open"       # the shared rows of §4.2
    # The document opened under Vim carries the macro bodies.
    let d = docOf(bkVim)
    for m in VimMacros: ck d.state.macros[m.id] == m.steps

  test "Kakoune: `*` and `Alt+*`; `s` no longer sets the pattern":
    let km = keymapOf(bkKakoune).keymap
    var star, altStar, s: seq[string] = @[]
    for b in km.bindings:
      if b.chords == @["*"]: star.add b.operation
      if b.chords == @["Shift+Alt+8"]: altStar.add b.operation
      if b.chords == @["s"]: s.add b.operation
    ck star.len > 0 and star[0] == "search-selection-whole-word"
    ck altStar.len > 0 and altStar[0] == "search-selection"
    ck "search-selection" notin s             # `s` is §4.2's step-into only
    ck KakouneUncoveredKeys.len == 1 and KakouneUncoveredKeys[0].key == "s"

  test "every new operation is catalogued with its table":
    for (name, table) in [("find.accept", FindTable), ("find.cancel", FindTable),
                          ("find.yank-word", FindTable),
                          ("find.open-symbol-at-caret", GlobalTable)]:
      ck isCatalogued(name)
      ck tableOfOperation(name) == table

suite "PLAT-70 Part C: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
