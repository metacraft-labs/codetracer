## viewmodels/agent_activity_text.nim
##
## **Every word and every decision the Agent Activity panel shows, in one
## place every front-end reads.**
##
## The desktop's panel (`views/isonim_agent_activity_view.nim`) used to make
## these decisions inside its render procs: how a turn's header reads ("Thought
## for 3s", "Thinking 2s", "Failed"), which of a finished turn's paragraphs is
## promoted out of its collapsed block, how markdown-ish agent text splits into
## code, bold and table spans, what a tool call's dot means, how many lines a
## changed file gained and lost, what a test-run card calls itself and which of
## three states it is in, which of five states an evidence card is in. A
## terminal or GPUI view that wanted the same panel would have had to copy those
## rules, and two copies drift. So they live here, pure and DOM-free, compiled
## for both Nim backends, and the desktop view, the terminal pane and the GPUI
## leaf all call them (`agent_activity_feed.nim` composes them into rows).
##
## Nothing here reads a signal: each proc is a function of the values it is
## given, so the whole vocabulary is assertable without a ViewModel.

import std/[strutils, tables]

import ../store/types
import evidence_call_vm, test_run_summary_vm
import agent_prompt_context

export agent_prompt_context

when defined(js):
  proc dateNowMs(): float {.importjs: "Date.now()".}
  proc wallClockTimeJs(ms: float): cstring
    {.importjs: "new Date(#).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})".}
  proc codePointToCStr(cp: int): cstring {.importjs: "String.fromCodePoint(#)".}
  proc codePointToStr(cp: int): string = $codePointToCStr(cp)
else:
  import std/[times, unicode]
  proc dateNowMs(): float = epochTime() * 1000.0
  proc codePointToStr(cp: int): string = $Rune(cp)

const
  AgentActivityPlaceholderText* = "Ask anything…"
  AgentActivityFollowUpPlaceholderText* =
    "Ask for a change, or type a follow-up…"
  AgentActivityTurnNoReasonText* =
    "The agent ended the turn with an error but gave no reason."
  AgentIdleHeading* = "Start an agent task"
  AgentIdleSubtitle* = "Describe a change, a bug to fix, or a feature to " &
    "add. The agent works in a sandbox and shows its progress here."
  AgentIdleChips* = ["Fix a bug in my code", "Explain this codebase",
                     "Write tests for function"]
  AgentWorkingText* = "Agent is working"
  AgentCanceledText* = "(canceled)"
  AgentRecordingFailedText* = "Recording failed before a trace was " &
    "produced; there is no recording to open."
  AgentOpenRecordingLabel* = "Open recording"
  AgentOpenRecordingNewTabLabel* = "Open in new tab"
  AgentOpenReviewLabel* = "Open review"
  AgentUnifiedDiffLabel* = "Unified diff"
  AgentPasswordPlaceholder* = "Password to continue"
  AgentPasswordContinueLabel* = "Continue"
  AgentPermissionHeading* = "Action needed"
  AgentPermissionDefaultText* = "The agent wants to perform an action"
  AgentPermissionSubtitle* =
    "Runs in the sandbox · network off · can't touch your machine."
  AgentPermissionChoices* = [("allow_once", "Allow once"),
                             ("allow_always", "Allow always"),
                             ("deny", "Deny")]
    ## The three answers, in the desktop's order: the value the host is
    ## handed, and the button's label.
  AgentFailedLabel* = "Failed"
  AgentFailedIcon* = "✕"

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

proc wallClockTime*(createdAtMs: float): string =
  ## A turn's clock time ("14:05"), or "" when the row carries no creation
  ## time. A row replayed from a review has none (`review_session
  ## .sessionMessages` sets no `createdAt`), and printing the epoch's clock
  ## time for it would state a time nothing happened at.
  if createdAtMs <= 0.0:
    return ""
  when defined(js):
    $wallClockTimeJs(createdAtMs)
  else:
    ""

proc thoughtDuration*(durationSec: float): string =
  if durationSec <= 0.0:
    "Thinking"
  elif durationSec < 60.0:
    "Thought for " & $int(durationSec) & "s"
  else:
    let m = int(durationSec / 60.0)
    let s = int(durationSec) mod 60
    if s == 0:
      "Thought for " & $m & "m"
    else:
      "Thought for " & $m & "m " & $s & "s"

