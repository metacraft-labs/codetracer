## test_plat70_find_regex.nim — the in-document find's regular expressions and
## Find in Selection (Find-And-Incremental-Search.md OQ-F5, decided by the
## user on 2026-11-20: *"regex in the core"*), on the C and the JS backend
## (vm-unit and vm-unit-js).
##
## What is graded:
##
## * **the one matcher (FS-1) with `regex` on**: `matchesOf` / `nextMatchOf` /
##   `matchLengthAt` agree with VS Code's search — line by line unless the
##   expression can match a line break (`isMultilineSource`), an empty match
##   counted, whole word as a test on each match, case folded, offsets in
##   bytes; a pattern that does not compile matches nowhere and
##   `patternError` says why;
## * **the guard**: nim-regex is a Thompson NFA, so the classic exponential
##   patterns finish over 20 000-character lines with the right answer — the
##   assertion is the answer, not a time, because a backtracking engine would
##   not produce one at all (this suite would hang and the lane's timeout
##   fail it); the two shapes the engine documents as non-linear are refused
##   before anything is searched;
## * **the session**: `toggleRegex` (`Alt+R`) and `toggleInSelection`
##   (`Alt+L`) — VS Code's scope rule, the first match in the scope, the walk
##   wrapping inside it, the scope mapped through an edit and dropped when the
##   session closes, the regex toggle kept; seeds escaped while it is on;
## * **the rows**: `Alt+R` / `Alt+L` under CUA and `M-r` under Emacs resolve to
##   the two operations in the find layer, through the shipped router.
##
## ## No mocks
## The shipped editing core, find session, bases and router, over documents
## written as data. Nothing is stood in for.

import std/[strutils, unittest]

import ../../editing_core
import ../../viewmodels/find_vm
import ../../keymap/keymap_router
import ../../keymap/layer_stack
import ../../keymap/scope_path
import ../../keymap/operation_catalogue

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 115

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Linux = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                      keyProtocol: kpKitty)
  Source = "let a1 = 10\n" &          # 0 .. 11
           "let b22 = 200\n" &        # 12 .. 25
           "# a1 and a12\n" &         # 26 .. 38
           "café = a1 + b22\n"        # 39 ..

let
  Window = element(ekWindow, "window")
  Tab = element(ekTab, "tab:1")
  EditorPath = @[Window, Tab, pane("editor"),
                 element(ekEditor, "editor:main.py")]
  FindPath = EditorPath & @[element(ekOverlay, "find"),
                            element(ekInput, "find-query")]

proc docOf(model: BaseKeymap; text = Source): EditingDocument =
  initEditingDocument("main.py", text, model)

func rx(caseSensitive = true; wholeWord = false): MatchOptions =
  MatchOptions(caseSensitive: caseSensitive, wholeWord: wholeWord,
               regex: true)

proc texts(doc: string; spans: seq[MatchSpan]): seq[string] =
  for m in spans: result.add doc[m.a ..< m.b]

proc selected(d: EditingDocument): string =
  let m = d.state.selection.mainRange
  d.state.doc[m.rangeFrom ..< m.rangeTo]

# ---------------------------------------------------------------------------

