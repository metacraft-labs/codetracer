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

import ../store/types
import agent_activity_vm, agent_activity_text

export agent_activity_text

const
  AgentOmnibarQuery* = "/ai "
    ## The omnibox's agent mode (`omnibar_vm.classifyOmnibarQuery`), the
    ## desktop's: where a native front-end's prompt is typed.

type
  AgentFeedSpanStyle* = enum
    fsPlain, fsCode, fsBold, fsItalic, fsBoldItalic, fsStrike, fsMuted,
    fsHeading, fsError, fsAdded, fsRemoved, fsButton

  AgentFeedSpan* = object
    text*: string
    style*: AgentFeedSpanStyle
    button*: int
      ## 0, or `k` when this span is the caption of the row's button `k - 1`
      ## (set by `wrapFeed`, so a press is read back off the painted line).

  AgentFeedRowKind* = enum
    frNotice = "notice"
    frIdleHeading = "idle-heading"
    frIdleSubtitle = "idle-subtitle"
    frIdleChip = "idle-chip"
    frUserHeader = "user-header"
    frAgentHeader = "agent-header"
    frTurnError = "turn-error"
    frText = "text"
    frCode = "code"
    frTableRow = "table-row"
    frImage = "image"
    frToolsToggle = "tools-toggle"
    frToolCall = "tool-call"
    frWorking = "working"
    frDiffHeader = "diff-header"
    frDiffFile = "diff-file"
    frTestRun = "test-run"
    frTestRow = "test-row"
    frTestDetail = "test-detail"
    frTestRecordingFailed = "test-recording-failed"
    frTestDiagnostic = "test-diagnostic"
    frTestOutput = "test-output"
    frRunDiagnostic = "run-diagnostic"
    frRunOutput = "run-output"
    frEvidenceHeader = "evidence-header"
    frEvidenceDataset = "evidence-dataset"
    frEvidenceCommand = "evidence-command"
    frEvidenceNote = "evidence-note"
    frEvidenceOutput = "evidence-output"
    frTerminal = "terminal"
    frPasswordPrompt = "password-prompt"
    frPermissionHeading = "permission-heading"
    frPermissionText = "permission-text"
    frPermissionSubtitle = "permission-subtitle"
    frContextPath = "context-path"
      ## A path the prompt's `+` attached (the desktop's chip above the
      ## prompt), sent with the next prompt; its button removes it.

  AgentFeedActionKind* = enum
    faNone = "none"
    faToggleThought = "toggle-thought"
    faToggleToolHistory = "toggle-tool-history"
    faToggleRun = "toggle-run"
    faToggleTest = "toggle-test"
    faOpenRecording = "open-recording"
    faOpenRecordingNewTab = "open-recording-new-tab"
    faOpenEvidence = "open-evidence"
    faOpenDiff = "open-diff"
    faFillPrompt = "fill-prompt"
    faPermission = "permission"
    faRemoveContext = "remove-context"

  AgentFeedAction* = object
    kind*: AgentFeedActionKind
    label*: string
      ## A button's caption ("" for the row's own press).
    arg*: string
      ## faOpenDiff: the desktop's target (`file:<msg>:<diff>` /
      ## `unified:<msg>`); faFillPrompt: the chip's text; faPermission: the
      ## answer (`allow_once` …); faRemoveContext: the attached path.
    group*: int
      ## faToggleToolHistory: the segment group.

  AgentFeedRow* = object
    kind*: AgentFeedRowKind
    key*: string
      ## Stable identity across re-derivations (`FeedScroll` anchors on it).
    messageId*, anchorId*, testId*: string
    spans*: seq[AgentFeedSpan]
    state*: string
      ## The row's state word, as the desktop's class modifier spells it: a
      ## run's `running`/`failed`/`passed`, a test's outcome, an evidence
      ## card's `ready`/`reading`/…, a tool call's `done`/`failed`/`running`.
    indent*: int
      ## Nesting depth (a test row under its run, a detail under its test).
    press*: AgentFeedAction
      ## What a press on the row itself does (faNone: nothing).
    buttons*: seq[AgentFeedAction]
      ## The row's buttons, in the desktop's order.

  AgentFeedLine* = object
    ## One painted line: a slice of row `row`'s spans, after wrapping.
    row*: int
    part*: int
      ## 0 for the row's first line.
    spans*: seq[AgentFeedSpan]

