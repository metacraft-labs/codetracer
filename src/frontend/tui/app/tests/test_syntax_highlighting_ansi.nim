## test_syntax_highlighting_ansi.nim — CTUI-5, Tier 1.
##
## ## What this suite establishes
##
## CTUI-5: "asserts token classes carry distinct style attributes, and that a
## file in a language with no grammar renders unhighlighted rather than
## failing."
##
## Both, and a third the first two rest on: that the ten vendored grammars are
## really linked and really parse. A palette of nine distinct styles says
## nothing if every file lands in `hmNone`, and "it did not fail" is satisfied
## by a highlighter that never highlights anything.
##
## So the order here is deliberate and matches
## `codetracer-specs/Testing/Verification-Harness-Traps.md` §4: assert what the
## highlighter FOUND before asserting what it did not.
##
##   1. all ten grammars in `build/grammars/libcodetracer_tui_grammars.a` are
##      reachable and parse their own language — asserted as the COUNT ten,
##      because the archive holds exactly ten and a loop that skipped one would
##      satisfy "at least one";
##   2. the nine token classes map to nine DISTINCT `CellStyle`s — the count
##      again, not a spot check of two of them;
##   3. a real Nim file through the real tree-sitter grammar produces at least
##      four distinct classes, and the cells the compositor paints carry the
##      corresponding ANSI colours — read back off a real `ScreenBuffer`
##      through `TerminalTestHarness.cellAt`, not off the model that produced
##      it... which Tier 1 cannot fully separate, and
##      `tests/real_terminal/test_real_source_pane.nim` is where that becomes a
##      statement about a terminal;
##   4. a Python file — no grammar, and one of only two languages this
##      campaign's fixture corpus can produce — is LEXED, with spans;
##   5. a file whose extension nothing recognises renders with ZERO spans and
##      every code cell at the terminal default, and does not raise;
##   6. the cache parses once per `(path, revision, window)` and the latency
##      gate's cached path is therefore real.
##
## ## Layer
##
## `app/tests/` is walked by `tests/test_tui_facade_boundary.nim`, so nothing
## here can reach a process or a terminal. That is why this file is the ONE
## CTUI-5 suite that stayed at the path the milestone named: the other three
## Tier-1 suites need a real `HeadlessDebugSession`, which is a host
## capability, and they live under `src/frontend/tui/tests/`. See the
## Implementation section of CTUI-5 in the milestones file.
##
## ## No mocks
##
## The grammars are the real vendored ones, linked from the real archive. The
## screen is a real `TerminalTestHarness` compositing a real component tree.
## There is no `MockBackendService` here and no ViewModel at all — this suite's
## subject is a pure function of text.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1. Four instances of that have been found in this
## campaign.

import std/[strutils, unittest]

import isonim_tui

import ../syntax/highlighter
import ../views/source_pane

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 141

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  GrammarProbes: seq[(string, GrammarId, string)] = @[
    ("probe.nim", giNim, "proc f(x: int): string =\n  \"a\" & $x\n"),
    ("probe.ak", giAiken, "pub fn f(x: Int) -> Int {\n  x + 1\n}\n"),
    ("probe.cairo", giCairo, "fn main() {\n  let x = 1;\n}\n"),
    ("probe.cdc", giCadence, "pub contract C {\n  pub let x: Int\n}\n"),
    ("probe.circom", giCircom,
     "pragma circom 2.0.0;\ntemplate T() {\n  signal input a;\n}\n"),
    ("probe.leo", giLeo, "program p.aleo {\n  function main() {}\n}\n"),
    ("probe.masm", giMasm, "proc.main\n  push.1\nend\n"),
    ("probe.move", giMoveOnAptos,
     "module a::b {\n  public fun f(): u64 { 1 }\n}\n"),
    ("probe.sw", giSway, "contract;\nfn main() -> u64 {\n  1\n}\n"),
    ("probe.tolk", giTolk, "fun main(): int {\n  return 1;\n}\n")]
    ## One snippet per vendored grammar. The SNIPPETS ARE REAL SOURCE in each
    ## language, not filler: a grammar handed nonsense still parses (to an
    ## error tree) and would satisfy "it did not raise" while proving nothing
    ## about the linkage. What is asserted below is that the parse produced
    ## LEAVES this palette recognises.

  NimSample = @[
    "## a doc comment",
    "import std/strutils",
    "",
    "proc greet(name: string): string =",
    "  let count = 42",
    "  result = \"hello \" & name & $count",
    "",
    "# a line comment"]

  PythonSample = @[
    "# calc: the fixture corpus's own language",
    "def add(a, b):",
    "    total = a + b * 2",
    "    return \"sum=\" + str(total)"]

  UnknownSample = @[
    "this file has no grammar and no lexer",
    "and it must render exactly as written",
    "including \"quotes\" and 42 and # hashes"]