suite "regular expressions in the one matcher (FS-1)":
  test "a class, a group, an alternation — and the literal still literal":
    ck texts(Source, matchesOf(Source, "[0-9]+", rx())) ==
         @["1", "10", "22", "200", "1", "12", "1", "22"]
    # Leftmost-first, as VS Code's (JavaScript's) alternation.
    ck texts(Source, matchesOf(Source, "a(1|12)", rx())) ==
         @["a1", "a1", "a1", "a1"]
    ck texts(Source, matchesOf(Source, "a(12|1)", rx())) ==
         @["a1", "a1", "a12", "a1"]
    # Without `regex` the same text is a literal and finds nothing.
    ck matchesOf(Source, "[0-9]+", MatchOptions(caseSensitive: true)).len == 0
    ck matchesOf("x.y xzy", ".", MatchOptions(caseSensitive: true)).len == 1
    ck matchesOf("x.y xzy", ".", rx()).len == 7

  test "anchors are line anchors; the search is line by line":
    ck texts(Source, matchesOf(Source, "^let", rx())) == @["let", "let"]
    ck texts(Source, matchesOf(Source, "[0-9]+$", rx())) == @["10", "200", "12", "22"]
    # `.` never crosses a line break, as in JavaScript.
    ck matchesOf(Source, "10.let", rx()).len == 0
    ck not isMultilineSource("10.let")

  test "an expression that can match a line break runs over the whole text":
    ck isMultilineSource("10\\nlet")
    ck isMultilineSource("a\\Wb")
    ck isMultilineSource("x\ny")
    let m = matchesOf(Source, "10\\nlet", rx())
    ck m == @[MatchSpan(a: 9, b: 15)]
    # Multi-line, `^` and `$` still mark line ends.
    ck texts(Source, matchesOf(Source, "\\d$\\n^#", rx())) == @["0\n#"]

  test "case folds; whole word tests each match; offsets are bytes":
    ck matchesOf(Source, "LET", rx(caseSensitive = false)).len == 2
    ck matchesOf(Source, "LET", rx()).len == 0
    ck texts(Source, matchesOf(Source, "a1\\d*", rx(wholeWord = true))) ==
         @["a1", "a1", "a12", "a1"]
    ck texts(Source, matchesOf(Source, "a1", rx(wholeWord = true))) ==
         @["a1", "a1", "a1"]
    # `café` is five bytes; the match after it starts at a byte offset.
    let caf = matchesOf(Source, "caf.", rx())
    ck caf.len == 1 and Source[caf[0].a ..< caf[0].b] == "café"
    ck caf[0].b - caf[0].a == 5
    ck matchesOf("ΣΙΣ σισ", "σ.σ", rx(caseSensitive = false)).len == 2

  test "an empty match counts, and the walk steps past it":
    # Five: the empty line after the final line break is a line, as in VS
    # Code's model.
    let caret = matchesOf(Source, "^", rx())
    ck caret.len == 5
    ck caret[1] == MatchSpan(a: 12, b: 12)
    let w = nextMatchOf(Source, "^", rx(), 1, forward = true)
    ck w.found and w.span == MatchSpan(a: 12, b: 12)
    ck matchLengthAt(Source, "^", rx(), 12) == 0
    ck matchLengthAt(Source, "b2+", rx(), 16) == 3
    ck matchLengthAt(Source, "b2+", rx(), 17) == -1

  test "the walk forward and back, wrapping, agrees with matchesOf":
    let all = matchesOf(Source, "a1\\d?", rx())
    var at = 0
    var seen: seq[MatchSpan] = @[]
    for i in 0 ..< all.len:
      let w = nextMatchOf(Source, "a1\\d?", rx(), at, forward = true)
      ck w.found and not w.wrapped
      seen.add w.span
      at = w.span.a + 1
    ck seen == all
    let wrap = nextMatchOf(Source, "a1\\d?", rx(), at, forward = true)
    ck wrap.wrapped and wrap.span == all[0]
    let back = nextMatchOf(Source, "a1\\d?", rx(), all[0].a, forward = false)
    ck back.wrapped and back.span == all[^1]
    let prev = nextMatchOf(Source, "a1\\d?", rx(), all[2].a, forward = false)
    ck prev.found and prev.span == all[1]

  test "a pattern that does not compile matches nowhere and says why":
    ck patternError("a(b", rx()).startsWith("invalid regular expression")
    ck matchesOf(Source, "a(b", rx()).len == 0
    ck not nextMatchOf(Source, "a(b", rx(), 0, forward = true).found
    ck patternError("a(b", MatchOptions()) == ""      # a literal is never refused
    ck matchesOf("a(b", "a(b", MatchOptions(caseSensitive: true)).len == 1
    ck patternError("", rx()) == ""

  test "invalid UTF-8 in the document is searched, not undefined":
    let bytes = "ok \xff\xfe ok"
    ck matchesOf(bytes, "ok", rx()).len == 2

