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
  std/[jsffi, math],
  karax, kdom,
  ../types,
  ../lib/jslib

# ---------------------------------------------------------------------------
# localStorage FFI for persistence (M11)
# ---------------------------------------------------------------------------

proc localStorageGetItem(key: cstring): cstring {.importjs: "window.localStorage.getItem(#)".}
proc localStorageSetItem(key: cstring, value: cstring) {.importjs: "window.localStorage.setItem(#, #)".}

const AutoHideStorageKey = cstring"codetracer-auto-hide-state"

# JS timer bindings used for hover delay and dismiss grace period.
proc jsSetTimeout(callback: proc(); delay: int): int {.importjs: "setTimeout(#, #)".}
proc jsClearTimeout(timerId: int) {.importjs: "clearTimeout(#)".}
proc jsSetInterval(callback: proc(); interval: int): int {.importjs: "setInterval(#, #)".}

# ---------------------------------------------------------------------------
# Window / screen geometry FFI (M12: adaptive strip sizing)
# ---------------------------------------------------------------------------
# These map to standard Web API properties available in the Electron renderer
# process.  They let us detect whether a window edge coincides with the
# screen boundary without IPC to the main process.

proc windowScreenX(): int =
  {.emit: "`result` = (window.screenX || 0);".}
proc windowScreenY(): int =
  {.emit: "`result` = (window.screenY || 0);".}
proc windowOuterWidth(): int =
  {.emit: "`result` = (window.outerWidth || 0);".}
proc windowOuterHeight(): int =
  {.emit: "`result` = (window.outerHeight || 0);".}
proc screenAvailWidth(): int =
  {.emit: "`result` = (screen.availWidth || 0);".}
proc screenAvailHeight(): int =
  {.emit: "`result` = (screen.availHeight || 0);".}
proc screenAvailLeft(): int =
  {.emit: "`result` = (screen.availLeft || 0);".}
proc screenAvailTop(): int =
  {.emit: "`result` = (screen.availTop || 0);".}

proc styleSetProperty(el: Element, name: cstring, value: cstring) {.importjs: "#.style.setProperty(#, #)".}
  ## Set a CSS custom property (variable) on an element's inline style.

# ---------------------------------------------------------------------------
# GoldenLayout FFI for detach / attach
# ---------------------------------------------------------------------------

proc detachChild*(stack: JsObject, item: JsObject): JsObject {.importjs: "#.detachChild(#)".}
proc attachChild*(stack: JsObject, detached: JsObject) {.importjs: "#.attachChild(#)".}

# ---------------------------------------------------------------------------
# GoldenLayout FFI for DragSource registration (M9: drag-back)
# ---------------------------------------------------------------------------

proc glNewDragSource*(layout: JsObject, element: Element, callback: proc(): JsObject): JsObject {.importjs: "#.newDragSource(#, #)".}
proc glRemoveDragSource*(layout: JsObject, handle: JsObject) {.importjs: "#.removeDragSource(#)".}

# Module-level reference to the GoldenLayout instance, set from layout.nim
# after layout.loadLayout so that DragSource registration can access it.
var glLayout*: JsObject

# Stores DragSource handles keyed by panel id so they can be removed when the
# panel leaves the auto-hide strip (restore, drag-back, or close).
var dragSourceHandles: seq[tuple[panelId: int, handle: JsObject]]

proc setAutoHideLayout*(layout: JsObject) =
  ## Store the GoldenLayout instance for DragSource registration.
  ## Called from layout.nim after ``layout.loadLayout()``.
  glLayout = layout

proc removeDragSourceForPanel(panelId: int) =
  ## Remove and unregister the DragSource handle for the given panel id.
  if glLayout.isNil:
    return
  var idx = -1
  for i in 0 ..< dragSourceHandles.len:
    if dragSourceHandles[i].panelId == panelId:
      idx = i
      break
  if idx >= 0:
    glRemoveDragSource(glLayout, dragSourceHandles[idx].handle)
    dragSourceHandles.delete(idx)

# Forward-declare restorePanel so the overlay header buttons can reference it.
proc restorePanel*(state: AutoHideState, panel: AutoHidePanel)

# Forward-declare addPanel so deserializeAutoHideState can call it.
proc addPanel*(state: AutoHideState,
               edge: AutoHideEdge,
               title: cstring,
               icon: cstring,
               content: Content,
               config: JsObject,
               preferredSize: float = 0.25): AutoHidePanel {.discardable.}

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

# ---------------------------------------------------------------------------
# Serialization / deserialization (M11: persistence across restarts)
# ---------------------------------------------------------------------------

