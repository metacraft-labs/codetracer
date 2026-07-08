## Auto-hide panes: panels that collapse to thin edge strips and expand
## on hover/click as slide-in overlays.
##
## The auto-hide system sits entirely at the application level, using
## Golden Layout v2.6.0's public `removeChild`/`addChild`/`addItem` APIs.
## No GL fork is required.
##
## Key design principle: LIVE DOM ELEMENT PRESERVATION.
## When a panel is pinned, its DOM element (containing the Monaco editor,
## rendered panel tree, scroll state, etc.) is captured and kept alive.
## The overlay shows this same element by reparenting it into the overlay
## container — no component recreation, no state loss. On unpin, the live
## element is reparented back into the GL layout.
##
## This follows the same pattern as VS Code's auto-hide and GL's own
## DragProxy: detach the DOM node, move it around, reattach it.
##
## Usage flow:
##   1. User clicks "Pin to Edge" in a stack's dropdown menu (added by
##      layout.nim's stackCreated handler).
##   2. `pinPanel` detaches the component from GL via `removeChild`,
##      captures the live DOM element from the GL container, and stores
##      both the element reference and serialised config in `AutoHideState`.
##   3. A thin strip tab appears on the chosen edge.
##   4. Clicking the strip tab calls `showOverlay` which reparents the
##      LIVE DOM element into the overlay container — content is visible
##      immediately with full state preserved.
##   5. The overlay has an "Unpin" button (`unpinPanel`) that re-adds
##      the component to GL via `addItem`, then swaps the new container's
##      content with the preserved live DOM element.
##
## Persistence: auto-hide state is saved alongside the GL layout config
## via `serializeAutoHideState` / `restoreAutoHideState`. Restored panels
## lack a live DOM element and will use config-based recreation.

import
  std / [ jsffi, jsconsole, strformat, sequtils ],
  kdom,
  ../types,
  ../lib/[ jslib, logging ]
# Node type comes from kdom; do not import dom.Node which conflicts.

when defined(js):
  import isonim/web/web_renderer
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_auto_hide_bottom_tabs_view import
    AutoHideBottomTabRecord, AutoHideBottomTabsCallbacks,
    renderAutoHideBottomTabsInto
  from ../viewmodel/views/isonim_auto_hide_side_strip_view import
    AutoHideSideStripRecord, AutoHideSideStripCallbacks,
    renderAutoHideSideStripInto
  from ../viewmodel/views/isonim_auto_hide_collapsed_icons_view import
    AutoHideCollapsedIconRecord, AutoHideCollapsedIconCallbacks,
    renderAutoHideCollapsedIconsInto
  from ../viewmodel/views/isonim_auto_hide_overlay_tabs_view import
    AutoHideOverlayTabRecord, AutoHideOverlayTabsCallbacks,
    renderAutoHideOverlayTabsInto

# JS array helpers (not exported from any shared module).
proc newJsArray(): JsObject {.importjs: "(new Array())".}
proc push(arr: JsObject, item: JsObject) {.importjs: "#.push(#)".}

template dispatchLayoutUpdated() =
  {.emit: """
    window.dispatchEvent(new CustomEvent('ct:layoutUpdated'));
  """.}

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  AutoHideEdge* = enum
    Left,
    Right,
    Bottom

  AutoHidePanel* = ref object
    ## A panel that has been detached from GL and pinned to an edge.
    edge*: AutoHideEdge
    title*: cstring
    content*: Content         ## The Content enum value (Trace, Events, etc.)
    componentId*: int         ## The component id within its Content group
    config*: JsObject         ## Serialised GL component config for re-attach
    domTab*: Element          ## The strip tab DOM element (for removal)
    liveElement*: Element     ## The preserved live DOM element from the GL container
    containerElement*: Element ## The GL container element (parent of liveElement)

  AutoHideState* = ref object
    ## Central state for all auto-hidden panels.
    panels*: seq[AutoHidePanel]
    activeOverlay*: AutoHidePanel  ## Currently shown overlay, or nil
    lastActivePanel*: AutoHidePanel  ## Last panel shown in overlay (survives hideOverlay)
    overlayVisible*: bool
    ## True when the overlay was opened via a click (stays open on mouse-leave).
    ## False when opened via hover-preview (auto-dismisses on mouse-leave).
    pinnedOpen*: bool
    ## Panel currently docked into the inline sidebar (not the overlay). nil if none.
    dockedPanel*: AutoHidePanel
    dockedVisible*: bool
    ## Collapsed mode: when true, side strips render as 1px accent lines
    ## instead of 28px text-label strips.  Activated when the window is
    ## maximized and the edge is bounded (no adjacent monitor).  Can be
    ## forced on via __ctForceCollapsedMode for E2E tests.
    collapsedMode*: bool
    ## Per-edge bounded flags (true = screen boundary, no adjacent monitor).
    ## Only meaningful when collapsedMode is true.
    leftBounded*: bool
    rightBounded*: bool
    ## Callback to re-render strips after mutations.
    onChanged*: proc()
    ## Callback fired after a panel's overlay is shown (with the panel
    ## as argument). Used to trigger a Karax redraw so standalone panels
    ## display up-to-date content when first revealed.
    onPanelShown*: proc(panel: AutoHidePanel)

# ---------------------------------------------------------------------------
# Module-level state (one per window, like `data`)
# ---------------------------------------------------------------------------

var autoHideState*: AutoHideState = nil

## The GoldenLayout instance, stored so strip-tab callbacks (close/unpin)
## can call unpinPanel without re-threading layout through every call site.
## Set by wireOverlayButtons in auto_hide_overlay.nim during layout init.
var autoHideLayout*: GoldenLayout = nil

