## Auto-hide overlay: the slide-in panel that appears when the user
## HOVERS a strip tab.
##
## Hover, not click: a click docks the panel inline instead (see
## `auto_hide.nim`'s usage-flow note and the strip callbacks' `onSelect`
## vs `onHoverEnter`). A click opened this overlay until 2026-07, and
## much of the GUI suite went on asserting that for a month afterwards,
## so the distinction is worth keeping in the first sentence.
##
## This module provides the overlay rendering logic and header controls
## (title, unpin button, close button). **The header row is currently
## styled `display: none !important`** — the active strip tab acts as
## the panel header and unpin/close are reached from its right-click
## context menu — so the header controls below are rendered but never
## painted. The overlay is an absolutely
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

  # Store layout globally so strip-tab unpin callbacks can reach it.
  autoHideLayout = layout

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

# `setOverlayContent(html: cstring)` was here: an exported proc whose entire
# body assigned its argument to `innerHTML`, described as a fallback "kept for
# panels restored from serialised state".  It had NO CALLERS — the restore path
# rebuilds a live element instead — so what it actually was is a loaded markup
# sink with a public name, waiting for the first caller to hand it a panel
# title or a serialised label.  Deleted rather than fixed: there is nothing to
# fix in a proc nobody calls, and `htmlSinks.test.mjs` asserts it stays gone.

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

proc cancelDismissal() =
  if mouseLeaveTimeoutId != -1:
    windowClearTimeout(mouseLeaveTimeoutId)
    mouseLeaveTimeoutId = -1

proc startDismissal() =
  if autoHideState.isNil or not autoHideState.overlayVisible:
    return
  # Don't auto-dismiss if the overlay was pinned open via a click.
  if autoHideState.pinnedOpen:
    return
  # Don't stack timers — cancel any running one first.
  cancelDismissal()
  mouseLeaveTimeoutId = windowSetTimeout(
    proc = hideOverlay(),
    MOUSE_LEAVE_DELAY_MS)

proc attachHoverZone(el: Element) =
  ## Register an element as part of the "safe zone": entering it cancels
  ## the dismiss timer, leaving it starts the timer.  Used for the overlay
  ## and both side-strip containers so that hovering sidebar tabs while the
  ## overlay is open does not trigger an accidental close.
  ## On mouseleave from the strip, the pending hover-open timer is also
  ## cancelled so a 200ms hover that exits before completing doesn't open.
  el.addEventListener(cstring"mouseleave", proc(ev: Event) =
    cancelHoverPreview()
    startDismissal())
  el.addEventListener(cstring"mouseenter", proc(ev: Event) = cancelDismissal())

proc setupMouseLeaveDismissal*() =
  ## Cancel auto-hide whenever the mouse is inside the overlay OR either
  ## side strip.  Moving between the strip tabs and the overlay content
  ## must not trigger a close — all three elements form one logical zone.
  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if not overlayEl.isNil:
    attachHoverZone(overlayEl)

  let stripLeft = document.getElementById(cstring"auto-hide-strip-left")
  if not stripLeft.isNil:
    attachHoverZone(stripLeft)

  let stripRight = document.getElementById(cstring"auto-hide-strip-right")
  if not stripRight.isNil:
    attachHoverZone(stripRight)

# ---------------------------------------------------------------------------
# Full overlay setup
# ---------------------------------------------------------------------------

proc setupAutoHideOverlay*(layout: GoldenLayout) =
  ## One-time setup for the auto-hide overlay and docked sidebars.
  ## Call after layout init and after the DOM is ready.
  wireOverlayButtons(layout)
  setupMouseLeaveDismissal()
  setupOverlayDismissal()
  setupDockedResizeHandles()
  setupOverlayResizeHandle()
  cdebug "auto_hide_overlay: overlay handlers installed"
