## test_plat70c_find.nim — PLAT-70 Part C (Find-And-Incremental-Search.md
## §2 – §4) in the terminal's own modules, in process:
##
##   * FS-1, THE SOURCE GATE, with its planted controls: no module of the
##     editor's surfaces — the terminal's `app/`, GPUI, the shared editor
##     vocabulary and views, the editing core, the find session — computes
##     where a query occurs in text itself; `matchesOf` is defined exactly
##     once. The planted lines are the two matchers Part C deleted (the
##     terminal's `runFind` one-shot and `app/views/search.nim`'s line
##     matcher), so the gate is graded against the very code it replaced;
##   * `app/views/search.nim` is `matchesOf`'s caller: its matches are the
##     shared matcher's spans, in cells;
##   * the PAINTERS: the Debug-mode source pane and the Edit pane draw every
##     find mark on the find ground and the current one on its own, over
##     the selection, from the view's left column (Horizontal-Overflow §4)
##     and cut to the code area — the cells read back off the grid.
##
## No mocks: the shipped matcher, painters and session over text written as
## data; the gate reads the shipped sources.

import std/[os, strutils, unittest]

import codetracer_embed

import ../app/views/styled_row
import ../app/views/source_pane
import ../app/views/edit_pane
import ../app/views/search
import ../app/theme/roles

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 32

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

const QueryNames = ["needle", "query", "pattern", "search"]

const NotDocumentSearch = [
  ## A proc that matches a `pattern` that is not a query over text the user
  ## is reading — the gate's heuristic cannot tell it from one, so it is
  ## named here with the reason, and only lines inside that proc are spared.
  ## The gate also requires each named proc to still exist, so an entry
  ## cannot outlive the code it describes.
  ("src/frontend/tui/app/theme/terminal_profile.nim", "globMatch",
   "a `[terminal \"<glob>\"]` settings section against the terminal's " &
   "identity (`kitty*`, `tmux>*`), never a find over a document")]

proc exemptLines(rel: string; lines: openArray[string]): (bool, seq[int]) =
  ## The lines of `rel` inside a `NotDocumentSearch` proc (its header to the
  ## next top-level line), and whether every proc named for `rel` was found.
  var all = true
  var spared: seq[int] = @[]
  for (file, procName, _) in NotDocumentSearch:
    if file != rel: continue
    var start = -1
    for i, l in lines:
      if l.startsWith("proc " & procName & "*(") or
          l.startsWith("proc " & procName & "("):
        start = i
        break
    if start < 0:
      all = false
      continue
    var i = start
    while i < lines.len:
      if i > start and lines[i].len > 0 and lines[i][0] notin {' ', '#'}:
        break
      spared.add i
      inc i
  (all, spared)

proc isQueryName(arg: string): bool =
  ## `arg` (an argument, trimmed) is a query-shaped identifier: it starts
  ## with one of `QueryNames` and the identifier goes on at most in letters.
  let a = arg.strip
  for n in QueryNames:
    if a.startsWith(n):
      var i = n.len
      while i < a.len and a[i] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
        inc i
      if i == a.len or a[i] notin {'(', '[', '.'}:
        return true
  false

proc secondMatchers(lines: openArray[string]): seq[string] =
  ## A line that SEARCHES TEXT FOR A QUERY by hand: `find` / `rfind` /
  ## `continuesWith` / `count` handed a query-shaped needle (`query`,
  ## `pattern`, `needle`, `search…`) as its first or second argument, or a
  ## query folded for a comparison (`query.toLowerAscii`).
  for raw in lines:
    var code = raw
    let comment = code.find('#')
    if comment >= 0: code = code[0 ..< comment]
    if code.strip.len == 0: continue
    var hit = false
    for callee in ["find(", "rfind(", "continuesWith(", "count("]:
      var at = code.find(callee)
      while at >= 0 and not hit:
        let before = if at > 0: code[at - 1] else: ' '
        if before notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
          let open = at + callee.len
          var close = code.find(')', open)
          if close < 0: close = code.len
          let args = code[open ..< close].split(',')
          if args.len > 0 and isQueryName(args[0]): hit = true
          if args.len > 1 and isQueryName(args[1]): hit = true
        at = code.find(callee, at + 1)
    for n in QueryNames:
      let fold = code.find(".toLowerAscii")
      if fold > 0:
        var s = fold - 1
        while s >= 0 and code[s] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
          dec s
        if isQueryName(code[s + 1 ..< fold]): hit = true
    if hit: result.add raw