func span(text: string; style = fsPlain): AgentFeedSpan =
  AgentFeedSpan(text: text, style: style)

func plainText*(row: AgentFeedRow): string =
  for s in row.spans:
    result.add s.text
  for b in row.buttons:
    result.add "  [" & b.label & "]"

# ---------------------------------------------------------------------------
# Agent text → rows
# ---------------------------------------------------------------------------

func styleOf(kind: MsgSegKind): AgentFeedSpanStyle =
  case kind
  of mskCode: fsCode
  of mskBold: fsBold
  of mskItalic: fsItalic
  of mskBoldItalic: fsBoldItalic
  of mskStrike: fsStrike
  else: fsPlain

proc inlineSpans(text: string): seq[AgentFeedSpan] =
  ## A table cell's inline markup, flattened to spans.
  for seg in parseInlineCode(text):
    case seg.kind
    of mskText, mskCode, mskBold, mskItalic, mskBoldItalic, mskStrike:
      result.add span(seg.content, styleOf(seg.kind))
    else:
      result.add span(seg.content)

proc addMarkup(rows: var seq[AgentFeedRow]; base: AgentFeedRow; key: string;
               text: string) =
  ## `text` — agent markdown — as rows: inline runs split at their newlines
  ## into `frText` rows, a code block's lines as `frCode`, a table's rows as
  ## `frTableRow`, an image as `frImage` naming its alt text.
  var line: seq[AgentFeedSpan] = @[]
  var n = 0
  template flush() =
    var r = base
    r.kind = frText
    r.key = key & "/" & $n
    r.spans = line
    rows.add r
    inc n
    line = @[]
  for seg in parseInlineCode(text):
    case seg.kind
    of mskText, mskCode, mskBold, mskItalic, mskBoldItalic, mskStrike:
      let parts = seg.content.split('\n')
      for i, p in parts:
        if i > 0:
          flush()
        if p.len > 0:
          line.add span(p, styleOf(seg.kind))
    of mskCodeBlock:
      if line.len > 0: flush()
      if seg.lang.len > 0:
        var r = base
        r.kind = frCode
        r.key = key & "/" & $n
        r.spans = @[span(seg.lang, fsMuted)]
        rows.add r
        inc n
      for codeLine in seg.content.split('\n'):
        var r = base
        r.kind = frCode
        r.key = key & "/" & $n
        r.spans = @[span(codeLine, fsCode)]
        rows.add r
        inc n
    of mskTable:
      if line.len > 0: flush()
      for ri, cells in seg.rows:
        var r = base
        r.kind = frTableRow
        r.key = key & "/" & $n
        for ci, cell in cells:
          if ci > 0:
            r.spans.add span(" │ ", fsMuted)
          for s in inlineSpans(cell):
            r.spans.add(if ri == 0: span(s.text, fsBold) else: s)
        rows.add r
        inc n
    of mskImage:
      if line.len > 0: flush()
      var r = base
      r.kind = frImage
      r.key = key & "/" & $n
      r.spans = @[span("[image: " & (if seg.lang.len > 0: seg.lang
                                     else: "attachment") & "]", fsMuted)]
      rows.add r
      inc n
  if line.len > 0 or n == 0:
    flush()

# ---------------------------------------------------------------------------
# One message
# ---------------------------------------------------------------------------

proc addUserMessage(rows: var seq[AgentFeedRow];
                    message: AgentActivityMessageEntry; nowMs: float) =
  var header = AgentFeedRow(kind: frUserHeader, key: message.id & "/h",
                            messageId: message.id)
  header.spans.add span("You", fsHeading)
  let age = relativeTimeAt(message.createdAt, nowMs)
  if age.len > 0:
    header.spans.add span("  " & age, fsMuted)
  if message.canceled:
    header.spans.add span(" " & AgentCanceledText, fsMuted)
  rows.add header
  for i, _ in message.images:
    rows.add AgentFeedRow(kind: frImage, key: message.id & "/img" & $i,
                          messageId: message.id,
                          spans: @[span("[image: attachment]", fsMuted)])
  rows.addMarkup(AgentFeedRow(messageId: message.id, indent: 1),
                 message.id & "/t", message.content)

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

