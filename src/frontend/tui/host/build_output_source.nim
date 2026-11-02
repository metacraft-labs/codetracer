## tui/host/build_output_source.nim — PLAT-56. **The terminal's Build Output
## pane is filled from the desktop's ViewModel, by the shared build reader.**
##
## The host half of the pane, as `problems_source.nim` is Problems': the
## window's `BuildVM` (the one `host/build_problems` feeds from the window's
## `:build`s, line by line, through the reader the desktop's BUILD panel reads
## its builds with) turned into the value `views/build_output.nim` paints, and
## the pane's commands (`TuiApp.buildCommand`) answered through the
## ViewModel's own actions — the ones the desktop's header controls call:
##
## * Run builds the shown build's command again; Stop cancels the running
##   build (the runner's flag); Clear clears the current build's output (its
##   history stays); Follow toggles auto-scroll;
## * the history picker shows a build the history kept (§3.7) — a new build
##   shows itself;
## * a press on a line that names a location opens its file at its line and
##   column (K35): a relative path against the build's working directory
##   (EMT-A36); a file that is not there is said, and nothing opens (EMT-D20).
##
## It also fills the status line's build indicator (§3.10), hands the Edit
## pane the Problems pane's rows for its marks (§3.9), and applies the shared
## reveal rule (`build_auto_reveal`, §3.8): a build brings the pane on screen,
## a failed one Problems too, and a clean success puts a REVEALED pane back on
## its edge two seconds later unless the user pressed or scrolled in it.

import std/[os, times]

import isonim/core/[signals, computation]
import ../../../common/[ct_home, window_policy]

import ../app/runtime
import ../app/tui_app
import ../app/views/build_output
import ../../viewmodel/store/types
import ../../viewmodel/viewmodels/build_auto_reveal
import ./build_problems
import ./problems_source

type
  BuildRerun* = proc(command, noun: string): string {.closure.}
    ## Start `command` as a new build (`noun` "build" or "run"); "" when it
    ## started, else why not.

  BuildOutputSource* = ref object
    problems*: ProblemsSource
      ## The window's build reader and its Problems pane (`problems_source`),
      ## whose `BuildVM` this pane draws.
    open: ProblemsOpener
    rerun: BuildRerun
    historyOpen: bool
    lastKey: string
      ## What the last published value was made of, so `tick` publishes only
      ## a change.
    lastShown: (int, int, int)
      ## (number, shown index, line count) of the last published output, for
      ## auto-scroll.
    reveal*: BuildAutoReveal
      ## §3.8: when this window's builds show and put away the pane.

proc vmOf(s: BuildOutputSource): BuildVM =
  if s.isNil or s.problems.isNil or s.problems.problems.isNil: nil
  else: s.problems.problems.build

proc paneModelOf*(vm: BuildVM; historyOpen = false): BuildPaneModel =
  ## The shared ViewModel as the pane's value — every word the ViewModel's
  ## (the desktop's panel reads the same procs), nothing derived here.
  let shown = vm.shownSnapshot()
  result = BuildPaneModel(loaded: true, status: shown.status,
                          headline: shown.headerText,
                          duration: shown.durationText(vm.clockMs.val),
                          output: shown.output, generation: shown.number,
                          running: vm.isRunning.val,
                          follow: vm.autoScroll.val,
                          historyOpen: historyOpen)
  if vm.history.val.len > 0:
    result.history = vm.historyLabels()
    result.historyShown = (if vm.showingLatest: 0 else: vm.shownIndex.val + 1)

proc statusOf*(vm: BuildVM): string =
  ## The status line's build indicator: the icon and the words, "" for none.
  let text = vm.statusText
  if text.len == 0: "" else: vm.statusIcon & " " & text

proc keyOf(vm: BuildVM; open: bool): string =
  let shown = vm.shownSnapshot()
  $shown.number & "|" & $vm.shownIndex.val & "|" & $shown.output.len & "|" &
    $shown.status & "|" & shown.durationText(vm.clockMs.val) & "|" &
    $vm.history.val.len & "|" & $vm.autoScroll.val & "|" & $open & "|" &
    vm.statusText

proc publish*(s: BuildOutputSource; rt: TuiRuntime) =
  ## Hand the app layer the pane's value and the status line's indicator.
  ## Auto-scroll: a shown build that grew, with the toggle on, is followed to
  ## its last line.
  let vm = s.vmOf
  if vm.isNil:
    return
  let top = rt.app.buildPane.scrollTop
  var model = paneModelOf(vm, s.historyOpen)
  let key = (model.generation, model.historyShown, model.output.len)
  model.scrollTop =
    if key[0] != s.lastShown[0] or key[1] != s.lastShown[1]:
      (if model.follow and model.historyShown == 0: model.output.len else: 0)
    elif model.follow and model.historyShown == 0 and
         key[2] > s.lastShown[2]:
      model.output.len
    else: top
  s.lastShown = key
  rt.app.buildPane = model
  rt.app.buildStatus = statusOf(vm)
  rt.app.buildStatusState = vm.status.val
  # §3.9: the Problems pane's rows, for the Edit pane's marks.
  if not s.problems.problems.vm.isNil:
    rt.app.buildDiagnostics = s.problems.problems.vm.problems.val
    rt.app.buildDiagnosticsDir = s.problems.problems.feed.workingDirectory
  s.lastKey = keyOf(vm, s.historyOpen)

