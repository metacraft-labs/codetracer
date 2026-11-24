## views/agent_harbor_control_center_words.nim
##
## The words, roles and rules the three hosts share for the control center
## (the web's `isonim_agent_harbor_control_center_view`, GPUI's
## `gpui/agent_harbor/ah_control_center`, the terminal's
## `tui/agent_harbor/ah_tui_control_center`), over `ControlCenterVM`
## (nim-agents-isonim-viewmodels).
##
## The control center (codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## D24, D64-D74) is a tab titled `Control Center` that fills the window, as
## the Welcome Page does:
##
## - on the left, `LAUNCH`: `New task` and `New initiative` (the mode), what
##   the launch is `For` (no initiative, or one of them: its manager is the
##   destination), the instruction's field, the composer's launch or
##   initiative form and its send line, Agent Harbor's answer to the last
##   launch, and `RECENT LAUNCHES`;
## - on the right, `WAITING FOR YOU` (D73: above the initiatives, as tall
##   as its rows, at most 45%), then the Initiatives panel as it is drawn
##   everywhere else (the same view, unchanged). The waiting list holds the
##   sessions that wait for the operator, in inbox order, one row each: the
##   session, its state word in its role, its initiative and how long it has
##   waited, and the line that says why (the agent's question). Its pie's
##   words are its accessible name; it draws no dot and no pie of its own.
## - Narrow: one column, launching first.
## - While a launch waits for Agent Harbor's answer (`launching`), the form
##   stays drawn and is locked: its toggles and `For` take no press, the
##   field takes no typing, `Launch` is busy and disabled, and `Launching…`
##   stands where the answer will go, in the body role (study D70, D74).
##
## Presses and keys are routed (Input-Routing-And-Keymaps.md §4 and §5.1):
## the control center is the `controlCenter` scope; the mode toggles carry
## `control-center.new-task` / `-new-initiative`, the `For` toggles
## `control-center.launch-for` with the initiative's id (none: empty), a
## waiting row `control-center.open-session` with its session's id, and the
## keys `Down` / `Up` / `Enter` walk and open the waiting rows. The launch
## form is the composer's, in the `composer` scope inside it, with the
## composer's own operations (`agent_harbor_composer_words`).

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/control_center_vm
import nim_agents_isonim_viewmodels/agent_harbor/progress_pie
import ./agent_harbor_composer_words

export control_center_vm, agent_harbor_composer_words, progress_pie

const
  ControlCenterSurface* = "agent-harbor-control-center"
  ControlCenterNewTaskOperation* = "control-center.new-task"
  ControlCenterNewInitiativeOperation* = "control-center.new-initiative"
  ControlCenterLaunchForOperation* = "control-center.launch-for"
  ControlCenterOpenSessionOperation* = "control-center.open-session"
  ControlCenterNextOperation* = "control-center.next"
  ControlCenterPreviousOperation* = "control-center.previous"
  ControlCenterOpenOperation* = "control-center.open"
  ControlCenterOperations* = [ControlCenterNextOperation, ControlCenterPreviousOperation,
                              ControlCenterOpenOperation]
    ## Every operation the control center's keys run.
  ControlCenterPressOperations* = [ControlCenterNewTaskOperation,
                                   ControlCenterNewInitiativeOperation,
                                   ControlCenterLaunchForOperation,
                                   ControlCenterOpenSessionOperation]
    ## Every operation a press on the control center carries (its launch
    ## form's are the composer's).
  LaunchLabel* = "LAUNCH"
  RecentLaunchesLabel* = "RECENT LAUNCHES"
  WaitingLabel* = "WAITING FOR YOU"
    ## The section labels, as the composer's (capitals, the label role).
  ForLabel* = "For"
  InstructionLabel* = "Instruction"
  TaskPlaceholder* = "What the task should do"
  InitiativePlaceholder* = "What the initiative is for"
  LoadingWords* = "Loading the initiatives\xE2\x80\xA6"
  ErrorTitle* = "Could not load the initiatives"
  NarrowBelowCells* = 90
    ## The terminal's narrow width, in cells: the web's and GPUI's 720px at
    ## the terminal's 8px a cell.
  Dot = " \xC2\xB7 "

