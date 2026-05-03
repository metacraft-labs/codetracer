## Session tab bar for multi-replay sessions (M10, M12).
##
## Renders a horizontal tab bar inside the caption/menu bar area (next
## to the omnibox), one tab per ``ReplaySession``. The active session
## is visually highlighted. With a single session (the current default)
## the bar is hidden via the ``.single-session`` CSS class.
##
## M12: The "+" button creates a new empty ReplaySession and switches
## to it. The new session inherits the current layout config so the
## panel arrangement is preserved.
##
## Rendering uses IsoNim WebRenderer for direct DOM construction,
## replacing the legacy Karax buildHtml approach. The tab bar still
## uses the same CSS classes and DOM structure for backward compatibility
## with Playwright tests and CSS styling.

import
  std/strformat,
  karax, karaxdsl, vdom,
  session_switch,
  ../types,
  ../viewmodel/views/isonim_session_tabs_view

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

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

proc sessionTabRecords(data: Data): seq[SessionTabRecord] =
  for i in 0 ..< data.sessions.len:
    result.add(SessionTabRecord(label: $sessionLabel(data.sessions[i], i)))

proc sessionTabCallbacks(data: Data): SessionTabsCallbacks =
  SessionTabsCallbacks(
    onSelect: proc(index: int) = switchSession(data, index),
    onClose: proc(index: int) = closeSession(data, index),
    onAdd: proc() = createNewSession(data))

# ---------------------------------------------------------------------------
# IsoNim WebRenderer rendering
# ---------------------------------------------------------------------------

when defined(js):
  proc renderIsoNimSessionTabs*(data: Data) =
    ## Build the session tab bar DOM using IsoNim WebRenderer and
    ## render directly into the existing `#session-tab-bar` element.
    ##
    ## Structure:
    ##   div#session-tab-bar.session-tab-bar[.single-session]
    ##     div.session-tab[.active]#session-tab-{i}
    ##       span.session-tab-label
    ##       span.session-tab-close            (only when multiple)
    ##     div.session-tab-add                 (the "+" button)
    let container = isonim_dom.getElementById(isonim_dom.document,
                                               cstring"session-tab-bar")
    if isonim_dom.isNodeNil(isonim_dom.Node(container)):
      return

    let r = WebRenderer()
    renderSessionTabsInto(
      r,
      container,
      sessionTabRecords(data),
      data.activeSessionIndex,
      sessionTabCallbacks(data))

  proc requestSessionTabsRender*(data: Data) =
    ## Refresh the direct IsoNim tab-bar mount after explicit session state
    ## changes.  This replaces the previous global redrawAll callback.
    renderIsoNimSessionTabs(data)
else:
  proc requestSessionTabsRender*(data: Data) =
    discard
