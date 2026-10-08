## headless_app/session_tabs.nim — PLAT-48 deliverable 3. THE SESSION TAB
## STRIP OVER `HeadlessApp`'S SLOTS.
##
## Layout-ViewModel §8 item 5 named the gap: `HeadlessApp` holds several
## sessions and knows which is active, the terminal had a `SessionTab` type
## for its header, and nothing drove a strip. This module is the strip's
## logical state — the tabs, their titles, which is active — and its four
## operations: activate, close, reorder, and step to the next / previous tab.
## It DERIVES the tabs from the slots every time it is asked rather than
## keeping a list of its own, so the strip and the application cannot
## disagree about which sessions exist; the terminal's header and GPUI's top
## bar both render `tabsOf`.
##
## Which tabs are SCROLLED into view when the strip is too narrow is the
## renderer's (it is a measurement); `scrollToShow` below is the one rule
## both renderers use to keep the active tab visible.

import codetracer_embed   # the store's agent sessions (`AgentSessionsState`)

import ./headless_app

type
  SessionTabAgent* = object
    ## PLAT-49 part B (finding 7): THE AGENT RUNNING IN A TAB, if any — the
    ## spec's progress indicator for a tab whose session has an agent task
    ## (Agentic-Coding-Integration.milestones.org: "The caption/tab area shows
    ## live agent progress as completed/total milestones"; DeepReview
    ## Agentic-Coding-Integration.md §3.1: agent icon, task name, milestone
    ## counter, progress bar, percentage; §3.2's states).
    present*: bool
      ## The session has an agent task at all.
    running*: bool
      ## It is connecting or working — the indicator animates, the tooltip
      ## says so.
    lifecycle*: AgentServiceLifecycle
    task*: string
      ## The task's name (`AgentServiceSessionEntry.title`).
    completed*, total*: int
      ## Milestones done, and in all (0 when the agent declared none).

  SessionTabView* = object
    id*: HeadlessSessionId
    title*: string
    active*: bool
    label*: string
      ## What the tab shows: the title, and — while an agent works in the
      ## session — its `completed/total` (`agentic_session_vm
      ## .captionForSession`'s spelling).
    tooltip*: string
      ## What hovering the tab says: the session's full title, and with an
      ## agent in it the task, its state and its progress
      ## (`agentTooltipText`).
    closable*: bool
      ## Draw a close control: the desktop's `.session-tab-close`, present
      ## only while there are several tabs (`multiSession`).
    agent*: SessionTabAgent

const
  SessionTabCloseGlyph* = "×"
  NewSessionTabGlyph* = "+"
    ## PLAT-49 part B: the strip's add control — the desktop's
    ## `.session-tab-add`, shown whether there are tabs or not
    ## (Multi-Window-Tab-Management.md, Tab Behavior rule 3: '"+" opens a new
    ## empty tab (for loading a new trace)').
  NewSessionTabTitle* = "New tab"
    ## Its tooltip, the desktop's (`isonim_session_tabs_view
    ## .SessionTabAddTitle`).

func agentRunning(l: AgentServiceLifecycle): bool =
  l in {aslConnecting, aslRunning}

func progressPercent*(a: SessionTabAgent): int =
  ## Whole percent of the milestones done; 0 when there are none.
  if a.total <= 0: 0 else: (100 * a.completed) div a.total

func agentStateText*(l: AgentServiceLifecycle): string =
  case l
  of aslDisconnected: "disconnected"
  of aslConnecting: "starting"
  of aslRunning: "working"
  of aslCompleted: "completed"
  of aslCancelled: "cancelled"
  of aslError: "failed"

func agentProgressText*(a: SessionTabAgent): string =
  ## `13/24 milestones (54%)`, or "" when the agent declared no milestones.
  if a.total <= 0: ""
  else: $a.completed & "/" & $a.total & " milestones (" &
        $a.progressPercent & "%)"