## Timer ID for the pending hover-preview open. -1 when idle.
## Cancelled when the mouse leaves the tab before 200ms elapses.
var hoverPreviewTimerId: int = -1

## Delay before a hover opens the overlay as a preview (ms).
const HOVER_PREVIEW_DELAY_MS* = 200

## Resize-drag state for docked sidebars.
var dockedResizing: bool = false
var dockedResizeStartX: int = 0
var dockedResizeStartWidth: int = 0
var dockedResizeContainerId: cstring = cstring""
## True when dragging the left-panel handle (drag right = expand).
## False for the right-panel handle (drag left = expand).
var dockedResizeIsLeft: bool = true

proc initAutoHideState*() =
  ## Initialise the auto-hide state. Call once during layout init.
  if autoHideState.isNil:
    autoHideState = AutoHideState(
      panels: @[],
      activeOverlay: nil,
      overlayVisible: false,
      onChanged: nil
    )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc panelsForEdge*(state: AutoHideState, edge: AutoHideEdge): seq[AutoHidePanel] =
  ## Return all panels pinned to a given edge.
  state.panels.filterIt(it.edge == edge)

proc findPanelByContent*(state: AutoHideState, content: Content): AutoHidePanel =
  ## Return the first auto-hidden panel matching the given Content type,
  ## or nil if no such panel is pinned.
  if state.isNil:
    return nil
  for panel in state.panels:
    if panel.content == content:
      return panel
  return nil

proc findPanelByContentAndId*(state: AutoHideState, content: Content, id: int): AutoHidePanel =
  ## Return the auto-hidden panel matching the given Content type and component ID,
  ## or nil if no such panel is pinned.
  if state.isNil:
    return nil
  for panel in state.panels:
    if panel.content == content and panel.componentId == id:
      return panel
  return nil

