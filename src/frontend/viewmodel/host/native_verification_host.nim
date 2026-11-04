## host/native_verification_host.nim — PLAT-63. **The Verification pane's
## host for the native front-ends**: the window's `VerificationVM` and
## `CounterexampleSessionVM`, and the run that fills them.
##
## The desktop keeps one pair per window (`ui/verification.nim`) because a
## run outlives any one trace tab; the terminal and the GPUI window keep one
## here, for the same reason, and both draw the pair through the shared
## pane model (`VerificationVM.panelModel`, `lines`, `rowMenu`).
##
## What it does, and nothing else:
##
## * **finds the run the project declares** — `project_action_runner.
##   loadProjectActions` over the window's project, `vernoActions` of it —
##   and offers it to the pane (`VerificationVM.offerRun`), or says why there
##   is none. Nothing is synthesised: a project that declares no Verno action
##   offers no run (Noir-Studio.md §9.3, VN-M3's rule);
## * **runs it** through VN-M3's runner (`startAction` / `pump` /
##   `cancelAction`) — non-blocking, polled from the window's own loop, so a
##   four-minute solve leaves the window live and the Stop control reachable;
##   the structured report is read at the end, by VN-M4's rule;
## * **finds a finding's file** on disk: the verifier spells it relative to
##   different roots in its two tiers (`VerificationVM.sourceCandidates`), and
##   only a host can look.
##
## The desktop's renderer has no process launcher, so the desktop pane draws
## no Run control (`VerificationPanelModel.canRun`); see the milestone's note.

import std/[options, os]

import isonim/core/[signals, computation]

import ../viewmodels/project_actions
import ../viewmodels/verification_vm
import ../viewmodels/counterexample_session_vm
import ./project_action_runner

export verification_vm, counterexample_session_vm

const
  NoVernoActionReason* =
    "this project declares no Verno action (.vscode/tasks.json or " &
    "package.json)"
  NoProjectReason* = "this window has no project to verify"

type
  NativeVerificationHost* = ref object
    vm*: VerificationVM
    session*: CounterexampleSessionVM
    projectRoot*: string
    action*: Option[ProjectAction]
      ## The project's first declared Verno action, when there is one.
    run: ProjectActionRun
    running: bool

proc newNativeVerificationHost*(): NativeVerificationHost =
  NativeVerificationHost(vm: createVerificationVM(),
                         session: createCounterexampleSessionVM())

proc running*(h: NativeVerificationHost): bool =
  not h.isNil and h.running

proc refresh*(h: NativeVerificationHost; projectRoot: string) =
  ## Read what `projectRoot` declares and offer its Verno action. A run in
  ## flight keeps its own project.
  if h.isNil:
    return
  h.projectRoot = projectRoot
  if projectRoot.len == 0 or not dirExists(projectRoot):
    h.action = none(ProjectAction)
    h.vm.offerRun("", NoProjectReason)
    return
  let actions = vernoActions(loadProjectActions(projectRoot))
  if actions.len == 0:
    h.action = none(ProjectAction)
    h.vm.offerRun("", NoVernoActionReason)
  else:
    h.action = some(actions[0])
    h.vm.offerRun(actions[0].label)

proc runVerification*(h: NativeVerificationHost): string =
  ## Start the project's Verno action. The words the status line shows.
  if h.isNil:
    return NoProjectReason
  if h.running:
    # The FIELD (this module sees it); `h` is not nil here.
    return "a verification run is already in flight; Stop it first"
  if h.action.isNone:
    return (if h.vm.runUnavailableReason.val.len > 0:
              h.vm.runUnavailableReason.val
            else: NoVernoActionReason)
  h.session.close()
  h.run = startAction(h.vm, h.action.get, h.projectRoot)
  h.running = h.run.active
  if h.running: "verifying: " & h.vm.commandLine.val
  else: h.vm.statusText.val

proc stopVerification*(h: NativeVerificationHost): string =
  ## Stop the run in flight: no outcome, by VN-M3's rule.
  if h.isNil or not h.running:
    return "no verification run is in flight"
  cancelAction(h.vm, h.run)
  "stopping " & h.vm.actionLabel.val & " …"

proc pump*(h: NativeVerificationHost): bool =
  ## Advance the run in flight. Whether anything the pane draws changed —
  ## a run keeps changing (its clock) until it settles.
  if h.isNil or not h.running:
    return false
  if pump(h.vm, h.run):
    h.running = false
  true

proc finishWait*(h: NativeVerificationHost; budgetMs = 5000) =
  ## The window ends: a run still going is stopped and polled until its
  ## process is gone (or `budgetMs` passes). A window that never made the
  ## host (it ended before drawing) has nothing to stop.
  if h.isNil or not h.running:
    return
  discard h.stopVerification()
  var waited = 0
  while h.running and waited < budgetMs:
    discard h.pump()
    sleep(20)
    waited += 20

proc resolveSource*(h: NativeVerificationHost;
                    activation: VerificationActivation):
                    tuple[ok: bool, path, why: string] =
  ## The file a press leads to, on disk: the first of the verifier's
  ## spelling's candidates that exists, or why none does.
  if activation.kind != vakSource:
    return (false, "", activation.note)
  for candidate in h.vm.sourceCandidates(activation.file):
    if fileExists(candidate):
      return (true, candidate, "")
  (false, "", activation.file & " is not in " &
              (if h.vm.projectRoot.val.len > 0: h.vm.projectRoot.val
               else: "the project"))