proc addEvidence(rows: var seq[AgentFeedRow]; call: EvidenceCall) =
  let anchor = call.anchorId
  let state = $evidenceCardState(call)
  var header = AgentFeedRow(kind: frEvidenceHeader, key: anchor & "/evidence",
                            messageId: anchor, anchorId: anchor, state: state,
                            spans: @[span(evidenceCommandName(call.kind),
                                          fsHeading)])
  let shape = evidenceDatasetShapeText(call)
  if shape.len > 0:
    header.spans.add span("  " & shape, fsMuted)
  if call.canOpenEvidence():
    header.buttons = @[AgentFeedAction(kind: faOpenEvidence,
                                       label: AgentOpenReviewLabel)]
  rows.add header
  rows.add AgentFeedRow(kind: frEvidenceDataset, key: anchor & "/dataset",
                        messageId: anchor, anchorId: anchor, state: state,
                        indent: 1, spans: @[span(call.datasetPath)])
  rows.add AgentFeedRow(kind: frEvidenceCommand, key: anchor & "/command",
                        messageId: anchor, anchorId: anchor, state: state,
                        indent: 1, spans: @[span(call.command, fsCode)])
  let note = evidenceNoteText(call)
  if note.len > 0:
    rows.add AgentFeedRow(kind: frEvidenceNote, key: anchor & "/note",
                          messageId: anchor, anchorId: anchor, state: state,
                          indent: 1, spans: @[span(note, fsMuted)])
  if call.failureText.len > 0:
    for oi, l in toSeq(call.failureText.split('\n')).pairs:
      rows.add AgentFeedRow(kind: frEvidenceOutput, key: anchor & "/out" & $oi,
                            messageId: anchor, anchorId: anchor, state: state,
                            indent: 1, spans: @[span(l, fsCode)])

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

# ---------------------------------------------------------------------------
# Lines and scrolling
# ---------------------------------------------------------------------------

type
  FeedMeasure* = proc(text: string): int {.closure.}
    ## The extent of `text` in the front-end's unit (cells, pixels).

proc runeMeasure*(text: string): int =
  ## One unit per code point — the default measure.
  text.runeLen

proc indentText*(row: AgentFeedRow): string =
  repeat("  ", row.indent)

proc markOf*(row: AgentFeedRow): string =
  ## The mark a native front-end draws before a row's text, where the desktop
  ## draws a coloured dot or a card's coloured edge: a tool call's dot, a
  ## card's left edge — coloured by `state`. "" for every other row.
  case row.kind
  of frToolCall: "● "
  of frTestRun, frEvidenceHeader: "▌ "
  else: ""

proc markedRows*(rows: openArray[AgentFeedRow]): seq[AgentFeedRow] =
  ## The rows with their marks written in as a leading span, so wrapping
  ## measures them like the rest of the line.
  for r in rows:
    var m = r
    let mark = r.markOf()
    if mark.len > 0:
      m.spans.insert AgentFeedSpan(text: mark, style: fsPlain), 0
    result.add m