suite "the guard against catastrophic patterns":
  # THE ASSERTION IS THE ANSWER. Each of these takes a backtracking engine
  # time exponential in the line's length — 2^20000 steps — so a run that
  # returns at all, with the right count, is the evidence that the engine
  # does not backtrack. Nothing here reads a clock.
  test "the classic exponential patterns finish, linearly, with the answer":
    let line = repeat('a', 20_000)
    ck matchesOf(line, "(a+)+b", rx()).len == 0
    ck matchesOf(line, "(a|aa)*c", rx()).len == 0
    ck matchesOf(line, "(a*)*b", rx()).len == 0
    ck matchesOf(line, "(x+x+)+y", rx()).len == 0
    ck matchesOf(line & "b", "(a+)+b", rx()).len == 1
    ck matchesOf(repeat("ab", 10_000), "(.*a){12}", rx()).len == 1
    # And as a whole document of many such lines, searched line by line.
    var doc = ""
    for i in 0 ..< 50: doc.add repeat('a', 2_000) & "\n"
    ck matchesOf(doc, "(a+)+b", rx()).len == 0
    ck matchesOf(doc, "^(a|a)+$", rx()).len == 50

  test "a look-around around a repetition is refused before it runs":
    ck lookaroundRepeats("(?<=a+)b")
    ck lookaroundRepeats("x(?=.*y)")
    ck lookaroundRepeats("(?!a{2,})")
    ck not lookaroundRepeats("(?<=ab)c")
    ck not lookaroundRepeats("a+(?=b)")
    ck not lookaroundRepeats("(?=[*+])")       # inside a class, not a repetition
    ck not lookaroundRepeats("(?=\\*)")        # escaped
    ck patternError("(?<=a+)b", rx()).contains("polynomial")
    ck matchesOf(repeat('a', 5_000) & "b", "(?<=a+)b", rx()).len == 0
    # A bounded look-around is searched.
    ck texts("xab yb", matchesOf("xab yb", "(?<=a)b", rx())) == @["b"]

  test "a counted repetition that expands past the limit is refused":
    ck expandedSize("abc") == 3
    ck expandedSize("(ab){3}") == 7
    ck expandedSize("(a{1000}){1000}") > RegexSizeLimit
    ck patternError("(a{1000}){1000}", rx()).contains("expand")
    ck matchesOf("aaaa", "(a{1000}){1000}", rx()).len == 0
    ck patternError("a{100}", rx()) == ""
    ck matchesOf(repeat('a', 250), "a{100}", rx()).len == 2

suite "the session: Alt+R":
  test "toggling reads the field as an expression, and back":
    var d = docOf(bkCua)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "b2+")
    ck f.matches.len == 0
    ck f.countText(d) == NoMatchesText
    discard f.toggleRegex(d)
    ck d.state.search.options.regex
    ck texts(Source, f.matches) == @["b22", "b22"]
    ck f.countText(d) == "1 of 2"
    ck selected(d) == "b22"
    discard f.toggleRegex(d)
    ck f.matches.len == 0

  test "an invalid expression's count says why; the toggle outlives the session":
    var d = docOf(bkCua)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.toggleRegex(d)
    discard f.setQuery(d, "a(")
    ck f.countText(d).startsWith("invalid regular expression")
    discard f.setQuery(d, "a\\d+")
    discard f.accept(d)
    ck d.state.search.options.regex                 # kept, as VS Code's isRegex
    ck d.state.search.pattern == "a\\d+"
    var g: FindVM
    discard g.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    ck d.state.search.options.regex
    discard g.setQuery(d, "a1\\d")
    ck texts(Source, g.matches) == @["a12"]
    discard g.cancel(d)

  test "the closed walk (F3 / n) walks the expression":
    var d = docOf(bkCua)
    d.state.search.pattern = "\\d{3}"
    d.state.search.options = rx()
    d.moveCaretTo(0, 0)
    let w = walkClosed(d, bkCua, next = true)
    ck w.message == ""
    ck selected(d) == "200"

  test "a seed from the text is escaped while the toggle is on":
    var d = docOf(bkCua, "x = a.b + a.b\n")
    d.state.search.options = rx(caseSensitive = false)
    d.selectSpan(4, 7)                          # `a.b`
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsSelectionOrWord, 1, 0)
    ck f.field == "a\\.b"
    ck f.matches.len == 2
    discard f.cancel(d)
    # `search-selection` (Vim's `g*`, Kakoune's `Alt+*`) escapes it too.
    d.selectSpan(4, 7)
    discard d.applyNamed("search-selection", OpArgs(), 0)
    ck d.state.search.pattern == "a\\.b"
    ck matchesOf(d.state.doc, d.state.search.pattern,
                 d.state.search.options).len == 2
    ck literalPattern("a.b", MatchOptions()) == "a.b"