suite "PLAT-70 Part C: one matcher (FS-1)":

  test "the gate's planted controls: the two matchers Part C deleted":
    # The terminal's `runFind` one-shot (runtime.nim before Part C).
    ck secondMatchers(["    at = text.find(query, min(sel.rangeTo, text.len))"]).len == 1
    ck secondMatchers(["      if text.continuesWith(query, i):"]).len == 1
    # `app/views/search.nim`'s own line matcher.
    ck secondMatchers(["    let found = haystack.find(needle, byteAt)"]).len == 1
    ck secondMatchers(["  let needle = if caseSensitive: query else: query.toLowerAscii"]).len == 1
    # The editor core's literal `findFrom` before Part C.
    ck secondMatchers(["    let i = doc.find(pattern, start)"]).len == 1
    # A call of the one matcher is not a second one.
    ck secondMatchers(["  for m in matchesOf(line, query, MatchOptions())"]).len == 0
    ck secondMatchers(["  let sp = text.find(' ')"]).len == 0

  test "no editor surface searches text for a query itself":
    var scanned = 0
    var found: seq[string] = @[]
    let dirs = ["src/frontend/tui/app", "src/frontend/gpui",
                "src/frontend/view_vocabulary", "src/frontend/viewmodel/editor",
                "src/frontend/viewmodel/views"]
    var files: seq[string] = @[]
    for dir in dirs:
      for f in walkDirRec(repo / dir):
        if f.endsWith(".nim") and "/tests/" notin f: files.add f
    for f in ["src/frontend/viewmodel/editing_core.nim",
              "src/frontend/viewmodel/viewmodels/find_vm.nim"]:
      files.add repo / f
    var exemptFound = 0
    for f in files:
      # The matcher itself is the one place matching is written.
      if f.endsWith("editor/find_match.nim"): continue
      inc scanned
      let rel = f.relativePath(repo)
      let lines = readFile(f).splitLines
      let (allNamed, spared) = exemptLines(rel, lines)
      for (file, _, _) in NotDocumentSearch:
        if file == rel and allNamed: inc exemptFound
      var kept: seq[string] = @[]
      for i, l in lines:
        if i notin spared: kept.add l
      for v in secondMatchers(kept):
        found.add rel & ": " & v.strip
    checkpoint("modules scanned: " & $scanned)
    for v in found: checkpoint("A SECOND MATCHER: " & v)
    ck scanned >= 150
    ck found.len == 0
    # Every exemption still names a proc that exists, in a scanned module.
    ck exemptFound == NotDocumentSearch.len

  test "`matchesOf` is defined once, in the editor core":
    var defs: seq[string] = @[]
    for f in walkDirRec(repo / "src/frontend"):
      if not f.endsWith(".nim") or "/tests/" in f: continue
      for line in readFile(f).splitLines:
        if line.startsWith("func matchesOf*") or line.startsWith("proc matchesOf*"):
          defs.add f.relativePath(repo)
    ck defs == @["src/frontend/viewmodel/editor/find_match.nim"]

  test "`app/views/search.nim` answers the shared matcher's spans, in cells":
    let lines = ["déjà vu: foo FOO foo", "foofoo", "no"]
    for caseSensitive in [true, false]:
      let got = findMatches(lines, "foo", caseSensitive)
      var want: seq[SearchMatch] = @[]
      for i, l in lines:
        for m in matchesOf(l, "foo", MatchOptions(caseSensitive: caseSensitive)):
          want.add SearchMatch(line: i + 1, column: cellWidthOf(l[0 ..< m.a]),
                               length: cellWidthOf(l[m.a ..< m.b]))
      ck got == want
    ck findMatches(lines, "foo", true).len == 4
    ck findMatches(lines, "foo", false).len == 5