proc thinkingLabel*(createdAt, thinkingEndedAt: float): string =
  ## Label for the "Thinking" header once the agent starts producing output.
  ## Shows how many seconds the pure thinking phase lasted.
  let sec = int((thinkingEndedAt - createdAt) / 1000.0)
  "Thinking " & $sec & "s"

proc relativeTimeAt*(createdAtMs, nowMs: float): string =
  ## A user message's age, against `nowMs`, or "" when it has no creation
  ## time (see `wallClockTime`).
  if createdAtMs <= 0.0:
    return ""
  let diffSec = (nowMs - createdAtMs) / 1000.0
  if diffSec < 60.0:
    "just now"
  elif diffSec < 3600.0:
    $int(diffSec / 60.0) & "m ago"
  else:
    $int(diffSec / 3600.0) & "h ago"

proc feedNowMs*(): float =
  ## The wall clock, in milliseconds since the epoch, as message
  ## `createdAt` values are.
  dateNowMs()

proc relativeTime*(createdAtMs: float): string =
  relativeTimeAt(createdAtMs, dateNowMs())

# ---------------------------------------------------------------------------
# A turn's segments, and what its header says
# ---------------------------------------------------------------------------

type
  ViewSegGroup* = object
    ## A rendered group of consecutive segments: either a block of text or a
    ## batch of consecutive tool calls shown with an expandable history.
    isTools*: bool
    content*: string
    tools*: seq[AgentActivitySegment]

  AgentToolState* = enum
    atsRunning = "running"
    atsDone = "done"
    atsFailed = "failed"

proc computeSegGroups*(segments: seq[AgentActivitySegment]): seq[ViewSegGroup] =
  ## Merge consecutive tool-call segments into groups so they can be rendered
  ## with an expandable history.  Text segments are kept separate.
  for seg in segments:
    if not seg.isToolCall:
      result.add(ViewSegGroup(isTools: false, content: seg.content))
    else:
      if result.len > 0 and result[^1].isTools:
        result[^1].tools.add(seg)
      else:
        result.add(ViewSegGroup(isTools: true, tools: @[seg]))

proc toolState*(status: string): AgentToolState =
  ## A tool call's dot: done, failed, or — for every other word the backend
  ## sends, and for none — still running.
  if status == "completed": atsDone
  elif status == "failed": atsFailed
  else: atsRunning

proc toolsUsedText*(count: int): string =
  $count & " tools used"

proc stillThinking*(message: AgentActivityMessageEntry): bool =
  message.thinkingEndedAt == 0.0 and message.isLoading

proc thoughtHeaderLabel*(message: AgentActivityMessageEntry): string =
  ## What an agent turn's header says.
  ##
  ## #862: a failed turn says so, rather than "Thought for Ns", which reads
  ## as a turn that finished.  A finished turn with no timing to report
  ## (every row of a session loaded into a review) says nothing: "Thinking"
  ## there would be the in-progress placeholder on a turn that is over.
  if message.failed:
    AgentFailedLabel
  elif message.duration > 0.0:
    thoughtDuration(message.duration)
  elif message.thinkingEndedAt > 0.0:
    thinkingLabel(message.createdAt, message.thinkingEndedAt)
  elif message.isLoading:
    "Thinking"
  else:
    ""

proc canceledSuffix*(label: string): string =
  ## Separated from the label only when there is a label to separate from.
  if label.len > 0: " " & AgentCanceledText else: AgentCanceledText

proc turnFailureText*(message: AgentActivityMessageEntry): string =
  if message.errorMessage.len > 0: message.errorMessage
  else: AgentActivityTurnNoReasonText

type
  TurnFinal* = object
    ## A finished turn's last text, promoted out of its collapsed block.
    text*: string
    groupIndex*: int
      ## The segment group it came from (skipped inside the block), -1 none.

