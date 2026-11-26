## viewmodels/agent_activity_feed.nim
##
## **The Agent Activity panel's conversation as rows** — the one model the
## terminal pane and the GPUI leaf draw, built from `AgentActivityVM` with the
## desktop's own words and decisions (`agent_activity_text.nim`).
##
## The desktop's panel (`views/isonim_agent_activity_view.nim`) walks the same
## ViewModel and emits DOM: a session notice, then for each message either an
## AA-2 test-run card, an AA-3 evidence card or the message itself (a user
## line, or an agent turn: its header, its segments with tool-call groups, the
## promoted final text, "Agent is working", the changed files), then the agent
## terminals and the password / permission prompts — or, with nothing at all,
## the idle state. `agentFeed` walks it in that order and yields one
## `AgentFeedRow` per thing the desktop draws on a line of its own, each with
## the action a press on it runs; nothing in a native view decides what a row
## says or does.
##
## A native view then needs only two more answers, both here so the two native
## front-ends agree:
##
##   * `wrapFeed` — the rows broken into the lines a pane of a given width
##     shows (a measure proc supplied by the front-end: cells or pixels);
##   * `FeedScroll` — where the reader is, kept across a re-derived feed:
##     following the end while rows arrive, or held on the row it was on
##     (PLAT-54 deliverable 3, "rows arrive while the agent runs, without
##     losing the reader's scroll position").

import std/[options, sequtils, strutils, unicode]

import isonim/core/signals

import nim_agents/activity_feed
import ../store/types
import agent_activity_vm, agent_activity_text, evidence_call_vm

export agent_activity_text, activity_feed

# The row, span and action types, `addUserMessage`, `addEvidence`, `wrapFeed`
# and `FeedScroll` live in `nim_agents/activity_feed` (CTF-M1); this module
# derives the rows from `AgentActivityVM` and runs a row's press.

proc addAgentMessage(rows: var seq[AgentFeedRow]; vm: AgentActivityVM;
                     message: AgentActivityMessageEntry) =
  let groups = computeSegGroups(message.segments)
  let final = finalTurnText(message, groups)
  let label = thoughtHeaderLabel(message)
  let collapsedByDefault = startsCollapsed(message, groups)
  let collapsed = collapsedByDefault xor vm.isThoughtToggled(message.id)
  var header = AgentFeedRow(kind: frAgentHeader, key: message.id & "/h",
                            messageId: message.id,
                            state: (if message.failed: "failed"
                                    elif message.isLoading: "running"
                                    else: "done"),
                            press: AgentFeedAction(kind: faToggleThought))
  header.spans.add span(expansionGlyph(not collapsed), fsMuted)
  if label.len > 0 or message.canceled:
    header.spans.add span(" " & label, fsHeading)
    if message.canceled:
      header.spans.add span(canceledSuffix(label), fsMuted)
  if message.failed:
    header.spans.add span(" " & AgentFailedIcon, fsError)
  let clock = wallClockTime(message.createdAt)
  if clock.len > 0:
    header.spans.add span("  " & clock, fsMuted)
  rows.add header
  if message.failed:
    rows.add AgentFeedRow(kind: frTurnError, key: message.id & "/err",
                          messageId: message.id, indent: 1,
                          spans: @[span(turnFailureText(message), fsError)])
  if not collapsed:
    if groups.len > 0:
      for gi, grp in groups:
        if final.groupIndex >= 0 and gi == final.groupIndex:
          continue
        if not grp.isTools:
          rows.addMarkup(AgentFeedRow(messageId: message.id, indent: 1),
                         message.id & "/g" & $gi, grp.content)
        else:
          let expanded = vm.isToolHistoryExpanded(message.id, gi)
          if grp.tools.len > 1:
            if expanded:
              for ti in 0 ..< grp.tools.len - 1:
                let tc = grp.tools[ti]
                rows.add AgentFeedRow(
                  kind: frToolCall, key: message.id & "/g" & $gi & "/" & $ti,
                  messageId: message.id, indent: 2,
                  state: $toolState(tc.toolStatus),
                  spans: @[span(tc.toolName)])
            rows.add AgentFeedRow(
              kind: frToolsToggle, key: message.id & "/g" & $gi & "/toggle",
              messageId: message.id, indent: 1,
              state: (if expanded: "expanded" else: "collapsed"),
              press: AgentFeedAction(kind: faToggleToolHistory, group: gi),
              spans: @[span(expansionGlyph(expanded) & " " &
                            toolsUsedText(grp.tools.len), fsMuted)])
          let current = grp.tools[^1]
          rows.add AgentFeedRow(
            kind: frToolCall, key: message.id & "/g" & $gi & "/current",
            messageId: message.id, indent: 1,
            state: $toolState(current.toolStatus),
            spans: @[span(current.toolName)])
    else:
      rows.addMarkup(AgentFeedRow(messageId: message.id, indent: 1),
                     message.id & "/t", message.content)
  if final.text.len > 0:
    rows.addMarkup(AgentFeedRow(messageId: message.id, indent: 1),
                   message.id & "/final", final.text)
  for i, _ in message.images:
    rows.add AgentFeedRow(kind: frImage, key: message.id & "/img" & $i,
                          messageId: message.id, indent: 1,
                          spans: @[span("[image: agent image]", fsMuted)])
  if message.showsWorking:
    rows.add AgentFeedRow(kind: frWorking, key: message.id & "/working",
                          messageId: message.id, indent: 1,
                          spans: @[span(AgentWorkingText, fsMuted)])
  if message.diffs.len > 0 and not message.isLoading:
    rows.add AgentFeedRow(
      kind: frDiffHeader, key: message.id & "/diffs", messageId: message.id,
      indent: 1, spans: @[span(filesChangedText(message.diffs.len), fsHeading)],
      buttons: @[AgentFeedAction(kind: faOpenDiff,
                                 label: AgentUnifiedDiffLabel,
                                 arg: "unified:" & message.id)])
    for diff in message.diffs:
      let (added, removed) = computeDiffStats(diff.original, diff.modified)
      rows.add AgentFeedRow(
        kind: frDiffFile, key: message.id & "/diff" & $diff.id,
        messageId: message.id, indent: 2,
        press: AgentFeedAction(kind: faOpenDiff,
                               arg: "file:" & message.id & ":" & $diff.id),
        spans: @[span(diff.path), span("  +" & $added, fsAdded),
                 span(" -" & $removed, fsRemoved)])

