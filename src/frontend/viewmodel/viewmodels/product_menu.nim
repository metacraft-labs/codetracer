## viewmodels/product_menu.nim — PLAT-48 deliverable 1. THE PROGRAM MENU'S
## TREE, AS DATA, ONCE.
##
## Until PLAT-48 the tree was written inside `ui_js.webTechMenu` with the
## `defineMenu` macro, as `MenuNode`s — a JavaScript-only type holding
## `cstring`s — so no other front-end could read it, and a terminal or GPUI
## menu would have been a second hand-written copy that drifts. The tree is
## now this function's value: the desktop builds its `MenuNode`s from it
## (`ui_js.menuNodeOf`, which is also what the native macOS menu and the
## command palette read), and the terminal and GPUI put it in their
## `MenuVM` directly. The dynamic additions the desktop makes at run time —
## a launch configuration folder, the Nim-specific View items — stay the
## desktop's, because they depend on desktop state; they reach the desktop's
## `MenuVM` because that VM's tree is translated back out of the finished
## `MenuNode` tree.
##
## The platform bits (`os`) are the desktop's `MenuNodeOS` values, spelled
## as numbers here so this module imports nothing of the desktop's:
##
##   MacOS = 1, NonMacOS = 2, Host = 4, NonHost = 8.
##
## `applyPlatform` marks what a given front-end does not show.

import ./menu_vm

export menu_vm

const
  OsMac* = 1
  OsNonMac* = 2
  OsHost* = 4
  OsNonHost* = 8

func macRole(role: string): MenuItem =
  ## An item macOS draws itself (`macrole` in the old DSL). Its action is
  ## never run — macOS performs the role — and the old macro gave it
  ## `forwardContinue` as a placeholder, which is kept so the translated
  ## `MenuNode` is the one the native menu has always been sent.
  item(role, "forwardContinue", os = OsMac, role = role)

func macStandardFolder(): MenuItem =
  folder("CodeTracer", @[
    sep(macRole("about")),
    sep(macRole("services")),
    macRole("hide"), macRole("hideOthers"), sep(macRole("unhide")),
    macRole("quit")], os = OsMac, role = "")

