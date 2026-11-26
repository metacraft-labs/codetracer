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
  import ./measured_width
  from ../lib/jslib import windowSetTimeout
  import std/[jsffi, jsconsole]
  import kdom except Location
  import ../context_menu_item
  from ../viewmodel/views/context_menu_bridge import showContextMenu
  when not defined(ctWeb):
    import ../viewmodel/input/dom_pointer
    from ../viewmodel/keymap/scope_path import TopBarScope

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
  var tabBarWidth: MeasuredWidth
    ## The bar's width, kept between renders (`ui/measured_width`): read again
    ## only after a resize of the window or of the bar.
  var observedTabBar: isonim_dom.Element
  var observingTabBar = false
    ## Whether a ResizeObserver watches `observedTabBar`.
  proc observeResize(el: isonim_dom.Element; onResize: proc() {.closure.}): bool
    {.importjs: "((el, cb) => { if (typeof ResizeObserver !== 'function') return false; new ResizeObserver(() => cb()).observe(el); return true; })(#, #)".}
  var resizeRenderPending = false

# ---------------------------------------------------------------------------
# Model derivation and direct rendering
# ---------------------------------------------------------------------------

proc sessionLabel(session: ReplaySession, index: int): cstring =
  ## Derive a human-readable label for a session tab.
  ## Edit sessions use the workspace directory; replay sessions use the trace
  ## program; blank welcome sessions fall back to a generic tab label.
  if session.startOptions.edit and session.startOptions.folder.len > 0:
    return baseName(session.startOptions.folder)
  if not session.trace.isNil and session.trace.program.len > 0:
    return baseName(session.trace.program)
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

    # Kept between renders: this runs on every redraw, and each read forces a
    # layout (`ui/measured_width`). Without a ResizeObserver to say when the
    # bar changed size, it is read every time, as before.
    if not observingTabBar or observedTabBar != container:
      observedTabBar = container
      tabBarWidth.invalidate()
      observingTabBar =
        observeResize(container, proc() = tabBarWidth.invalidate())
    if not observingTabBar:
      tabBarWidth.invalidate()
    let width = tabBarWidth.widthOf(proc(): int = container.clientWidth)
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
      tabBarWidth.invalidate()
      if resizeRenderPending:
        return
      resizeRenderPending = true
      discard windowSetTimeout(proc() =
        resizeRenderPending = false
        requestSessionTabsRender(data),
        50))

  when not defined(ctWeb):
    proc sessionTabIndexOf(el: JsObject): int {.importjs:
      "((e) => { const t = (e && e.closest) ? e.closest('.session-tab') : null; " &
      "const m = (t && t.id) ? /^session-tab-(\\d+)$$/.exec(t.id) : null; " &
      "return m ? parseInt(m[1], 10) : -1; })(#)".}
    proc closestSessionTab(el: JsObject): JsObject {.importjs:
      "((e) => (e && e.closest) ? e.closest('.session-tab') : null)(#)".}

    var openInNewWindowInstalled = false

    proc installOpenInNewWindowMenu(data: Data) =
      ## Multi-Window-Tab-Management.md §"Multi-Window Behavior" (3): a
      ## right-click on a session tab offers "Open in New Window", which asks
      ## the main process for a secondary window on that session
      ## (`CODETRACER::open-new-window`, `index/window.onOpenNewWindow`).
      ##
      ## The press is the pointer keymap's (Input-Routing §5.1): the strip is
      ## the `topBar` scope (`data-ct-pane`), a session tab its `tab` element
      ## (this hit test), and a right click on it resolves to
      ## `context-menu.open`, which the desktop's fallback hands to the menu
      ## registered for the scope here. No listener on the tab itself.
      ## Desktop only: the web build has no second window (`capMultiWindow`).
      if openInNewWindowInstalled:
        return
      openInNewWindowInstalled = true
      registerHitTest(TopBarScope, proc(target, event: JsObject): ElementHit =
        let tab = closestSessionTab(target)
        if tab.isNil or tab.isUndefined: ElementHit()
        else: ElementHit(element: tab, kind: "tab"))
      registerPaneMenu(TopBarScope, proc(press: ElementPress): bool =
        let index = sessionTabIndexOf(press.element)
        if index < 0:
          return false
        let x = press.event.clientX.to(int)
        let y = press.event.clientY.to(int)
        # The tab is named by its id, not its place in the strip: the main
        # process knows a tab of this window by the id its messages carry.
        let session = if index < data.sessions.len: data.sessions[index] else: nil
        if session.isNil:
          return false
        let tabId = int(session.id)
        showContextMenu(@[ContextMenuItem(
          name: cstring"Open in New Window", hint: cstring"",
          handler: proc(e: kdom.Event) =
            console.log cstring"session_tabs: open tab in a new window: ", tabId
            data.ipc.send(cstring"CODETRACER::open-new-window",
                          js{sessionId: tabId}))], x, y)
        true)

  var lastDrawnBar: isonim_dom.Element
  var lastDrawnSignature = ""
    ## The strip the last draw went into, and what it showed
    ## (`renderIsoNimSessionTabs`).

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

    let records = sessionTabRecords(data)
    let visibleCount = visibleTabCapacity(container, records.len)
    # The strip as drawn: its tabs, the active one and how many fit.
    #
    # Every redraw asks for the strip again (`ui/menu.nim`), and drawing it
    # replaces every node in it. A press on "+" or a tab whose release came
    # after such a redraw went down on one node and up on another, so the
    # browser sent no click and the press did nothing: on a busy window the
    # first click on "+" often opened no tab. The strip is only drawn again
    # when what it shows has changed.
    var signature = $data.activeSessionIndex & "/" & $visibleCount
    for record in records:
      signature.add "/" & record.label
    if container == lastDrawnBar and signature == lastDrawnSignature and
        not isonim_dom.isNodeNil(isonim_dom.Node(container).firstChild):
      return
    lastDrawnBar = container
    lastDrawnSignature = signature

    let r = WebRenderer()
    let overflowWasOpen = container.hasClass(cstring"overflow-open")
    renderSessionTabsInto(
      r,
      container,
      records,
      data.activeSessionIndex,
      visibleCount,
      sessionTabCallbacks(data))
    if overflowWasOpen:
      container.addClass(cstring"overflow-open")
    when not defined(ctWeb):
      # The strip is the `topBar` press scope (scope_path.TopBarScope).
      isonim_dom.setAttribute(container, cstring"data-ct-pane", cstring TopBarScope)
      installOpenInNewWindowMenu(data)

  proc requestSessionTabsRender*(data: Data) =
    ## Refresh the direct IsoNim tab-bar mount after explicit session state
    ## changes. This replaces the previous Karax host stub and global redraw
    ## callback path.
    installResizeRender(data)
    renderIsoNimSessionTabs(data)
else:
  proc requestSessionTabsRender*(data: Data) =
    discard
