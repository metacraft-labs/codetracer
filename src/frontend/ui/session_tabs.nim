## Session tab bar for multi-replay sessions (M10, M12).
##
## Renders a horizontal tab bar inside the caption/menu bar area (next
## to the omnibox), one tab per ``ReplaySession``.  The active session
## is visually highlighted.  With a single session (the current default)
## the bar is hidden via the ``.single-session`` CSS class.
##
## M12: The "+" button creates a new empty ReplaySession and switches
## to it.  The new session inherits the current layout config so the
## panel arrangement is preserved.
##
## Rendering uses IsoNim WebRenderer for direct DOM construction,
## replacing the legacy Karax buildHtml approach. The tab bar still
## uses the same CSS classes and DOM structure for backward compatibility
## with Playwright tests and CSS styling.

import
  std/[strformat, strutils, jsffi],
  karax, karaxdsl, vdom,
  session_switch,
  ../types

from kdom import document, getElementById, Event, stopPropagation

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  from isonim/dsl/ui import ui
  from isonim/core/computation import createRenderEffect

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const tabIdPrefix = "session-tab-"

proc tabIndexFromId(id: cstring): int =
  ## Extract the integer session index from a tab element id like
  ## ``"session-tab-3"``.  Returns -1 if the id is malformed.
  let s = $id
  if s.startsWith(tabIdPrefix):
    try:
      return parseInt(s[tabIdPrefix.len .. ^1])
    except ValueError:
      discard
  return -1

# ---------------------------------------------------------------------------
# Click handler factories (avoid closure-in-loop capture issues)
# ---------------------------------------------------------------------------

when defined(js):
  proc makeTabClickHandler(data: Data; index: int): proc(ev: isonim_dom.Event) =
    ## Factory for tab click handlers. Creates a separate closure for
    ## each tab index to avoid the classic JS closure-in-loop bug.
    let idx = index
    result = proc(ev: isonim_dom.Event) =
      switchSession(data, idx)

  proc makeCloseClickHandler(data: Data; index: int): proc(ev: isonim_dom.Event) =
    ## Factory for close button click handlers.
    let idx = index
    result = proc(ev: isonim_dom.Event) =
      {.emit: "`ev`.stopPropagation();".}
      closeSession(data, idx)

# ---------------------------------------------------------------------------
# Post-render native click handler attachment (legacy, still used by Karax
# path when ?karax=1 is set)
# ---------------------------------------------------------------------------

proc attachTabClickHandlers*(data: Data) =
  ## Attach native DOM click handlers to every ``.session-tab`` element.
  ##
  ## This is the primary mechanism that ensures tab clicks always call
  ## ``switchSession``.  The Nim JS backend compiles closures inside
  ## for-loops into a **single shared closure environment**, so a
  ## ``let idx = i`` captured inside the loop body ends up pointing to
  ## the **last** loop index by the time any handler fires (the classic
  ## JS closure-in-loop bug).  We avoid this by using raw JS that creates
  ## a proper per-iteration closure via an IIFE.
  ##
  ## Called after every Karax redraw of the tab bar via the post-render
  ## callback registered in ``layout.nim``.
  {.emit: ["""
    (function() {
      var tabBar = document.getElementById('session-tab-bar');
      if (!tabBar) return;
      var tabs = tabBar.querySelectorAll('.session-tab');
      var switchFn = """, switchSession, """;
      var dataRef = """, data, """;
      for (var i = 0; i < tabs.length; i++) {
        (function(idx) {
          tabs[idx].addEventListener('click', function(ev) {
            switchFn(dataRef, idx);
          });
        })(i);
      }
    })();
  """].}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc sessionLabel(session: ReplaySession, index: int): cstring =
  ## Derive a human-readable label for a session tab.
  ## Prefer the trace program name; fall back to a generic "Trace N".
  if not session.trace.isNil and session.trace.program.len > 0:
    session.trace.program
  else:
    cstring(fmt"Trace {index + 1}")

proc renderSessionTabs*(data: Data): VNode =
  ## Legacy Karax render stub. Returns an empty container.
  ## The IsoNim renderer (renderIsoNimSessionTabs) is the primary
  ## rendering path, mounted via layout.nim.
  buildHtml(tdiv(id = "session-tab-bar", class = "session-tab-bar"))

# ---------------------------------------------------------------------------
# IsoNim WebRenderer rendering
# ---------------------------------------------------------------------------

when defined(js):
  proc renderIsoNimSessionTabs*(data: Data) =
    ## Build the session tab bar DOM using IsoNim WebRenderer.
    ## Renders directly into the #session-tab-bar element.
    ##
    ## Structure:
    ##   div#session-tab-bar.session-tab-bar[.single-session]
    ##     div.session-tab[.active]#session-tab-{i}
    ##       span.session-tab-label  "Trace N"
    ##       span.session-tab-close  "x"  (if multiple sessions)
    ##     div.session-tab-add  "+"
    let container = isonim_dom.getElementById(isonim_dom.document,
                                               cstring"session-tab-bar")
    if isonim_dom.isNodeNil(isonim_dom.Node(container)):
      return

    # Clear existing content for re-render.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let r = WebRenderer()

    # Update the container class based on session count.
    let barClass =
      if data.sessions.len <= 1: "session-tab-bar single-session"
      else: "session-tab-bar"
    r.setAttribute(container, "class", barClass)

    # Render each session tab.
    for i in 0 ..< data.sessions.len:
      let session = data.sessions[i]
      let isActive = i == data.activeSessionIndex
      let tabClass =
        if isActive: "session-tab active"
        else: "session-tab"
      let tabId = tabIdPrefix & $i
      let tab = ui(r):
        tdiv(class = tabClass, id = tabId):
          discard
      r.appendChild(container, tab)

      # Click handler for tab selection (uses factory to avoid
      # closure-in-loop capture issue).
      isonim_dom.addEventListener(isonim_dom.Node(tab), cstring"click",
        makeTabClickHandler(data, i))

      # Tab label
      let label = ui(r):
        span(class = "session-tab-label"):
          text $sessionLabel(session, i)
      r.appendChild(tab, label)

      # Close button (only when multiple sessions exist)
      if data.sessions.len > 1:
        let closeBtn = ui(r):
          span(class = "session-tab-close"):
            text "\u00D7"
        r.appendChild(tab, closeBtn)

        # Close handler with stopPropagation to prevent tab switch.
        isonim_dom.addEventListener(isonim_dom.Node(closeBtn), cstring"click",
          makeCloseClickHandler(data, i))

    # "+" button to create a new session.
    let addBtn = ui(r):
      tdiv(class = "session-tab-add"):
        text "+"
    r.appendChild(container, addBtn)
    isonim_dom.addEventListener(isonim_dom.Node(addBtn), cstring"click",
      proc(ev: isonim_dom.Event) =
        createNewSession(data)
    )