proc finalTurnText*(message: AgentActivityMessageEntry;
                    groups: seq[ViewSegGroup]): TurnFinal =
  ## The text a finished turn shows outside its collapsed block.
  ##
  ## When the ACP completion summary contains `Last agent message:
  ## Some("...")` the inner content (with `\n` unescaped) is the recap;
  ## otherwise the last paragraph of the final text segment.
  result = TurnFinal(groupIndex: -1)
  if message.isLoading:
    return
  for grpIdx in 0 ..< groups.len:
    let grp = groups[grpIdx]
    if not grp.isTools and grp.content.len > 0:
      result.text = grp.content
      result.groupIndex = grpIdx
  if result.text.len == 0:
    return
  const lastMsgMarker = "Last agent message: Some(\""
  let markerIdx = result.text.find(lastMsgMarker)
  if markerIdx >= 0:
    let start = markerIdx + lastMsgMarker.len
    let closingIdx = result.text.rfind("\")")
    if closingIdx > start:
      result.text = result.text[start ..< closingIdx].replace("\\n", "\n")
  else:
    let paragraphs = result.text.split("\n\n")
    var lastParagraph = ""
    for i in countdown(paragraphs.len - 1, 0):
      let p = paragraphs[i].strip()
      if p.len > 0:
        lastParagraph = p
        break
    if lastParagraph.len > 0:
      result.text = lastParagraph

proc showsFlatContent*(message: AgentActivityMessageEntry;
                       groups: seq[ViewSegGroup]): bool =
  ## A message with no segments: its flat `content` IS the message.
  groups.len == 0 and message.content.len > 0

proc startsCollapsed*(message: AgentActivityMessageEntry;
                      groups: seq[ViewSegGroup]): bool =
  ## Completed turns start collapsed so the conversation stays readable; a
  ## turn still in flight is open, and so is a message whose flat content is
  ## all there is (collapsing it would hide all of it behind the header —
  ## a replayed review session read as a column of bare headers).
  not message.isLoading and not showsFlatContent(message, groups)

proc showsWorking*(message: AgentActivityMessageEntry): bool =
  ## "Agent is working": the agent still produces output after the thinking
  ## phase ended.
  message.isLoading and not message.stillThinking and not message.canceled

# ---------------------------------------------------------------------------
# Agent text: the markdown subset the panel renders
# ---------------------------------------------------------------------------

type
  MsgSegKind* = enum
    mskText, mskCode, mskCodeBlock,
    mskBold, mskItalic, mskBoldItalic, mskStrike,
    mskTable, mskImage

  MsgSegment* = object
    kind*: MsgSegKind
    content*: string
    lang*: string          ## code block language; image alt text
    rows*: seq[seq[string]]

proc isSeparatorLine(line: string): bool =
  if line.len == 0 or line[0] != '|': return false
  var hasDash = false
  for ch in line:
    if ch notin {'-', ':', ' ', '|'}: return false
    if ch == '-': hasDash = true
  hasDash

proc parsePipeRow(line: string): seq[string] =
  let parts = line.split('|')
  for p in parts:
    let cell = p.strip()
    if cell.len > 0:
      result.add(cell)

