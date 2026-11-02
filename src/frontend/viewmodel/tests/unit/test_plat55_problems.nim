## test_plat55_problems.nim — PLAT-55: the Problems pane's shared pieces, which
## the desktop, the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.3 (the Problems panel),
## §3.4 (the matchers); `Planned-Features/Edit-Mode-Toolbar.md` §11 (EMT-D20,
## D21, D22, A36).
##
## Asserted:
##
##   * THE ONE RULE (`build_diagnostics.feedBuildLine`), over a REAL compiler
##     transcript — `nargo compile`'s stderr on the PLAT-55 crate, two files,
##     two errors and a warning, recorded below byte for byte, and the
##     repository's recorded `noir_build_error` transcript: one row per
##     diagnostic, the path as the compiler wrote it, the line, the column,
##     the sentence and the severity carried from the header line; a `Hint`
##     line is never a row; a fresh scanner does not inherit the last build's
##     keyword;
##   * THE FEED (`BuildProblemsFeed`): a new build clears the list and the
##     cursor (EMT-D22.7); a failed build highlights its first error WITHOUT
##     a jump (EMT-D21); a successful one highlights nothing;
##   * WHERE A ROW'S FILE IS (`resolvedPath`): relative against the build's
##     working directory (EMT-A36), absolute, Windows drive and UNC paths as
##     written, `./` dropped;
##   * THE WORDS moved out of the desktop's view (icons, classes, locations,
##     the badges, the filter labels, the empty state) and THE LIST the native
##     panes draw (`displayRows`): flat, filtered, grouped by file in the order
##     the files first appear, the empty state;
##   * NEXT / PREVIOUS (EMT-D22): errors only, wrapping and announced, an
##     empty list a no-op saying "no errors", the jump handed the row;
##   * THE COLUMNS (`problemsFit`): the icon and the location never cut, the
##     message given the slack, both cut columns shrinking before the pane
##     scrolls;
##   (the vocabulary view, `pane_views.problemsPaneView`, is the `tui`
##   lane's `test_plat55_problems.nim`'s: it imports the layout model).
##
## NO MOCKS: the ViewModel, the parser and the scanner run for real over real
## compiler output. The one stand-in is the `onJumpToProblem` closure, which
## records what it is handed — it is the seam the hosts install (the desktop's
## `data.openLocation`, the native panes' editors), so capturing its argument
## is observing the ViewModel's output, not replacing a collaborator.

import std/[strutils, unittest]

import isonim/core/[owner, signals]

import ../../store/types
import ../../viewmodels/errors_vm
import ../../viewmodels/build_diagnostics
import ../../viewmodels/table_fit

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 89

const
  # `nargo compile` (1.0.0-beta.26) on the PLAT-55 crate
  # (`tui/tests/fixtures/plat55_noir_build.nim`), its stderr as the pipe
  # received it — recorded 2026-10-25, the same output the native suites
  # get from running the compiler and the desktop's capture feeds its pane.
  Plat55Transcript = @[
    "warning: unused variable unused",
    "  ┌─ src/util.nr:2:9",
    "  │",
    "2 │     let unused = 1;",
    "  │         ------ unused variable",
    "  │",
    "",
    "error: Expected type bool, found type Field",
    "  ┌─ src/util.nr:3:22",
    "  │",
    "3 │     let flag: bool = v;",
    "  │                      -",
    "  │",
    "",
    "error: Expected type bool, found type Field",
    "  ┌─ src/main.nr:5:19",
    "  │",
    "5 │     let b: bool = a;",
    "  │                   -",
    "  │",
    "",
    "Aborting due to 2 previous errors"]

proc problemsOfTranscript(lines: openArray[string]): seq[BuildProblemLine] =
  ## Every row a whole transcript yields, read from the start by a fresh
  ## scanner — what the Problems pane lists after a build that printed
  ## `lines`.
  var scanner: BuildLocationScanner
  for raw in lines:
    let fed = scanner.feedBuildLine(raw)
    if fed.problem:
      result.add fed.row

proc withVM(body: proc(vm: ErrorsVM)) =
  var vm: ErrorsVM
  createRoot proc(dispose: proc()) =
    vm = createErrorsVM(nil)
    body(vm)
    dispose()

