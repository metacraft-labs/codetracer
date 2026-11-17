## views/agent_harbor_activity_words.nim
##
## What every host's session activity timeline draws besides the lines the
## viewmodel publishes (`SessionTimelineVM.lines`): the words of its chrome
## (the `Running: <command>` strip, the `N new · Jump to latest` chip, the
## filter's count), which lines wrap and which are cut, how a line that names
## a file splits into its words and its path, which drawn line shows the
## running command, and what each of the timeline's keys does.
##
## ## Why this module exists
##
## The web (`isonim_agent_harbor_session_activity_view.nim`), GPUI
## (`gpui/agent_harbor/ah_session_activity.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_session_activity.nim`) draw the same viewmodel,
## and must decide these things alike. As with `agent_harbor_words`, the
## rules live in a module that renders nothing and imports no renderer, so
## each host imports it without the others' rendering code.
##
## ## The keys
##
## The timeline's keys are keymap rows (`overlay_rows`, the table
## `SessionActivityTable`), never a `case` over key names in a view
## (Input-Routing §4.3): `Right` opens the focused line, `Left` closes it (or,
## on a closed line, moves the focus to the line that holds it), `Enter`
## steps in, `+` and `-` open every group and close everything, and `Down`
## and `Up` move the focus. A host routes a key through its router and hands
## the operation it resolves to `runActivityOperation`.
##
## ## The presses
##
## A press is routed too (Input-Routing §5.1). A view draws, on each element
## a press acts on, the operation it carries (`data-ct-operation`): a line
## that opens carries `session-activity.toggle`, a detail's Copy
## `session-activity.copy`, the unseen chip `session-activity.jump-to-latest`
## and the error block's Retry `session-activity.retry`; and what the press
## acts on (`PressTargetAttribute`: the line's id, the text Copy copies). The
## host's hit test hands both to its router (`element_press`), and the
## operation it resolves, with the target, to `runActivityPress`. A view
## holds no handler that decides what a press does.

import std/strutils

import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm

export session_timeline_vm

const
  ActivityOpenOperation* = "session-activity.open"
  ActivityCloseOperation* = "session-activity.close"
  ActivityStepInOperation* = "session-activity.step-in"
  ActivityExpandAllOperation* = "session-activity.expand-all"
  ActivityCollapseAllOperation* = "session-activity.collapse-all"
  ActivityFocusNextOperation* = "session-activity.focus-next"
  ActivityFocusPreviousOperation* = "session-activity.focus-previous"
  ActivityToggleOperation* = "session-activity.toggle"
  ActivityCopyOperation* = "session-activity.copy"
  ActivityJumpOperation* = "session-activity.jump-to-latest"
  ActivityRetryOperation* = "session-activity.retry"
  ActivityOperations* = [ActivityOpenOperation, ActivityCloseOperation,
                         ActivityStepInOperation, ActivityExpandAllOperation,
                         ActivityCollapseAllOperation, ActivityFocusNextOperation,
                         ActivityFocusPreviousOperation]
    ## Every operation the timeline's keys run (`operation_catalogue`).
  ActivityPressOperations* = [ActivityToggleOperation, ActivityCopyOperation,
                              ActivityJumpOperation, ActivityRetryOperation]
    ## Every operation a press on the timeline carries.
  PressTargetAttribute* = "data-ah-target"
    ## What a press on an element acts on: a line's id, or the text a
    ## detail's Copy copies.

  RunningPrefix* = "Running: "
    ## The strip that names the running command while its line is out of
    ## view (`runningStripText`).
  CopyLabel* = "Copy"
    ## A level-2 detail's copy action.
  ProseKinds = ["operator", "agent", "question", "failure", "completed",
                "cancelled"]
    ## Item kinds whose line is the operator's or the agent's own words.

proc runActivityOperation*(vm: SessionTimelineVM; operation: string): bool =
  ## Runs one of the timeline's operations on `vm` (its keys resolve to
  ## these); false for an operation that is not the timeline's.
  case operation
  of ActivityOpenOperation:
    for line in vm.lines:
      if line.focused and line.expandable and not line.expanded:
        vm.toggle(line.id)
    true
  of ActivityCloseOperation:
    var done = false
    for line in vm.lines:
      if line.focused and line.expanded:
        vm.toggle(line.id)
        done = true
    if not done: vm.stepOut()
    true
  of ActivityStepInOperation:
    vm.stepIn()
    true
  of ActivityExpandAllOperation:
    vm.expandAll()
    true
  of ActivityCollapseAllOperation:
    vm.collapseAll()
    true
  of ActivityFocusNextOperation:
    vm.focusNext()
    true
  of ActivityFocusPreviousOperation:
    vm.focusPrev()
    true
  else: false

