## test_plat56_build_output.nim — PLAT-56: the Build Output pane's shared
## pieces, which the desktop, the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.13 (the pane on every
## front-end), §3.5 (ANSI colour), §3.7 (build history), §3.10 (the status
## bar); `Edit-Mode-Toolbar.md` §11.2 (EMT-D21: the first `next error` after
## a failed build lands on the highlighted error).
##
## Asserted:
##
##   * THE READER (`build_output_model.BuildLineReader`) over a REAL compiler
##     transcript — `gcc`'s coloured stderr on the PLAT-56 project
##     (`build_fixtures/plat56_c_build`): each line's text with every escape
##     decoded away, its styled runs (their texts are the text; the colours
##     and weights the compiler wrote, as `cssOf` — `ansi_up`'s declarations
##     — draws them), the lines that name a location and their severity,
##     path, line and column, the diagnostics rule's rows; tabs expanded;
##     a fresh reader carries no colour;
##   * THE CHUNK RULE (`chunkLines`);
##   * THE WORDS: the header's verdicts, the duration, the status bar's
##     indicator, the history's labels;
##   * THE BuildVM: a build begun, fed and finished (passing, failing,
##     cancelled); the history (newest first, bounded, a new build shows
##     itself, an old one shown on request); Clear; the jump handed the
##     column;
##   * THE DESKTOP'S VIEW (`isonim_build_view`, under the Mock renderer): a
##     line as styled spans in text nodes, the line classes, the verdict's
##     header class and words, the empty state, the history picker;
##   * THE FIRST `next error` AFTER A FAILED BUILD lands on the highlighted
##     error (codetracer-pm issue
##     `2026-10-26-next-error-after-a-failed-build-skips-the-highlighted-error`).
##
## NO MOCKS: the ViewModels, the reader, the scanner and the parser run for
## real over real compiler output. The one stand-in is the `onJumpToLine` /
## `onJumpToProblem` closure, which records what it is handed — the seam the
## hosts install (the desktop's `data.openLocation`, the native editors), so
## capturing its argument is observing the ViewModel's output, not replacing
## a collaborator.