# ---------------------------------------------------------------------------
# AA-2 / AA-3 cards
# ---------------------------------------------------------------------------

proc addTestRun(rows: var seq[AgentFeedRow]; vm: AgentActivityVM;
                entry: AgentTestRunEntry) =
  let summary = entry.summary
  let anchor = entry.anchorId
  let expanded = vm.isTestRunExpanded(anchor)
  rows.add AgentFeedRow(
    kind: frTestRun, key: anchor & "/run", messageId: anchor, anchorId: anchor,
    state: $testRunState(summary),
    press: AgentFeedAction(kind: faToggleRun),
    spans: @[span(expansionGlyph(expanded) & " ", fsMuted),
             span(testRunTitle(summary), fsHeading),
             span("  " & summaryText(summary), fsMuted)])
  if not expanded:
    return
  for row in summary.rows:
    let testExpanded = vm.isTestExpanded(anchor, row.testId)
    var r = AgentFeedRow(
      kind: frTestRow, key: anchor & "/test/" & row.testId,
      messageId: anchor, anchorId: anchor, testId: row.testId, indent: 1,
      state: $row.outcome, press: AgentFeedAction(kind: faToggleTest),
      spans: @[span($row.outcome, fsMuted), span(" " & row.name)])
    let duration = testRowDurationText(row)
    if duration.len > 0:
      r.spans.add span("  " & duration, fsMuted)
    if row.hasRecording:
      r.buttons = @[
        AgentFeedAction(kind: faOpenRecording, label: AgentOpenRecordingLabel),
        AgentFeedAction(kind: faOpenRecordingNewTab,
                        label: AgentOpenRecordingNewTabLabel)]
    rows.add r
    if testExpanded:
      let base = anchor & "/test/" & row.testId
      rows.add AgentFeedRow(kind: frTestDetail, key: base & "/detail",
                            messageId: anchor, anchorId: anchor,
                            testId: row.testId, indent: 2,
                            spans: @[span(testRowDetailText(row), fsMuted)])
      if row.recordingFailed:
        rows.add AgentFeedRow(kind: frTestRecordingFailed,
                              key: base & "/recording-failed",
                              messageId: anchor, anchorId: anchor,
                              testId: row.testId, indent: 2,
                              spans: @[span(AgentRecordingFailedText, fsError)])
      for di, d in row.diagnostics:
        rows.add AgentFeedRow(kind: frTestDiagnostic, key: base & "/diag" & $di,
                              messageId: anchor, anchorId: anchor,
                              testId: row.testId, indent: 2,
                              state: d.severity,
                              spans: @[span(d.message,
                                (if d.severity == "error": fsError
                                 else: fsMuted))])
      if row.output.len > 0:
        for oi, l in toSeq(row.output.split('\n')).pairs:
          rows.add AgentFeedRow(kind: frTestOutput, key: base & "/out" & $oi,
                                messageId: anchor, anchorId: anchor,
                                testId: row.testId, indent: 2,
                                spans: @[span(l, fsCode)])
  for di, d in summary.diagnostics:
    rows.add AgentFeedRow(kind: frRunDiagnostic, key: anchor & "/diag" & $di,
                          messageId: anchor, anchorId: anchor, indent: 1,
                          spans: @[span(d.message, fsError)])
  if summary.frameworkOutput.len > 0:
    for oi, l in toSeq(summary.frameworkOutput.split('\n')).pairs:
      rows.add AgentFeedRow(kind: frRunOutput, key: anchor & "/out" & $oi,
                            messageId: anchor, anchorId: anchor, indent: 1,
                            spans: @[span(l, fsCode)])