suite "PLAT-55: one rule from a build's output to its Problems rows":

  test "the real nargo transcript: three rows, severities from the headers":
    let rows = problemsOfTranscript(Plat55Transcript)
    ck rows.len == 3
    ck rows[0] == BuildProblemLine(severity: blsWarning, path: "src/util.nr",
                                   line: 2, col: 9,
                                   message: "unused variable unused")
    ck rows[1] == BuildProblemLine(severity: blsError, path: "src/util.nr",
                                   line: 3, col: 22,
                                   message: "Expected type bool, found type Field")
    ck rows[2] == BuildProblemLine(severity: blsError, path: "src/main.nr",
                                   line: 5, col: 19,
                                   message: "Expected type bool, found type Field")

  test "the repository's recorded noir_build_error transcript":
    const text = staticRead(
      "../../../../../test-programs/noir_build_error/recorded-nargo-compile.stderr")
    let rows = problemsOfTranscript(text.splitLines)
    var errors, warnings = 0
    for r in rows:
      if r.severity == blsError: inc errors
      if r.severity == blsWarning: inc warnings
    ck rows.len == 3
    ck errors == 1
    ck warnings == 2
    ck rows[2].line == 3 and rows[2].col == 19 and rows[2].path == "src/main.nr"

  test "each line read once: located, problem, row":
    var scanner: BuildLocationScanner
    let header = scanner.feedBuildLine("warning: unused variable x")
    ck not header.located and not header.problem
    let loc = scanner.feedBuildLine("  ┌─ src/main.nr:1:9")
    ck loc.located and loc.problem
    ck loc.row.severity == blsWarning and loc.row.message == "unused variable x"
    # The gutter line under it is no row.
    ck not scanner.feedBuildLine("  │").problem
    # GCC's own line carries its keyword; a Nim `Hint:` line is never a row.
    let gcc = scanner.feedBuildLine("main.c:10:5: error: expected ';' before '}' token")
    ck gcc.problem and gcc.row.severity == blsError and gcc.row.path == "main.c"
    ck not scanner.feedBuildLine(
      "/src/app.nim(3, 1) Hint: 'x' is declared but not used [XDeclaredButNotUsed]").located
    let nim = scanner.feedBuildLine("/src/app.nim(42, 5) Error: undeclared identifier: 'foo'")
    ck nim.problem and nim.row.line == 42 and nim.row.col == 5

  test "a fresh scanner does not inherit the last build's keyword":
    var scanner: BuildLocationScanner
    discard scanner.feedBuildLine("warning: unused variable x")
    scanner.reset()
    let row = scanner.feedBuildLine("  ┌─ src/main.nr:3:19")
    ck row.problem
    ck row.row.severity != blsWarning

suite "PLAT-55: the feed a native host drives":

  test "a new build clears; a failed build highlights its first error, no jump":
    withVM proc(vm: ErrorsVM) =
      var jumped = 0
      vm.onJumpToProblem = proc(path: string; line, col: int) = inc jumped
      let feed = newBuildProblemsFeed(vm)
      feed.beginBuild("/work/crate")
      for line in Plat55Transcript:
        discard feed.feedLine(line)
      ck vm.problems.val.len == 3
      ck feed.active
      feed.endBuild(failed = true)
      ck not feed.active
      ck vm.selectedIndex.val == 1          # the first ERROR, not the warning
      ck jumped == 0                         # EMT-D21: highlighted, not moved
      ck feed.workingDirectory == "/work/crate"
      # EMT-D22.7: the next build starts clean, the cursor gone.
      vm.announce("error 1 of 2")
      feed.beginBuild("/work/other")
      ck vm.problems.val.len == 0
      ck vm.selectedIndex.val == NO_SELECTED_PROBLEM
      ck vm.statusMessage.val == ""
      feed.endBuild(failed = false)
      ck vm.selectedIndex.val == NO_SELECTED_PROBLEM

  test "a successful build with a warning selects nothing":
    withVM proc(vm: ErrorsVM) =
      let feed = newBuildProblemsFeed(vm)
      feed.beginBuild("/w")
      discard feed.feedLine("warning: unused variable x")
      ck feed.feedLine("  ┌─ src/main.nr:1:9")
      feed.endBuild(failed = false)
      ck vm.problems.val.len == 1
      ck vm.selectedIndex.val == NO_SELECTED_PROBLEM

  test "where a row's file is":
    ck resolvedPath("src/main.nr", "/work/crate") == "/work/crate/src/main.nr"
    ck resolvedPath("./src/main.nr", "/work/crate/") == "/work/crate/src/main.nr"
    ck resolvedPath("/abs/main.nim", "/work") == "/abs/main.nim"
    ck resolvedPath("C:\\proj\\main.c", "/work") == "C:\\proj\\main.c"
    ck resolvedPath("D:/proj/main.c", "/work") == "D:/proj/main.c"
    ck resolvedPath("\\\\host\\share\\a.c", "/work") == "\\\\host\\share\\a.c"
    ck resolvedPath("src/a.nr", "") == "src/a.nr"