suite "PLAT-70 Part C: the painters draw the session's marks":

  proc groundAt(g: StyledGrid; row, col: int): SemanticRole =
    g.styleAt(row, col).surface

  test "the Debug-mode source pane: every match, the current one distinct":
    var model = initSourcePaneModel(path = "m.py",
                                    heldLines = @["foo = foo + 1", "x"],
                                    totalLineCount = 2)
    model.selected = @[(line: 1, fromColumn: 7, toColumn: 10)]
    model.findMarks = @[(line: 1, fromColumn: 1, toColumn: 4, current: false),
                        (line: 1, fromColumn: 7, toColumn: 10, current: true)]
    let area = CellArea(col: 0, row: 0, width: 40, height: 4)
    var g = newStyledGrid(40, 4)
    let screen = paintSourcePane(g, area, model)
    let code = screen.gutterWidth
    let row = 1
    ck g.groundAt(row, code + 0) == srSurfaceFindMatch
    ck g.groundAt(row, code + 2) == srSurfaceFindMatch
    ck g.groundAt(row, code + 3) != srSurfaceFindMatch
    # The current match is the selection; its own style wins.
    ck g.groundAt(row, code + 6) == srSurfaceFindMatchCurrent
    ck g.groundAt(row, code + 8) == srSurfaceFindMatchCurrent
    ck g.groundAt(row, code + 9) notin {srSurfaceFindMatch,
                                         srSurfaceFindMatchCurrent}

  test "the source pane draws the marks from the view's left column":
    var model = initSourcePaneModel(path = "m.py",
                                    heldLines = @["abc foo def foo" & repeat('x', 50)],
                                    totalLineCount = 1)
    model.hview = HorizontalView(leftCol: 4, contentCols: 65, viewportCols: 20)
    model.findMarks = @[(line: 1, fromColumn: 5, toColumn: 8, current: false)]
    let area = CellArea(col: 0, row: 0, width: 30, height: 3)
    var g = newStyledGrid(30, 3)
    let screen = paintSourcePane(g, area, model)
    let code = screen.gutterWidth
    # `foo` at columns 5 – 7 is drawn from the view's column 5: cells 0 – 2.
    ck g.groundAt(1, code + 0) == srSurfaceFindMatch
    ck g.groundAt(1, code + 3) != srSurfaceFindMatch
    ck g.groundAt(1, code + 4) != srSurfaceFindMatch

  test "the Edit pane: the selection and the marks, from the view's left":
    var model = initEditPaneModel(path = "m.py",
                                  lines = @["abc foo def foo" & repeat('x', 50),
                                            "foo"],
                                  viewportTop = 1, caretLine = 2)
    model.hview = HorizontalView(leftCol: 4, contentCols: 65, viewportCols: 20)
    model.selected = @[(line: 1, fromColumn: 13, toColumn: 16)]
    model.findMarks = @[(line: 1, fromColumn: 5, toColumn: 8, current: false),
                        (line: 1, fromColumn: 13, toColumn: 16, current: true),
                        (line: 2, fromColumn: 1, toColumn: 4, current: false)]
    let area = CellArea(col: 0, row: 0, width: 30, height: 4)
    var g = newStyledGrid(30, 4)
    let screen = paintEditPane(g, area, model)
    let code = screen.gutterWidth
    # Line 1 is drawn from column 5 (`leftCol` 4): `foo` at cells 0 – 2.
    ck g.groundAt(1, code + 0) == srSurfaceFindMatch
    ck g.groundAt(1, code + 3) != srSurfaceFindMatch
    ck g.groundAt(1, code + 8) == srSurfaceFindMatchCurrent
    # Line 2's `foo` lies left of the view, so nothing of it is drawn.
    ck g.groundAt(2, code + 0) != srSurfaceFindMatch
    ck screen.codeWidth > 0

  test "the session's marks are what the panes are handed":
    var d = initEditingDocument("m.py", "abc foo def foo\nfoo\n", bkCua)
    var f: FindVM
    discard f.openFind(d, bkCua, "e", false, fsNone, 1, 0)
    discard f.setQuery(d, "foo")
    let marks = f.marksInWindow(d, 1, 2)
    ck marks.len == 3
    ck marks[0].line == 1 and marks[0].fromColumn == 5 and marks[0].toColumn == 8
    var current = 0
    for m in marks:
      if m.current: inc current
    ck current == 1

suite "PLAT-70 Part C: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