# ---------------------------------------------------------------------------
# The whole feed
# ---------------------------------------------------------------------------

proc feedIsIdle*(vm: AgentActivityVM): bool =
  ## The desktop's idle state: nothing said, nothing running, nothing asked.
  vm.sessionNotice.val.len == 0 and vm.messages.val.len == 0 and
    vm.terminals.val.len == 0 and not vm.wantsPassword.val and
    not vm.wantsPermission.val

proc promptPlaceholder*(vm: AgentActivityVM): string =
  if vm.messages.val.len > 0 or vm.terminals.val.len > 0:
    AgentActivityFollowUpPlaceholderText
  else:
    AgentActivityPlaceholderText

const
  AgentContextChipLead* = "context "
    ## What a native attachment row reads before its path: the desktop's chip
    ## is a box above the prompt, a native row needs the word.
  AgentContextRemoveLabel* = "×"
    ## The chip's remove control (the desktop's `.agent-paste-remove`).

proc contextRows*(vm: AgentActivityVM): seq[AgentFeedRow] =
  ## The prompt's attachments (`contextPaths`), one row each, in the order
  ## they were attached: the desktop's chips, drawn by a native front-end at
  ## the end of the feed, right above its prompt.
  if vm.isNil:
    return
  for i, p in vm.contextPaths.val:
    result.add AgentFeedRow(
      kind: frContextPath, key: "context/" & $i & "/" & p,
      spans: @[span(AgentContextChipLead, fsMuted), span(p, fsCode)],
      buttons: @[AgentFeedAction(kind: faRemoveContext,
                                 label: AgentContextRemoveLabel, arg: p)])

proc conversationRowsAt(vm: AgentActivityVM; nowMs: float): seq[AgentFeedRow]

proc agentFeedAt*(vm: AgentActivityVM; nowMs: float): seq[AgentFeedRow] =
  ## Every row the desktop's conversation area draws, in its order, then the
  ## prompt's attachments (`contextRows`).
  if vm.isNil:
    return
  result = vm.conversationRowsAt(nowMs)
  result.add vm.contextRows()