import std/[strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../store/types
import ../../viewmodels/build_vm
import ../../viewmodels/errors_vm
import ../../viewmodels/terminal_output_model
import ../../views/isonim_build_view
import ./build_fixtures/plat56_c_build

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 122

proc newVM(): BuildVM = createBuildVM(nil)

proc feedAll(vm: BuildVM; lines: openArray[string]; isStdout = false) =
  for l in lines:
    discard vm.feedOutput(l, isStdout)

proc findAll(node: MockNode; cls: string; acc: var seq[MockNode]) =
  if node.isNil:
    return
  if (" " & node.attributes.getOrDefault("class") & " ").contains(
      " " & cls & " "):
    acc.add node
  for child in node.children:
    findAll(child, cls, acc)

proc allByClass(node: MockNode; cls: string): seq[MockNode] =
  findAll(node, cls, result)

proc textOf(node: MockNode): string =
  if node.isNil: "" else: node.textContent

proc attr(node: MockNode; name: string): string =
  node.attributes.getOrDefault(name)

proc style(node: MockNode; name: string): string =
  node.styles.getOrDefault(name)

suite "the reader over a real coloured build":

  test "text, runs, locations and rows of gcc's failing build":
    var r: BuildLineReader
    var reads: seq[ReadBuildLine] = @[]
    for raw in Plat56FailTranscript:
      reads.add r.read(raw, isStdout = false)
    ck reads.len == 15
    # EVERY ESCAPE DECODED AWAY: no ESC byte in any text, and the runs are
    # the text, cut where the attributes change.
    var clean = true
    var runsAreText = true
    for x in reads:
      clean = clean and '\e' notin x.line.text
      var joined = ""
      for run in x.line.runs: joined.add run.text
      runsAreText = runsAreText and joined == x.line.text
    ck clean
    ck runsAreText
    ck reads[1].line.text ==
      "src/main.c:5:17: error: expected ‘;’ before ‘}’ token"
    # The located lines, in order, with their severity, path, line, column.
    var located: seq[string] = @[]
    for x in reads:
      if x.line.located:
        located.add $x.line.severity & " " & x.line.locationPath & ":" &
                    $x.line.locationLine & ":" & $x.line.locationCol
    var expected: seq[string] = @[]
    for e in Plat56FailLocated:
      expected.add "bls" & e.severity.capitalizeAscii & " " & e.path & ":" &
                   $e.line & ":" & $e.col
    checkpoint(located.join(" | "))
    ck located == expected
    # "In function" names a file and no line: not a jump target.
    ck not reads[0].line.located
    ck not reads[10].line.located
    # THE COLOURS AS WRITTEN: the location bold; `error: ` bold in palette 1
    # (`ansi_up`'s red, 187,0,0); the caret's green `;` fix-it.
    ck reads[1].line.runs[0].text == "src/main.c:5:17:"
    ck cssOf(reads[1].line.runs[0].style) == "font-weight:bold"
    ck reads[1].line.runs[2].text == "error: "
    ck cssOf(reads[1].line.runs[2].style) ==
      "color:rgb(187,0,0);font-weight:bold"
    ck reads[4].line.runs[^1].text == ";"
    ck cssOf(reads[4].line.runs[^1].style) == "color:rgb(0,187,0)"
    # The warning's colour (magenta) and the note's (cyan).
    ck cssOf(reads[7].line.runs[2].style) ==
      "color:rgb(187,0,187);font-weight:bold"
    ck cssOf(reads[14].line.runs[2].style) ==
      "color:rgb(0,187,187);font-weight:bold"
    # THE ROWS the diagnostics rule makes, from the TEXT (not the escapes).
    var rows: seq[string] = @[]
    for x in reads:
      if x.fed.problem:
        rows.add $x.fed.row.severity & " " & $x.fed.row.line & ":" &
                 $x.fed.row.col
    ck rows == @["blsError 5:17", "blsWarning 4:9", "blsError 10:12",
                 "blsInfo 10:12"]

  test "the passing build: one located warning, the colour reset per line":
    var r: BuildLineReader
    var reads: seq[ReadBuildLine] = @[]
    for raw in Plat56PassTranscript:
      reads.add r.read(raw, isStdout = false)
    ck reads.len == 4
    ck reads[1].line.located
    ck reads[1].line.severity == blsWarning
    ck reads[1].line.locationPath == "src/ok.c"
    ck reads[1].line.locationLine == 4
    ck reads[1].line.locationCol == 9
    # `ESC[m` closed every run: the quoted source starts plain.
    ck cssOf(reads[2].line.runs[0].style) == ""

  test "an attribute left set carries to the next line; a fresh reader not":
    var r: BuildLineReader
    discard r.read("\e[31mred and still", true)
    let next = r.read("red here", true)
    ck cssOf(next.line.runs[0].style) == "color:rgb(187,0,0)"
    r.reset()
    let fresh = r.read("plain", true)
    ck cssOf(fresh.line.runs[0].style) == ""

  test "tabs expand to the next multiple of eight; controls are dropped":
    var r: BuildLineReader
    let x = r.read("a\tb\r", true)
    ck x.line.text == "a       b"
    let e = r.read("", true)
    ck e.line.text == ""
    ck e.line.runs.len == 0

  test "the chunk rule":
    ck chunkLines("a\nb\n") == @["a", "b"]
    ck chunkLines("a\n\nb") == @["a", "", "b"]
    ck chunkLines("one") == @["one"]
    ck chunkLines("") == @[""]
    ck chunkLines("crlf\r\n") == @["crlf"]

suite "the words":

  test "durations as the desktop writes them":
    ck formatBuildDuration(3200.0) == "3.2s"
    ck formatBuildDuration(0.0) == "0.0s"
    ck formatBuildDuration(64_000.0) == "1m 4.0s"

  test "the counts":
    ck countWords(@[BuildProblemLine(severity: blsError),
                    BuildProblemLine(severity: blsError),
                    BuildProblemLine(severity: blsWarning)]) ==
      "2 errors, 1 warning"
    ck countWords(@[BuildProblemLine(severity: blsError)]) == "1 error"
    ck countWords(@[BuildProblemLine(severity: blsInfo)]) == ""

suite "the BuildVM: a build from start to verdict":

  test "a failing build: lines, rows, verdict, duration, status bar":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      ck vm.status.val == bsIdle
      ck vm.headerText == ""
      ck vm.statusText == ""
      vm.beginBuild(Plat56FailCommand, 1000.0)
      ck vm.status.val == bsRunning
      ck vm.headerText == "running " & Plat56FailCommand
      vm.tickClock(2500.0)
      ck vm.durationText == "1.5s"
      ck vm.statusText == "Building… 1.5s"
      vm.feedAll(Plat56FailTranscript)
      vm.finishBuild(1, 3200.0)
      ck vm.status.val == bsFailed
      ck vm.output.val.len == 15
      ck vm.problems.val.len == 4
      ck vm.headerText == "build failed (exit code 1)"
      ck vm.durationText == "in 2.2s"
      ck vm.statusText == "Build failed: 2 errors, 1 warning"
      ck vm.statusIcon == "✗"
      dispose()

  test "a passing build, a cancelled one, and one that failed in silence":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      vm.beginBuild(Plat56PassCommand, 0.0 + 10.0)
      vm.feedAll(Plat56PassTranscript)
      vm.finishBuild(0, 210.0)
      ck vm.status.val == bsSucceeded
      ck vm.headerText == "build succeeded"
      ck vm.statusText == "Build succeeded in 0.2s"
      ck vm.statusIcon == "✓"
      vm.beginBuild("sleep 60", 1000.0)
      vm.finishBuild(143, 2000.0, cancelled = true)
      ck vm.status.val == bsCancelled
      ck vm.headerText == "build cancelled"
      ck vm.statusText == "Build cancelled"
      # NO OUTPUT IS STILL A VERDICT: a build that failed without a word is
      # a failed build, not an idle pane.
      vm.beginBuild("false", 3000.0)
      vm.finishBuild(1, 3010.0)
      ck vm.status.val == bsFailed
      ck vm.statusText == "Build failed (exit code 1)"
      # The terminal's `:run` is a run, in the same words.
      vm.beginBuild("./app", 4000.0, noun = "run")
      vm.finishBuild(0, 4100.0)
      ck vm.headerText == "run succeeded"
      ck vm.statusText == "Run succeeded in 0.1s"
      dispose()

  test "the history: newest first, bounded, a new build shows itself":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      vm.beginBuild(Plat56FailCommand, 1000.0)
      vm.feedAll(Plat56FailTranscript)
      vm.finishBuild(1, 1400.0)
      ck vm.history.val.len == 0
      vm.beginBuild(Plat56PassCommand, 2000.0)
      vm.feedAll(Plat56PassTranscript)
      vm.finishBuild(0, 2300.0)
      ck vm.history.val.len == 1
      ck vm.history.val[0].number == 1
      ck vm.number.val == 2
      ck vm.historyLabels() == @[BuildLatestLabel,
        "#1 " & Plat56FailCommand & " — failed (exit code 1), 0.4s"]
      # THE OLD BUILD, SHOWN: its output, its verdict, its words; the status
      # bar still reports the current one.
      vm.showBuild(0)
      ck not vm.showingLatest
      ck vm.shownSnapshot().output.len == 15
      ck vm.headerText == "build failed (exit code 1)"
      ck vm.statusText == "Build succeeded in 0.3s"
      vm.showBuild(-1)
      ck vm.showingLatest
      ck vm.shownSnapshot().output.len == 4
      vm.showBuild(0)
      vm.beginBuild("third", 3000.0)
      ck vm.showingLatest
      ck vm.history.val.len == 2
      ck vm.history.val[0].command == Plat56PassCommand
      # BOUNDED: the oldest goes.
      for i in 0 ..< BuildHistoryMax + 3:
        vm.finishBuild(0, 3001.0 + float(i))
        vm.beginBuild("b" & $i, 4000.0 + float(i))
      ck vm.history.val.len == BuildHistoryMax
      ck vm.history.val[^1].number > 1
      dispose()

  test "Clear empties the current build and keeps the history":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      vm.beginBuild("one", 1.0)
      vm.finishBuild(0, 2.0)
      vm.beginBuild(Plat56PassCommand, 10.0)
      vm.feedAll(Plat56PassTranscript)
      vm.finishBuild(0, 20.0)
      vm.clearOutput()
      ck vm.status.val == bsIdle
      ck vm.output.val.len == 0
      ck vm.headerText == ""
      ck vm.history.val.len == 1
      dispose()

  test "a located line's jump is handed its column":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      var jumps: seq[string] = @[]
      vm.onJumpToLine = proc(path: string; line, col: int) =
        jumps.add path & ":" & $line & ":" & $col
      vm.beginBuild(Plat56FailCommand, 1.0)
      vm.feedAll(Plat56FailTranscript)
      vm.jumpToLine(vm.output.val[1])
      vm.jumpToLine(vm.output.val[2])
      ck jumps == @["src/main.c:5:17"]
      dispose()

suite "the desktop's view draws the runs":

  test "spans in text nodes, classes, header and the empty state":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      let r = MockRenderer()
      let panel = renderBuildPanel[MockRenderer, MockNode](r, vm)
      let empty = allByClass(panel, "build-empty")
      ck empty.len == 1
      ck textOf(empty[0]) == BuildIdleText
      ck empty[0].style("display") == "block"
      vm.beginBuild(Plat56FailCommand, 1.0)
      vm.feedAll(Plat56FailTranscript)
      vm.feedAll(@["<b onclick=go>bold</b>"], isStdout = true)
      vm.finishBuild(1, 2.0)
      ck empty[0].style("display") == "none"
      let header = allByClass(panel, "build-header")
      ck header.len == 1
      ck header[0].attr("class") == "build-header build-failed"
      ck textOf(allByClass(panel, "build-command-label")[0]) ==
        "build failed (exit code 1)"
      ck allByClass(panel, "build-clickable").len == 4
      ck allByClass(panel, "build-line-error").len == 2
      ck allByClass(panel, "build-line-warning").len == 1
      ck allByClass(panel, "build-stderr").len == 11
      ck allByClass(panel, "build-stdout").len == 1
      # A line is its runs: one span each, styled with `cssOf`, the text a
      # text node — so a compiler's `<b>` is characters, not an element.
      let line = allByClass(panel, "build-line-error")[0]
      ck line.children.len == vm.output.val[1].runs.len
      ck line.children[2].attr("style") ==
        "color:rgb(187,0,0);font-weight:bold"
      ck textOf(line) == vm.output.val[1].text
      let stdoutLine = allByClass(panel, "build-stdout")[0]
      ck textOf(stdoutLine) == "<b onclick=go>bold</b>"
      ck stdoutLine.children[0].children[0].kind == mnkText
      dispose()

  test "the history picker":
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      let r = MockRenderer()
      let panel = renderBuildPanel[MockRenderer, MockNode](r, vm)
      let btn = allByClass(panel, "build-history-btn")
      ck btn.len == 1
      ck btn[0].style("display") == "none"
      vm.beginBuild(Plat56FailCommand, 1.0)
      vm.feedAll(Plat56FailTranscript)
      vm.finishBuild(1, 2.0)
      vm.beginBuild(Plat56PassCommand, 3.0)
      vm.feedAll(Plat56PassTranscript)
      vm.finishBuild(0, 4.0)
      ck btn[0].style("display") == "inline-block"
      btn[0].fireEvent("click")
      let items = allByClass(panel, "build-history-item")
      ck items.len == 2
      ck textOf(items[0]) == BuildLatestLabel
      items[1].fireEvent("click")
      ck vm.shownIndex.val == 0
      ck allByClass(panel, "build-clickable").len == 4
      ck textOf(allByClass(panel, "build-command-label")[0]) ==
        "build failed (exit code 1)"
      dispose()

suite "the first next error after a failed build":

  test "lands on the highlighted error, then steps":
    createRoot proc(dispose: proc()) =
      let errs = createErrorsVM(nil)
      var opened: seq[string] = @[]
      errs.onJumpToProblem = proc(path: string; line, col: int) =
        opened.add $line & ":" & $col
      var r: BuildLineReader
      for raw in Plat56FailTranscript:
        let x = r.read(raw, false)
        if x.fed.problem:
          errs.appendProblem(x.fed.row)
      ck errs.highlightFirstError()
      ck errs.selectedIndex.val == 0
      ck opened.len == 0
      ck errs.gotoNextError() == enoMoved
      ck opened == @["5:17"]
      ck errs.statusMessage.val == "error 1 of 2"
      ck errs.gotoNextError() == enoMoved
      ck opened[^1] == "10:12"
      # A selection made by hand is an origin again.
      discard errs.highlightFirstError()
      errs.selectProblemIndex(0)
      ck errs.gotoNextError() == enoMoved
      ck opened[^1] == "10:12"
      # `previous` steps from the highlight: it wraps to the last error.
      discard errs.highlightFirstError()
      ck errs.gotoPreviousError() == enoWrapped
      ck opened[^1] == "10:12"
      dispose()

suite "the count":
  test "every assertion ran":
    checkpoint("asserted: " & $asserted)
    check asserted == ExpectedAssertions
