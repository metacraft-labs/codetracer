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
## Rendering uses IsoNim WebRenderer for direct DOM construction while keeping
## the same CSS classes and DOM structure for backward compatibility with
## Playwright tests and CSS styling.

import
  std/strformat,
  session_switch,
  ../types,
  ../viewmodel/views/isonim_session_tabs_view

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  from ../lib/jslib import windowSetTimeout

  proc requestSessionTabsRender*(data: Data)

  proc toggleClass(el: isonim_dom.Element; className: cstring) {.
    importcpp: "#.classList.toggle(#)".}
  proc addClass(el: isonim_dom.Element; className: cstring) {.
    importcpp: "#.classList.add(#)".}
  proc hasClass(el: isonim_dom.Element; className: cstring): bool {.
    importcpp: "#.classList.contains(#)".}
  proc clientWidth(el: isonim_dom.Element): int {.importcpp: "#.clientWidth".}
  proc appendToDocumentBody(node: isonim_dom.Element) {.importjs: "document.body.appendChild(#)".}
  proc insertBeforeNode(parent, node, reference: isonim_dom.Element) {.importjs: "#.insertBefore(#, #)".}
  proc parentElement(node: isonim_dom.Element): isonim_dom.Element {.importjs: "#.parentNode".}
  proc addWindowResizeListener(handler: proc() {.closure.}) {.importjs: "window.addEventListener('resize', #)".}

  var resizeRenderInstalled = false
  var resizeRenderPending = false

# ---------------------------------------------------------------------------
# Model derivation and direct rendering
# ---------------------------------------------------------------------------

proc sessionLabel(session: ReplaySession, index: int): cstring =
  ## Derive a human-readable label for a session tab.
  ## Prefer the trace program name; fall back to a generic "Trace N".
  if not session.trace.isNil and session.trace.program.len > 0:
    session.trace.program
  else:
    cstring(fmt"Trace {index + 1}")

proc sessionTabRecords(data: Data): seq[SessionTabRecord] =
  for i in 0 ..< data.sessions.len:
    result.add(SessionTabRecord(label: $sessionLabel(data.sessions[i], i)))

proc sessionTabCallbacks(data: Data): SessionTabsCallbacks =
  SessionTabsCallbacks(
    onSelect: proc(index: int) = switchSession(data, index),
    onClose: proc(index: int) = closeSession(data, index),
    onAdd: proc() = createNewSession(data),
    onToggleOverflow: proc() =
      when defined(js):
        let bar = isonim_dom.getElementById(
          isonim_dom.document,
          cstring SessionTabBarId)
        if not isonim_dom.isNodeNil(isonim_dom.Node(bar)):
          bar.toggleClass(cstring"overflow-open")
      else:
        discard)

# ---------------------------------------------------------------------------
# IsoNim WebRenderer rendering
# ---------------------------------------------------------------------------

when defined(js):
  proc visibleTabCapacity(container: isonim_dom.Element; tabCount: int): int =
    ## Fit visible tabs from real caption space. Extra sessions stay reachable
    ## through the overflow menu instead of forcing tabs below their min width.
    if tabCount <= 0:
      return 0

    let width = container.clientWidth
    if width <= 0:
      return tabCount

    let tabStride = SessionTabMinWidthPx + SessionTabGapPx
    let capacityWithoutOverflow =
      max(0, (width - SessionTabButtonWidthPx -
        SessionTabHorizontalPaddingPx) div tabStride)
    if tabCount <= capacityWithoutOverflow:
      return tabCount

    max(0, min(tabCount, (width - (SessionTabButtonWidthPx * 2) -
      SessionTabHorizontalPaddingPx) div tabStride))

  proc ensureSessionTabBarHost(): isonim_dom.Element =
    ## Return the static tab-bar host, creating it if an older shell or test
    ## harness did not include the index.html node.
    result = isonim_dom.getElementById(
      isonim_dom.document,
      cstring SessionTabBarId)
    if not isonim_dom.isNodeNil(isonim_dom.Node(result)):
      return

    result = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(result, cstring"id", cstring SessionTabBarId)
    isonim_dom.setAttribute(result, cstring"class", cstring SessionTabBarClass)

    let menu = isonim_dom.getElementById(isonim_dom.document, cstring"menu")
    if not isonim_dom.isNodeNil(isonim_dom.Node(menu)):
      discard isonim_dom.appendChild(isonim_dom.Node(menu), isonim_dom.Node(result))
      return

    let rootContainer = isonim_dom.getElementById(
      isonim_dom.document,
      cstring"root-container")
    if isonim_dom.isNodeNil(isonim_dom.Node(rootContainer)):
      appendToDocumentBody(result)
    else:
      insertBeforeNode(rootContainer.parentElement(), result, rootContainer)

  proc installResizeRender(data: Data) =
    if resizeRenderInstalled:
      return
    resizeRenderInstalled = true
    addWindowResizeListener(proc() =
      if resizeRenderPending:
        return
      resizeRenderPending = true
      discard windowSetTimeout(proc() =
        resizeRenderPending = false
        requestSessionTabsRender(data),
        50))

  proc renderIsoNimSessionTabs*(data: Data) =
    ## Build the session tab bar DOM using IsoNim WebRenderer and
    ## render directly into `#session-tab-bar`.
    ##
    ## Structure:
    ##   div#session-tab-bar.session-tab-bar[.single-session]
    ##     div.session-tab[.active]#session-tab-{i}
    ##       span.session-tab-label
    ##       span.session-tab-close            (only when multiple)
    ##     div.session-tab-add                 (the "+" button)
    let container = ensureSessionTabBarHost()
    if isonim_dom.isNodeNil(isonim_dom.Node(container)):
      return

    let r = WebRenderer()
    let records = sessionTabRecords(data)
    let overflowWasOpen = container.hasClass(cstring"overflow-open")
    renderSessionTabsInto(
      r,
      container,
      records,
      data.activeSessionIndex,
      visibleTabCapacity(container, records.len),
      sessionTabCallbacks(data))
    if overflowWasOpen:
      container.addClass(cstring"overflow-open")

  proc requestSessionTabsRender*(data: Data) =
    ## Refresh the direct IsoNim tab-bar mount after explicit session state
    ## changes. This replaces the previous Karax host stub and global redraw
    ## callback path.
    installResizeRender(data)
    renderIsoNimSessionTabs(data)
else:
  proc requestSessionTabsRender*(data: Data) =
    discard