proc edgeToString(edge: AutoHideEdge): cstring =
  ## Convert an AutoHideEdge to its string representation for JSON.
  case edge
  of Left:   cstring"Left"
  of Right:  cstring"Right"
  of Bottom: cstring"Bottom"

proc stringToEdge(s: cstring): AutoHideEdge =
  ## Parse a string back to an AutoHideEdge.  Defaults to Bottom on unknown input.
  if s == cstring"Left":   return Left
  if s == cstring"Right":  return Right
  return Bottom

proc serializeAutoHideState*(state: AutoHideState): JsObject =
  ## Convert the auto-hide state to a JSON-serializable JS object.
  ##
  ## Saves each panel's edge, title, icon, content enum ordinal, preferred size,
  ## and GoldenLayout component config.  Runtime-only fields (detachedElement,
  ## detachedHandle) are deliberately omitted — they will be nil on load and
  ## panels will be lazily re-created when restored to GL.
  var panelArray = newSeq[JsObject]()
  for edge in AutoHideEdge:
    for panel in state.panels[edge]:
      let obj = JsObject{}
      obj.edge = edgeToString(panel.edge).toJs
      obj.title = panel.title.toJs
      obj.icon = panel.icon.toJs
      obj.content = cast[int](panel.content).toJs
      obj.preferredSize = panel.preferredSize.toJs
      if not panel.componentConfig.isNil:
        obj.componentConfig = panel.componentConfig
      else:
        obj.componentConfig = jsNull
      panelArray.add(obj)

  let resultObj = JsObject{}
  resultObj.panels = panelArray.toJs
  resultObj.nextId = state.nextId.toJs
  return resultObj

proc deserializeAutoHideState*(jsObj: JsObject): AutoHideState =
  ## Reconstruct an AutoHideState from a previously serialized JS object.
  ##
  ## Panels are created without detachedElement or detachedHandle — they show
  ## in the strips and their component config is available for creating a fresh
  ## GL component when the user restores or opens them.
  result = newAutoHideState()

  if jsObj.isNil:
    return

  let panels = jsObj.panels
  if panels.isNil or panels.isUndefined:
    return

  let length = cast[int](panels.length)
  for i in 0 ..< length:
    let p = panels[i]
    let edge = stringToEdge(cast[cstring](p.edge))
    let title = cast[cstring](p.title)
    let icon = cast[cstring](p.icon)
    let contentOrd = cast[int](p.content)
    let content = cast[Content](contentOrd)
    let preferredSize = cast[float](p.preferredSize)
    var config: JsObject = nil
    if not p.componentConfig.isNil and not p.componentConfig.isUndefined:
      config = p.componentConfig

    discard result.addPanel(edge, title, icon, content, config, preferredSize)

  # Restore the nextId counter so new panels don't collide with loaded ones.
  if not jsObj.nextId.isNil and not jsObj.nextId.isUndefined:
    result.nextId = cast[int](jsObj.nextId)

# ---------------------------------------------------------------------------
# Persistence via localStorage (M11)
# ---------------------------------------------------------------------------

proc saveAutoHideState*(state: AutoHideState) =
  ## Serialize the current auto-hide state and persist it to localStorage.
  ## Called from ``refreshAllStrips`` after every state mutation.
  let serialized = serializeAutoHideState(state)
  let json = JSON.stringify(serialized)
  localStorageSetItem(AutoHideStorageKey, json)

proc loadAutoHideState*(): AutoHideState =
  ## Load previously saved auto-hide state from localStorage.
  ## Returns a fresh empty state if nothing was saved or the data is invalid.
  let json = localStorageGetItem(AutoHideStorageKey)
  if json.isNil or json == cstring"":
    return newAutoHideState()
  try:
    let parsed = JSON.parse(json)
    return deserializeAutoHideState(cast[JsObject](parsed))
  except:
    # If the saved data is corrupted, start fresh rather than crashing.
    return newAutoHideState()

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
  ## Also removes any DragSource registration for the panel (M9).
  for edge in AutoHideEdge:
    let panels = state.panels[edge]
    for i in 0 ..< panels.len:
      if panels[i].id == panelId:
        # If this panel's overlay is currently visible, dismiss it.
        if not state.activeOverlay.isNil and state.activeOverlay.id == panelId:
          state.activeOverlay = nil
          state.overlayPinned = false
        # Remove the GL DragSource registration (M9: drag-back).
        removeDragSourceForPanel(panelId)
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
# DOM management — module-level state variables
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

  # M8: Edge indicator elements shown during GL drag-to-edge operations.
  indicatorElements: array[AutoHideEdge, Element]
  indicatorsCreated = false

  # M8: Track the most recently detected edge during a drag so the
  # ``dragExternalDrop`` handler knows where to place the panel.
  lastDragEdge*: AutoHideEdge = Bottom
  dragNearEdge*: bool = false

  # M12: Per-edge bounding state.  True when the window edge coincides with
  # the screen boundary (mouse can't overshoot → thin strip is fine).
  edgeBounded: array[AutoHideEdge, bool]
  boundingCheckStarted = false

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

  # M8: Edge indicator CSS class names (keep in sync with auto_hide.styl).
  IndicatorLeftClass    = "auto-hide-indicator-left"
  IndicatorRightClass   = "auto-hide-indicator-right"
  IndicatorBottomClass  = "auto-hide-indicator-bottom"

  # Distance in pixels from the container edge at which we consider the
  # cursor "near" the edge during a drag.
  EdgeThresholdPx = 60

  # M12: CSS class applied to strips whose edge is bounded by the screen
  # boundary (Fitts' Law — the mouse stops at the screen edge, so the
  # activation zone can be very thin).
  StripBoundedClass = "auto-hide-strip-bounded"

  # M12: Strip width in pixels when the edge is bounded vs unbounded.
  BoundedStripPx  = 3
  DefaultStripPx  = 28

  # M12: Tolerance in pixels for screen-edge detection.  A small tolerance
  # accounts for rounding and OS-specific insets.
  EdgeBoundTolerance = 4