suite "PLAT-55: the words and the list every front-end draws":

  test "icons, classes, locations, badges, labels":
    ck severityIcon(blsError) == "●"
    ck severityIcon(blsWarning) == "⚠"
    ck severityIcon(blsInfo) == "ⓘ"
    ck severityClassSuffix(blsWarning) == "warning"
    ck severityClassSuffix(blsNone) == "info"
    ck locationText(BuildProblemLine(line: 3, col: 22)) == "3:22"
    ck locationText(BuildProblemLine(line: 3, col: -1)) == "3"
    ck ProblemFilterLabels == ["All", "Errors", "Warnings"]
    ck GroupByFileLabel == "Group by File"
    ck ProblemsEmptyText == "No problems detected."
    ck groupHeaderText("src/util.nr", 2) == "src/util.nr (2)"
    withVM proc(vm: ErrorsVM) =
      vm.setProblems(problemsOfTranscript(Plat55Transcript))
      ck vm.errorBadgeText == "● 2"
      ck vm.warningBadgeText == "⚠ 1"
      ck vm.totalBadgeText == "Total: 3"

  test "the list: flat, filtered, grouped, empty":
    withVM proc(vm: ErrorsVM) =
      let empty = vm.displayRows()
      ck empty.len == 1 and empty[0].kind == pdEmpty and
         empty[0].text == ProblemsEmptyText
      vm.setProblems(problemsOfTranscript(Plat55Transcript))
      var flat: seq[int] = @[]
      for d in vm.displayRows():
        ck d.kind == pdRow
        flat.add d.index
      ck flat == @[0, 1, 2]
      vm.setFilter(pfErrors)
      var errorsOnly: seq[int] = @[]
      for d in vm.displayRows(): errorsOnly.add d.index
      ck errorsOnly == @[1, 2]
      vm.setFilter(pfWarnings)
      ck vm.displayRows().len == 1 and vm.displayRows()[0].index == 0
      vm.setFilter(pfAll)
      vm.setGroupByFile(true)
      let grouped = vm.displayRows()
      ck grouped.len == 5
      ck grouped[0].kind == pdFileHeader and grouped[0].text == "src/util.nr (2)"
      ck grouped[1].index == 0 and grouped[2].index == 1
      ck grouped[3].kind == pdFileHeader and grouped[3].text == "src/main.nr (1)"
      ck grouped[4].index == 2
      vm.setFilter(pfWarnings)
      ck vm.displayRows().len == 2   # one header, one row
      # The selection is held against the master list: a filter that hides
      # it keeps it.
      vm.selectProblemIndex(2)
      vm.setFilter(pfErrors)
      ck vm.selectedIndex.val == 2

suite "PLAT-55: next and previous error (EMT-D22)":

  test "errors only, wrapping, announced; the jump handed the row":
    withVM proc(vm: ErrorsVM) =
      var jumps: seq[string] = @[]
      vm.onJumpToProblem = proc(path: string; line, col: int) =
        jumps.add path & ":" & $line & ":" & $col
      ck vm.gotoNextError() == enoEmpty
      ck vm.statusMessage.val == "no errors"
      ck jumps.len == 0
      vm.setProblems(problemsOfTranscript(Plat55Transcript))
      ck vm.gotoNextError() == enoMoved
      ck vm.selectedIndex.val == 1
      ck vm.statusMessage.val == "error 1 of 2"
      ck vm.gotoNextError() == enoMoved
      ck vm.selectedIndex.val == 2
      ck vm.gotoNextError() == enoWrapped
      ck vm.statusMessage.val == "wrapped to first error"
      ck vm.selectedIndex.val == 1
      ck vm.gotoPreviousError() == enoWrapped
      ck vm.statusMessage.val == "wrapped to last error"
      ck jumps == @["src/util.nr:3:22", "src/main.nr:5:19",
                    "src/util.nr:3:22", "src/main.nr:5:19"]

suite "PLAT-55: the row's columns":

  test "fit, shrink, scroll":
    let wide = problemsFit(1, 11, 4, 36, 80)
    ck wide.mode == fmFit
    ck wide.widths[0] == 1 and wide.widths[1] == 11 and wide.widths[2] == 4
    ck wide.widths[3] == 80 - 1 - 11 - 4 - 3      # the message takes the slack
    let narrow = problemsFit(1, 11, 4, 36, 40)
    ck narrow.mode == fmShrink
    ck narrow.widths[2] == 4                       # the location never cut
    ck narrow.widths[1] >= ProblemPathFloor and narrow.widths[1] <= 11
    ck narrow.widths[3] >= ProblemMessageFloor
    ck narrow.contentUnits == 40
    let tiny = problemsFit(1, 11, 4, 36, 20)
    ck tiny.mode == fmScroll
    ck tiny.widths[1] == ProblemPathFloor and tiny.widths[3] == ProblemMessageFloor

suite "PLAT-55: the count":

  test "the assertion count is the one declared":
    check asserted == ExpectedAssertions
