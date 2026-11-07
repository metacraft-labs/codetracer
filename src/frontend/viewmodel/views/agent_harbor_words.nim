## views/agent_harbor_words.nim
##
## The words the Agent Harbor views of every front-end say: the notices of
## their load states, and the texts a view composes from viewmodel facts
## (a tab's label, a group's counts, a row's meta line, the fleet header's
## summary, a recording button's state suffix).
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

import std/strutils

import isonim/core/signals
import nim_agents_isonim_viewmodels/agent_harbor/[session_tabs_vm, initiative_progress_vm,
                                                   fleet_vm, recording_switcher]

const
  AgentHarborTabsLoadingText* = "Loading sessions\xE2\x80\xA6"
  AgentHarborTabsErrorText* = "Sessions unavailable"
  AgentHarborTabsEmptyText* = "No sessions yet. Start one with + or from any Agent Harbor front-end."
  AgentHarborFleetLoadingText* = "Loading sessions\xE2\x80\xA6"
  AgentHarborFleetEmptyText* = "No sessions on this server yet."
  AgentHarborFleetFilteredEmptyText* = "No session in this category."
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