proc edgeStripClass(edge: AutoHideEdge): cstring =
  ## Return the CSS class list for a strip element, including the bounded
  ## modifier when M12 edge-bounding detects the edge is at the screen boundary.
  let base = case edge
    of Left:   StripClass & " " & StripLeftClass
    of Right:  StripClass & " " & StripRightClass
    of Bottom: StripClass & " " & StripBottomClass
  if edgeBounded[edge]:
    cstring(base & " " & StripBoundedClass)
  else:
    cstring(base)

# ---------------------------------------------------------------------------
# M12: Adaptive strip sizing — detect bounded edges
# ---------------------------------------------------------------------------

proc updateEdgeBounding() =
  ## Check which window edges coincide with the screen work-area boundary.
  ##
  ## When an edge is "bounded" (i.e. the window extends to the screen edge),
  ## the mouse cursor physically stops at the screen boundary (Fitts' Law),
  ## so a very thin activation strip (3 px) is sufficient.  When the edge is
  ## "unbounded" (floating window, adjacent monitor) we keep the default
  ## 28 px strip so it is easy to target.
  ##
  ## Updates the ``edgeBounded`` array and refreshes strip CSS classes and
  ## the CSS custom properties used by the overlay inset.
  let winX = windowScreenX()
  let winY = windowScreenY()
  let winW = windowOuterWidth()
  let winH = windowOuterHeight()
  let scrW = screenAvailWidth()
  let scrH = screenAvailHeight()
  let scrLeft = screenAvailLeft()
  let scrTop  = screenAvailTop()

  edgeBounded[Left]   = (winX - scrLeft) <= EdgeBoundTolerance
  edgeBounded[Right]  = (scrLeft + scrW) - (winX + winW) <= EdgeBoundTolerance
  edgeBounded[Bottom] = (scrTop + scrH) - (winY + winH) <= EdgeBoundTolerance

  # Update strip element CSS classes to reflect bounded state.
  if stripsCreated:
    for edge in AutoHideEdge:
      stripElements[edge].class = edgeStripClass(edge)

    # Set CSS custom properties on the session container so the overlay
    # positioning (via var(--auto-hide-strip-*)) tracks the current strip
    # widths without hard-coded pixel values in the stylesheet.
    let container = document.getElementById("session-container-0")
    if not container.isNil:
      let leftPx  = if edgeBounded[Left]:   BoundedStripPx else: DefaultStripPx
      let rightPx = if edgeBounded[Right]:  BoundedStripPx else: DefaultStripPx
      let botPx   = if edgeBounded[Bottom]: BoundedStripPx else: DefaultStripPx
      styleSetProperty(container, cstring"--auto-hide-strip-left",   cstring($leftPx & "px"))
      styleSetProperty(container, cstring"--auto-hide-strip-right",  cstring($rightPx & "px"))
      styleSetProperty(container, cstring"--auto-hide-strip-bottom", cstring($botPx & "px"))

# ---------------------------------------------------------------------------
# M8: Edge indicators — shown during drag when cursor nears an edge
# ---------------------------------------------------------------------------

proc showEdgeIndicator*(edge: AutoHideEdge) =
  ## Make the indicator for the given edge visible; hide the others.
  if not indicatorsCreated:
    return
  for e in AutoHideEdge:
    if e == edge:
      indicatorElements[e].style.display = "block"
    else:
      indicatorElements[e].style.display = "none"