proc parseInlineCode*(s: string): seq[MsgSegment] =
  var i = 0
  var cur = ""

  template flushText() =
    if cur.len > 0:
      result.add(MsgSegment(kind: mskText, content: cur))
      cur = ""

  while i < s.len:
    # Escape sequences: \* \_ \` \\ \~ and literal \n / \t from ACP streams
    if s[i] == '\\' and i + 1 < s.len:
      case s[i+1]
      of '*', '_', '`', '\\', '~':
        cur.add(s[i+1])
        inc i, 2
        continue
      of 'n':
        # Literal \n from ACP stream → real newline (renders via pre-wrap)
        cur.add('\n')
        inc i, 2
        continue
      of 't':
        cur.add('\t')
        inc i, 2
        continue
      of 'u':
        # \uXXXX Unicode escape from un-decoded ACP JSON content
        if i + 5 < s.len:
          let h = s[i+2 ..< i+6]
          var allHex = true
          for c in h:
            if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
              allHex = false
              break
          if allHex:
            cur.add(codePointToStr(parseHexInt(h)))
            inc i, 6
            continue
      else: discard

    # Markdown image: ![alt](src) — only for data: URIs to avoid false positives
    if s[i] == '!' and i + 1 < s.len and s[i+1] == '[':
      let altStart = i + 2
      let altEnd = s.find(']', altStart)
      if altEnd >= altStart and altEnd + 1 < s.len and s[altEnd + 1] == '(':
        let srcStart = altEnd + 2
        let srcEnd = s.find(')', srcStart)
        if srcEnd > srcStart:
          let src = s[srcStart ..< srcEnd]
          if src.startsWith("data:image/") or src.startsWith("data:"):
            flushText()
            result.add(MsgSegment(kind: mskImage, content: src, lang: s[altStart ..< altEnd]))
            i = srcEnd + 1
            continue
      cur.add(s[i])
      inc i

    # Triple backtick code block
    elif i + 2 < s.len and s[i] == '`' and s[i+1] == '`' and s[i+2] == '`':
      flushText()
      inc i, 3
      var lang = ""
      while i < s.len and s[i] != '\n':
        lang.add(s[i])
        inc i
      if i < s.len: inc i
      var code = ""
      while i < s.len:
        if i + 2 < s.len and s[i] == '`' and s[i+1] == '`' and s[i+2] == '`':
          inc i, 3
          break
        code.add(s[i])
        inc i
      if code.len > 0 and code[^1] == '\n':
        code.setLen(code.len - 1)
      result.add(MsgSegment(kind: mskCodeBlock, content: code, lang: lang))

    # Double-backtick code span: `` content `` (can contain backtick characters)
    elif i + 1 < s.len and s[i] == '`' and s[i+1] == '`' and
         (i + 2 >= s.len or s[i+2] != '`'):
      let j = s.find("``", i + 2)
      if j >= 0:
        flushText()
        var code = s[i+2 ..< j]
        # CommonMark: strip one leading/trailing space if both present
        if code.len >= 2 and code[0] == ' ' and code[^1] == ' ':
          code = code[1 ..< code.len - 1]
        result.add(MsgSegment(kind: mskCode, content: code))
        i = j + 2
      else:
        cur.add(s[i])
        inc i

    # Bold+italic ***
    elif i + 2 < s.len and s[i] == '*' and s[i+1] == '*' and s[i+2] == '*':
      let j = s.find("***", i + 3)
      if j >= 0:
        flushText()
        result.add(MsgSegment(kind: mskBoldItalic, content: s[i+3 ..< j]))
        i = j + 3
      else:
        cur.add(s[i])
        inc i

    # Bold **
    elif i + 1 < s.len and s[i] == '*' and s[i+1] == '*':
      let j = s.find("**", i + 2)
      if j >= 0:
        flushText()
        result.add(MsgSegment(kind: mskBold, content: s[i+2 ..< j]))
        i = j + 2
      else:
        cur.add(s[i])
        inc i

    # Italic *
    elif s[i] == '*':
      let j = s.find('*', i + 1)
      if j > i:
        flushText()
        result.add(MsgSegment(kind: mskItalic, content: s[i+1 ..< j]))
        i = j + 1
      else:
        cur.add(s[i])
        inc i

    # Strikethrough ~~
    elif i + 1 < s.len and s[i] == '~' and s[i+1] == '~':
      let j = s.find("~~", i + 2)
      if j >= 0:
        flushText()
        result.add(MsgSegment(kind: mskStrike, content: s[i+2 ..< j]))
        i = j + 2
      else:
        cur.add(s[i])
        inc i

    # Italic _ (only at word boundaries to avoid matching my_var_name)
    elif s[i] == '_':
      let prevOk = i == 0 or s[i-1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}
      let nextOk = i + 1 < s.len and s[i+1] notin {' ', '\n', '_'}
      if prevOk and nextOk:
        let j = s.find('_', i + 1)
        let closeOk = j > i and (j + 1 >= s.len or
          s[j+1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'})
        if closeOk:
          flushText()
          result.add(MsgSegment(kind: mskItalic, content: s[i+1 ..< j]))
          i = j + 1
        else:
          cur.add(s[i])
          inc i
      else:
        cur.add(s[i])
        inc i

    # Inline code `
    elif s[i] == '`':
      inc i
      var code = ""
      while i < s.len and s[i] != '`':
        code.add(s[i])
        inc i
      if i < s.len: inc i
      if code.len == 0:
        cur.add("``")
      else:
        flushText()
        result.add(MsgSegment(kind: mskCode, content: code))

    # GFM pipe table (must start at beginning of line)
    elif s[i] == '|' and (i == 0 or s[i-1] == '\n'):
      var lineEnd = i
      while lineEnd < s.len and s[lineEnd] != '\n': inc lineEnd
      let headerLine = s[i ..< lineEnd]
      let sepStart = lineEnd + 1
      if sepStart < s.len and s[sepStart] == '|':
        var sepEnd = sepStart
        while sepEnd < s.len and s[sepEnd] != '\n': inc sepEnd
        let sepLine = s[sepStart ..< sepEnd]
        if isSeparatorLine(sepLine):
          flushText()
          var tableRows: seq[seq[string]] = @[]
          tableRows.add(parsePipeRow(headerLine))
          var j = sepEnd + 1
          while j < s.len and s[j] == '|':
            var rowEnd = j
            while rowEnd < s.len and s[rowEnd] != '\n': inc rowEnd
            tableRows.add(parsePipeRow(s[j ..< rowEnd]))
            j = if rowEnd < s.len: rowEnd + 1 else: rowEnd
          result.add(MsgSegment(kind: mskTable, rows: tableRows))
          i = j
        else:
          cur.add(s[i])
          inc i
      else:
        cur.add(s[i])
        inc i

    else:
      cur.add(s[i])
      inc i

  flushText()

# ---------------------------------------------------------------------------
# Changed files
# ---------------------------------------------------------------------------

proc computeDiffStats*(original: string; modified: string): (int, int) =
  ## Lines gained and lost between two versions of a file: per distinct line,
  ## how many more times it occurs in one than the other. The desktop used to
  ## compute this in a JavaScript snippet only the renderer could run (a
  ## native build reported 0/0 for every file); this is the same arithmetic,
  ## so every front-end prints the same "+N -M".
  var o = initCountTable[string]()
  var m = initCountTable[string]()
  for l in original.split('\n'): o.inc l
  for l in modified.split('\n'): m.inc l
  var added, removed = 0
  for line, count in m:
    added += max(0, count - o.getOrDefault(line, 0))
  for line, count in o:
    removed += max(0, count - m.getOrDefault(line, 0))
  (added, removed)

proc terminalTitle*(id: string): string =
  ## An agent terminal's caption.
  "Terminal " & id

proc filesChangedText*(count: int): string =
  $count & (if count == 1: " file changed" else: " files changed")

# ---------------------------------------------------------------------------
# AA-2 — a `ct test` run's card
# ---------------------------------------------------------------------------

type
  TestRunState* = enum
    ## Three-valued rather than boolean: "running" is not a kind of failure,
    ## and an empty run is not a kind of success.
    trsRunning = "running"
    trsFailed = "failed"
    trsPassed = "passed"

proc testRunState*(summary: TestRunSummary): TestRunState =
  if summary.inProgress: trsRunning
  elif summary.failed > 0 or summary.errored > 0: trsFailed
  else: trsPassed

proc testRunTitle*(summary: TestRunSummary): string =
  ## What the card calls itself.
  ##
  ## The runner's own reported command when there is one, because that is the
  ## thing the reviewer actually asked for; otherwise the provider's id.  Never
  ## a reconstructed command line — a command CodeTracer invented would read as
  ## one that ran.
  if summary.commandLine.len > 0:
    summary.commandLine
  elif summary.providerId.len > 0:
    summary.providerId
  else:
    "ct test"

proc testRowDetailText*(row: TestRunRow): string =
  ## The line an expanded test shows: its status and how long it took.
  ## §2.1.2: "an individual test can be expanded to its status, duration and
  ## captured output."  A duration of zero is omitted rather than printed,
  ## for the same reason a zero count is: it is not a measurement.
  result = "Status: " & $row.outcome
  if row.durationMs > 0:
    result.add " · Duration: " & formatDurationMs(row.durationMs)

proc testRowDurationText*(row: TestRunRow): string =
  if row.durationMs > 0: formatDurationMs(row.durationMs) else: ""

proc expansionGlyph*(expanded: bool): string =
  ## The run card's disclosure triangle.
  if expanded: "▾" else: "▸"

# ---------------------------------------------------------------------------
# AA-3 — an evidence card
# ---------------------------------------------------------------------------

type
  EvidenceCardState* = enum
    ## Derived from the two facts that decide it — what the command did, and
    ## whether its dataset can be read — because "no affordance" has four
    ## different reasons and a reviewer should be able to tell which.
    ecReady = "ready"
    ecReading = "reading"
    ecUnavailable = "unavailable"
    ecFailed = "failed"
    ecUnreported = "unreported"

proc evidenceCardState*(call: EvidenceCall): EvidenceCardState =
  case call.state
  of ecsUnreported: ecUnreported
  of ecsFailed: ecFailed
  of ecsCompleted:
    case call.dataset.state
    of edsReady: ecReady
    of edsUnknown: ecReading
    of edsUnavailable: ecUnavailable
