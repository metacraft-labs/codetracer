## views/agent_harbor_words.nim
##
## The words the Agent Harbor views of every front-end say: the notices of
## their load states, and the texts a view composes from viewmodel facts
## (a tab's label, a group's counts, a row's meta line, the fleet header's
## summary, a recording button's state suffix), and what a `+N` chip says
## about the items it hides, in words and in its progress pie (`chipPie`).
##
## ## Why this module exists
##
## These helpers were written inside the web views
## (`isonim_agent_harbor_*_view.nim`, `isonim_recording_switcher_view.nim`).
## The GPUI views must say exactly the same words, and importing a web view
## to reach them would put the web's rendering code -- its IsoNim DSL
## templates and its JS-only DOM hooks -- into the native front-end's
## closure. So the words live here, in a module that renders nothing and
## imports no renderer: only the viewmodels and the standard library. The
## web views import and re-export it, so their own callers are unchanged;
## the GPUI views (`gpui/agent_harbor/`) import it directly.
##
## The pure-module pattern is the one `debug_control_marks.nim` set for the
## debugger toolbar's marks, which the web, TUI and GPUI front-ends share.

import std/[options, strutils]

import ./cut_text_rules
export cut_text_rules

import isonim/core/signals
import nim_agents_isonim_viewmodels/agent_harbor/[session_tabs_vm, initiative_progress_vm,
                                                   fleet_vm, recording_switcher,
                                                   initiative_tabs_vm]
import nim_agents_isonim_viewmodels/agent_harbor/progress_pie

const
  AgentHarborTabsLoadingText* = "Loading sessions\xE2\x80\xA6"
  AgentHarborTabsErrorText* = "Sessions unavailable"
  AgentHarborTabsEmptyText* = "No sessions yet. Start one with + or from any Agent Harbor front-end."
  AgentHarborFleetLoadingText* = "Loading sessions\xE2\x80\xA6"
  AgentHarborFleetEmptyText* = "No sessions on this server yet."
  AgentHarborFleetFilteredEmptyText* = "No session in this category."
  AgentHarborFleetEmptyCellText* = "\xE2\x80\x94"
    ## A fleet column with nothing to say -- a session of no initiative, an
    ## agent or host the server did not name: an em dash, set in the disabled
    ## text role, so the cell reads as empty rather than as a gap in the
    ## grid. The web and GPUI fleet views both draw it from here.
  InitiativesLoadingText* = "Loading initiatives\xE2\x80\xA6"
  InitiativesEmptyText* = "No initiative is running on this server."
  ProgressEmptyText* = "Select an initiative to see its progress."
  InitiativeSessionLinesShown* = 4
    ## Session lines under an initiative before "+N more".

# ---------------------------------------------------------------------------
# Sessions as tabs, and the session list
# ---------------------------------------------------------------------------

proc tabLabelOf*(tab: SessionItem): string =
  ## A tab's text: its title; for a session known only by its id, the id
  ## alone -- "Session " would take the room that tells tabs apart.
  if tab.titleSource == lsId: tab.shortId else: tab.title

proc countsText*(counts: array[SessionAttention, int]): string =
  ## `2 need input · 1 idle · 3 running` -- the states worth naming; ended
  ## sessions are not (the node's mark says when nothing is live).
  var parts: seq[string]
  if counts[saNeedsInput] > 0:
    parts.add $counts[saNeedsInput] & (if counts[saNeedsInput] == 1: " needs input" else: " need input")
  if counts[saIdle] > 0: parts.add $counts[saIdle] & " idle"
  if counts[saRunning] > 0: parts.add $counts[saRunning] & " running"
  if counts[saQueued] > 0: parts.add $counts[saQueued] & " queued"
  if counts[saFailed] > 0: parts.add $counts[saFailed] & " failed"
  parts.join(" \xC2\xB7 ")

proc metaOf*(tab: SessionItem): string =
  ## The row's meta line after its status word: origin, agent, host.
  var parts: seq[string]
  if tab.originLabel.len > 0: parts.add tab.originLabel
  if tab.agentLabel.len > 0: parts.add tab.agentLabel
  if tab.host.len > 0: parts.add tab.host
  parts.join(" \xC2\xB7 ")

# ---------------------------------------------------------------------------
# Initiatives and Initiative Progress
# ---------------------------------------------------------------------------

proc statusCountsText*(counts: array[MilestoneStatusClass, int]): string =
  ## `2 in progress · 1 blocked · 9 planned · 5 completed`.
  var parts: seq[string]
  for status in MilestoneStatusClass:
    if counts[status] > 0: parts.add $counts[status] & " " & $status
  parts.join(" \xC2\xB7 ")

proc milestoneMetaParts*(m: MilestoneLine): tuple[before, failing, after: string] =
  ## The meta line split around its failing count (`1 failing`), which a
  ## view draws in the error role; `failing` is "" when no test fails.
  let full = (if m.deliverablesText.len > 0: m.deliverablesText & " \xC2\xB7 " else: "") &
             m.testsText
  let word = $m.failing & " failing"
  let at = if m.failing > 0: full.find(word) else: -1
  if at < 0: return (full, "", "")
  (full[0 ..< at], word, full[at + word.len .. ^1])

