## Auto-hide strip UI for CodeTracer.
##
## Panels that are "auto-hidden" collapse into thin strips along the left,
## right, and bottom edges of the GoldenLayout container.  Each strip shows
## small tabs (icon + title) that can be clicked or hovered to slide the
## panel content in as an overlay.
##
## The strips are plain DOM elements created via `document.createElement` and
## appended as siblings of the GL `<section id="main">` inside the active
## session container.  This avoids interference with the Karax and
## GoldenLayout rendering pipelines.

import
  std/[jsffi, dom],
  ../types

# JS timer bindings used for hover delay and dismiss grace period.
proc jsSetTimeout(callback: proc(); delay: int): int {.importjs: "setTimeout(#, #)".}
proc jsClearTimeout(timerId: int) {.importjs: "clearTimeout(#)".}

# ---------------------------------------------------------------------------
# GoldenLayout FFI for detach / attach
# ---------------------------------------------------------------------------

proc detachChild*(stack: JsObject, item: JsObject): JsObject {.importjs: "#.detachChild(#)".}
proc attachChild*(stack: JsObject, detached: JsObject) {.importjs: "#.attachChild(#)".}

# Forward-declare restorePanel so the overlay header buttons can reference it.
proc restorePanel*(state: AutoHideState, panel: AutoHidePanel)

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc newAutoHideState*(): AutoHideState =
  ## Create an empty auto-hide state with no panels on any edge.
  AutoHideState(
    panels: [newSeq[AutoHidePanel](),   # Left
             newSeq[AutoHidePanel](),   # Right
             newSeq[AutoHidePanel]()],  # Bottom
    activeOverlay: nil,
    overlayPinned: false,
    nextId: 0
  )

proc addPanel*(state: AutoHideState,
               edge: AutoHideEdge,
               title: cstring,
               icon: cstring,
               content: Content,
               config: JsObject,
               preferredSize: float = 0.25): AutoHidePanel {.discardable.} =
  ## Add a new panel to the given edge strip and return it.
  let panel = AutoHidePanel(
    id: state.nextId,
    edge: edge,
    title: title,
    icon: icon,
    content: content,
    preferredSize: preferredSize,
    componentConfig: config
  )
  inc state.nextId
  state.panels[edge].add(panel)
  result = panel

proc removePanel*(state: AutoHideState, panelId: int) =
  ## Remove the panel with the given id from whichever edge it belongs to.
  for edge in AutoHideEdge:
    let panels = state.panels[edge]
    for i in 0 ..< panels.len:
      if panels[i].id == panelId:
        # If this panel's overlay is currently visible, dismiss it.
        if not state.activeOverlay.isNil and state.activeOverlay.id == panelId:
          state.activeOverlay = nil
          state.overlayPinned = false
        state.panels[edge].delete(i)
        return

proc findPanel*(state: AutoHideState, panelId: int): AutoHidePanel =
  ## Find a panel by id across all edges.  Returns nil if not found.
  for edge in AutoHideEdge:
    for panel in state.panels[edge]:
      if panel.id == panelId:
        return panel
  return nil

# ---------------------------------------------------------------------------
# CSS class names (keep in sync with auto_hide.styl)
# ---------------------------------------------------------------------------

const
  StripClass        = "auto-hide-strip"
  StripLeftClass    = "auto-hide-strip-left"
  StripRightClass   = "auto-hide-strip-right"
  StripBottomClass  = "auto-hide-strip-bottom"
  TabClass          = "auto-hide-tab"
  TabActiveClass    = "auto-hide-tab-active"
  TabIconClass      = "auto-hide-tab-icon"
  TabTitleClass     = "auto-hide-tab-title"

  # Overlay CSS classes (keep in sync with auto_hide.styl).
  BackdropClass       = "auto-hide-backdrop"
  OverlayClass        = "auto-hide-overlay"
  OverlayLeftClass    = "auto-hide-overlay-left"
  OverlayRightClass   = "auto-hide-overlay-right"
  OverlayBottomClass  = "auto-hide-overlay-bottom"
  OverlayVisibleClass = "auto-hide-overlay-visible"
  OverlayHeaderClass  = "auto-hide-overlay-header"
  OverlayTitleClass   = "auto-hide-overlay-title"
  OverlayBtnClass     = "auto-hide-overlay-btn"
  OverlayContentClass = "auto-hide-overlay-content"

  # Grace period (ms) before the overlay auto-dismisses on mouse-leave.
  DismissGraceMs = 300

