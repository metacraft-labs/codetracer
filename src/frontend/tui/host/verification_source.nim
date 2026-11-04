## tui/host/verification_source.nim — PLAT-63. **The terminal's Verification
## pane is filled from the desktop's ViewModel, by the native host.**
##
## The host half of the pane, as `problems_source.nim` is Problems': it owns
## the window's `NativeVerificationHost` (`viewmodel/host/
## native_verification_host`: the window's `VerificationVM` and
## `CounterexampleSessionVM`, and the project's Verno run), hands the app
## layer the value `views/verification_pane.nim` paints, and answers the
## pane's acts (`TuiApp.verificationAct`) through the ViewModel's own procs —
## the ones the desktop's view calls:
##
## * a press on a finding (or Enter on it) goes to its source location in
##   the editor; one with none says so (K64);
## * a press on an offer opens its counterexample in the pane; a press on a
##   step moves the counterexample there, and to its source when recorded;
## * a right press opens the shared row menu (K65);
## * the Run / Stop controls start and stop the project's declared Verno
##   action (K66), polled from the loop that reads the keyboard (`tick`).
##
## ONE PER WINDOW, like the desktop's (`ui/verification.nim`): the run is of
## the window's project (`app.projectRoot`), not of a trace tab.

import isonim/core/[signals, computation]

import ../../viewmodel/host/native_verification_host
import ../../headless_app/verification_menu
import ../app/runtime
import ../app/tui_app
import ../app/views/verification_pane

export native_verification_host

type
  VerificationOpener* = proc(path: string; line, col: int): string {.closure.}
    ## Open the absolute `path` at `line:col` (1-based); "" when it opened,
    ## else why not.

  VerificationSource* = ref object
    host*: NativeVerificationHost
    open: VerificationOpener
    root: proc(): string {.closure.}
    rootSeen: string

proc paneModelOf*(vm: VerificationVM;
                  session: CounterexampleSessionVM): VerificationPaneModel =
  ## The shared ViewModel as the pane's value — every word the ViewModel's
  ## (the desktop's view reads the same model), nothing derived here.
  let model = vm.panelModel(session)
  VerificationPaneModel(loaded: true, status: model.statusText,
                        command: model.commandLine,
                        runLabel: (if model.canRun: model.runLabel else: ""),
                        stopShown: model.cancellable,
                        lines: model.lines, selectedKey: model.selectedKey)

proc publish*(s: VerificationSource; rt: TuiRuntime) =
  ## Hand the app layer the pane's value; the reading position is the
  ## reader's (the painter clamps it).
  if s.isNil:
    return
  let top = rt.app.verification.scrollTop
  rt.app.verification = paneModelOf(s.host.vm, s.host.session)
  rt.app.verification.scrollTop = top

proc goTo(s: VerificationSource; activation: VerificationActivation;
          result: var VerificationActResult) =
  ## A press's source location, opened in the editor — or why not.
  if activation.kind != vakSource:
    result.note = activation.note
    return
  let found = s.host.resolveSource(activation)
  if not found.ok:
    result.note = found.why
    return
  let why = if s.open.isNil: "this window cannot open files"
            else: s.open(found.path, activation.line, activation.column)
  if why.len > 0:
    result.note = why
  else:
    result.opened = true
    result.note = "opened " & activation.note

proc act(s: VerificationSource; rt: TuiRuntime;
         a: VerificationAct): VerificationActResult =
  let vm = s.host.vm
  let session = s.host.session
  case a.kind
  of vrPress:
    s.goTo(vm.activateLine(session, a.key), result)
  of vrActivate:
    if vm.selectedKey.val.len == 0:
      result.note = "no line of the Verification pane is selected"
    else:
      s.goTo(vm.activateLine(session, vm.selectedKey.val), result)
  of vrRowMenu:
    vm.selectLine(a.key)
    result.menu = verificationRowContextMenuOf(vm, session, a.key)
  of vrMenuChoice:
    let outcome = runVerificationMenu(vm, session, a.action, a.target)
    result.copied = outcome.copied
    if outcome.activation.kind == vakSource:
      s.goTo(outcome.activation, result)
    else:
      result.note = outcome.note
  of vrKey:
    let key =
      case a.operation
      of "list.focus-first": vm.moveSelection(session, -1, toEnd = true)
      of "list.focus-last": vm.moveSelection(session, 1, toEnd = true)
      of "list.focus-page-down": vm.moveSelection(session, max(1, a.page))
      of "list.focus-page-up": vm.moveSelection(session, -max(1, a.page))
      of "list.focus-previous", "editor.scroll-line-up":
        vm.moveSelection(session, -1)
      else: vm.moveSelection(session, 1)
    if key.len == 0:
      result.note = "the Verification pane lists nothing to select"
  of vrRun:
    s.host.refresh(s.root())
    s.rootSeen = s.root()
    result.note = s.host.runVerification()
  of vrStop:
    result.note = s.host.stopVerification()
  s.publish(rt)

proc newVerificationSource*(rt: TuiRuntime; root: proc(): string {.closure.};
                            open: VerificationOpener): VerificationSource =
  ## The window's Verification source, its acts installed on `rt`'s app.
  ## `root` is the window's project (`app.projectRoot`), read at each run.
  result = VerificationSource(host: newNativeVerificationHost(), open: open,
                              root: root)
  let s = result
  s.rootSeen = root()
  s.host.refresh(s.rootSeen)
  rt.app.verificationAct = proc(a: VerificationAct): VerificationActResult =
    s.act(rt, a)
  s.publish(rt)

proc tick*(s: VerificationSource; rt: TuiRuntime): bool =
  ## Follow the run in flight, and a re-rooted project. Whether the pane
  ## changed.
  if s.isNil:
    return false
  if not s.host.running and s.root() != s.rootSeen:
    s.rootSeen = s.root()
    s.host.refresh(s.rootSeen)
    result = true
  let wasRunning = s.host.running
  if s.host.pump():
    result = true
    if wasRunning and not s.host.running:
      rt.app.notification = s.host.vm.statusText.val
  if result:
    s.publish(rt)

proc running*(s: VerificationSource): bool =
  not s.isNil and s.host.running

proc close*(s: VerificationSource) =
  if not s.isNil:
    s.host.finishWait()