# ---------------------------------------------------------------------------
# The fleet
# ---------------------------------------------------------------------------

proc filterLabel*(filter: FleetFilter): string =
  case filter
  of ffAll: "All"
  of ffNeedsInput: "Needs input"
  of ffRunning: "Running"
  of ffQueued: "Queued"
  of ffFailed: "Failed"
  of ffEnded: "Ended"

proc activityLineIsError*(row: FleetRow; line: int): bool =
  ## Whether a fleet row's activity line `line` is drawn in the error
  ## colour: it is one the viewmodel marks error-level, AND the row has no
  ## failure line. A failure line already says the fault in red; the
  ## activity under it stays in the caption role, so one fault is not shown
  ## twice in red: a failed row shows a red failure line, or else an
  ## error-coloured activity line. One rule for the three front-ends: the
  ## web sets `ah-fleet-activity-error` from it, GPUI and the terminal pick
  ## the ink from it. A selected row draws every line in the selection's
  ## text colour, whatever this says.
  line >= 0 and line < row.activityLevels.len and row.activityLevels[line] == "error" and
    row.failureText.len == 0

proc filterCountInk*(count: int; active: bool): tuple[disabled, body: bool] =
  ## Which role a fleet filter's count takes: the active filter's count is
  ## in the body role even at 0 (on the active fill the disabled role falls
  ## to about 2.2:1); another filter's 0 is in the disabled role, quieter
  ## than a count; any other count in the caption role (neither flag set).
  if active: (false, true)
  elif count == 0: (true, false)
  else: (false, false)

proc filterCount*(counts: FleetCounts; filter: FleetFilter): int =
  case filter
  of ffAll: counts.listed
  of ffNeedsInput: counts.byCategory[fcNeedsInput]
  of ffRunning: counts.byCategory[fcRunning]
  of ffQueued: counts.byCategory[fcQueued]
  of ffFailed: counts.byCategory[fcFailed]
  of ffEnded: counts.byCategory[fcEnded]

proc metaPartsShort*(row: FleetRow): seq[string] =
  ## The meta line when agent, host, initiative and duration have columns.
  if row.repository.len > 0:
    result.add(if row.branch.len > 0: row.repository & " \xC2\xB7 " & row.branch
               else: row.repository)
  if row.workspace.len > 0: result.add(row.workspace)
  if row.titleSource != "id": result.add(row.shortId)

proc metaParts*(row: FleetRow): seq[string] =
  ## The meta line, in reading order; empty parts are left out.
  if row.agentLabel.len > 0:
    result.add(if row.agentCount > 1: row.agentLabel & " \xC3\x97" & $row.agentCount
               else: row.agentLabel)
  if row.repository.len > 0:
    result.add(if row.branch.len > 0: row.repository & " \xC2\xB7 " & row.branch
               else: row.repository)
  if row.workspace.len > 0: result.add(row.workspace)
  if row.initiative.len > 0: result.add(row.initiative)
  if row.host.len > 0: result.add(row.host)
  if row.titleSource != "id": result.add(row.shortId)
  if row.durationLabel.len > 0: result.add(row.durationLabel)

proc withheldNote*(vm: FleetSnapshotVM): string =
  ## Said once, in the header, after the session count: the server withheld
  ## the prompts, so rows are titled by what else names them.
  let counts = vm.counts
  if counts.withheldPrompts == 0: ""
  elif counts.withheldPrompts >= counts.listed:
    "prompts withheld by the server"
  else:
    "prompts of " & $counts.withheldPrompts & " withheld by the server"

proc headerSummary*(vm: FleetSnapshotVM): string =
  ## `471 sessions`; `13 of 471 sessions` while a filter shows some of them
  ## (or while the server reports more than it listed).
  let counts = vm.counts
  let filtered = vm.filter.val != ffAll
  let shown = if filtered: vm.rows.len else: counts.listed
  let outOf = if filtered: counts.listed else: counts.total
  if outOf > shown or filtered:
    $shown & " of " & $outOf & " sessions"
  else:
    $shown & (if shown == 1: " session" else: " sessions")

# ---------------------------------------------------------------------------
# The recording switcher
# ---------------------------------------------------------------------------

proc stateSuffix*(state: RecordingState): string =
  ## A recording's state as it reads on the button itself: still loading
  ## `2 …`, failed to load `3 ✕`, no longer there `4 ?`; a ready one is its
  ## number alone.
  case state
  of rsReady: ""
  of rsLoading: " \xE2\x80\xA6"
  of rsFailed: " \xE2\x9C\x95"
  of rsMissing: " ?"

# ---------------------------------------------------------------------------
# The `+N` chips: what they hide
# ---------------------------------------------------------------------------