suite "the session: Alt+L, Find in Selection":
  test "the scope is the selection; matches outside it are gone":
    var d = docOf(bkCua)
    # Lines 2 and 3, the selection ending at the start of line 4 (VS Code
    # ends such a scope at line 3's end).
    d.selectSpan(12, 39)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.toggleInSelection(d)
    ck f.hasScope
    ck f.scope == @[MatchSpan(a: 12, b: 38)]
    discard f.setQuery(d, "a1")
    ck f.matches == @[MatchSpan(a: 28, b: 30), MatchSpan(a: 35, b: 37)]
    ck f.countText(d) == "1 of 2"
    ck f.current == MatchSpan(a: 28, b: 30)
    # The walk wraps inside the scope.
    discard f.step(d, next = true)
    ck f.current == MatchSpan(a: 35, b: 37)
    discard f.step(d, next = true)
    ck f.current == MatchSpan(a: 28, b: 30) and f.wrapped
    discard f.step(d, next = false)
    ck f.current == MatchSpan(a: 35, b: 37)
    # Off: the whole document again.
    discard f.toggleInSelection(d)
    ck not f.hasScope
    ck f.matches.len == 4

  test "with nothing selected it stays off":
    var d = docOf(bkCua)
    d.moveCaretTo(1, 2)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.toggleInSelection(d)
    ck not f.hasScope

  test "every range of a multi-range selection is scope; each is its own text":
    var d = docOf(bkCua)
    d.state.selection = editorSelection(@[spanRange(0, 11), spanRange(39, 55)], 0)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.toggleRegex(d)
    discard f.toggleInSelection(d)
    ck f.scope.len == 2
    discard f.setQuery(d, "^\\S+")
    # `^` holds at each range's start, as VS Code searches its scope.
    ck texts(Source, f.matches) == @["let", "café"]

  test "the scope follows an edit, and the session's close drops it":
    var d = docOf(bkCua)
    d.selectSpan(26, 38)                         # line 3
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.toggleInSelection(d)
    discard f.setQuery(d, "a1")
    ck f.matches.len == 2
    # An edit before the scope moves it; the scope's matches move with it.
    d.selectSpan(0, 0)
    discard d.applyNamed("insert-text", OpArgs(text: "## "), 0)
    discard f.setQuery(d, "a1")
    ck f.scope == @[MatchSpan(a: 29, b: 41)]
    ck f.matches == @[MatchSpan(a: 31, b: 33), MatchSpan(a: 38, b: 40)]
    discard f.accept(d)
    ck f == FindVM()
    var g: FindVM
    discard g.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    ck not g.hasScope

  test "the highlights in a window honour the scope":
    var d = docOf(bkCua)
    d.selectSpan(26, 38)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.toggleInSelection(d)
    discard f.setQuery(d, "a1")
    let marks = f.marksInWindow(d, 1, 10)
    ck marks.len == 2
    for m in marks: ck m.line == 3

suite "the rows, through the shipped router":
  proc findRouter(model: BaseKeymap): KeymapRouter =
    result = initKeymapRouter(model, Linux)
    discard result.pushLayer(FindTable, "editor:main.py", "FIND")

  proc facts(): SessionFacts =
    SessionFacts(product: pmDebug, replayLoaded: true, findWidgetVisible: true,
                 editor: EditorFacts(readOnly: true, mode: emInsert))

  proc opOf(res: EditingResolution): string =
    if res.kind != erOperation: "<" & $res.kind & ">" else: res.operation

  test "CUA: Alt+R and Alt+L; Emacs: M-r":
    var c = findRouter(bkCua)
    ck c.route(facts(), FindPath, nmNormal, "Alt+r", 0).opOf == "find.toggle-regex"
    var c2 = findRouter(bkCua)
    ck c2.route(facts(), FindPath, nmNormal, "Alt+l", 0).opOf ==
         "find.toggle-in-selection"
    var e = findRouter(bkEmacs)
    ck e.route(facts(), FindPath, nmNormal, "Alt+r", 0).opOf == "find.toggle-regex"
    for name in ["find.toggle-regex", "find.toggle-in-selection"]:
      ck isCatalogued(name)
      ck tableOfOperation(name) == FindTable

suite "OQ-F5: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