proc hideAllEdgeIndicators*() =
  ## Hide all edge indicators.
  if not indicatorsCreated:
    return
  for e in AutoHideEdge:
    indicatorElements[e].style.display = "none"

type DragEdgeResult* = tuple[edge: AutoHideEdge, near: bool]

proc detectNearestEdge*(x, y: float): DragEdgeResult =
  ## Determine which edge (if any) the cursor at ``(x, y)`` is close to.
  ## Returns the nearest edge and whether the cursor is within the threshold.
  ##
  ## Uses the bounding rect of ``#session-container-0`` as the reference frame.
  let container = document.getElementById("session-container-0")
  if container.isNil:
    return (edge: Bottom, near: false)

  let rect = container.getBoundingClientRect()

  let distLeft   = x - rect.left
  let distRight  = rect.right - x
  let distBottom = rect.bottom - y

  # Check each edge against the threshold.  When multiple edges are within
  # range (e.g. the bottom-left corner), prefer the one with the smallest
  # distance.
  var minDist = Inf
  var bestEdge = Bottom
  var nearAny = false

  if distLeft < EdgeThresholdPx.float and distLeft < minDist:
    minDist = distLeft
    bestEdge = Left
    nearAny = true

  if distRight < EdgeThresholdPx.float and distRight < minDist:
    minDist = distRight
    bestEdge = Right
    nearAny = true

  if distBottom < EdgeThresholdPx.float and distBottom < minDist:
    minDist = distBottom
    bestEdge = Bottom
    nearAny = true

  # Update the module-level drag state so that the dragExternalDrop handler
  # in layout.nim can read it.
  lastDragEdge = bestEdge
  dragNearEdge = nearAny

  return (edge: bestEdge, near: nearAny)

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

  # M9: Register the tab as a GL DragSource so it can be dragged back into the
  # layout area.  The config callback returns the panel's saved component
  # config with a ``fromAutoHide`` marker so the itemDropped handler in
  # layout.nim can clean up the auto-hide panel after the drop completes.
  if not glLayout.isNil and not panel.componentConfig.isNil:
    let panelId = panel.id
    let config = panel.componentConfig
    let handle = glNewDragSource(glLayout, tab, proc(): JsObject =
      # Stamp the config with a marker so the drop handler knows this
      # component came from the auto-hide strip.
      config.componentState.toJs.fromAutoHide = panelId.toJs
      result = config
    )
    dragSourceHandles.add((panelId: panelId, handle: handle))

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
  ## Also triggers a redraw of the Karax status bar so the M10 toggle icons
  ## stay in sync with the current auto-hide panel set and active overlay.
  if not stripsCreated:
    return

  # M12: Re-evaluate which edges are bounded before rebuilding strips, so
  # the strip class list (and overlay inset CSS vars) are up-to-date.
  updateEdgeBounding()

  for edge in AutoHideEdge:
    refreshStrip(state, edge)

  # Drive overlay visibility based on activeOverlay state.
  if not state.activeOverlay.isNil:
    showOverlay(state, state.activeOverlay)

  # M11: Persist auto-hide state to localStorage on every mutation.
  saveAutoHideState(state)

  # M10: Notify the status bar so its auto-hide icons re-render.
  if not data.ui.status.isNil and not data.ui.status.kxi.isNil:
    redraw(data.ui.status.kxi)

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
  # M8: Edge indicator elements — thin highlight bars shown during drag.
  # -------------------------------------------------------------------------

  if not indicatorsCreated:
    indicatorsCreated = true
    let indicatorClasses: array[AutoHideEdge, cstring] = [
      cstring(IndicatorLeftClass),
      cstring(IndicatorRightClass),
      cstring(IndicatorBottomClass)
    ]
    for edge in AutoHideEdge:
      let ind = document.createElement("div")
      ind.class = indicatorClasses[edge]
      # Hidden by default; shown by showEdgeIndicator during drag.
      indicatorElements[edge] = ind
      sessionContainer.appendChild(ind)

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
  styleSetProperty(overlayPinBtn, cstring"opacity", cstring"1.0")
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

  # -------------------------------------------------------------------------
  # M12: Window resize and periodic checks for edge-bounding changes
  # -------------------------------------------------------------------------
  # Electron fires "resize" on the renderer window when the OS window is
  # resized or maximized.  It does NOT fire a "move" event, so we also poll
  # every 2 seconds to catch window drags that change which edges are
  # bounded.

  if not boundingCheckStarted:
    boundingCheckStarted = true

    window.addEventListener("resize", proc(ev: Event) =
      updateEdgeBounding()
    )

    # Periodic fallback: catches window moves that don't trigger resize.
    discard jsSetInterval(proc() =
      updateEdgeBounding()
    , 2000)

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
