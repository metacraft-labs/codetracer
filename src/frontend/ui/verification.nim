## Verification Panel — a Verno run, and the counterexample it produced.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the only renderer.
##
## There is no legacy Karax `method render` here and there never was one: this
## panel is VN-M3/VN-M5 work, built on the ViewModel layer from the start. The
## `VerificationComponent` exists purely as the GoldenLayout carrier — it gives
## the panel a `Content` identity, a container id and a place on the event bus.
##
## Lifecycle:
## 1. ``utils.nim::makeVerificationComponent`` constructs the legacy
##    ``VerificationComponent`` and registers it under ``Content.Verification``.
## 2. GoldenLayout's component factory creates the
##    ``verificationComponent-{id}`` container and the panel host
##    (``ui/panel_host``) mounts the pane into it, with the renderer this
##    module registers: ``renderVerificationPane``, the run and then the
##    counterexample, each in a host rebuilt by its own effect.
## 3. Nothing installs a shared store: neither VM has one. `VerificationVM` is
##    pushed at by this module's host (below: the project's declared Verno
##    action, run by the main process) and pulls at `verification_report`,
##    which is pure; `CounterexampleSessionVM` reads only the payload the run
##    attached. They are this module's, not the session's, so the pane keeps
##    one run across trace switches.
## ---------------------------------------------------------------------------
##
## ## Why the counterexample is not a `Content` of its own
##
## Because it would then be a thing a user can open when there is nothing to
## open. The counterexample region of this panel exists only while a session is
## open, and a session opens only from a finding whose payload carries a model
## with steps in it (`canOpenCounterexample`). A menu entry, a palette row or a
## restorable tab for it would be a standing affordance for something that is
## usually absent — which is the promise VN-M3's whole text tier was designed
## not to make, and which VN-M5 has no reason to start making.
##
## So the reachable surface is exactly one entry: **View ▸ Verification**. What
## the developer sees there depends only on what the run produced.
##
## **On macOS that entry is reachable through the command palette, not the
## menu, and the difference is not ours.** `electron_profile.nim` gives darwin
## `capNativeMenuBar`, so `topbar_actions` withholds `tbaInPageMenu` and
## `menu.nim` suppresses the in-page HTML menu; the *native* menu is only
## registered under `-d:ctmacos`, which the nix/reprobuild build path never
## passes (`repro.nim`'s `RendererDefines` is `chronicles_enabled=off` +
## `ctRenderer`). The palette is unaffected: `ui_js.nim` builds its command list
## from `getCommands(data.ui.menuNode)` — the same tree — whether or not that
## tree is rendered. So one `element` declaration buys the menu on Linux and
## Windows and the palette everywhere, and a UI test that drives the *menu* must
## skip darwin the way `welcome-screen/launch_config.spec.ts` already does.
##
## ## Where it is run
##
## The registration below is compiled by the `renderer-electron` lane (`nim js
## -d:ctRenderer src/frontend/ui_js.nim`). The panel's behaviour is asserted
## headlessly in `viewmodel/tests/unit/test_counterexample_session.nim` and
## `test_plat63_verification_vm.nim` against the same views this file mounts;
## the mount and the host (the task file read, Run, the live run in the main
## process, Stop, the report read at the end) are driven in the real Electron
## app by `src/tests/gui/tests/verification-pane/desktop_verno_run.spec.ts`.

import
  ui_imports,
  ../[ types, communication ]

from isonim/web/dom_api import nil
import isonim/web/web_renderer
import ./panel_host
import ../viewmodel/input/dom_pointer
from ../viewmodel/session_vm import SessionViewModel
import std/options
import ../viewmodel/viewmodels/verification_vm
from ../viewmodel/viewmodels/project_actions import ProjectAction,
  TasksJsonNames, PackageJsonName, collectProjectActions, launchArgv
from ../viewmodel/viewmodels/verification_payload import PayloadFileName,
  PayloadDirectoryNames