proc edgeCssClass*(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring"auto-hide-strip-left"
  of Right:  cstring"auto-hide-strip-right"
  of Bottom: cstring"auto-hide-strip-bottom"

proc edgeOverlayCssClass*(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring"auto-hide-overlay-left"
  of Right:  cstring"auto-hide-overlay-right"
  of Bottom: cstring"auto-hide-overlay-bottom"

# Forward declarations — defined in the docked sidebar section below.
# Placed here so pinPanel / unpinPanel can call them before they are defined.
proc hideDockedPanel*()
proc cancelHoverPreview*()
proc hideOverlay*()
proc deferredUpdateGLSize()

# ---------------------------------------------------------------------------
# Pin / Unpin
# ---------------------------------------------------------------------------

proc pinPanel*(
  layout: GoldenLayout,
  contentItem: GoldenContentItem,
  edge: AutoHideEdge = Bottom
) =
  ## Detach a component from Golden Layout and add it to the auto-hide strip.
  ##
  ## `contentItem` must be a component-level item (isComponent == true).
  ## Its config is serialised before removal so it can be restored later.
  if autoHideState.isNil:
    initAutoHideState()

  if contentItem.isNil:
    cerror "auto_hide: pinPanel called with nil contentItem"
    return

  # Capture the component state before detaching so we can rebuild
  # the config later for re-attach.
  let resolvedConfig = contentItem.toConfig()
  let componentState = cast[GoldenItemState](resolvedConfig.componentState)
  let content = componentState.content
  let componentId = componentState.id

  # Build an unresolved component config that `addItem` can consume.
  # We cannot use `toConfig().toJs` directly because the resolved config
  # uses numeric type enums and `componentType` instead of the string-based
  # `type` and `componentName` that `addItem` expects.
  let componentName = if componentState.isEditor:
      cstring"editorComponent"
    else:
      cstring"genericUiComponent"
  let config = js{
    "type": cstring"component",
    "componentName": componentName,
    "componentState": js{
      "id": componentState.id,
      "label": componentState.label,
      "content": cint(ord(componentState.content)),
      "fullPath": componentState.fullPath,
      "name": componentState.name,
      "editorView": cint(ord(componentState.editorView)),
      "isEditor": componentState.isEditor,
      "noInfoMessage": componentState.noInfoMessage
    }
  }

  # Extract the display title from the GL tab header element, which
  # contains the user-visible label (e.g. "FILES") set by
  # layout.nim's tab creation logic. Falls back to the component
  # state label if the tab element is not available.
  let title = block:
    let tab = contentItem.tab
    if not tab.isNil and not tab.titleElement.isNil:
      let text = tab.titleElement.textContent
      if not text.isNil and not text.isUndefined:
        text.to(cstring)
      else:
        componentState.label
    else:
      componentState.label

  # Capture the live DOM element from the GL container BEFORE detaching.
  # GL's container.getElement() returns the wrapper div that holds the
  # component's rendered content (Monaco editor, Karax tree, etc.).
  # We must grab this reference before removeChild, because GL may
  # clean up container references during removal.
  var liveEl: Element = nil
  var containerEl: Element = nil
  if not contentItem.container.isNil:
    let glEl = contentItem.container.getElement()
    if not glEl.isNil and not glEl.isUndefined:
      containerEl = cast[Element](glEl)
      # The live content is the container element itself — it wraps
      # the component-container div with the Karax/Monaco content.
      liveEl = containerEl

  # Detach from GL.  The parent is typically a Stack.
  let parent = contentItem.parent
  if not parent.isNil:
    if not data.ui.isNil:
      data.ui.isReparenting = true
    try:
      parent.removeChild(contentItem)
    finally:
      if not data.ui.isNil:
        data.ui.isReparenting = false
  else:
    console.warn cstring"auto_hide: contentItem has no parent, skipping removeChild"

  # After removeChild, GL detaches the container element from the DOM tree
  # but does not destroy it. If we didn't capture it above, try again from
  # the now-orphaned contentItem.
  if liveEl.isNil and not contentItem.container.isNil:
    let glEl = contentItem.container.getElement()
    if not glEl.isNil and not glEl.isUndefined:
      containerEl = cast[Element](glEl)
      liveEl = containerEl

  if liveEl.isNil:
    console.warn cstring"auto_hide: could not capture live DOM element for panel"

  # Detach the live element from wherever GL left it so it doesn't get
  # garbage-collected or hidden. We'll reparent it on overlay show.
  if not liveEl.isNil and not liveEl.parentNode.isNil:
    liveEl.parentNode.removeChild(liveEl)

  let panel = AutoHidePanel(
    edge: edge,
    title: title,
    content: content,
    componentId: componentId,
    config: config,
    domTab: nil,  # will be set when strip is rendered
    liveElement: liveEl,
    containerElement: containerEl
  )
  autoHideState.panels.add(panel)

  cdebug fmt"auto_hide: pinned panel '{title}' to edge {edge}"

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

  # When the first panel is pinned to a side edge, the strip expands from
  # 0 to 2em, compressing #ROOT.  GL must recompute its size to fill the
  # narrower container; defer so the flex reflow is done first.
  deferredUpdateGLSize()
  dispatchLayoutUpdated()

proc addStandaloneAutoHidePanel*(
  title: cstring,
  content: Content,
  componentId: int,
  liveElement: Element,
  edge: AutoHideEdge = Bottom
) =
  ## Register a panel directly in the auto-hide state without ever
  ## placing it in Golden Layout. Use this for panels that should
  ## always live as auto-hide panes (BUILD, PROBLEMS, SEARCH RESULTS).
  ##
  ## `liveElement` is the DOM element that will be shown in the overlay.
  ## The caller is responsible for creating this element, attaching a
  ## Karax renderer to it, and keeping it alive (not attached to the
  ## visible DOM tree — the overlay will reparent it on show).
  if autoHideState.isNil:
    initAutoHideState()

  # Avoid duplicates: if a panel with this content is already registered,
  # skip the add.
  for existing in autoHideState.panels:
    if existing.content == content:
      cdebug fmt"auto_hide: standalone panel for content {content} already registered, skipping"
      return

  let panel = AutoHidePanel(
    edge: edge,
    title: title,
    content: content,
    componentId: componentId,
    config: js{},  # No GL config — standalone panel
    domTab: nil,
    liveElement: liveElement,
    containerElement: nil
  )
  autoHideState.panels.add(panel)

  cdebug fmt"auto_hide: added standalone panel '{title}' to edge {edge}"

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

type
  UnpinPanelTargetProc* = proc(layout: GoldenLayout, panel: AutoHidePanel) {.nimcall.}

var unpinPanelTarget*: UnpinPanelTargetProc

proc unpinPanel*(layout: GoldenLayout, panel: AutoHidePanel) =
  ## Re-attach a pinned panel back into Golden Layout and remove it
  ## from the auto-hide state. The live DOM element is reparented into
  ## the newly created GL container, preserving all component state.
  if autoHideState.isNil or layout.isNil:
    return

  # Detach the live element from the docked sidebar if it's currently there.
  if autoHideState.dockedVisible and autoHideState.dockedPanel == panel:
    hideDockedPanel()

  # Detach the live element from the overlay if it's currently shown there.
  if autoHideState.activeOverlay == panel:
    let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
    if not contentEl.isNil and not panel.liveElement.isNil:
      if panel.liveElement.parentNode == cast[Node](contentEl):
        contentEl.removeChild(panel.liveElement)
    autoHideState.activeOverlay = nil
    autoHideState.overlayVisible = false

  # Re-add to GL via addItem — this creates a new GL container + component
  # shell. We'll then swap the new container's content with our preserved
  # live DOM element.
  if not data.ui.isNil:
    data.ui.isReparenting = true

  # Set isReparenting to true in the panel's component state so the GoldenLayout registration callback
  # knows it needs to reparent the live DOM element.
  {.emit: """
  if (`panel`.config && `panel`.config.componentState) {
    `panel`.config.componentState.isReparenting = true;
  }
  """.}

  try:
    if not unpinPanelTarget.isNil:
      unpinPanelTarget(layout, panel)
    else:
      let ground = layout.groundItem
      if not ground.isNil and ground.contentItems.len > 0:
        let target = ground.contentItems[0]
        discard target.addItem(panel.config)
      else:
        console.warn cstring"auto_hide: no existing container — adding to root"
        discard ground.addItem(panel.config)
  except:
    cerror "auto_hide: failed to re-add panel to GL: " & getCurrentExceptionMsg()
  finally:
    if not data.ui.isNil:
      data.ui.isReparenting = false

  # Remove from state regardless of whether re-add succeeded, so the
  # strip tab is cleaned up and the user can retry by re-opening
  # the component from the menu.
  autoHideState.panels = autoHideState.panels.filterIt(it != panel)

  cdebug fmt"auto_hide: unpinned panel '{panel.title}'"

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

  # When the last panel is unpinned from a side edge, the strip collapses
  # back to 0, widening #ROOT.  GL must recompute its size; defer so the
  # flex reflow and GL's addItem DOM changes are settled first.
  deferredUpdateGLSize()
  dispatchLayoutUpdated()

# ---------------------------------------------------------------------------
# Docked sidebar — inline panel that pushes GL content sideways (click open).
# ---------------------------------------------------------------------------

proc dockedContainerId(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring"auto-hide-docked-left"
  of Right:  cstring"auto-hide-docked-right"
  of Bottom: cstring"auto-hide-docked-left"  # Bottom panels fall back to left

proc dockedContentId(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring"auto-hide-docked-left-content"
  of Right:  cstring"auto-hide-docked-right-content"
  of Bottom: cstring"auto-hide-docked-left-content"

proc getElementOffsetWidth(el: Element): int {.importjs: "#.offsetWidth".}

proc updateGLSize() =
  ## Tell GoldenLayout to recompute its size after the docked sidebar
  ## changes width.  autoHideLayout is set by wireOverlayButtons once
  ## the layout is initialised.
  if not autoHideLayout.isNil:
    {.emit: "`autoHideLayout`.updateSize();".}

proc deferredUpdateGLSize() =
  ## Schedule two GL size updates: one on the next animation frame (so the
  ## browser has reflowed the new docked-panel width before GL reads it)
  ## and one after the 150ms CSS transition completes.  Both are needed:
  ## the first corrects the initial reflow, the second catches the final
  ## post-transition size.
  if autoHideLayout.isNil:
    return
  {.emit: """
    requestAnimationFrame(function() {
      if (`autoHideLayout`[0]) `autoHideLayout`[0].updateSize();
    });
  """.}
  discard windowSetTimeout(proc() = updateGLSize(), 200)

proc hideDockedPanel*() =
  ## Collapse the docked sidebar back to nothing.
  if autoHideState.isNil or not autoHideState.dockedVisible:
    return

  let panel = autoHideState.dockedPanel
  if not panel.isNil:
    let contentEl = document.getElementById(dockedContentId(panel.edge))
    if not contentEl.isNil and not panel.liveElement.isNil:
      if panel.liveElement.parentNode == cast[Node](contentEl):
        contentEl.removeChild(panel.liveElement)
    let containerEl = document.getElementById(dockedContainerId(panel.edge))
    if not containerEl.isNil:
      containerEl.classList.remove(cstring"docked-open")

  autoHideState.dockedPanel = nil
  autoHideState.dockedVisible = false

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

  deferredUpdateGLSize()
  dispatchLayoutUpdated()

proc showDockedPanel*(panel: AutoHidePanel) =
  ## Expand the inline docked sidebar for `panel` (triggered by tab click).
  ## The panel content is reparented into the sidebar, pushing GL content
  ## sideways.  Clicking the same tab again collapses the sidebar.
  if autoHideState.isNil:
    return

  cancelHoverPreview()

  # Toggle: clicking the same tab closes it.
  if autoHideState.dockedVisible and autoHideState.dockedPanel == panel:
    hideDockedPanel()
    return

  # If a different panel is already docked, close it first.
  if autoHideState.dockedVisible:
    hideDockedPanel()

  # If this panel is currently shown in the hover overlay, close that too.
  if autoHideState.overlayVisible and autoHideState.activeOverlay == panel:
    hideOverlay()

  let contentEl = document.getElementById(dockedContentId(panel.edge))
  let containerEl = document.getElementById(dockedContainerId(panel.edge))
  if contentEl.isNil or containerEl.isNil:
    cerror fmt"auto_hide: docked elements not found for edge {panel.edge}"
    return

  # Reparent the live DOM element — same live-element preservation as overlay.
  contentEl.innerHTML = cstring""
  if not panel.liveElement.isNil:
    contentEl.appendChild(panel.liveElement)
    panel.liveElement.style.display = cstring"block"
    panel.liveElement.style.width = cstring"100%"
    panel.liveElement.style.height = cstring"100%"
    panel.liveElement.style.position = cstring"relative"
    cdebug fmt"auto_hide: docked live element for '{panel.title}'"
  else:
    console.warn cstring"auto_hide: no live element for docked panel"

  containerEl.classList.add(cstring"docked-open")

  autoHideState.dockedPanel = panel
  autoHideState.dockedVisible = true

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

  if not autoHideState.onPanelShown.isNil:
    autoHideState.onPanelShown(panel)
    let shownPanel = panel
    discard windowSetTimeout(proc() =
      if not autoHideState.isNil and autoHideState.dockedPanel == shownPanel:
        if not autoHideState.onPanelShown.isNil:
          autoHideState.onPanelShown(shownPanel)
    , 50)

  deferredUpdateGLSize()
  dispatchLayoutUpdated()

proc setupDockedResizeHandles*() =
  ## Wire drag-to-resize on both docked panel grips.
  ## Must be called once after the DOM is ready.

  # Single document-level handlers update whichever panel is being dragged.
  document.addEventListener(cstring"mousemove", proc(ev: Event) =
    if not dockedResizing:
      return
    let mouseEv = cast[JsObject](ev)
    let clientX = mouseEv.clientX.to(int)
    let dx = if dockedResizeIsLeft: clientX - dockedResizeStartX
             else: dockedResizeStartX - clientX
    let newWidth = max(150, min(800, dockedResizeStartWidth + dx))
    let containerEl = document.getElementById(dockedResizeContainerId)
    if not containerEl.isNil:
      containerEl.style.width = cstring($newWidth & "px")
    updateGLSize())

  document.addEventListener(cstring"mouseup", proc(ev: Event) =
    if dockedResizing:
      dockedResizing = false
      # Remove .resizing highlight from all handles.
      let lh = document.getElementById(cstring"auto-hide-docked-left-resize")
      let rh = document.getElementById(cstring"auto-hide-docked-right-resize")
      if not lh.isNil: lh.classList.remove(cstring"resizing")
      if not rh.isNil: rh.classList.remove(cstring"resizing"))

  proc attachResizeHandle(handleId: cstring; containerId: cstring; isLeft: bool) =
    let handle = document.getElementById(handleId)
    let container = document.getElementById(containerId)
    if handle.isNil or container.isNil:
      return
    handle.addEventListener(cstring"mousedown", proc(ev: Event) =
      let mouseEv = cast[JsObject](ev)
      dockedResizing = true
      dockedResizeIsLeft = isLeft
      dockedResizeStartX = mouseEv.clientX.to(int)
      dockedResizeStartWidth = getElementOffsetWidth(container)
      dockedResizeContainerId = containerId
      handle.classList.add(cstring"resizing"))

  attachResizeHandle(
    cstring"auto-hide-docked-left-resize",
    cstring"auto-hide-docked-left",
    true)
  attachResizeHandle(
    cstring"auto-hide-docked-right-resize",
    cstring"auto-hide-docked-right",
    false)

proc closePanelFromStrip*(panel: AutoHidePanel) =
  ## Remove a panel from the auto-hide strip entirely, discarding it.
  ## Unlike unpinPanel, the panel is NOT re-added to Golden Layout —
  ## the user can re-open it via the menu if they want it back.
  if autoHideState.isNil:
    return

  # If this panel is currently docked, collapse the sidebar.
  if autoHideState.dockedVisible and autoHideState.dockedPanel == panel:
    hideDockedPanel()

  # If this panel is currently shown in the overlay, detach its live
  # element first so the overlay is cleaned up.
  if autoHideState.activeOverlay == panel:
    let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
    if not contentEl.isNil and not panel.liveElement.isNil:
      if panel.liveElement.parentNode == cast[Node](contentEl):
        contentEl.removeChild(panel.liveElement)
    autoHideState.activeOverlay = nil
    autoHideState.overlayVisible = false
    let overlayEl = document.getElementById(cstring"auto-hide-overlay")
    if not overlayEl.isNil:
      overlayEl.classList.remove(cstring"visible")
      overlayEl.classList.remove(cstring"auto-hide-overlay-left")
      overlayEl.classList.remove(cstring"auto-hide-overlay-right")
      overlayEl.classList.remove(cstring"auto-hide-overlay-bottom")
      overlayEl.classList.remove(cstring"collapsed-overlay")

  autoHideState.panels = autoHideState.panels.filterIt(it != panel)

  cdebug fmt"auto_hide: closed panel '{panel.title}' from strip"

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

  dispatchLayoutUpdated()

# ---------------------------------------------------------------------------
# Overlay show / hide
# ---------------------------------------------------------------------------

proc cancelHoverPreview*() =
  ## Cancel any pending hover-preview open timer.
  if hoverPreviewTimerId != -1:
    windowClearTimeout(hoverPreviewTimerId)
    hoverPreviewTimerId = -1

proc isEdgeCollapsed*(edge: AutoHideEdge): bool =
  ## Returns true when the given edge should render in collapsed (1px) mode.
  if autoHideState.isNil or not autoHideState.collapsedMode:
    return false
  case edge
  of Left:   autoHideState.leftBounded
  of Right:  autoHideState.rightBounded
  of Bottom: false  # Bottom uses status bar icons, not 1px strip

proc hideOverlay*() =
  ## Hide the currently visible auto-hide overlay.
  ## The live DOM element is detached from the overlay but NOT destroyed —
  ## it remains referenced by the AutoHidePanel and will be reparented
  ## back into the overlay on next show, or into GL on unpin.
  if autoHideState.isNil:
    return

  cancelHoverPreview()
  autoHideState.pinnedOpen = false

  # Before clearing state, detach the live element from the overlay so it
  # survives. We must NOT use innerHTML = "" which would destroy child nodes.
  let activePanel = autoHideState.activeOverlay
  let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
  if not contentEl.isNil and not activePanel.isNil and not activePanel.liveElement.isNil:
    # Detach the live element — removeChild returns the node, keeping it alive.
    if activePanel.liveElement.parentNode == cast[Node](contentEl):
      contentEl.removeChild(activePanel.liveElement)
  elif not contentEl.isNil:
    # No live element to preserve — safe to clear.
    contentEl.innerHTML = cstring""

  autoHideState.activeOverlay = nil
  autoHideState.overlayVisible = false

  # Remove the "visible" CSS class from the overlay container.
  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if not overlayEl.isNil:
    overlayEl.classList.remove(cstring"visible")
    # Remove edge-specific classes.
    overlayEl.classList.remove(cstring"auto-hide-overlay-left")
    overlayEl.classList.remove(cstring"auto-hide-overlay-right")
    overlayEl.classList.remove(cstring"auto-hide-overlay-bottom")
    overlayEl.classList.remove(cstring"collapsed-overlay")

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

proc doShowOverlayImpl(panel: AutoHidePanel) =
  ## Internal: perform the DOM manipulation to show `panel` in the overlay.
  ## Callers must set `autoHideState.pinnedOpen` before calling.
  ## Capture the previously active panel before updating state, so we can
  ## safely detach its live element from the overlay without destroying it.
  let previousPanel = autoHideState.lastActivePanel

  autoHideState.activeOverlay = panel
  autoHideState.lastActivePanel = panel
  autoHideState.overlayVisible = true

  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if overlayEl.isNil:
    cerror "auto_hide: #auto-hide-overlay not found in DOM"
    return

  # Set the title.
  let titleEl = document.getElementById(cstring"auto-hide-overlay-title")
  if not titleEl.isNil:
    titleEl.innerHTML = panel.title

  # Apply edge-specific class and make visible.
  overlayEl.classList.remove(cstring"auto-hide-overlay-left")
  overlayEl.classList.remove(cstring"auto-hide-overlay-right")
  overlayEl.classList.remove(cstring"auto-hide-overlay-bottom")
  overlayEl.classList.add(edgeOverlayCssClass(panel.edge))
  overlayEl.classList.add(cstring"visible")

  # In collapsed mode, add "collapsed-overlay" class to hide the header
  # row and show the floating pin button instead.
  if isEdgeCollapsed(panel.edge):
    overlayEl.classList.add(cstring"collapsed-overlay")
  else:
    overlayEl.classList.remove(cstring"collapsed-overlay")

  # Reparent the live DOM element into the overlay content area.
  # This preserves all component state (scroll position, Monaco editor
  # content, Karax tree state, event listeners, etc.).
  let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
  if not contentEl.isNil:
    # If a different panel's live element is still in the overlay, detach it
    # safely (don't use innerHTML="" which would destroy it).
    if not previousPanel.isNil and
       previousPanel != panel and
       not previousPanel.liveElement.isNil:
      let prevEl = previousPanel.liveElement
      if prevEl.parentNode == cast[Node](contentEl):
        contentEl.removeChild(prevEl)
    # Clear any remaining non-live content.
    contentEl.innerHTML = cstring""
    if not panel.liveElement.isNil:
      contentEl.appendChild(panel.liveElement)
      # Ensure the reparented element is visible and fills the overlay.
      panel.liveElement.style.display = cstring"block"
      panel.liveElement.style.width = cstring"100%"
      panel.liveElement.style.height = cstring"100%"
      panel.liveElement.style.position = cstring"relative"
      cdebug fmt"auto_hide: reparented live DOM element into overlay for '{panel.title}'"
    else:
      console.warn cstring"auto_hide: no live DOM element for panel — overlay will be empty"

    # In collapsed mode, inject a floating pin button in the content area.
    # This replaces the full header row (hidden via CSS).
    if isEdgeCollapsed(panel.edge):
      var pinBtn = document.getElementById(cstring"overlay-floating-pin-btn")
      if pinBtn.isNil:
        pinBtn = kdom.document.createElement("div")
        pinBtn.id = cstring"overlay-floating-pin-btn"
        pinBtn.class = cstring"overlay-floating-pin"
        pinBtn.setAttribute(cstring"title", cstring"Unpin (restore to layout)")
        pinBtn.innerHTML = cstring"&#x2715;"  # X close/dismiss icon
        pinBtn.addEventListener(cstring"click", proc(ev: Event) =
          # Trigger the same unpin logic as the header button.
          let unpinTarget = if not autoHideState.isNil and not autoHideState.activeOverlay.isNil:
              autoHideState.activeOverlay
            elif not autoHideState.isNil:
              autoHideState.lastActivePanel
            else:
              nil
          if not unpinTarget.isNil:
            hideOverlay())
      contentEl.appendChild(pinBtn)

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

  # Notify layout code so it can trigger a Karax redraw for the panel.
  # This ensures standalone panels (not backed by a GL container) show
  # up-to-date content when the overlay first appears.
  #
  # We fire the callback both immediately (so the content is available
  # as soon as possible) and after a short delay. The delayed call
  # ensures the browser has committed the reparented DOM element to
  # the layout before the direct renderer refreshes it; without this, the
  # first render can target a zero-size element and leave an empty overlay.
  if not autoHideState.onPanelShown.isNil:
    autoHideState.onPanelShown(panel)
    let shownPanel = panel
    discard windowSetTimeout(proc() =
      if not autoHideState.isNil and autoHideState.activeOverlay == shownPanel:
        if not autoHideState.onPanelShown.isNil:
          autoHideState.onPanelShown(shownPanel)
    , 50)

proc showOverlayPreview*(panel: AutoHidePanel) =
  ## Show the overlay as a hover preview — auto-dismisses on mouse-leave.
  ## Does nothing if the overlay is already pinned open or the panel is docked.
  if autoHideState.isNil:
    return
  # Don't show preview for a panel that's already visible in the sidebar.
  if autoHideState.dockedVisible and autoHideState.dockedPanel == panel:
    return
  # Don't override a click-pinned overlay with a preview.
  if autoHideState.overlayVisible and autoHideState.pinnedOpen:
    return
  # Same panel already shown in preview — nothing to do.
  if autoHideState.activeOverlay == panel and autoHideState.overlayVisible:
    return
  autoHideState.pinnedOpen = false
  doShowOverlayImpl(panel)

proc showOverlay*(panel: AutoHidePanel) =
  ## Show the overlay pinned open (via click).
  ## Clicking the same panel again toggles it closed.
  ## Clicking a different panel while in preview mode upgrades to pinned.
  ##
  ## The overlay container is a pre-existing DOM element in index.html
  ## (#auto-hide-overlay). We inject the component content into
  ## #auto-hide-overlay-content and apply edge-specific CSS classes
  ## for positioning/animation.
  if autoHideState.isNil:
    return

  cancelHoverPreview()

  if autoHideState.activeOverlay == panel and autoHideState.overlayVisible:
    if autoHideState.pinnedOpen:
      # Already pinned open for this panel — toggle it closed.
      hideOverlay()
    else:
      # Currently a preview — upgrade to pinned without re-rendering.
      autoHideState.pinnedOpen = true
      if not autoHideState.onChanged.isNil:
        autoHideState.onChanged()
    return

  autoHideState.pinnedOpen = true
  doShowOverlayImpl(panel)

# ---------------------------------------------------------------------------
# Strip rendering (called from layout.nim or a dedicated Karax renderer)
# ---------------------------------------------------------------------------

proc contentIcon*(content: Content): cstring =
  ## Return a Unicode icon character for a Content type, used in the
  ## status bar icon zone when strips are in collapsed mode.
  case content
  of Content.Filesystem:
    cstring"\xF0\x9F\x93\x81" # file folder
  of Content.Calltrace:
    cstring"\xF0\x9F\x94\x8D" # magnifying glass
  of Content.EventLog:
    cstring"\xF0\x9F\x93\x8B" # clipboard
  of Content.State:
    cstring"\xF0\x9F\x94\xA2" # input numbers
  of Content.Build:
    cstring"\xE2\x9A\x99" # gear
  of Content.BuildErrors:
    cstring"\xE2\x9A\xA0" # warning sign
  of Content.SearchResults:
    cstring"\xF0\x9F\x94\x8E" # magnifying glass right
  of Content.TerminalOutput:
    cstring"\xF0\x9F\x96\xA5" # desktop computer
  of Content.Shell:
    cstring"\xF0\x9F\x92\xBB" # laptop
  else:
    cstring"\xE2\x96\xA3" # square with dot


proc sideAutoHideTabsModel*(edge: AutoHideEdge): tuple[
    panels: seq[AutoHidePanel];
    collapsed: bool] =
  ## Derive left/right side-strip state while preserving the 1.28
  ## Xvfb-sensitive collapsed-mode heuristic in ``isEdgeCollapsed``.
  let panels = if not autoHideState.isNil:
      autoHideState.panelsForEdge(edge)
    else:
      @[]
  (panels: panels, collapsed: isEdgeCollapsed(edge))

when defined(js):
  proc requestAutoHideSideStripRender*(containerId: cstring, edge: AutoHideEdge) =
    ## Refresh one left/right auto-hide strip through IsoNim direct DOM.
    let container = dom_api.getElementById(dom_api.document, containerId)
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    let model = sideAutoHideTabsModel(edge)
    var records: seq[AutoHideSideStripRecord] = @[]
    for panel in model.panels:
      # Tab is active when the panel is docked OR shown in the overlay.
      let isActive = not autoHideState.isNil and (
        (not autoHideState.dockedPanel.isNil and autoHideState.dockedPanel == panel) or
        (not autoHideState.activeOverlay.isNil and autoHideState.activeOverlay == panel))
      records.add(AutoHideSideStripRecord(title: $panel.title, active: isActive))

    let panels = model.panels
    let callbacks = AutoHideSideStripCallbacks(
      onSelect: proc(index: int) =
        if index >= 0 and index < panels.len:
          showDockedPanel(panels[index]),
      onClose: proc(index: int) =
        if index >= 0 and index < panels.len:
          closePanelFromStrip(panels[index]),
      onUnpin: proc(index: int) =
        if not autoHideLayout.isNil and index >= 0 and index < panels.len:
          hideOverlay()
          hideDockedPanel()
          unpinPanel(autoHideLayout, panels[index]),
      onCollapsedSelect: proc() =
        if panels.len > 0:
          let target = if not autoHideState.isNil and
                          not autoHideState.lastActivePanel.isNil and
                          autoHideState.lastActivePanel.edge == edge:
              autoHideState.lastActivePanel
            else:
              panels[0]
          showDockedPanel(target),
      onHoverEnter: proc(index: int) =
        if index >= 0 and index < panels.len:
          # Don't show a hover preview for the panel that's already docked.
          if autoHideState.dockedVisible and autoHideState.dockedPanel == panels[index]:
            return
          cancelHoverPreview()
          let capturedPanel = panels[index]
          hoverPreviewTimerId = windowSetTimeout(proc() =
            hoverPreviewTimerId = -1
            showOverlayPreview(capturedPanel)
          , HOVER_PREVIEW_DELAY_MS))
    let r = WebRenderer()
    renderAutoHideSideStripInto(
      r, container, records, model.collapsed, callbacks)
else:
  proc requestAutoHideSideStripRender*(containerId: cstring, edge: AutoHideEdge) =
    discard

proc bottomAutoHideTabsModel*(): seq[AutoHidePanel] =
  ## Derive bottom-pinned panels for the status-bar bottom tab host.
  if autoHideState.isNil:
    return @[]
  autoHideState.panelsForEdge(AutoHideEdge.Bottom)

when defined(js):
  proc requestBottomAutoHideTabsRender*(containerId: cstring) =
    ## Refresh bottom auto-hide tabs through IsoNim direct DOM.
    let container = dom_api.getElementById(dom_api.document, containerId)
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    let panels = bottomAutoHideTabsModel()
    var records: seq[AutoHideBottomTabRecord] = @[]
    for panel in panels:
      records.add(AutoHideBottomTabRecord(title: $panel.title))

    let callbacks = AutoHideBottomTabsCallbacks(
      onSelect: proc(index: int) =
        if index >= 0 and index < panels.len:
          showOverlay(panels[index]))
    let r = WebRenderer()
    renderAutoHideBottomTabsInto(r, container, records, callbacks)
else:
  proc requestBottomAutoHideTabsRender*(containerId: cstring) =
    discard

proc collapsedIconZoneModel*(): seq[AutoHidePanel] =
  ## Derive side-pinned panels that should appear in the collapsed status-bar
  ## icon zone. Bottom panels keep their separate text tabs.
  if autoHideState.isNil or not autoHideState.collapsedMode:
    return @[]

  for panel in autoHideState.panels:
    if panel.edge == Bottom:
      continue
    if not isEdgeCollapsed(panel.edge):
      continue
    result.add(panel)

when defined(js):
  proc requestCollapsedIconZoneRender*(containerId: cstring) =
    ## Refresh the collapsed status-bar icon zone through IsoNim direct DOM.
    let container = dom_api.getElementById(dom_api.document, containerId)
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    let panels = collapsedIconZoneModel()
    var records: seq[AutoHideCollapsedIconRecord] = @[]
    for panel in panels:
      records.add(AutoHideCollapsedIconRecord(
        icon: $contentIcon(panel.content),
        title: $panel.title))

    let callbacks = AutoHideCollapsedIconCallbacks(
      onSelect: proc(index: int) =
        if index >= 0 and index < panels.len:
          showOverlay(panels[index]))
    let r = WebRenderer()
    renderAutoHideCollapsedIconsInto(r, container, records, callbacks)
else:
  proc requestCollapsedIconZoneRender*(containerId: cstring) =
    discard

proc overlaySideTabsModel*(): tuple[
    visible: bool;
    edgeClass: string;
    panels: seq[AutoHidePanel]] =
  ## Derive the render model for collapsed overlay side tabs from the live
  ## auto-hide state. Kept separate so the direct IsoNim renderer and tests can
  ## exercise the same visibility / edge-class rules.
  if autoHideState.isNil or
     not autoHideState.collapsedMode or
     autoHideState.activeOverlay.isNil:
    return (visible: false, edgeClass: "", panels: @[])

  let activeEdge = autoHideState.activeOverlay.edge
  if not isEdgeCollapsed(activeEdge):
    return (visible: false, edgeClass: "", panels: @[])

  let edgeClass = case activeEdge
    of Left:  " side-tabs-left"
    of Right: " side-tabs-right"
    of Bottom: ""

  (visible: true,
   edgeClass: edgeClass,
   panels: autoHideState.panelsForEdge(activeEdge))

when defined(js):
  proc requestOverlaySideEdgeTabsRender*(containerId: cstring) =
    ## Refresh the collapsed overlay side tabs through IsoNim direct DOM.
    ## This owns the overlay tab refresh that layout.nim requests when the
    ## active collapsed edge changes.
    let container = dom_api.getElementById(dom_api.document, containerId)
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    let model = overlaySideTabsModel()
    var records: seq[AutoHideOverlayTabRecord] = @[]
    for panel in model.panels:
      records.add(AutoHideOverlayTabRecord(
        title: $panel.title,
        active: panel == autoHideState.activeOverlay))

    let panels = model.panels
    let callbacks = AutoHideOverlayTabsCallbacks(
      onSelect: proc(index: int) =
        if index >= 0 and index < panels.len:
          showOverlay(panels[index]))
    let r = WebRenderer()
    renderAutoHideOverlayTabsInto(
      r, container, records, model.visible, model.edgeClass, callbacks)
else:
  proc requestOverlaySideEdgeTabsRender*(containerId: cstring) =
    discard

# ---------------------------------------------------------------------------
# Serialisation for layout save/load
# ---------------------------------------------------------------------------

proc serializeAutoHideState*(): JsObject =
  ## Serialise the auto-hide state to a JSON-compatible object for
  ## inclusion in the saved layout config.
  if autoHideState.isNil or autoHideState.panels.len == 0:
    return js{}

  var panelArray = newJsArray()
  for panel in autoHideState.panels:
    let edge = panel.edge
    let title = panel.title
    let content = panel.content
    let componentId = panel.componentId
    let config = panel.config
    let obj = js{
      "edge": cint(ord(edge)),
      "title": title,
      "content": cint(ord(content)),
      "componentId": componentId,
      "config": config
    }
    panelArray.push(obj)

  return js{"panels": panelArray}

proc restoreAutoHideState*(saved: JsObject) =
  ## Restore auto-hide panels from a previously serialised state.
  ## Call after layout init but before rendering strips.
  if saved.isNil or saved.isUndefined:
    return

  initAutoHideState()

  let panelArray = saved["panels"]
  if panelArray.isNil or panelArray.isUndefined:
    return

  let panelLen = cast[int](panelArray.length)
  for i in 0 ..< panelLen:
    let obj = panelArray[i]
    let panel = AutoHidePanel(
      edge: AutoHideEdge(obj["edge"].to(int)),
      title: obj["title"].to(cstring),
      content: Content(obj["content"].to(int)),
      componentId: obj["componentId"].to(int),
      config: obj["config"],
      domTab: nil,
      liveElement: nil,      # No live element for restored panels — will use config fallback
      containerElement: nil
    )
    autoHideState.panels.add(panel)

  cdebug fmt"auto_hide: restored {autoHideState.panels.len} pinned panels"

# ---------------------------------------------------------------------------
# Keyboard / backdrop dismissal
# ---------------------------------------------------------------------------

proc setupOverlayDismissal*() =
  ## Set up global event handlers for dismissing the auto-hide overlay:
  ## - Escape key
  ## - Click on the backdrop element
  ## - Mouse-leave from the overlay (with a short delay)
  ##
  ## Call once after DOM is ready.

  # Escape key handler.
  document.addEventListener(cstring"keydown", proc(ev: Event) =
    let keyEv = cast[JsObject](ev)
    if keyEv.key.to(cstring) == cstring"Escape":
      if not autoHideState.isNil and autoHideState.overlayVisible:
        hideOverlay())

  # Backdrop click handler.
  let backdrop = document.getElementById(cstring"auto-hide-backdrop")
  if not backdrop.isNil:
    backdrop.addEventListener(cstring"click", proc(ev: Event) =
      hideOverlay())
