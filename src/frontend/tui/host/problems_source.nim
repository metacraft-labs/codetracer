## tui/host/problems_source.nim — PLAT-55. **The terminal's Problems pane is
## filled from the desktop's ViewModel, by the shared build reader.**
##
## The host half of the pane, as `test_results_source.nim` is Test Results':
## it owns the window's `BuildProblems` (`host/build_problems`: the window's
## `ErrorsVM`, fed from its `:build`s by the rule the desktop's Build component
## calls), hands the app layer the value `views/problems_pane.nim` paints, and
## answers the pane's commands (`TuiApp.problemsCommand`) through the
## ViewModel's own actions — the ones the desktop's panel and its
## `aGotoNextError` / `aGotoPreviousError` call:
##
## * a press on a row selects it and opens its file at its line (K35), the
##   editor focused (EMT-D21); a row whose file is not there says why and
##   stays listed (EMT-D20);
## * `problems.next` / `problems.previous` walk the errors, wrapping, and
##   announce in the pane's header and on the status line (EMT-D22);
## * the filter buttons and Group by File act on the list.
##
## Opening a file is the loop's (`open`): Edit mode's editor, or — in a
## replay's Debug mode — the file shown from the recording.

import std/strutils

import isonim/core/signals

import ../app/runtime
import ../app/tui_app
import ../app/views/problems_pane
import ../../viewmodel/store/types
import ./build_problems

export build_problems

type
  ProblemsOpener* = proc(path: string; line, col: int): string {.closure.}
    ## Open the absolute `path` at `line:col` (1-based); "" when it opened,
    ## else why not.

  ProblemsSource* = ref object
    problems*: BuildProblems
    open: ProblemsOpener
    said: string
      ## What the last jump said (an open that failed, or "opened …").

proc toneOf(severity: BuildLineSeverity): ProblemsTone =
  case severity
  of blsError: ptError
  of blsWarning: ptWarning
  of blsInfo, blsNone: ptInfo

proc paneModelOf*(vm: ErrorsVM): ProblemsPaneModel =
  ## The shared ViewModel as the pane's value — every word the ViewModel's
  ## (the desktop's panel reads the same procs), nothing derived here.
  result = ProblemsPaneModel(loaded: true, selected: vm.selectedIndex.val,
                             errorBadge: vm.errorBadgeText,
                             warningBadge: vm.warningBadgeText,
                             totalBadge: vm.totalBadgeText,
                             status: vm.statusMessage.val,
                             filter: ord(vm.filter.val),
                             groupLabel: GroupByFileLabel,
                             grouped: vm.groupByFile.val)
  for tag in ProblemFilterTag:
    result.filters.add ProblemFilterLabels[tag]
  let problems = vm.problems.val
  for d in vm.displayRows():
    case d.kind
    of pdRow:
      let p = problems[d.index]
      result.rows.add ProblemsPaneRow(index: d.index, tone: toneOf(p.severity),
                                      icon: severityIcon(p.severity),
                                      path: p.path, location: locationText(p),
                                      message: p.message)
      result.lines.add ProblemsPaneLine(kind: plRow, row: result.rows.high)
    of pdFileHeader:
      result.lines.add ProblemsPaneLine(kind: plFileHeader, row: -1,
                                        text: d.text)
    of pdEmpty:
      result.lines.add ProblemsPaneLine(kind: plEmpty, row: -1, text: d.text)

proc publish*(s: ProblemsSource; rt: TuiRuntime) =
  ## Hand the app layer the pane's value; the reading position is the
  ## reader's (the painter clamps it).
  if s.isNil:
    return
  let top = rt.app.problems.scrollTop
  rt.app.problems = paneModelOf(s.problems.vm)
  rt.app.problems.scrollTop = top

proc jump(s: ProblemsSource; path: string; line, col: int) =
  ## The ViewModel's `onJumpToProblem`: the file opened at the diagnostic,
  ## or why not.
  let t = s.problems.targetOf(path, line, col)
  if not t.ok:
    s.said = t.why
    return
  let why = if s.open.isNil: "this window cannot open files" else:
            s.open(t.path, t.line, t.col)
  s.said = if why.len > 0: why
           else: "opened " & path & ":" & $line &
                 (if col > 0: ":" & $col else: "")

proc command(s: ProblemsSource; rt: TuiRuntime; kind: ProblemsCommandKind;
             index: int): string =
  let vm = s.problems.vm
  s.said = ""
  case kind
  of pcmSelect:
    vm.selectProblemIndex(index)
  of pcmOpen:
    vm.selectProblemIndex(index)
    let problems = vm.problems.val
    if index >= 0 and index < problems.len:
      vm.jumpToProblem(problems[index])
    else:
      s.said = "that problem is no longer listed"
  of pcmNext, pcmPrevious:
    discard (if kind == pcmNext: vm.gotoNextError() else: vm.gotoPreviousError())
    # The announcement (`error 2 of 3`, `wrapped to first error`, `no errors`)
    # first, then what the jump said when it could not open the file.
    let announced = vm.statusMessage.val
    if s.said.len == 0 or s.said.startsWith("opened "):
      s.said = announced
    else:
      s.said = announced & " — " & s.said
  of pcmFilter:
    if index >= ord(low(ProblemFilterTag)) and index <= ord(high(ProblemFilterTag)):
      vm.setFilter(ProblemFilterTag(index))
  of pcmGroup:
    vm.toggleGroupByFile()
  s.publish(rt)
  s.said

proc newProblemsSource*(rt: TuiRuntime; open: ProblemsOpener): ProblemsSource =
  ## The window's Problems source, its commands installed on `rt`'s app.
  result = ProblemsSource(problems: newBuildProblems(), open: open)
  let s = result
  s.problems.vm.onJumpToProblem = proc(path: string; line, col: int) =
    s.jump(path, line, col)
  rt.app.problemsCommand = proc(kind: ProblemsCommandKind; index: int): string =
    s.command(rt, kind, index)
  s.publish(rt)

proc tick*(s: ProblemsSource; rt: TuiRuntime; nowMs = 0'i64): bool =
  ## Follow the window's build (`rt.app.build`). Whether the pane changed.
  ## `nowMs` ticks the running build's clock (PLAT-56: the Build Output
  ## pane's duration and the status line's indicator).
  if s.isNil:
    return false
  result = s.problems.follow(rt.app.build, nowMs)
  if result:
    s.publish(rt)

proc close*(s: ProblemsSource) =
  if not s.isNil:
    s.problems.close()