proc modeChoices*(vm: ControlCenterVM): seq[(LaunchMode, string, string, bool)] =
  ## The two mode toggles: the mode, its label, its operation, pressed.
  let mode = vm.mode
  @[(lmTask, NewTaskLabel, ControlCenterNewTaskOperation, mode == lmTask),
    (lmInitiative, NewInitiativeLabel, ControlCenterNewInitiativeOperation,
     mode == lmInitiative)]

proc instructionPlaceholder*(vm: ControlCenterVM): string =
  if vm.mode == lmInitiative: InitiativePlaceholder else: TaskPlaceholder

proc stateRole*(attention: SessionAttention): string =
  ## A waiting row's state word's role: the warning role for a session on a
  ## question, the caption role for an ended turn (P2a's roles).
  if attention == saNeedsInput: "warning" else: "caption"

proc waitingMetaParts*(row: WaitingRow): tuple[initiative, age: string] =
  ## The row's second part in its two pieces: its initiative (`No
  ## initiative` for a session in none), and how long it has waited, with
  ## the separator before it (` · 12m`; "" when unknown). A host that must
  ## cut the line cuts the initiative and keeps the age.
  result.initiative = if row.item.initiativeTitle.len > 0: row.item.initiativeTitle
                      else: noInitiativeLabel()
  result.age = if row.item.ageLabel.len > 0: Dot & row.item.ageLabel else: ""

proc waitingMeta*(row: WaitingRow): string =
  ## The row's second part: its initiative (`No initiative` for a session in
  ## none) and how long it has waited (`Shield model hardening · 12m`), after
  ## the state word.
  let (initiative, age) = row.waitingMetaParts
  initiative & age

proc waitingWhy*(row: WaitingRow): string =
  ## What the row says it waits for: the agent's last line (its question),
  ## without the speaker's prefix the listing carries.
  var line = row.item.lastActivityLine
  for prefix in ["assistant: ", "agent: "]:
    if line.startsWith(prefix): line = line[prefix.len .. ^1]
  line

proc stateWordOf*(row: WaitingRow): string = attentionWord(row.item.attention)

proc showsLaunchForm*(vm: ControlCenterVM): bool =
  ## The launch or initiative form is drawn: while composing (the
  ## composer's rule), and while a launch waits for its answer, locked
  ## (`launching`), so the operator sees what is being launched.
  vm.composer.showsForm or vm.launching

proc formSummary*(vm: ControlCenterVM): tuple[text: string, problem: bool] =
  ## The launch form folded to one summary, where a host that cannot scroll
  ## has no room for the whole form (study D75): the repository, the branch,
  ## the agents, then only what differs from the form's defaults -- a host
  ## other than the server's choice (`This machine`, or the executor's
  ## name), a place other than a new tab, a schedule -- so the summary says
  ## what the operator chose and stays short enough to sit whole, uncut, over
  ## what follows it (study D84). An initiative: its iterations and plan
  ## file. The form's first problem instead, while it has one.
  let c = vm.composer
  let problems = c.problems
  if problems.len > 0: return (problems[0].text, true)
  if c.intent == riNewInitiative:
    let f = c.initiative
    return ($f.iteration & " iterations" & Dot & c.planPreview, false)
  let o = c.launch
  var parts = @[o.repository]
  if o.branch.len > 0: parts.add o.branch
  parts.add o.agents.join(", ")
  case o.runOn
  of roServerChoice: discard
  of roExecutor: parts.add(if o.executor.len > 0: o.executor else: $o.runOn)
  else: parts.add $o.runOn
  if o.openIn != oiNewTab: parts.add $o.openIn
  if o.schedule.enabled: parts.add c.scheduleSummary.text
  (parts.join(Dot), false)

proc launchSendHint*(vm: ControlCenterVM): tuple[hint, more: string; blocked: bool] =
  ## The send line's hint beside `Launch`: the composer's, except while a
  ## launch waits for its answer, when the line under the form says
  ## `Launching…` and the hint says nothing (one status, not two).
  if vm.launching: ("", "", false) else: vm.composer.sendHint

