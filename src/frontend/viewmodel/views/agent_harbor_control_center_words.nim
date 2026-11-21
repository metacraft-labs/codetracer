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

proc waitingMeta*(row: WaitingRow): string =
  ## The row's second part: its initiative (`No initiative` for a session in
  ## none) and how long it has waited (`Shield model hardening · 12m`), after
  ## the state word.
  var parts: seq[string]
  parts.add(if row.item.initiativeTitle.len > 0: row.item.initiativeTitle
            else: noInitiativeLabel())
  if row.item.ageLabel.len > 0: parts.add row.item.ageLabel
  parts.join(Dot)

proc waitingWhy*(row: WaitingRow): string =
  ## What the row says it waits for: the agent's last line (its question),
  ## without the speaker's prefix the listing carries.
  var line = row.item.lastActivityLine
  for prefix in ["assistant: ", "agent: "]:
    if line.startsWith(prefix): line = line[prefix.len .. ^1]
  line

proc stateWordOf*(row: WaitingRow): string = attentionWord(row.item.attention)

proc centerFacts*(vm: ControlCenterVM; width: int): seq[(string, string)] =
  ## The facts the control center carries in every host (`data-ah-*`),
  ## read back by the hosts' tests and the play checks.
  let (notice, failed, _) = vm.launchNotice
  @[("surface", ControlCenterSurface), ("cc-state", $vm.state),
    ("cc-columns", $vm.layoutFor(width)), ("cc-mode", $vm.mode),
    ("cc-launch-for", vm.launchForTitle), ("cc-waiting", $vm.waiting.len),
    ("cc-recent", $vm.recent.len), ("cc-notice", notice),
    ("cc-notice-failed", $failed), ("cc-empty", $vm.isEmptyFleet)]

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