proc conversationRowsAt(vm: AgentActivityVM; nowMs: float): seq[AgentFeedRow] =
  if vm.feedIsIdle():
    result.add AgentFeedRow(kind: frIdleHeading, key: "idle/heading",
                            spans: @[span(AgentIdleHeading, fsHeading)])
    result.add AgentFeedRow(kind: frIdleSubtitle, key: "idle/subtitle",
                            spans: @[span(AgentIdleSubtitle, fsMuted)])
    for i, chip in AgentIdleChips:
      result.add AgentFeedRow(kind: frIdleChip, key: "idle/chip" & $i,
                              press: AgentFeedAction(kind: faFillPrompt,
                                                     arg: chip),
                              spans: @[span(chip)])
    return
  if vm.sessionNotice.val.len > 0:
    result.add AgentFeedRow(kind: frNotice, key: "notice",
                            spans: @[span(vm.sessionNotice.val, fsMuted)])
  for message in vm.messages.val:
    let runIndex = vm.testRunIndex(message.id)
    let evidence = vm.evidenceCallFor(message.id)
    if runIndex >= 0:
      result.addTestRun(vm, vm.testRuns.val[runIndex])
    elif evidence.isSome:
      result.addEvidence(evidence.get)
    elif message.role == aamrUser:
      result.addUserMessage(message, nowMs)
    else:
      result.addAgentMessage(vm, message)
  for terminal in vm.terminals.val:
    result.add AgentFeedRow(kind: frTerminal, key: "terminal/" & terminal.id,
                            spans: @[span(terminalTitle(terminal.id),
                                          fsHeading)])
  if vm.wantsPassword.val:
    result.add AgentFeedRow(kind: frPasswordPrompt, key: "password",
                            spans: @[span(AgentPasswordPlaceholder, fsMuted)],
                            buttons: @[AgentFeedAction(
                              kind: faNone,
                              label: AgentPasswordContinueLabel)])
  if vm.wantsPermission.val:
    let description =
      if vm.permissionInfo.val.len > 0: vm.permissionInfo.val
      else: AgentPermissionDefaultText
    result.add AgentFeedRow(kind: frPermissionHeading, key: "permission/h",
                            spans: @[span(AgentPermissionHeading, fsHeading)])
    result.add AgentFeedRow(kind: frPermissionText, key: "permission/text",
                            spans: @[span(description)])
    var sub = AgentFeedRow(kind: frPermissionSubtitle, key: "permission/sub",
                           spans: @[span(AgentPermissionSubtitle, fsMuted)])
    for choice in AgentPermissionChoices:
      sub.buttons.add AgentFeedAction(kind: faPermission, label: choice[1],
                                      arg: choice[0])
    result.add sub

proc agentFeed*(vm: AgentActivityVM): seq[AgentFeedRow] =
  agentFeedAt(vm, feedNowMs())

# ---------------------------------------------------------------------------
# Running a row's action
# ---------------------------------------------------------------------------

type
  AgentFeedEffect* = object
    ## What a native host still has to do after `runFeedAction`: nothing
    ## (the ViewModel did it all), or hand the prompt / a permission answer /
    ## a diff target to the host that owns those.
    kind*: AgentFeedActionKind
    arg*: string
    handled*: bool
      ## The ViewModel acted (toggled, opened).

proc runFeedAction*(vm: AgentActivityVM; row: AgentFeedRow;
                    action: AgentFeedAction): AgentFeedEffect =
  ## Run `action` of `row` — the same ViewModel calls the desktop's handlers
  ## make, so a native press and a desktop click cannot do different things.
  result = AgentFeedEffect(kind: action.kind, arg: action.arg)
  case action.kind
  of faNone:
    discard
  of faToggleThought:
    vm.toggleThought(row.messageId)
    result.handled = true
  of faToggleToolHistory:
    vm.toggleToolHistory(row.messageId, action.group)
    result.handled = true
  of faToggleRun:
    vm.toggleTestRun(row.anchorId)
    result.handled = true
  of faToggleTest:
    vm.toggleTest(row.anchorId, row.testId)
    result.handled = true
  of faOpenRecording:
    result.handled = vm.openTestRecording(row.anchorId, row.testId,
                                          topCurrentTab)
  of faOpenRecordingNewTab:
    result.handled = vm.openTestRecording(row.anchorId, row.testId, topNewTab)
  of faOpenEvidence:
    result.handled = vm.openEvidence(row.anchorId)
  of faFillPrompt:
    vm.setInputValue(action.arg)
    result.handled = true
  of faRemoveContext:
    # The desktop's chip `×` (`removeContextPathHandler`), by path so a press
    # read off a stale line cannot remove a different attachment.
    let at = vm.contextPaths.val.find(action.arg)
    if at >= 0:
      vm.removeContextPath(at)
      result.handled = true
  of faOpenDiff, faPermission:
    discard   # the host's: it owns the diff tabs and the agent connection
