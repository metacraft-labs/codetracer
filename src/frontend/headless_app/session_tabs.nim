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

import ./headless_app

type
  SessionTabView* = object
    id*: HeadlessSessionId
    title*: string
    active*: bool

proc tabsOf*(app: HeadlessApp): seq[SessionTabView] =
  ## Every session, in strip order, with its title and whether it is active.
  if app.isNil:
    return
  for id in app.slotIds():
    let s = app.slot(id)
    if s.isNil:
      continue
    result.add SessionTabView(id: id,
                              title: (if s.title.len > 0: s.title else: $id),
                              active: id == app.activeSessionId())

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