from ../lib/electron_presence import inElectron
from ./errors import desktopResolvedPath
from ../event_helpers import warnMessage
from ../viewmodel/viewmodels/counterexample_session_vm import
  CounterexampleSessionVM, createCounterexampleSessionVM, close
import ../viewmodel/views/isonim_verification_view

var verificationVMInstance*: VerificationVM
var counterexampleVMInstance*: CounterexampleSessionVM

proc initVerificationVM*() =
  ## Bring both VMs up if they are not already.
  ##
  ## **The two are created together and live as long as the panel does.** The
  ## session VM is not created per counterexample: `openCounterexample` is what
  ## fills it, and `close` is what empties it, so "is a counterexample open" is
  ## a property of its `isOpen` signal rather than of whether an object exists.
  ## A VM created on demand would make "no session" and "a session that failed
  ## to open" the same state, which is the distinction
  ## `CounterexampleSessionVM.refusalReason` exists to keep.
  if verificationVMInstance.isNil:
    verificationVMInstance = createVerificationVM()
  if counterexampleVMInstance.isNil:
    counterexampleVMInstance = createCounterexampleSessionVM()

# ---------------------------------------------------------------------------
# The desktop's host: the project's declared Verno action, run by the main
# process (`index/verification_runner`), pushed into the window's VM exactly
# as the native host (`host/native_verification_host` over
# `host/project_action_runner`) pushes into theirs.
# ---------------------------------------------------------------------------
#
# The renderer reads what the project declares (its task files, through the
# same pure `collectProjectActions` / `vernoActions`), offers the first Verno
# action's label (`offerRun`, which is what draws the shared Run control),
# and on Run sends the action's argv (`launchArgv`) and working directory to
# the main process. The main process streams the output back line by line
# and reports the exit; the structured report is read only then, by VN-M4's
# rule, from where the discovery convention puts it
# (`<cwd>/target/verno-report.json`), and handed to `finish` with the time
# this run started, so an earlier run's report is refused as stale.
#
# A browser tab has no main process to run anything, so it offers no run.

proc nodeReadText(path: cstring): JsObject {.importjs: """(function(p) {
  try { return {ok: true, text: require('fs').readFileSync(p, 'utf8')}; }
  catch (e) { return {ok: false, text: ''}; } })(#)""".}

proc nodeDirExists(path: cstring): bool {.importjs: """(function(p) {
  try { return require('fs').statSync(p).isDirectory(); }
  catch (e) { return false; } })(#)""".}