proc applyReveal(s: BuildOutputSource; rt: TuiRuntime; vm: BuildVM): bool =
  ## §3.8: the shared rule's step for this window's build, applied to its
  ## docking. Whether the screen changed.
  let now = epochTime() * 1000.0
  if rt.app.buildPaneTouched:
    rt.app.buildPaneTouched = false
    s.reveal.interact()
  let errs = s.problems.problems.vm
  let step = s.reveal.observe(vm.number.val, vm.status.val,
                              (if errs.isNil: 0 else: errs.errorCount.val),
                              (if errs.isNil: 0 else: errs.warningCount.val),
                              now)
  case step
  of brsReveal:
    rt.autoRevealBuildPane()
    result = true
  of brsRevealProblems:
    rt.revealFailedBuild()
    result = true
  else:
    discard
  if s.reveal.due(now) == brsDismiss:
    result = rt.dismissBuildReveal() or result

proc tick*(s: BuildOutputSource; rt: TuiRuntime): bool =
  ## Publish when the build (or its clock) moved. Whether the pane changed.
  let vm = s.vmOf
  if vm.isNil:
    return false
  let revealed = s.applyReveal(rt, vm)
  if keyOf(vm, s.historyOpen) == s.lastKey:
    return revealed
  s.publish(rt)
  true

proc command(s: BuildOutputSource; rt: TuiRuntime; kind: BuildPaneCommandKind;
             index: int): string =
  let vm = s.vmOf
  if vm.isNil:
    return "this window has no build"
  case kind
  of bpcRun:
    if vm.isRunning.val:
      result = "a build is already running; Stop it first"
    else:
      let shown = vm.shownSnapshot()
      if shown.command.len == 0:
        result = "nothing to run again; :build <command> first"
      elif s.rerun.isNil:
        result = "this window cannot run builds"
      else:
        result = s.rerun(shown.command,
                         (if shown.noun.len > 0: shown.noun else: "build"))
  of bpcStop:
    if rt.app.build.isNil or rt.app.build.verdict != bvRunning:
      result = "nothing is running"
    else:
      rt.app.build.requestCancel()
      result = "cancelling " & $rt.app.build.kind & " …"
  of bpcClear:
    vm.clearOutput()
  of bpcFollow:
    vm.toggleAutoScroll()
  of bpcHistory:
    s.historyOpen = not s.historyOpen and vm.history.val.len > 0
  of bpcShow:
    vm.showBuild(index - 1)
    s.historyOpen = false
  of bpcOpen:
    let shown = vm.shownSnapshot()
    if index < 0 or index >= shown.output.len:
      result = "that line is no longer shown"
    else:
      let line = shown.output[index]
      let t = s.problems.problems.targetOf(line.locationPath,
                                           line.locationLine,
                                           line.locationCol)
      if not t.ok:
        result = t.why
      else:
        let why = if s.open.isNil: "this window cannot open files"
                  else: s.open(t.path, t.line, t.col)
        result = if why.len > 0: why
                 else: "opened " & line.locationPath & ":" &
                       $line.locationLine &
                       (if line.locationCol > 0: ":" & $line.locationCol
                        else: "")
  s.publish(rt)

proc revealSetting(): BuildRevealSetting =
  ## §5.1's `build.autoReveal` / `build.autoDismissOnSuccess`, from the
  ## configuration file the desktop reads (found as it finds it). A value that
  ## is not true or false leaves the default, and is not fatal.
  result = DefaultBuildRevealSetting
  let file = findUserConfigFile(getCurrentDir(), ctConfigDir())
  if file.len > 0:
    try:
      result = buildRevealSettingOfConfigText(readFile(file)).setting
    except IOError:
      discard

proc newBuildOutputSource*(rt: TuiRuntime; problems: ProblemsSource;
                           open: ProblemsOpener;
                           rerun: BuildRerun): BuildOutputSource =
  ## The window's Build Output source over `problems`' reader, its commands
  ## installed on `rt`'s app.
  result = BuildOutputSource(problems: problems, open: open, rerun: rerun,
                             lastShown: (-1, -1, 0),
                             reveal: initBuildAutoReveal(revealSetting()))
  let s = result
  rt.app.buildCommand = proc(kind: BuildPaneCommandKind; index: int): string =
    s.command(rt, kind, index)
  let vm = s.vmOf
  if not vm.isNil:
    vm.runBuild = proc() =
      discard s.command(rt, bpcRun, -1)
  s.publish(rt)