type
  ActivityPress* = proc(operation, target: string)
    ## A host's route for a press: the operation the pressed element carries
    ## and its target (`PressTargetAttribute`). The host resolves it through
    ## its router and runs what it resolves to (`runActivityPress`).

proc runActivityPress*(vm: SessionTimelineVM; operation, target: string;
                       copy: proc(text: string) = nil): bool =
  ## Runs the operation a press resolved to, on `target`: opening or closing
  ## a line (and focusing it), copying a detail's text through the host's
  ## `copy`, jumping to the latest line, loading again; or any of the keys'
  ## operations. False for an operation that is not the timeline's.
  case operation
  of ActivityToggleOperation:
    if target.len == 0: return false
    vm.setFocus(target)
    vm.toggle(target)
    true
  of ActivityCopyOperation:
    if copy != nil: copy(target)
    true
  of ActivityJumpOperation:
    vm.jumpToLatest()
    true
  of ActivityRetryOperation:
    vm.load()
    true
  else: vm.runActivityOperation(operation)

proc isProse*(line: TimelineLine): bool =
  ## Whether a line wraps (the operator's and the agent's words, a question,
  ## a failure's reason, a detail, a trace's lines) rather than being cut
  ## to one line with "…" (a summary, a command, a path, a status).
  line.kind in {tlkDetail, tlkTraceLine} or
    (line.kind in {tlkItem, tlkTurn} and line.itemKind in ProseKinds)

proc isMono*(role: string): bool =
  ## A part set in the monospace face: a command's output, a diff, a trace.
  role == "mono"

proc pathWords*(line: TimelineLine): string =
  ## The words before a line's path (`Read `, `Edited `), or the whole first
  ## part when the line names no path.
  if line.parts.len == 0: return ""
  if line.path.len == 0: return line.parts[0].text
  let first = line.parts[0].text
  first[0 ..< first.len - line.path.len]

proc runningStripText*(vm: SessionTimelineVM): string =
  ## `Running: <command>` for the newest running command, "" when none runs.
  let item = vm.runningLine
  if item.id.len == 0: return ""
  RunningPrefix & (if item.command.len > 0: item.command else: item.line)

proc runningLineId*(lines: openArray[TimelineLine]; running: TimelineItem): string =
  ## The drawn line that shows the running command: its own line when it is
  ## drawn (an open group's item), else the group line that names it, "" when
  ## none runs or the filter hides it.
  if running.id.len == 0: return ""
  for line in lines:
    if line.id == running.id: return line.id
  for line in lines:
    if line.kind == tlkGroup and line.running > 0:
      for part in line.parts:
        if part.role == "running" and part.text == running.line: return line.id
  ""

proc unseenChipText*(unseen: int): string =
  ## `3 new · Jump to latest`.
  $unseen & " new \xC2\xB7 Jump to latest"

proc showsUnseenChip*(vm: SessionTimelineVM): bool =
  ## The chip shows while the reader does not follow and items arrived.
  not vm.follow.val and vm.unseen.val > 0

proc filterCountText*(vm: SessionTimelineVM): string =
  ## The filter's count beside its query: `2 lines match`, `No line matches`.
  let n = vm.matchCount
  if n == 0: "No line matches"
  elif n == 1: "1 line matches"
  else: $n & " lines match"

proc turnGlyph*(): string = "\xE2\x80\xBA"
  ## `›`, before an operator's message (a turn's first line).

proc lineFacts*(line: TimelineLine): seq[(string, string)] =
  ## The facts every host tags a drawn line with (`data-ah-*`), read back by
  ## the hosts' tests: its id, kind, level, item kind, state, text, and its
  ## open, focused and group counts.
  result = @[("line", line.id), ("line-kind", $line.kind),
             ("level", $line.level), ("indent", $line.indent),
             ("text", line.text), ("role", line.textRole)]
  if line.itemKind.len > 0: result.add ("item-kind", line.itemKind)
  if line.state != tisNone: result.add ("state", $line.state)
  if line.expandable: result.add ("expanded", $line.expanded)
  if line.focused: result.add ("focused", "true")
  if line.kind == tlkGroup:
    result.add ("count", $line.count)
    result.add ("failed", $line.failed)
    result.add ("running", $line.running)
  if line.path.len > 0: result.add ("path", line.path)
  if line.copyText.len > 0: result.add ("copy", line.copyText)

proc partsAfterFirst*(line: TimelineLine): seq[LinePart] =
  ## A line's parts after its first, those with text.
  for i in 1 ..< line.parts.len:
    if line.parts[i].text.strip.len > 0: result.add line.parts[i]
