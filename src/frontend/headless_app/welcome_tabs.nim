## headless_app/welcome_tabs.nim — PLAT-51 deliverable 8: THE TABS A "+"
## OPENS, beside the session tabs, on the terminal and in the GPUI window.
##
## Multi-Window-Tab-Management.md rule 3: the "+" opens a new tab showing the
## Welcome Screen; choosing an option turns that tab into the session it
## starts. A `HeadlessApp` slot is a REPLAY session over a backend
## (`openSession` refuses one without), so a tab that is not yet a session —
## or that became an Edit-mode session over a folder, which has no engine —
## is kept here, and the strip is the slots' tabs followed by these
## (`stripTabsOf`). A tab that becomes a replay leaves this list: the host
## opens the recording as an ordinary slot and closes the welcome tab it came
## from (`closeWelcomeTab`), so the strip shows it where the session is.
##
## Both native front-ends render `stripTabsOf` and resolve a click through
## `stripTabAt`, so the strip and the hit-test cannot disagree about which
## tab is which. Pure: no renderer, no session.

import std/strutils

import ./headless_app
import ./session_tabs

export session_tabs

type
  WelcomeTabKind* = enum
    wtkWelcome = "welcome"
      ## Still the Welcome Screen.
    wtkFolder = "folder"
      ## Turned into an Edit-mode session over `folder` (Open folder).

  WelcomeTab* = object
    serial*: int
      ## Stable for the tab's life: what a host keys its per-tab state by.
    kind*: WelcomeTabKind
    folder*: string

  WelcomeTabs* = object
    tabs*: seq[WelcomeTab]
    active*: int
      ## Index into `tabs` of the tab shown, or -1 when a SESSION tab is.
    nextSerial*: int

  StripTabRef* = object
    ## What a strip index stands for.
    isWelcome*: bool
    sessionIndex*: int
      ## Into `app.tabsOf()`, when not a welcome tab.
    welcomeIndex*: int
      ## Into `WelcomeTabs.tabs`, when one.

const
  WelcomeTabTitle* = "Welcome"
    ## A new tab's label until it becomes a session (the desktop's new tab
    ## shows its welcome screen under the product's name).

func initWelcomeTabs*(): WelcomeTabs =
  WelcomeTabs(tabs: @[], active: -1, nextSerial: 1)

func welcomeShown*(w: WelcomeTabs): bool =
  ## A welcome (or folder) tab is the one shown, not a session tab.
  w.active >= 0 and w.active < w.tabs.len

func shownTab*(w: WelcomeTabs): WelcomeTab =
  if w.welcomeShown: w.tabs[w.active] else: WelcomeTab()

proc addWelcomeTab*(w: var WelcomeTabs): int =
  ## The "+": a new Welcome tab, appended and shown. Answers its index.
  w.tabs.add WelcomeTab(serial: w.nextSerial, kind: wtkWelcome)
  inc w.nextSerial
  w.active = w.tabs.high
  w.active

proc closeWelcomeTab*(w: var WelcomeTabs; index: int) =
  ## Remove tab `index` (closed, or turned into a replay slot). When it was
  ## the one shown, the session tabs are shown again.
  if index < 0 or index >= w.tabs.len:
    return
  w.tabs.delete(index)
  if w.active == index:
    w.active = -1
  elif w.active > index:
    dec w.active

proc turnIntoFolder*(w: var WelcomeTabs; index: int; folder: string) =
  ## Open folder: the tab becomes an Edit-mode session over `folder`.
  if index < 0 or index >= w.tabs.len:
    return
  w.tabs[index].kind = wtkFolder
  w.tabs[index].folder = folder

func folderTitle*(folder: string): string =
  var f = folder
  while f.len > 1 and f[^1] == '/':
    f.setLen(f.len - 1)
  let at = f.rfind('/')
  if at >= 0 and at < f.high: f[at + 1 .. ^1] else: f

proc stripTabsOf*(app: HeadlessApp; w: WelcomeTabs): seq[SessionTabView] =
  ## The whole strip: the session tabs (`tabsOf`), then the welcome and
  ## folder tabs. While one of those is shown no session tab is active;
  ## every tab may be closed when there are several.
  result = app.tabsOf()
  let shown = w.welcomeShown
  if shown:
    for t in result.mitems:
      t.active = false
  let total = result.len + w.tabs.len
  for t in result.mitems:
    t.closable = total > 1
  for i, t in w.tabs:
    let title = if t.kind == wtkFolder: folderTitle(t.folder)
                else: WelcomeTabTitle
    result.add SessionTabView(id: HeadlessSessionId(-1 - i), title: title,
                              active: shown and w.active == i,
                              label: title,
                              tooltip: (if t.kind == wtkFolder: t.folder
                                        else: WelcomeTabTitle),
                              closable: total > 1)

proc stripTabAt*(app: HeadlessApp; w: WelcomeTabs; index: int): StripTabRef =
  ## Strip index `index` -> a session tab or a welcome tab.
  let sessions = app.tabsOf().len
  if index < sessions:
    StripTabRef(isWelcome: false, sessionIndex: index, welcomeIndex: -1)
  else:
    StripTabRef(isWelcome: true, sessionIndex: -1,
                welcomeIndex: index - sessions)
