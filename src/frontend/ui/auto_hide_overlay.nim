## Auto-hide overlay: the slide-in panel that appears when the user
## clicks a strip tab.
##
## This module provides the overlay rendering logic and header controls
## (title, unpin button, close button). The overlay is an absolutely
## positioned container that slides in from the pinned edge with a CSS
## transition.
##
## The overlay DOM structure lives in index.html as:
##   #auto-hide-overlay
##     #auto-hide-overlay-header
##       #auto-hide-overlay-title
##       .auto-hide-overlay-unpin-btn
##       .auto-hide-overlay-close-btn
##     #auto-hide-overlay-content
##
## This module wires up the header button event handlers and provides
## a proc to inject/clear component content in the overlay body.

import
  std / [ jsffi, jsconsole, strformat ],
  kdom,
  ../types,
  ../lib/[ jslib, logging ],
  auto_hide

# Node type comes from kdom; do not import dom.Node which conflicts.

# ---------------------------------------------------------------------------
# Overlay header button wiring
# ---------------------------------------------------------------------------

proc wireOverlayButtons*(layout: GoldenLayout) =
  ## Attach click handlers to the overlay header buttons.
  ## Call once after DOM is ready and layout is initialised.

  # Unpin button: re-attach the panel to GL.
  let unpinBtn = document.getElementById(cstring"auto-hide-overlay-unpin-btn")
  if not unpinBtn.isNil:
    unpinBtn.addEventListener(cstring"click", proc(ev: Event) =
      if autoHideState.isNil:
        return
      # Use activeOverlay if still set, otherwise fall back to
      # lastActivePanel. This handles the race where the mouse-leave
      # auto-dismiss timer fires before the click handler runs,
      # clearing activeOverlay.
      let panel = if not autoHideState.activeOverlay.isNil:
          autoHideState.activeOverlay
        else:
          autoHideState.lastActivePanel
      if panel.isNil:
        return
      hideOverlay()
      unpinPanel(layout, panel))

  # Close button: just dismiss the overlay without unpinning.
  let closeBtn = document.getElementById(cstring"auto-hide-overlay-close-btn")
  if not closeBtn.isNil:
    closeBtn.addEventListener(cstring"click", proc(ev: Event) =
      hideOverlay())

# ---------------------------------------------------------------------------
# Overlay content management
# ---------------------------------------------------------------------------

proc setOverlayContent*(html: cstring) =
  ## Replace the overlay body with the given HTML string.
  ## Prefer the live-element reparenting in showOverlay() — this fallback
  ## is kept for panels restored from serialised state that lack a live element.
  let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
  if not contentEl.isNil:
    contentEl.innerHTML = html

proc clearOverlayContent*() =
  ## Remove all content from the overlay body. Does NOT destroy live elements —
  ## use hideOverlay() which properly detaches them first.
  let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
  if not contentEl.isNil:
    contentEl.innerHTML = cstring""

# ---------------------------------------------------------------------------
# Mouse-leave auto-dismiss
# ---------------------------------------------------------------------------

var mouseLeaveTimeoutId: int = -1
const MOUSE_LEAVE_DELAY_MS = 300  ## ms before overlay auto-hides on mouse-leave

proc setupMouseLeaveDismissal*() =
  ## When the mouse leaves the overlay container, start a short timer
  ## to auto-hide. If the mouse re-enters before the timer fires,
  ## cancel it. This prevents accidental dismissal from brief mouse
  ## movements.
  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if overlayEl.isNil:
    return

  overlayEl.addEventListener(cstring"mouseleave", proc(ev: Event) =
    if autoHideState.isNil or not autoHideState.overlayVisible:
      return
    mouseLeaveTimeoutId = windowSetTimeout(
      proc = hideOverlay(),
      MOUSE_LEAVE_DELAY_MS))

  overlayEl.addEventListener(cstring"mouseenter", proc(ev: Event) =
    if mouseLeaveTimeoutId != -1:
      windowClearTimeout(mouseLeaveTimeoutId)
      mouseLeaveTimeoutId = -1)

# ---------------------------------------------------------------------------
# Full overlay setup
# ---------------------------------------------------------------------------

proc setupAutoHideOverlay*(layout: GoldenLayout) =
  ## One-time setup for the auto-hide overlay.  Call after layout init
  ## and after the DOM is ready.
  wireOverlayButtons(layout)
  setupMouseLeaveDismissal()
  setupOverlayDismissal()
  cdebug "auto_hide_overlay: overlay handlers installed"