type
  HiddenSeverity* = enum
    ## The most severe status among the items a `+N` chip hides, which the
    ## chip takes: its colour and mark, and its accessible name.
    hsNone = "none"            ## nothing that asks for the reader
    hsNeedsInput = "needs-input" ## a hidden item waits (the warning mark)
    hsFailed = "failed"        ## a hidden item failed (the error colour and mark)

  HiddenSummary* = object
    ## What a `+N` chip hides: how many items, how many of them wait for
    ## the reader and how many failed, and the most severe of these.
    hidden*, waiting*, failed*: int
    severity*: HiddenSeverity

proc hiddenSummary*(waiting, failed, hidden: int): HiddenSummary =
  ## A chip hiding `hidden` items, `waiting` of them waiting and `failed`
  ## of them failed; a failure is more severe than a wait.
  result = HiddenSummary(hidden: hidden, waiting: waiting, failed: failed)
  result.severity = if failed > 0: hsFailed elif waiting > 0: hsNeedsInput else: hsNone

proc hiddenSessions*(attentions: openArray[SessionAttention]): HiddenSummary =
  ## The session tabs a chip hides, by their attention.
  var waiting, failed = 0
  for a in attentions:
    if a == saNeedsInput: inc waiting
    elif a == saFailed: inc failed
  hiddenSummary(waiting, failed, attentions.len)

proc hiddenRecordings*(states: openArray[RecordingState]): HiddenSummary =
  ## The recordings a recording switcher's chip hides: a recording that
  ## failed to load is a failure; one no longer on the server (missing,
  ## drawn in the warning colour) is a warning.
  var waiting, failed = 0
  for s in states:
    if s == rsFailed: inc failed
    elif s == rsMissing: inc waiting
  hiddenSummary(waiting, failed, states.len)

proc chipTitle*(h: HiddenSummary; noun, nouns: string): string =
  ## The chip's accessible name and tooltip: `3 more tabs, 1 failed, 1
  ## needing input`, so what the chip's colour says is also said in words.
  ## A recording switcher's chip names what its buttons are: `recording`,
  ## or `process` on a multi-process recording's tab (`ProcessNoun`).
  let loaded = noun in ["recording", "process"]
  result = $h.hidden & " more " & (if h.hidden == 1: noun else: nouns)
  if h.failed > 0:
    result.add ", " & $h.failed & (if loaded: " failed to load" else: " failed")
  if h.waiting > 0:
    result.add ", " & $h.waiting & (if loaded: " missing" else: " needing input")

proc chipPie*(h: HiddenSummary; noun, nouns: string): Option[ProgressPie] =
  ## The progress pie a `+N` chip draws beside its count: the role of the
  ## most severe hidden item (a failure the error role, a wait the warning
  ## role), with no wedge, since a chip counts items and has no progress of
  ## its own. Its shape is therefore the pie's unknown shape (the ring and
  ## the dot), never a 0 % ring, which would claim a share. Its accessible
  ## name is the chip's own words (`chipTitle`), not "progress unknown",
  ## which would claim the chip had a progress to know. A chip hiding nothing
  ## that waits or failed (`hsNone`) draws no pie, as it drew no mark before:
  ## `none`. One rule for the three front ends, so no host decides the
  ## chip's role or words itself.
  let role = case h.severity
    of hsNone: return none(ProgressPie)
    of hsNeedsInput: prWarning
    of hsFailed: prError
  some(ProgressPie(role: role, known: false, label: chipTitle(h, noun, nouns)))

proc hiddenBarTabs*(tabs: openArray[StripTab]; hidden: openArray[int]): HiddenSummary =
  ## The initiative bar's tabs a chip hides (indexes into `tabs`): an
  ## initiative that needs input, or a session that does, waits; an
  ## initiative whose milestone is blocked with nothing working (its red
  ## mark), or a session that failed, is a failure.
  var waiting, failed = 0
  for i in hidden:
    let t = tabs[i]
    case t.kind
    of stkInitiative:
      if t.state == isNeedsInput: inc waiting
      elif t.state == isBlocked: inc failed
    of stkSession:
      if t.session.attention == saNeedsInput: inc waiting
      elif t.session.attention == saFailed: inc failed
  hiddenSummary(waiting, failed, hidden.len)

# ---------------------------------------------------------------------------
# Cut text: the rules are in `cut_text_rules`, re-exported here
# ---------------------------------------------------------------------------

proc countsFloor*(counts: string): string =
  ## The least a tree node's counts are cut to (CTF-P1c D7): the first
  ## count's number and the ellipsis, `1…` for `1 needs input · 2 running`.
  ## The counts never shrink below it; the title gives way first. Counts
  ## that are a number alone, or do not open with one, are their own floor.
  var digits = 0
  while digits < counts.len and counts[digits] in Digits: inc digits
  if digits == 0 or digits == counts.len: counts
  else: counts[0 ..< digits] & CutEllipsis
