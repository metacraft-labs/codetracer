## session_tab_strip_redraw_test.nim
##
## A PRESS ON THE SESSION STRIP SURVIVES A REDRAW.
##
## Every redraw of the window asks for the session strip again
## (`ui/menu.nim`'s `requestSessionTabsRenderSoon`), and the strip used to be
## drawn anew each time: every node in it, "+" included, was replaced. A
## browser sends `click` only when the press and the release land on the same
## node, so a press on "+" whose release came after a redraw opened no tab. On
## a busy window, which redraws many times a second, the first click on "+"
## often did nothing (the multi-window scenario's `session-add` step, at load
## ~105).
##
## The strip is now drawn again only when what it shows changes: its tabs'
## labels, the active tab, or how many fit. This suite holds both halves: a
## redraw that changes nothing keeps the node a press went down on, in the
## document; a redraw after a new tab, a renamed tab or another active tab
## draws the new strip.
##
## REAL: `ui/session_tabs.requestSessionTabsRender` (the call every redraw
## makes) and the window's `data` from `types`, over jsdom's DOM. No stand-in:
## `legacy_loop_dom_bootstrap` supplies the import-time Monaco models the
## legacy UI tree builds when it loads, as for the other renderer suites.
## jsdom has no layout, so the strip's width reads 0 and every tab is shown
## (`visibleTabCapacity`).
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import ./legacy_loop_dom_bootstrap
import std/[dom]

import ../types
import ../ui/[agent_activity, agent_workspace, layout, editor, trace, session_switch, session_tabs]

proc failExit() {.importjs: "(function() { process.exitCode = 1; })()".}
proc isConnected(n: Element): bool {.importjs: "(!!#.isConnected)".}

const ExpectedChecks = 7
var checks = 0
var failedChecks = 0
var caseFailed = false

template ck(cond: untyped; detail: string = "") =
  inc checks
  if not (cond):
    inc failedChecks
    caseFailed = true
    echo "    Check failed: " & astToStr(cond) &
      (if detail.len > 0: "  -- " & detail else: "")

proc endCase(name: string) =
  echo(if caseFailed: "  [FAILED] " else: "  [OK] ", name)
  caseFailed = false

proc plus(): Element = document.querySelector(cstring"#session-tab-bar .session-tab-add")
proc tabLabels(): seq[string] =
  for el in document.querySelectorAll(cstring"#session-tab-bar .session-tab-label"):
    result.add $el.textContent

echo ""
echo "[Suite] the session strip and the redraws around a press"

block:
  requestSessionTabsRender(data)
  let pressed = plus()
  ck not pressed.isNil, "the strip draws its \"+\""
  # A press goes down on "+", the window redraws, the press comes up.
  requestSessionTabsRender(data)
  requestSessionTabsRender(data)
  ck plus() == pressed, "a redraw that changes nothing keeps the \"+\" the press went down on"
  ck pressed.isConnected, "and it is still in the document, where the release lands"
  endCase("a redraw that changes nothing keeps the strip's nodes")

block:
  let before = plus()
  let second = newReplaySession(ReplaySessionId(data.sessions.len))
  second.startOptions = StartOptions()
  data.sessions.add second
  requestSessionTabsRender(data)
  ck tabLabels() == @["Trace 1", "Trace 2"], "a new tab is drawn: " & $tabLabels()
  ck plus() != before, "the strip was drawn again"
  data.activeSessionIndex = 1
  let beforeSwitch = plus()
  requestSessionTabsRender(data)
  ck plus() != beforeSwitch, "another active tab draws the strip again"
  data.activeSessionIndex = 0
  second.startOptions.edit = true
  second.startOptions.folder = cstring"/work/project"
  requestSessionTabsRender(data)
  ck tabLabels() == @["Trace 1", "project"], "a renamed tab is drawn: " & $tabLabels()
  endCase("a new, renamed or newly active tab draws the strip again")

echo "CHECKS: " & $checks
if checks != ExpectedChecks:
  echo "  [FAILED] assertion count is " & $checks & ", expected " & $ExpectedChecks
  failExit()
if failedChecks > 0:
  failExit()