func agentTooltipText*(title: string; a: SessionTabAgent): string =
  ## A tab's tooltip: its title, then — with an agent in the session — "agent
  ## <state>: <task> — <progress>".
  result = title
  if not a.present:
    return
  result.add " — agent " & agentStateText(a.lifecycle)
  if a.task.len > 0:
    result.add ": " & a.task
  let p = agentProgressText(a)
  if p.len > 0:
    result.add " — " & p

proc agentOf*(state: AgentSessionsState): SessionTabAgent =
  ## The agent a session's tab reports: the store's active agent session,
  ## else the first running one, else the first.
  if state.sessions.len == 0:
    return
  var pick = -1
  for i, e in state.sessions:
    if e.tabId.len > 0 and e.tabId == state.activeTabId:
      pick = i
  if pick < 0:
    for i, e in state.sessions:
      if agentRunning(e.lifecycle):
        pick = i
        break
  if pick < 0:
    pick = 0
  let e = state.sessions[pick]
  SessionTabAgent(present: true, running: agentRunning(e.lifecycle),
                  lifecycle: e.lifecycle,
                  task: (if e.title.len > 0: e.title else: e.prompt),
                  completed: e.milestonesCompleted,
                  total: e.milestonesTotal)

func tabLabelOf*(title: string; a: SessionTabAgent): string =
  ## The tab's text: the title, with the agent's `completed/total` while it
  ## works (`captionForSession`'s spelling).
  result = title
  if a.running and a.total > 0:
    result.add " " & $a.completed & "/" & $a.total

proc tabsOf*(app: HeadlessApp): seq[SessionTabView] =
  ## Every session, in strip order, with its title, whether it is active, and
  ## (PLAT-49 part B) its label, tooltip, close control and agent.
  if app.isNil:
    return
  let ids = app.slotIds()
  for id in ids:
    let s = app.slot(id)
    if s.isNil:
      continue
    let title = if s.title.len > 0: s.title else: $id
    var agent = SessionTabAgent()
    if not s.session.isNil and not s.session.store.isNil:
      agent = agentOf(s.session.store.agentSessions.val)
    result.add SessionTabView(id: id, title: title,
                              active: id == app.activeSessionId(),
                              label: tabLabelOf(title, agent),
                              tooltip: agentTooltipText(title, agent),
                              closable: ids.len > 1,
                              agent: agent)

proc activeTabIndex*(app: HeadlessApp): int =
  for i, t in app.tabsOf():
    if t.active:
      return i
  -1

proc activateTab*(app: HeadlessApp; index: int): bool =
  let tabs = app.tabsOf()
  if index < 0 or index >= tabs.len or tabs[index].active:
    return false
  app.activate(tabs[index].id)

proc stepTab*(app: HeadlessApp; delta: int): bool =
  ## The next (`delta > 0`) or previous tab, wrapping — a strip with one tab
  ## does nothing.
  let tabs = app.tabsOf()
  if tabs.len < 2:
    return false
  let at = max(0, app.activeTabIndex())
  app.activateTab((at + delta + tabs.len) mod tabs.len)

proc closeTab*(app: HeadlessApp; index: int;
               disconnectBackend = true): bool =
  let tabs = app.tabsOf()
  if index < 0 or index >= tabs.len:
    return false
  app.closeSession(tabs[index].id, disconnectBackend)

proc moveTab*(app: HeadlessApp; index, toIndex: int): bool =
  let tabs = app.tabsOf()
  if index < 0 or index >= tabs.len:
    return false
  app.moveSlot(tabs[index].id, toIndex)

func scrollToShow*(widths: seq[int]; active, budget, current: int): int =
  ## The first tab to draw so that the ACTIVE tab is inside `budget` cells or
  ## pixels, starting from the current first tab `current` — the strip
  ## scrolls only as far as it must. `widths` are the tabs' extents.
  if widths.len == 0 or active < 0:
    return 0
  var first = max(0, min(current, widths.high))
  if active < first:
    return active
  while first < active:
    var used = 0
    for i in first .. active:
      used += widths[i]
    if used <= budget:
      break
    inc first
  first
