## headless_app/auto_hide_hover.nim — PLAT-49 part B (finding 9). THE
## DESKTOP'S AUTO-HIDE POINTER BEHAVIOUR, as one pure state machine every
## front-end drives.
##
## Measured in the desktop's source (`ui/auto_hide.nim`,
## `ui/auto_hide_overlay.nim`) and specified in Auto-Hide-Panes.md §3.2–§3.3:
##
##   * the pointer ENTERS a strip label: after `HoverPreviewDelayMs`
##     (`HOVER_PREVIEW_DELAY_MS` = 300) the pane is shown as an OVERLAY — a
##     preview (`showOverlayPreview`). Leaving the label before then cancels
##     it (`cancelHoverPreview`). A label whose pane is already docked open
##     previews nothing;
##   * the pointer LEAVES the hover zone — the labels and the overlay
##     together (`setupZoneTracking`'s `CT_HOVER_ZONE`) — while a preview is
##     up: after `LeaveDismissDelayMs` (`MOUSE_LEAVE_DELAY_MS` = 300) the
##     overlay closes (`startDismissal`); coming back into the zone first
##     cancels that (`cancelDismissal`);
##   * a CLICK on a label docks its pane OPEN, taking space — no overlay —
##     and a click on the open pane's label closes it (`showDockedPanel`);
##     that is the layout's command (`binding.toggleDockOpen`), and here it
##     only ends the preview and its timers.
##
## Pure: the caller passes the clock (`nowMs`) and where the pointer is, and
## is told what to do. The overlay itself is PLAT-5's transient
## `ikRevealingDock`; the pointer's timing is this module's, held by the
## front-end — never in the layout or its interaction (PLAT-5's purity law).

import std/options

import ./layout_model

const
  HoverPreviewDelayMs* = 300
    ## `ui/auto_hide.nim`'s `HOVER_PREVIEW_DELAY_MS`.
  LeaveDismissDelayMs* = 300
    ## `ui/auto_hide_overlay.nim`'s `MOUSE_LEAVE_DELAY_MS`.

type
  AutoHideCue* = enum
    ahcNone = "none"
    ahcPreview = "preview"
      ## Show `pane` as an overlay preview.
    ahcDismiss = "dismiss"
      ## Close the preview overlay.

  AutoHideReply* = object
    cue*: AutoHideCue
    pane*: PaneKind

  AutoHideHover* = object
    ## The pointer's timing. A value; the front-end keeps one.
    pending*: Option[PaneKind]
      ## The label under the pointer whose preview is due at `pendingAt`.
    pendingAt*: int64
    previewing*: Option[PaneKind]
      ## The pane this machine is previewing (its overlay is up).
    leaveAt*: int64
      ## When a preview closes because the pointer left the zone; -1 while
      ## it is inside (or no preview is up).
    overLabel*: Option[PaneKind]
      ## The label the pointer was over at its last report.

func initAutoHideHover*(): AutoHideHover =
  AutoHideHover(pending: none(PaneKind), pendingAt: -1,
                previewing: none(PaneKind), leaveAt: -1,
                overLabel: none(PaneKind))

func pointerAt*(h: var AutoHideHover; label: Option[PaneKind];
                inOverlay: bool; labelIsOpen: bool;
                nowMs: int64): AutoHideReply =
  ## The pointer moved: it is over `label` (a strip label, or none), inside
  ## the preview overlay or not. `labelIsOpen`: that label's pane is docked
  ## open already (nothing to preview). Answers what to do NOW; a due timer
  ## fires from `tick`.
  result = AutoHideReply(cue: ahcNone)
  let entered = label.isSome and h.overLabel != label
  h.overLabel = label
  if label.isNone:
    h.pending = none(PaneKind)
  elif entered:
    if labelIsOpen:
      h.pending = none(PaneKind)
      # The desktop: hovering a docked-open tab closes a preview of another.
      if h.previewing.isSome and h.previewing != label:
        result = AutoHideReply(cue: ahcDismiss, pane: h.previewing.get)
        h.previewing = none(PaneKind)
        h.leaveAt = -1
        return
    elif h.previewing != label:
      h.pending = label
      h.pendingAt = nowMs + HoverPreviewDelayMs
  let inZone = label.isSome or inOverlay
  if h.previewing.isSome:
    if inZone:
      h.leaveAt = -1
    elif h.leaveAt < 0:
      h.leaveAt = nowMs + LeaveDismissDelayMs

func tick*(h: var AutoHideHover; nowMs: int64): AutoHideReply =
  ## The clock moved: a due preview opens, a due dismissal closes.
  if h.pending.isSome and nowMs >= h.pendingAt:
    let pane = h.pending.get
    h.pending = none(PaneKind)
    h.previewing = some(pane)
    h.leaveAt = -1
    return AutoHideReply(cue: ahcPreview, pane: pane)
  if h.previewing.isSome and h.leaveAt >= 0 and nowMs >= h.leaveAt:
    let pane = h.previewing.get
    h.previewing = none(PaneKind)
    h.leaveAt = -1
    return AutoHideReply(cue: ahcDismiss, pane: pane)
  AutoHideReply(cue: ahcNone)

func nextDueMs*(h: AutoHideHover): int64 =
  ## When `tick` next has something to do, or -1 — so a loop can wake then.
  result = -1
  if h.pending.isSome:
    result = h.pendingAt
  if h.previewing.isSome and h.leaveAt >= 0:
    result = if result < 0: h.leaveAt else: min(result, h.leaveAt)

func clicked*(h: var AutoHideHover) =
  ## A label was clicked (it docks open or closes): no preview is pending or
  ## up any more — the layout's command hides the overlay.
  h.pending = none(PaneKind)
  h.previewing = none(PaneKind)
  h.leaveAt = -1

func overlayClosed*(h: var AutoHideHover) =
  ## The overlay closed for another reason (Escape, an outside click).
  h.previewing = none(PaneKind)
  h.leaveAt = -1