proc productMenuTree*(program: string; shellUi = false): MenuItem =
  ## THE MENU. `program` titles the root (the trace's program name).
  ##
  ## Folder by folder the entries are the desktop's, in the desktop's order,
  ## with the desktop's labels and actions — see the history of
  ## `ui_js.webTechMenu` for why each is where it is (Stop in the Debug
  ## folder per Debugger-Controls.md; Keyboard Shortcuts in the menu and not
  ## on the top bar per Noir-Studio.md §1a.2; Report a Problem under Help).
  if shellUi:
    return folder(program, @[
      macStandardFolder(),
      folder("Themes", @[
        item("Mac Classic Theme", "aTheme0"),
        item("Default White Theme", "aTheme1"),
        item("Default Black Theme", "aTheme2"),
        item("Default Dark Theme", "aTheme3")]),
      folder("Window", @[
        macRole("minimize"), sep(macRole("zoom")),
        sep(macRole("front")),
        macRole("window")], os = OsMac, role = "window"),
      folder("Help", @[], os = OsMac, role = "help"),
      item("Exit CodeTracer", "aExit", os = OsNonMac)])

  folder(program, @[
    macStandardFolder(),
    folder("File", @[
      item("Open Trace...", "aOpenTrace"),
      item("Open Trace in New Tab...", "aOpenTraceInNewTab"),
      item("Record New Trace...", "aRecordNewTrace"),
      item("New Trace Tab", "aNewTraceTab"),
      item("Close Current File", "closeTab"),
      item("Reopen File", "reopenTab"),
      item("Next File", "switchTabRight"),
      item("Previous File", "switchTabLeft"),
      sep(item("Switch File", "switchTabHistory")),
      item("Exit CodeTracer", "aExit", os = OsNonHost or OsNonMac)]),
    folder("Edit", @[
      item("Find in Files", "findInFiles"),
      sep(item("Find Symbol", "findSymbol")),
      item("Expand All", "aExpandAll"),
      item("Collapse All", "aCollapseAll")]),
    folder("View", @[
      item("Filesystem", "aFilesystem"),
      item("Calltrace", "aFullCalltrace"),
      item("State", "aState"),
      item("Event Log", "aEventLog"),
      item("Timeline", "aTimeline"),
      item("Terminal Output", "aTerminal"),
      item("Scratchpad", "aScratchpad"),
      item("Breakpoints & Tracepoints", "aPointList"),
      item("Agent Activity", "aAgentActivity"),
      item("Verification", "aVerification"),
      item("Start Agent Worktree Session", "aStartAgenticWorktreeSession"),
      item("Notifications", "aNotifications"),
      item("Reset Layout", "aResetLayout"),
      sep(item("Shell", "aShell")),
      folder("Theme", @[
        item("Default Dark Theme", "aTheme3"),
        item("Default White Theme", "aTheme1")])]),
    folder("Build", @[
      item("Rebuild/Re-record file", "aReRecord"),
      item("Rebuild/Re-record project", "aReRecordProject"),
      item("Apply Edit & Hot-Reload", "aApplyEditAndReload"),
      item("Live Edit (HCR)…", "aToggleLiveEditPanel"),
      sep(item("Launch Under Live Edit (HCR)…", "aLaunchUnderHcr")),
      item("Go to Next Error", "aGotoNextError"),
      item("Go to Previous Error", "aGotoPreviousError")]),
    folder("Reset", @[
      item("Restart replay-server", "aRestartDbBackend"),
      item("Restart session-manager", "aRestartBackendManager")]),
    folder("Debug", @[
      item("Continue", "forwardContinue"),
      item("Step Over", "forwardNext"),
      item("Step In", "forwardStep"),
      item("Step Out", "forwardStepOut"),
      item("Reverse Continue", "reverseContinue"),
      item("Reverse Step Over", "reverseNext"),
      item("Reverse Step In", "reverseStep"),
      item("Reverse Step Out", "reverseStepOut"),
      sep(item("Stop", "stop")),
      sep(item("Keyboard Shortcuts", "aKeyboardShortcuts")),
      item("Add a Breakpoint", "aBreakpoint"),
      item("Delete Breakpoint", "aDeleteBreakpoint"),
      item("Delete All Breakpoints", "aDeleteAllBreakpoints"),
      item("Enable Breakpoint", "aEnableBreakpoint"),
      item("Enable All Breakpoints", "aEnableAllBreakpoint"),
      item("Disable Breakpoint", "aDisableBreakpoint"),
      sep(item("Disable All Breakpoints", "aDisableAllBreakpoints")),
      item("Add a Tracepoint", "aTracepoint"),
      item("Delete Tracepoint", "aDeleteTracepoint"),
      item("Enable Tracepoint", "aEnableTracepoint"),
      item("Enable All Tracepoints", "aEnableAllTracepoints"),
      item("Disable Tracepoint", "aDisableTracepoint"),
      item("Disable All Tracepoints", "aDisableAllTracepoints"),
      sep(item("Run All Tracepoints", "aCollectEnabledTracepointResults")),
      item("Invite to Collaborative Session...", "aCollabInvite")]),
    folder("Window", @[], os = OsMac, role = "window"),
    folder("Help", @[item("Report a Problem...", "aReportProblem")],
           os = OsMac, role = "help"),
    folder("Help", @[item("Report a Problem...", "aReportProblem")],
           os = OsNonMac)])

func hiddenOn*(os: int; ownsWindow: bool): bool =
  ## Whether an item with platform bits `os` is hidden in an in-page menu:
  ## the desktop's `ui/menu.shouldRenderMenuNode`, which every non-macOS
  ## in-page menu uses (macOS draws its menu natively and never shows this
  ## one). `ownsWindow` is `capWindowControls` on the desktop; the terminal
  ## and GPUI own their process and window, so they pass `true`.
  if ownsWindow:
    (os and OsHost) != 0 or (os and OsMac) != 0
  else:
    (os and OsNonHost) != 0 or (os and OsMac) != 0

proc applyPlatform*(root: var MenuItem; ownsWindow: bool) =
  ## Mark every item this front-end does not show `hidden`.
  for c in root.children.mitems:
    c.hidden = hiddenOn(c.os, ownsWindow)
    if c.kind == mikFolder:
      applyPlatform(c, ownsWindow)

proc nativeFrontEndMenu*(program: string): MenuItem =
  ## The tree the terminal and the GPUI window show: the product menu with
  ## the macOS-only entries hidden.
  result = productMenuTree(program)
  result.applyPlatform(ownsWindow = true)