proc launchSendLabel*(vm: ControlCenterVM): string =
  ## The primary button's label: `Launch` (or `Start initiative`) for what
  ## the form launches, also while that launch waits for its answer (the
  ## composer's own label falls back to `Send` once sent).
  if vm.launching: sendLabel(vm.composer.draft.sentIntent) else: vm.composer.sendLabel

proc breakableWords*(line: string): seq[string] =
  ## `line`'s words as a host may break between them: split at its spaces,
  ## a lone separator (`·`, `—`) kept with the word after it, so a wrapped
  ## line never ends in one (`Plan started on hub-a ·`; review of the
  ## step-4 follow-up, study D74). Joined with single spaces they give the
  ## line back.
  for w in line.splitWhitespace:
    if result.len > 0 and result[^1] in ["\xC2\xB7", "\xE2\x80\x94"]:
      result[^1] = result[^1] & " " & w
    else:
      result.add w

proc noticeRole*(failed: bool): string =
  ## The role of the line under the form: the error role for
  ## `Could not launch: …`; the body role for `Launching…` and for Agent
  ## Harbor's notice (study D74).
  if failed: "error" else: "body"

proc centerFacts*(vm: ControlCenterVM; width: int): seq[(string, string)] =
  ## The facts the control center carries in every host (`data-ah-*`),
  ## read back by the hosts' tests and the play checks.
  let (notice, failed, _) = vm.launchNotice
  @[("surface", ControlCenterSurface), ("cc-state", $vm.state),
    ("cc-columns", $vm.layoutFor(width)), ("cc-mode", $vm.mode),
    ("cc-launch-for", vm.launchForTitle), ("cc-waiting", $vm.waiting.len),
    ("cc-recent", $vm.recent.len), ("cc-notice", notice),
    ("cc-notice-failed", $failed), ("cc-launching", $vm.launching),
    ("cc-empty", $vm.isEmptyFleet)]

proc waitingFacts*(row: WaitingRow; focused: bool): seq[(string, string)] =
  @[("waiting-session", row.item.id), ("waiting-title", row.item.title),
    ("waiting-state", stateWordOf(row)), ("waiting-words", row.words),
    ("waiting-focused", $focused)]

proc recentFacts*(launch: RecentLaunch): seq[(string, string)] =
  @[("recent-launch", launch.text), ("recent-line", recentLine(launch)),
    ("recent-failed", $launch.failed), ("recent-mode", $launch.mode)]

proc runControlCenterOperation*(vm: ControlCenterVM; operation: string): bool =
  ## Runs one of the control center's key operations; false for one that is
  ## not its own.
  case operation
  of ControlCenterNextOperation: vm.moveFocus(1)
  of ControlCenterPreviousOperation: vm.moveFocus(-1)
  of ControlCenterOpenOperation: vm.openFocused()
  else: false

type
  ControlCenterPress* = proc(operation, target: string)
    ## A host's route for a press: the operation the pressed element carries
    ## and its target. The host resolves it through its router and runs what
    ## it resolves to (`runControlCenterPress`).

proc runControlCenterPress*(vm: ControlCenterVM; operation, target: string): bool =
  ## Runs the operation a press resolved to, on `target`: the mode, the
  ## initiative a launch is for ("" for none), opening a waiting session; the
  ## launch form's presses are the composer's (`runComposerPress`, on
  ## `vm.composer`); or any of the keys' operations. False for an operation
  ## that is neither the control center's nor the composer's.
  if vm.isNil: return false
  case operation
  of ControlCenterNewTaskOperation:
    vm.newTask()
    true
  of ControlCenterNewInitiativeOperation:
    vm.newInitiative()
    true
  of ControlCenterLaunchForOperation:
    vm.chooseInitiative(target)
    true
  of ControlCenterOpenSessionOperation:
    if target.len == 0: return false
    vm.openSession(target)
    true
  else:
    if vm.runControlCenterOperation(operation): return true
    vm.composer.runComposerPress(operation, target)
