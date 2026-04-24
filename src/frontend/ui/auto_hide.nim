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

# JS timer bindings used for hover delay.
proc jsSetTimeout(callback: proc(); delay: int): int {.importjs: "setTimeout(#, #)".}
proc jsClearTimeout(timerId: int) {.importjs: "clearTimeout(#)".}

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

proc clearChildren(el: Element) =
  ## Remove all child nodes from an element.
  while el.childNodes.len > 0:
    el.removeChild(el.childNodes[0])

# Forward-declare refreshAllStrips so the interaction handlers can call it,
# and the tab builder can reference the interaction handlers.
proc refreshAllStrips*(state: AutoHideState)

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
    # Dismiss the current overlay.
    state.activeOverlay = nil
    state.overlayPinned = false
  else:
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
  ## Re-render all three strip elements.
  if not stripsCreated:
    return
  for edge in AutoHideEdge:
    refreshStrip(state, edge)

proc setupStripElements*(state: AutoHideState) =
  ## Create the strip DOM elements and append them to the active session
  ## container as siblings of the GL ``<section id="main">``.
  ##
  ## Safe to call multiple times — only acts on the first invocation.
  if stripsCreated:
    return
  stripsCreated = true

  let sessionContainer = document.getElementById("session-container-0")
  if sessionContainer.isNil:
    return

  # The session container needs relative positioning so that the absolutely
  # positioned strips reference it correctly.
  sessionContainer.style.position = "relative"

  for edge in AutoHideEdge:
    let el = document.createElement("div")
    el.class = edgeStripClass(edge)
    el.style.display = "none"  # hidden by default (no panels)
    stripElements[edge] = el
    sessionContainer.appendChild(el)

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