proc wrapFeed*(rows: openArray[AgentFeedRow]; width: int;
               measure: FeedMeasure = nil): seq[AgentFeedLine] =
  ## The rows as the lines a pane `width` units wide shows: each row's
  ## indent, spans and buttons (`[Open review]`), broken at spaces where it
  ## can and mid-word where it must. Every row yields at least one line, so
  ## an empty text row still holds its place.
  let m: FeedMeasure = if measure.isNil: runeMeasure else: measure
  let w = max(1, width)
  for ri, row in rows:
    var pieces = row.spans
    for bi, b in row.buttons:
      pieces.add span("  ")
      pieces.add AgentFeedSpan(text: "[" & b.label & "]", style: fsButton,
                               button: bi + 1)
    let lead = row.indentText()
    var part = 0
    var cur: seq[AgentFeedSpan] = @[]
    var used = 0
    if lead.len > 0:
      cur.add span(lead)
      used = m(lead)
    template emit() =
      result.add AgentFeedLine(row: ri, part: part, spans: cur)
      inc part
      cur = @[]
      used = 0
      if lead.len > 0:
        cur.add span(lead)
        used = m(lead)
    for s in pieces:
      var rest = s.text
      while rest.len > 0:
        let room = w - used
        if m(rest) <= room:
          cur.add AgentFeedSpan(text: rest, style: s.style, button: s.button)
          used += m(rest)
          rest = ""
          break
        # A button is never broken across lines: it moves to the next one
        # whole when it fits there (a press is read back by the span).
        let leadCells = if lead.len > 0: m(lead) else: 0
        if s.button > 0 and used > leadCells and m(rest) <= w - leadCells:
          emit()
          continue
        # Fit as many runes as the room takes, preferring the last space.
        var take = 0
        var fitBytes = 0
        var lastSpace = -1
        for r in rest.runes:
          let piece = $r
          if m(rest[0 ..< fitBytes] & piece) > room:
            break
          fitBytes += piece.len
          inc take
          if piece == " ":
            lastSpace = fitBytes
        if take == 0:
          if used > (if lead.len > 0: m(lead) else: 0):
            emit()
            continue
          # Not even one rune fits a fresh line: place one anyway.
          fitBytes = rest.runeLenAt(0)
        elif lastSpace > 0 and lastSpace < rest.len:
          fitBytes = lastSpace
        cur.add AgentFeedSpan(text: rest[0 ..< fitBytes], style: s.style,
                              button: s.button)
        rest = rest[fitBytes .. ^1]
        emit()
    if cur.len > 0 or part == 0:
      result.add AgentFeedLine(row: ri, part: part, spans: cur)

type
  FeedScroll* = object
    ## Where the reader is in the feed.
    top*: int
      ## The first line shown.
    follow*: bool
      ## At the end, and staying there as rows arrive (the default, as a
      ## conversation is read from its newest turn).
    anchorKey*: string
    anchorPart*: int
      ## The row (by `AgentFeedRow.key`) and wrapped line the top is on, so a
      ## re-derived feed — new rows, a turn collapsing above — puts the same
      ## line back at the top.

proc initFeedScroll*(): FeedScroll = FeedScroll(follow: true)

proc maxTop*(lines, view: int): int = max(0, lines - max(1, view))

proc settle*(s: var FeedScroll; rows: openArray[AgentFeedRow];
             lines: openArray[AgentFeedLine]; view: int) =
  ## Re-place the view over a (re-)derived feed: at the end when following,
  ## else on the line it was anchored to (or that row's first line, when the
  ## row now wraps differently).
  let last = maxTop(lines.len, view)
  if s.follow:
    s.top = last
  elif s.anchorKey.len > 0:
    var found = -1
    for i, l in lines:
      if rows[l.row].key == s.anchorKey:
        if found < 0 or l.part == s.anchorPart:
          found = i
        if l.part == s.anchorPart:
          break
    if found >= 0:
      s.top = found
  s.top = clamp(s.top, 0, last)
  if s.top < lines.len:
    s.anchorKey = rows[lines[s.top].row].key
    s.anchorPart = lines[s.top].part

proc scrollTo*(s: var FeedScroll; top: int; rows: openArray[AgentFeedRow];
               lines: openArray[AgentFeedLine]; view: int) =
  ## The reader moved the view (wheel, keys, the scrubber): hold this line,
  ## and follow the end again only when it is the end.
  let last = maxTop(lines.len, view)
  s.top = clamp(top, 0, last)
  s.follow = s.top >= last
  if s.top < lines.len:
    s.anchorKey = rows[lines[s.top].row].key
    s.anchorPart = lines[s.top].part
  else:
    s.anchorKey = ""
    s.anchorPart = 0

proc lineOfRow*(lines: openArray[AgentFeedLine]; row: int): int =
  for i, l in lines:
    if l.row == row:
      return i
  -1