proc nodeJoin(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc nodeIsAbsolute(p: cstring): bool {.importjs: "require('path').isAbsolute(#)".}
proc onWindows(): bool {.importjs:
  "(typeof process !== 'undefined' && process.platform === 'win32')".}
proc nowMs(): float {.importjs: "Date.now()".}
proc clearIntervalJs(id: int) {.importjs: "clearInterval(#)".}

proc readIfPresent(path: string): string =
  ## The file's text, or "" when it is absent or unreadable — the native
  ## runner's rule (an unreadable report says nothing; the text tier stands).
  let read = nodeReadText(cstring(path))
  if read["ok"].to(bool): $read["text"].to(cstring) else: ""

type
  DesktopVerificationRun = object
    active: bool
    cancelling: bool
    action: ProjectAction
    projectRoot: string
    cwd: string
    startedAtUnixMs: int64
    stdout, stderr: string
    clock: int

var desktopAction: Option[ProjectAction]
var desktopProjectRoot = ""
var desktopRun: DesktopVerificationRun

proc verificationProjectRoot(): string =
  ## The window's project: the folder it was opened on (Edit mode, or a
  ## replay started from one).
  if data.isNil or data.startOptions.folder.isNil: ""
  else: $data.startOptions.folder

proc actionWorkingDirectory(action: ProjectAction; projectRoot: string): string =
  ## `project_action_runner.workingDirectory`'s rule: a task's `options.cwd`,
  ## taken relative to the project root when it is relative.
  if action.cwd.len == 0: projectRoot
  elif nodeIsAbsolute(cstring(action.cwd)): action.cwd
  else: $nodeJoin(cstring(projectRoot), cstring(action.cwd))

proc refreshDesktopVerification() =
  ## Read what the window's project declares and offer its Verno action. A
  ## run in flight keeps its own project.
  initVerificationVM()
  if desktopRun.active or not inElectron:
    return
  let vm = verificationVMInstance
  let root = verificationProjectRoot()
  desktopProjectRoot = root
  if root.len == 0 or not nodeDirExists(cstring(root)):
    desktopAction = none(ProjectAction)
    vm.offerRun("", NoProjectReason)
    return
  var tasks = ""
  for name in TasksJsonNames:
    # The first that EXISTS, as `project_action_runner.tasksJsonPath` picks.
    let read = nodeReadText(nodeJoin(cstring(root), cstring(name)))
    if read["ok"].to(bool):
      tasks = $read["text"].to(cstring)
      break
  let actions = vernoActions(collectProjectActions(
    tasks, readIfPresent($nodeJoin(cstring(root), cstring(PackageJsonName)))))
  if actions.len == 0:
    desktopAction = none(ProjectAction)
    vm.offerRun("", NoVernoActionReason)
  else:
    desktopAction = some(actions[0])
    vm.offerRun(actions[0].label)

proc stopClock() =
  if desktopRun.clock != 0:
    clearIntervalJs(desktopRun.clock)
    desktopRun.clock = 0

proc elapsedNow(): int =
  max(0, int(nowMs() - float(desktopRun.startedAtUnixMs)))

proc runDesktopVerification(): string =
  ## Run's press: start the project's Verno action. The words a status line
  ## would show (the native host's).
  initVerificationVM()
  let vm = verificationVMInstance
  if desktopRun.active:
    return "a verification run is already in flight; Stop it first"
  refreshDesktopVerification()
  if desktopAction.isNone:
    return (if vm.runUnavailableReason.val.len > 0: vm.runUnavailableReason.val
            else: NoVernoActionReason)
  counterexampleVMInstance.close()
  let action = desktopAction.get
  let cwd = actionWorkingDirectory(action, desktopProjectRoot)
  vm.start(action, projectRoot = desktopProjectRoot)
  desktopRun = DesktopVerificationRun(active: true, action: action,
    projectRoot: desktopProjectRoot, cwd: cwd,
    # Recorded *before* the launch, so it can only be earlier than the
    # producer's own start, never later (`attachPayload`'s tolerance).
    startedAtUnixMs: int64(nowMs()))
  var argv: seq[cstring] = @[]
  for arg in launchArgv(action, windows = onWindows()):
    argv.add cstring(arg)
  data.ipc.send cstring"CODETRACER::verification-start",
    js{argv: argv.toJs, cwd: cstring(cwd)}
  desktopRun.clock = windowSetInterval(proc() =
    if desktopRun.active:
      vm.noteElapsed(elapsedNow()), 1000)
  "verifying: " & vm.commandLine.val

proc stopDesktopVerification(): string =
  ## Stop's press: no outcome, by VN-M3's rule.
  if not desktopRun.active:
    return "no verification run is in flight"
  desktopRun.cancelling = true
  verificationVMInstance.requestCancel()
  data.ipc.send cstring"CODETRACER::verification-cancel", js{}
  "stopping " & verificationVMInstance.actionLabel.val & " …"

proc noteDesktopVerificationRunning*() =
  ## `CODETRACER::verification-running`: the process exists.
  if desktopRun.active:
    verificationVMInstance.noteRunning()

proc noteDesktopVerificationOutput*(stream, text: string) =
  ## `CODETRACER::verification-output`: whole lines of one stream. Stdout's
  ## lines are the pane's "last output line", as on the native hosts; both
  ## streams are kept for the classifier.
  if not desktopRun.active:
    return
  if stream == "stderr":
    desktopRun.stderr.add text
    return
  desktopRun.stdout.add text
  for line in text.splitLines:
    if line.strip().len > 0:
      verificationVMInstance.noteOutput(line)

proc settleDesktopVerification*(exitCode: Option[int]; cancelled: bool) =
  ## `CODETRACER::verification-exit`: the process is gone. Hand the whole
  ## output to the classifier, with the report the run left (read now).
  if not desktopRun.active:
    return
  stopClock()
  let vm = verificationVMInstance
  let run = desktopRun
  desktopRun.active = false
  vm.noteElapsed(elapsedNow())
  if run.cancelling or cancelled:
    vm.noteCancelled()
  else:
    let output =
      if run.stderr.len == 0: run.stdout
      elif run.stdout.len == 0: run.stderr
      else: run.stdout & run.stderr
    var payloadText = ""
    for directory in PayloadDirectoryNames:
      payloadText = readIfPresent($nodeJoin(nodeJoin(cstring(run.cwd),
        cstring(directory)), cstring(PayloadFileName)))
      if payloadText.len > 0:
        break
    vm.finish(output, exitCode, timedOut = false, payloadText = payloadText,
              runStartedAtUnixMs = run.startedAtUnixMs)
  refreshDesktopVerification()

proc failDesktopVerification*(reason: string) =
  ## `CODETRACER::verification-failed-to-start`: nothing ran.
  if not desktopRun.active:
    return
  stopClock()
  desktopRun.active = false
  verificationVMInstance.noteFailedToStart(reason)
  refreshDesktopVerification()

verificationRunRequest = proc() = discard runDesktopVerification()
verificationStopRequest = proc() = discard stopDesktopVerification()

# PLAT-63: a press on a finding (or Go to Source in its menu) opens the
# finding's file at its line in the editor — the Problems pane's opener. The
# view hands the verifier's spelling's candidates (`sourceCandidates`: the
# payload spells a file from the package root, the text tier from its
# parent); the first that exists is opened, as the native host's
# `resolveSource` does, and the window says so when none does.
proc nodeFileExists(path: cstring): bool {.importjs: """(function(p) {
  try { return require('fs').statSync(p).isFile(); }
  catch (e) { return false; } })(#)""".}

verificationSourceOpener = proc(activation: VerificationActivation;
                                candidates: seq[string]) =
  for candidate in candidates:
    let path = desktopResolvedPath(candidate)
    if nodeFileExists(cstring(path)):
      discard data.openLocation(cstring(path), activation.line,
                                activation.column)
      return
  let root = verificationVMInstance.projectRoot.val
  data.viewsApi.warnMessage(cstring(activation.file & " is not in " &
    (if root.len > 0: root else: "the project")))

# The panel host mounts the pane into the container GoldenLayout creates.
setPanelRenderer(Content.Verification,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    initVerificationVM()
    refreshDesktopVerification()
    renderVerificationPane[WebRenderer, dom_api.Element](r,
      verificationVMInstance, counterexampleVMInstance))

method register*(self: VerificationComponent, api: MediatorWithSubscribers) =
  ## No subscriptions: the VMs are pushed at by this module's host.
  self.api = api
  initVerificationVM()

# A press on a finding goes to its source (K64): the pointer row
# `verification.go-to-source`, performed on the row the key router's hit test
# found (`input/dom_pointer`), by the pane's own activation.
registerElementOperation("verification.go-to-source", proc(p: ElementPress): bool =
  let key = attributeOf(p.element, "data-ct-verification-key")
  if key.len == 0:
    return false
  initVerificationVM()
  verificationHandlersFor(verificationVMInstance,
                          counterexampleVMInstance).onActivate(key)
  true)