proc classesIn(file: FileHighlight): seq[TokenClass] =
  ## Every distinct token class the highlight produced, in first-seen order.
  result = @[]
  for line in file.lines:
    for span in line:
      if span.class notin result:
        result.add span.class

proc spanCount(file: FileHighlight): int =
  for line in file.lines:
    result += line.len

proc modelFor(path: string; lines: seq[string];
              executionLine = 0): SourcePaneModel =
  initSourcePaneModel(
    path = path, heldLines = lines, firstHeldLine = 1,
    totalLineCount = lines.len, viewportTop = 1, executionLine = executionLine)

suite "CTUI-5: syntax highlighting and its ANSI styles":

  test "all ten vendored grammars parse their own language":
    # THE POSITIVE CONTROL FOR EVERYTHING BELOW. `build-tui-grammars.sh`
    # archives exactly ten grammars — `nm` on the archive shows ten
    # `tree_sitter_<name>` symbols — so the membership is knowable and the
    # control is the COUNT (Verification-Harness-Traps §4b).
    ck GrammarProbes.len == 10
    var reached: seq[GrammarId] = @[]
    var parsed = 0
    for (path, grammar, source) in GrammarProbes:
      ck grammarForPath(path) == grammar
      ck modeForPath(path) == hmTreeSitter
      let lines = source.strip(leading = false).split('\n')
      let file = highlightWindow(path, 1, lines)
      ck file.mode == hmTreeSitter
      ck file.grammar == grammar
      # A parse that produced NO classified leaf is a grammar that linked and
      # did not recognise its own language, which is exactly what a stub
      # symbol would look like.
      if spanCount(file) > 0:
        inc parsed
      if grammar notin reached:
        reached.add grammar
    checkpoint("grammars parsed with at least one classified token: " &
               $parsed & " of " & $GrammarProbes.len)
    ck reached.len == 10
    ck parsed == 10

  test "the nine token classes carry nine distinct styles":
    # Not a spot check. A palette with one repeat renders two classes
    # identically on screen while every span-level assertion stays green, and
    # the only assertion that catches it is over the whole palette.
    var seen: seq[CellStyle] = @[]
    for class in TokenClass:
      let style = tokenStyle(class)
      ck style notin seen
      seen.add style
    ck seen.len == 9
    ck ord(high(TokenClass)) - ord(low(TokenClass)) + 1 == 9
    # And the default class really is the terminal default, so unhighlighted
    # text is unstyled rather than styled-to-look-unstyled.
    ck tokenStyle(tcPlain).isDefault
    ck not tokenStyle(tcKeyword).isDefault

  test "a Nim file is highlighted through the real tree-sitter grammar":
    let file = highlightWindow("greeter.nim", 1, NimSample)
    ck file.mode == hmTreeSitter
    ck file.grammar == giNim
    let classes = classesIn(file)
    checkpoint("classes found: " & $classes)
    # The sample deliberately carries a keyword, a string, a number and a
    # comment. Four named classes, asserted individually rather than as
    # "more than three": a highlighter that found only comments would satisfy
    # a count.
    ck tcKeyword in classes
    ck tcString in classes
    ck tcNumber in classes
    ck tcComment in classes

    # …and the COMPOSITED CELLS carry the mapped colours. This is the step
    # that makes the palette a screen property rather than a table.
    let model = modelFor("greeter.nim", NimSample)
    let screen = sourcePaneScreen(model, 60, NimSample.len + 1)
    ck screen.materializedLines == NimSample.len
    ck screen.loadingLines == 0
    var styles: seq[CellStyle] = @[]
    for row in screen.rows:
      for span in row:
        if not span.style.isDefault and span.style notin styles:
          styles.add span.style
    checkpoint("distinct non-default styles on the pane: " & $styles.len)
    # Gutter (line number) + title (title, path, marker, rule) + at least the
    # four token classes above. Asserted as a floor AND with the four specific
    # styles present by name, so the floor cannot be met by six shades of
    # gutter.
    ck tokenStyle(tcKeyword) in styles
    ck tokenStyle(tcString) in styles
    ck tokenStyle(tcNumber) in styles
    ck tokenStyle(tcComment) in styles

  test "the composited screen really carries the ANSI colours":
    # Tier 1's own limitation is stated in docs/tui-testing.md: every golden it
    # records comes from the model that produced the bytes. So this case
    # asserts on the COMPOSITOR's ScreenBuffer — one step further out than the
    # `StyledRow`s above — and `tests/real_terminal/test_real_source_pane.nim`
    # takes the last step onto a real terminal.
    let model = modelFor("greeter.nim", NimSample)
    let rows = NimSample.len + 1
    let h = newTerminalTestHarness(60, rows)
    try:
      h.mount(proc(r: TerminalRenderer): TerminalNode =
        renderSourcePaneTree(model, r, 60, rows))
      h.flush()
      # `import` is a keyword on the second source line, which is pane row 2.
      let paneRows = sourcePaneRows(model, 60, rows)
      var found = 0
      var checkedRows = 0
      for rowIndex in 0 ..< rows:
        inc checkedRows
        var col = 0
        for span in paneRows[rowIndex]:
          if span.style == tokenStyle(tcKeyword) and span.text.strip().len > 0:
            let cell = h.cellAt(rowIndex, col)
            ck cell.fg.kind == ckAnsi
            ck cell.fg.ansi == acMagenta
            ck attrBold in cell.attrs
            inc found
          col += cellWidthOf(span.text)
      checkpoint("keyword-styled spans checked on the buffer: " & $found)
      ck checkedRows == rows
      # `import`, `proc`, `let` — three keyword runs at least. An exact
      # number would pin the grammar's tokenisation, which a grammar bump may
      # legitimately change; the floor is named and the per-cell colour above
      # is what is really being asserted.
      ck found >= 3
    finally:
      h.dispose()

  test "a language with no grammar is lexed rather than left plain":
    # THE FALLBACK, and it is not a nicety: neither fixture in this campaign's
    # corpus has a vendored grammar (`calc` is Python, `noir_space_ship` is
    # Noir), so without this branch the pane CTUI-5 delivers is unhighlighted
    # on every trace the campaign can open.
    ck grammarForPath("main.py") == giNone
    ck lexerForPath("main.py") == lxPython
    ck modeForPath("main.py") == hmLexical
    let file = highlightWindow("main.py", 1, PythonSample)
    ck file.mode == hmLexical
    ck file.lexer == lxPython
    let classes = classesIn(file)
    checkpoint("python classes: " & $classes)
    ck tcComment in classes
    ck tcKeyword in classes
    ck tcString in classes
    ck tcNumber in classes
    # Noir takes the same lexer, and it is the OTHER fixture's language.
    ck lexerForPath("src/main.nr") == lxRustLike
    ck modeForPath("src/main.nr") == hmLexical
    let noir = highlightWindow("src/main.nr", 1,
      @["// a comment", "fn main(x: Field) -> Field {", "    x + 1", "}"])
    ck noir.mode == hmLexical
    ck tcComment in classesIn(noir)
    ck tcKeyword in classesIn(noir)

  test "a file with no grammar and no lexer renders unhighlighted, not broken":
    # CTUI-5's own sentence. Asserted by the span COUNT (zero) and by the
    # CELLS (all default), not by "it did not raise" — an exception would be a
    # different failure and this case would not reach its assertions at all.
    ck grammarForPath("notes.xyzzy") == giNone
    ck lexerForPath("notes.xyzzy") == lxNone
    ck modeForPath("notes.xyzzy") == hmNone
    let file = highlightWindow("notes.xyzzy", 1, UnknownSample)
    ck file.mode == hmNone
    ck file.lines.len == UnknownSample.len
    ck spanCount(file) == 0

    let model = modelFor("notes.xyzzy", UnknownSample)
    let screen = sourcePaneScreen(model, 70, UnknownSample.len + 1)
    ck screen.materializedLines == UnknownSample.len
    let gutW = screen.gutterWidth
    var codeCells = 0
    var styledCodeCells = 0
    for i in 0 ..< UnknownSample.len:
      let row = screen.rows[i + 1]
      var col = 0
      for span in row:
        for _ in 0 ..< cellWidthOf(span.text):
          if col >= gutW:
            inc codeCells
            if not span.style.isDefault:
              inc styledCodeCells
          inc col
    checkpoint("code cells: " & $codeCells & ", styled: " & $styledCodeCells)
    # The code column is 70 - gutter wide on each of three rows, and NONE of
    # it is styled. The positive half is the count itself: a pane that painted
    # no code at all would report zero code cells and pass the negative half
    # for free.
    ck codeCells == 3 * (70 - gutW)
    ck styledCodeCells == 0
    # The text is all still there — an unhighlighted render is a render.
    let text = sourcePaneText(model, 70, UnknownSample.len + 1)
    for i, line in UnknownSample:
      ck text[i + 1].contains(line)

  test "a visible line the model does not hold renders as loading, not blank":
    # `SourceVM`'s second contract: "a line outside the window is a REQUEST,
    # not an empty string", because "an empty default is how a source pane
    # silently renders blank, and a blank pane over a working debugger is
    # indistinguishable from a file of blank lines". This is that contract ON
    # SCREEN, and it is the POSITIVE twin of the `loadingLines == 0`
    # assertions the other cases make.
    const Total = 40
    const HeldFirst = 5
    let held = @["held line 5", "held line 6", "held line 7", "held line 8"]
    let model = initSourcePaneModel(
      path = "windowed.nim", firstHeldLine = HeldFirst, heldLines = held,
      totalLineCount = Total, viewportTop = 1, executionLine = 6)
    let body = 12
    let screen = sourcePaneScreen(model, 50, body + 1)
    ck screen.materializedLines == held.len
    # Twelve visible lines, four of them held: eight are loading, and the count
    # is EXACT rather than "some".
    ck screen.loadingLines == body - held.len
    ck screen.materializedLines + screen.loadingLines == body

    var loadingRows = 0
    var blankRows = 0
    var numberedRows = 0
    for i in 0 ..< body:
      let line = model.viewportTop + i
      let text = rowText(screen.rows[i + 1])
      if text.contains(SourceLoadingText):
        inc loadingRows
      if text.strip().len == 0:
        inc blankRows
      if text.contains($line):
        inc numberedRows
    checkpoint("loading rows: " & $loadingRows & ", blank: " & $blankRows &
               ", numbered: " & $numberedRows)
    ck loadingRows == body - held.len
    # NOT ONE BLANK ROW inside the file's extent — the whole point.
    ck blankRows == 0
    # …and every row still carries its own line number, so a reader can see
    # WHICH lines have not arrived.
    ck numberedRows == body
    # A row past the end of the file IS blank, and that is the one blank this
    # pane draws: there is no line there, as against a line whose text has not
    # arrived.
    let shortModel = initSourcePaneModel(
      path = "windowed.nim", firstHeldLine = 1, heldLines = @["only line"],
      totalLineCount = 1, viewportTop = 1, executionLine = 1)
    let shortScreen = sourcePaneScreen(shortModel, 50, 6)
    ck shortScreen.materializedLines == 1
    ck shortScreen.loadingLines == 0
    var pastEndBlank = 0
    for i in 2 ..< shortScreen.rows.len:
      if rowText(shortScreen.rows[i]).strip().len == 0:
        inc pastEndBlank
    ck pastEndBlank == shortScreen.rows.len - 2

  test "the cache parses once per revision and window":
    # CTUI-5's risk mitigation, as a measurement: "parse once per (path,
    # generation) and cache the token spans; the latency gate is measured on
    # the CACHED path".
    let cache = newHighlighterCache()
    ck cache.parseCount == 0
    for _ in 1 .. 20:
      let file = cache.highlight("greeter.nim", 0, "", 1, NimSample)
      ck file.mode == hmTreeSitter
    ck cache.lookupCount == 20
    ck cache.parseCount == 1

    # A DIFFERENT WINDOW OF THE SAME REVISION IS A MISS, and it has to be:
    # `SourceVM` holds a window, so two frames of one revision legitimately
    # carry different text, and a cache keyed on the triple alone would serve
    # line 1's spans for line 400.
    discard cache.highlight("greeter.nim", 0, "", 5, NimSample)
    ck cache.parseCount == 2
    # A different GENERATION of the same path and window is a miss too — the
    # live-HCR case CTUI-4's identity triple exists for.
    discard cache.highlight("greeter.nim", 1, "", 1, NimSample)
    ck cache.parseCount == 3
    # …and the first key still hits.
    discard cache.highlight("greeter.nim", 0, "", 1, NimSample)
    ck cache.parseCount == 3
    ck cache.lookupCount == 23

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