proc edgeStripClass(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring(StripClass & " " & StripLeftClass)
  of Right:  cstring(StripClass & " " & StripRightClass)
  of Bottom: cstring(StripClass & " " & StripBottomClass)

# ---------------------------------------------------------------------------
# DOM management — forward declarations
# ---------------------------------------------------------------------------

# References to the three strip DOM elements so we can update them in place.
var
  stripElements: array[AutoHideEdge, Element]
  stripsCreated = false
  hoverTimerId: int = 0

  # Overlay DOM elements — a single shared overlay, backdrop, and dismiss timer.
  overlayEl: Element       ## The slide-in panel container.
  backdropEl: Element      ## Semi-transparent backdrop behind the overlay.
  overlayTitleEl: Element  ## Title text span inside the overlay header.
  overlayContentEl: Element ## Content area where panel DOM will be placed.
  overlayPinBtn: Element   ## Pin / unpin toggle button.
  dismissTimerId: int = 0  ## Grace timer for mouse-leave dismissal.
  escListenerInstalled = false

proc clearChildren(el: Element) =
  ## Remove all child nodes from an element.
  while el.childNodes.len > 0:
    el.removeChild(el.childNodes[0])

# Forward-declare refreshAllStrips so the interaction handlers can call it,
# and the tab builder can reference the interaction handlers.
proc refreshAllStrips*(state: AutoHideState)

proc edgeOverlayClass(edge: AutoHideEdge): string =
  ## Return the edge-specific CSS class for the overlay positioning.
  case edge
  of Left:   OverlayLeftClass
  of Right:  OverlayRightClass
  of Bottom: OverlayBottomClass

# ---------------------------------------------------------------------------
# Overlay show / hide
# ---------------------------------------------------------------------------

proc cancelDismissTimer() =
  ## Cancel any pending grace-period dismiss timer.
  if dismissTimerId != 0:
    jsClearTimeout(dismissTimerId)
    dismissTimerId = 0

proc showOverlay*(state: AutoHideState, panel: AutoHidePanel) =
  ## Position and reveal the overlay for the given panel.
  ## The overlay slides in from the edge where the panel's strip lives.
  if overlayEl.isNil:
    return

  # Update header title.
  if not overlayTitleEl.isNil:
    overlayTitleEl.innerHTML = panel.title

  # Update pin button text to reflect current pin state.
  if not overlayPinBtn.isNil:
    if state.overlayPinned:
      overlayPinBtn.innerHTML = cstring"\xF0\x9F\x93\x8C"  # 📌 (pinned)
    else:
      overlayPinBtn.innerHTML = cstring"\xF0\x9F\x93\x8C"  # same icon, styled differently via active class

  # Reparent the detached GL component's DOM element into the overlay content
  # area.  If no detached element is available, show a placeholder.
  if not overlayContentEl.isNil:
    clearChildren(overlayContentEl)
    if not panel.detachedElement.isNil:
      # The detached element from GL needs to fill the overlay content area.
      panel.detachedElement.style.width = "100%"
      panel.detachedElement.style.height = "100%"
      panel.detachedElement.style.display = "block"
      overlayContentEl.appendChild(panel.detachedElement)
    else:
      let placeholder = document.createElement("div")
      placeholder.style.padding = "16px"
      placeholder.style.color = "#888"
      placeholder.style.fontFamily = "SpaceGrotesk"
      placeholder.style.fontSize = "13px"
      placeholder.innerHTML = cstring("Panel content will appear here")
      overlayContentEl.appendChild(placeholder)

  # Set edge-specific class and size based on the panel's preferred dimension.
  let edgeCls = edgeOverlayClass(panel.edge)
  overlayEl.class = cstring(OverlayClass & " " & edgeCls)

  case panel.edge
  of Left, Right:
    let w = int(panel.preferredSize * float(window.innerWidth))
    overlayEl.style.width = cstring($w & "px")
    overlayEl.style.height = ""   # top/bottom set by CSS
  of Bottom:
    let h = int(panel.preferredSize * float(window.innerHeight))
    overlayEl.style.height = cstring($h & "px")
    overlayEl.style.width = ""    # left/right set by CSS

  # Show backdrop and overlay (display must come before adding visible class
  # so that the CSS transition fires from the off-screen transform).
  backdropEl.style.display = "block"
  overlayEl.style.display = "block"

  # Force a reflow so the browser registers the initial transform before we
  # add the visible class that transitions to the final position.
  discard overlayEl.offsetHeight

  # Slide in by adding the visible class.
  overlayEl.class = cstring(OverlayClass & " " & edgeCls & " " & OverlayVisibleClass)

proc hideOverlay*(state: AutoHideState) =
  ## Slide the overlay out and hide it.  Clears activeOverlay and overlayPinned.
  cancelDismissTimer()

  if overlayEl.isNil:
    return

  # Remove the visible class to trigger the slide-out CSS transition.
  if not state.activeOverlay.isNil:
    let edgeCls = edgeOverlayClass(state.activeOverlay.edge)
    overlayEl.class = cstring(OverlayClass & " " & edgeCls)
  else:
    # Fallback: just remove visible class if no panel reference.
    overlayEl.class = cstring(OverlayClass)

  # Detach the panel's DOM element from the overlay content area before hiding
  # so it isn't destroyed — it stays referenced by the panel for later re-show.
  let leavingPanel = state.activeOverlay
  if not leavingPanel.isNil and not leavingPanel.detachedElement.isNil and
     not overlayContentEl.isNil:
    if leavingPanel.detachedElement.parentNode == overlayContentEl:
      overlayContentEl.removeChild(leavingPanel.detachedElement)

  # After the transition completes (200ms matches the CSS), hide the elements
  # and clear any remaining placeholder content.
  discard jsSetTimeout(proc() =
    overlayEl.style.display = "none"
    backdropEl.style.display = "none"
    if not overlayContentEl.isNil:
      clearChildren(overlayContentEl)
  , 220)

  state.activeOverlay = nil
  state.overlayPinned = false

# ---------------------------------------------------------------------------
# Interaction handlers
# ---------------------------------------------------------------------------

proc cancelHover*() =
  ## Cancel any pending hover-triggered overlay activation.
  if hoverTimerId != 0:
    jsClearTimeout(hoverTimerId)
    hoverTimerId = 0

proc handleTabClick*(state: AutoHideState, panel: AutoHidePanel) =
  ## Toggle the overlay for the given panel.  If the same panel is already
  ## showing, dismiss it; otherwise switch to it.
  if not state.activeOverlay.isNil and state.activeOverlay.id == panel.id:
    # Clicking the active tab dismisses the overlay (hard dismiss).
    hideOverlay(state)
    refreshAllStrips(state)
  else:
    # Show the new panel's overlay, pinned (click implies intent to keep it).
    state.activeOverlay = panel
    state.overlayPinned = true
    refreshAllStrips(state)

proc handleTabHover*(state: AutoHideState, panel: AutoHidePanel) =
  ## Activate the overlay for the given panel after a short delay (300 ms).
  ## If the overlay is already pinned via click, hovering does nothing.
  cancelHover()
  if state.overlayPinned:
    return
  hoverTimerId = jsSetTimeout(proc() =
    hoverTimerId = 0
    if state.overlayPinned:
      return
    state.activeOverlay = panel
    refreshAllStrips(state)
  , 300)

# ---------------------------------------------------------------------------
# DOM element builders
# ---------------------------------------------------------------------------

proc buildTabElement(state: AutoHideState, panel: AutoHidePanel): Element =
  ## Create the DOM element for a single auto-hide tab.
  let tab = document.createElement("div")
  tab.class = cstring(TabClass)
  tab.setAttribute("data-panel-id", cstring($panel.id))

  # Active class when this panel's overlay is currently shown.
  if not state.activeOverlay.isNil and state.activeOverlay.id == panel.id:
    tab.class = cstring(TabClass & " " & TabActiveClass)

  # Icon span
  let iconSpan = document.createElement("span")
  iconSpan.class = cstring(TabIconClass & " ") & panel.icon
  tab.appendChild(iconSpan)

  # Title span
  let titleSpan = document.createElement("span")
  titleSpan.class = cstring(TabTitleClass)
  titleSpan.innerHTML = panel.title
  tab.appendChild(titleSpan)

  # Click handler — toggle overlay for this panel.
  tab.addEventListener("click", proc(ev: Event) =
    handleTabClick(state, panel)
  )

  # Hover handlers — activate overlay after a short delay.
  tab.addEventListener("mouseenter", proc(ev: Event) =
    handleTabHover(state, panel)
  )
  tab.addEventListener("mouseleave", proc(ev: Event) =
    cancelHover()
    # If an overlay is showing (hover-triggered, not pinned), start a grace
    # timer so it dismisses if the mouse doesn't re-enter.
    if not state.activeOverlay.isNil and not state.overlayPinned:
      cancelDismissTimer()
      dismissTimerId = jsSetTimeout(proc() =
        dismissTimerId = 0
        if not state.overlayPinned and not state.activeOverlay.isNil:
          hideOverlay(state)
          refreshAllStrips(state)
      , DismissGraceMs)
  )

  result = tab

proc refreshStrip(state: AutoHideState, edge: AutoHideEdge) =
  ## Re-render the strip element for one edge based on current state.
  let el = stripElements[edge]
  if el.isNil:
    return

  clearChildren(el)

  let panels = state.panels[edge]
  if panels.len == 0:
    # Hide the strip when there are no panels.
    el.style.display = "none"
  else:
    el.style.display = ""
    for panel in panels:
      el.appendChild(buildTabElement(state, panel))

proc refreshAllStrips*(state: AutoHideState) =
  ## Re-render all three strip elements and synchronise overlay visibility.
  if not stripsCreated:
    return
  for edge in AutoHideEdge:
    refreshStrip(state, edge)

  # Drive overlay visibility based on activeOverlay state.
  if not state.activeOverlay.isNil:
    showOverlay(state, state.activeOverlay)

proc setupStripElements*(state: AutoHideState) =
  ## Create the strip DOM elements and the shared overlay container, then
  ## append them to the active session container as siblings of the GL
  ## ``<section id="main">``.
  ##
  ## Safe to call multiple times — only acts on the first invocation.
  if stripsCreated:
    return
  stripsCreated = true

  let sessionContainer = document.getElementById("session-container-0")
  if sessionContainer.isNil:
    return

  # The session container needs relative positioning so that the absolutely
  # positioned strips and overlay reference it correctly.
  sessionContainer.style.position = "relative"

  for edge in AutoHideEdge:
    let el = document.createElement("div")
    el.class = edgeStripClass(edge)
    el.style.display = "none"  # hidden by default (no panels)
    stripElements[edge] = el
    sessionContainer.appendChild(el)

  # -------------------------------------------------------------------------
  # Overlay elements — a single shared overlay that slides in over the GL area.
  # -------------------------------------------------------------------------

  # Backdrop (semi-transparent, covers GL area but not the strips).
  backdropEl = document.createElement("div")
  backdropEl.class = cstring(BackdropClass)
  backdropEl.style.display = "none"
  sessionContainer.appendChild(backdropEl)

  # Dismiss overlay when the backdrop is clicked.
  backdropEl.addEventListener("click", proc(ev: Event) =
    hideOverlay(state)
    refreshAllStrips(state)
  )

  # Overlay panel container.
  overlayEl = document.createElement("div")
  overlayEl.class = cstring(OverlayClass)
  overlayEl.style.display = "none"
  sessionContainer.appendChild(overlayEl)

  # -- Header bar --
  let header = document.createElement("div")
  header.class = cstring(OverlayHeaderClass)

  overlayTitleEl = document.createElement("span")
  overlayTitleEl.class = cstring(OverlayTitleClass)
  header.appendChild(overlayTitleEl)

  # Pin button — restore the panel back to the GoldenLayout tree.
  overlayPinBtn = document.createElement("span")
  overlayPinBtn.class = cstring(OverlayBtnClass)
  overlayPinBtn.innerHTML = cstring"\xF0\x9F\x93\x8C"  # 📌
  overlayPinBtn.setAttribute("title", "Restore to layout")
  overlayPinBtn.addEventListener("click", proc(ev: Event) =
    let panel = state.activeOverlay
    if not panel.isNil:
      restorePanel(state, panel)
  )
  overlayPinBtn.style.opacity = "1.0"
  header.appendChild(overlayPinBtn)

  # Close button — restore panel to GL and dismiss overlay.
  let closeBtn = document.createElement("span")
  closeBtn.class = cstring(OverlayBtnClass)
  closeBtn.innerHTML = cstring"\xE2\x9C\x95"  # ✕
  closeBtn.setAttribute("title", "Restore to layout")
  closeBtn.addEventListener("click", proc(ev: Event) =
    let panel = state.activeOverlay
    if not panel.isNil:
      restorePanel(state, panel)
    else:
      hideOverlay(state)
      refreshAllStrips(state)
  )
  header.appendChild(closeBtn)

  overlayEl.appendChild(header)

  # -- Content area --
  overlayContentEl = document.createElement("div")
  overlayContentEl.class = cstring(OverlayContentClass)
  overlayEl.appendChild(overlayContentEl)

  # -------------------------------------------------------------------------
  # Dismissal handlers: mouse-leave grace timer
  # -------------------------------------------------------------------------

  # When the mouse leaves the overlay, start a grace timer.  If it re-enters
  # the overlay or a strip tab before the timer fires, cancel the dismiss.
  overlayEl.addEventListener("mouseleave", proc(ev: Event) =
    if state.overlayPinned:
      return
    cancelDismissTimer()
    dismissTimerId = jsSetTimeout(proc() =
      dismissTimerId = 0
      if not state.overlayPinned and not state.activeOverlay.isNil:
        hideOverlay(state)
        refreshAllStrips(state)
    , DismissGraceMs)
  )

  overlayEl.addEventListener("mouseenter", proc(ev: Event) =
    cancelDismissTimer()
  )

  # Also cancel the dismiss timer when hovering back over any strip tab.
  for edge in AutoHideEdge:
    stripElements[edge].addEventListener("mouseenter", proc(ev: Event) =
      cancelDismissTimer()
    )

  # -------------------------------------------------------------------------
  # Global Escape key dismissal
  # -------------------------------------------------------------------------

  if not escListenerInstalled:
    escListenerInstalled = true
    document.addEventListener("keydown", proc(ev: Event) =
      # keyCode 27 = Escape
      if cast[int](ev.toJs.keyCode) == 27:
        if not state.activeOverlay.isNil:
          hideOverlay(state)
          refreshAllStrips(state)
    )

  refreshAllStrips(state)

# ---------------------------------------------------------------------------
# Convenience: add / remove and auto-refresh
# ---------------------------------------------------------------------------

proc addPanelAndRefresh*(state: AutoHideState,
                         edge: AutoHideEdge,
                         title: cstring,
                         icon: cstring,
                         content: Content,
                         config: JsObject,
                         preferredSize: float = 0.25): AutoHidePanel {.discardable.} =
  ## Add a panel and immediately update the strip DOM.
  result = state.addPanel(edge, title, icon, content, config, preferredSize)
  refreshAllStrips(state)

proc removePanelAndRefresh*(state: AutoHideState, panelId: int) =
  ## Remove a panel and immediately update the strip DOM.
  state.removePanel(panelId)
  refreshAllStrips(state)

# ---------------------------------------------------------------------------
# Restore panel back to GoldenLayout
# ---------------------------------------------------------------------------

proc restorePanel*(state: AutoHideState, panel: AutoHidePanel) =
  ## Restore an auto-hidden panel back into the GoldenLayout tree.
  ##
  ## Uses the DetachedComponent handle saved during detach to call
  ## ``stack.attachChild(detached)`` on a suitable stack.  If no detached
  ## handle is available the panel is simply removed from auto-hide.

  # Dismiss the overlay first (if this panel is currently shown).
  if not state.activeOverlay.isNil and state.activeOverlay.id == panel.id:
    hideOverlay(state)

  if not panel.detachedHandle.isNil:
    # Find a suitable stack in the GL layout to re-attach to.
    # We access the layout via the global `data` object.  The import is
    # kept lightweight by going through JsObject.
    {.emit: """
      // Find the first stack in the GL ground item to attach to.
      var layout = `data`.ui.layout;
      if (layout && layout.groundItem) {
        var stacks = [];
        function findStacks(item) {
          if (item.isStack) stacks.push(item);
          if (item.contentItems) {
            for (var i = 0; i < item.contentItems.length; i++) {
              findStacks(item.contentItems[i]);
            }
          }
        }
        findStacks(layout.groundItem);
        if (stacks.length > 0) {
          stacks[0].attachChild(`panel`.detachedHandle);
        }
      }
    """.}

  # Clean up references on the panel.
  panel.detachedElement = nil
  panel.detachedHandle = nil

  # Remove the panel from auto-hide state and refresh strips.
  state.removePanel(panel.id)
  refreshAllStrips(state)
