## gpui/hover_label.nim — the window's HOVER LABEL: the small box on the
## window's ground, inside the pane outline, that says what the thing under
## the pointer (or the keyboard's highlight) is or why it cannot be used — a
## control's tooltip and key, a session tab's tooltip, a disabled menu item's
## reason, a Test Results control's title. A desktop tooltip, drawn natively.
##
## The module holds the element and its placements; the window decides WHAT
## is hovered and WHICH placement it takes:
##
##   * `hoverLabelBelow`: one line under its anchor, at the anchor's left edge
##     (a top-bar control, a session tab).
##   * `hoverLabelUnder`: lines under the anchor, above it when the window has
##     no room below, moved left to stay inside the window (a pane control's
##     title). `placeBelowOrAbove` is the same rule for any box size.
##   * `hoverLabelBeside`: beside a box, to its right where the label fits on
##     one line, else to its left, else wrapped on the roomier side, and over
##     the box only when neither side is wide enough even for that (a menu
##     item's reason, which must never cover the menu it explains).
##
## THE ICON SLOT. A label may lead with a small square image (`HoverLabelIcon`),
## drawn before the first line, with the further lines indented under the
## first line's words. The zero `HoverLabelIcon` is no icon: it takes no
## width (`iconSlotPx` is 0), no element is drawn for it, and the label is
## drawn exactly as a label without the slot.
##
## The functions here are pure geometry over `PxRect`, apart from
## `drawHoverLabel`, so a placement is unit-tested without a window.

import std/strutils

import isonim_gpui/renderer

import ./chrome
import ./window_geometry
from ./window_top_bar import textPx

const
  HoverLabelPx* = 24
    ## One line of a hover label: its height, and a wrapped label's line
    ## pitch.
  HoverLabelWrapChars* = 60
    ## Where a long label wraps when the window has the room: about a desktop
    ## tooltip's maximum width.
  HoverLabelIconGapPx* = 6
    ## Between a leading icon and the words.
  HoverLabelBesideGapPx* = 4
    ## Between the box a `hoverLabelBeside` label explains and the label.
  HoverLabelAttribute* = "data-ct-hover-label"
    ## On the label's box: its whole text.
  HoverLabelLineAttribute* = "data-ct-hover-label-line"
    ## On each line of a wrapped label: that line.
  HoverLabelIconAttribute* = "data-ct-hover-label-icon"
    ## On a leading icon: its image's path.

type
  HoverLabelIcon* = object
    ## An optional leading icon: the image at `src` (a file the renderer's
    ## `img` reads), drawn `sizePx` square before the first line's words. The
    ## zero value is no icon.
    src*: string
    sizePx*: int

  HoverLabelSide* = enum
    ## Where `hoverLabelBeside` put the label.
    hlsRight  ## right of the box
    hlsLeft   ## left of the box, flush against it
    hlsOver   ## over the box: neither side is wide enough

  HoverLabelPlace* = object
    ## A placed label: its lines (one entry per drawn line) and its box.
    lines*: seq[string]
    at*: PxRect
    side*: HoverLabelSide

func hasIcon*(icon: HoverLabelIcon): bool =
  ## True when `icon` draws anything.
  icon.src.len > 0 and icon.sizePx > 0

func iconSlotPx*(icon: HoverLabelIcon): int =
  ## The width the icon adds to a label: its size and the gap after it, or
  ## 0 for no icon.
  if icon.hasIcon: icon.sizePx + HoverLabelIconGapPx else: 0

func hoverLabelLines*(text: string; maxChars: int): seq[string] =
  ## `text` broken at spaces into lines of at most `maxChars` characters, the
  ## way a desktop tooltip wraps at its maximum width. A word longer than
  ## `maxChars` keeps a line of its own, uncut (cutting could split a UTF-8
  ## sequence). Joining the lines with one space gives back the words.
  var line = ""
  for word in text.splitWhitespace:
    if line.len == 0:
      line = word
    elif line.len + 1 + word.len <= maxChars:
      line.add ' '
      line.add word
    else:
      result.add line
      line = word
  if line.len > 0:
    result.add line

func hoverLabelWidthPx*(lines: openArray[string];
                        icon = HoverLabelIcon()): int =
  ## The label's width for `lines`: its widest line, the padding either
  ## side, and the icon's slot.
  var widest = 0
  for l in lines:
    widest = max(widest, textPx(l))
  widest + 2 * TabPadPx + iconSlotPx(icon)

func hoverLabelBelow*(anchor: PxRect; text: string; gapPx: int;
                      icon = HoverLabelIcon()): PxRect =
  ## One line under `anchor`, `gapPx` below its bottom edge, at its left
  ## edge.
  PxRect(x: anchor.x, y: anchor.y + anchor.h + gapPx,
         w: hoverLabelWidthPx([text], icon), h: HoverLabelPx)

func placeBelowOrAbove*(anchor: PxRect; w, h, gapPx,
                        viewW, viewH: int): PxRect =
  ## A `w` × `h` box `gapPx` under `anchor`, or as far above it when the
  ## window (`viewW` × `viewH`) has no room below; at the anchor's left edge,
  ## moved left to stay inside the window.
  let below = anchor.y + anchor.h + gapPx
  PxRect(x: max(0, min(anchor.x, viewW - w)),
         y: (if below + h <= viewH: below
             else: max(0, anchor.y - h - gapPx)),
         w: w, h: h)

func hoverLabelUnder*(anchor: PxRect; lines: openArray[string]; gapPx,
                      viewW, viewH: int; icon = HoverLabelIcon()): PxRect =
  ## The label holding `lines`, placed by `placeBelowOrAbove`, no wider than
  ## the window.
  let w = min(viewW, hoverLabelWidthPx(lines, icon))
  let h = max(1, lines.len) * HoverLabelPx
  placeBelowOrAbove(anchor, w, h, gapPx, viewW, viewH)

func hoverLabelBeside*(text: string; box, row: PxRect; viewW, viewH: int;
                       icon = HoverLabelIcon()): HoverLabelPlace =
  ## `text` beside `box` (an open popover, a list), level with `row` (the
  ## line of `box` it explains), in a `viewW` × `viewH` window:
  ##
  ## * right of `box` where the label fits there on one line;
  ## * else left of it, flush against it, where it fits there on one line;
  ## * else wrapped, on the roomier side, when that side is at least
  ##   `MinSidePx` wide;
  ## * else over `box`, wrapped to the window.
  ##
  ## The label is kept inside the window on both axes.
  const MinSidePx = 20 * TabCharPx + 2 * TabPadPx
    ## The narrowest side a wrapped label is put on: about three words a
    ## line. Narrower than that, it reads better over the box.
  let slot = iconSlotPx(icon)
  let oneLine = textPx(text) + 2 * TabPadPx + slot
  let rightX = box.x + box.w + HoverLabelBesideGapPx
  let rightRoom = viewW - rightX
  let leftRoom = box.x - HoverLabelBesideGapPx
  let (side, room) =
    if oneLine <= rightRoom: (hlsRight, rightRoom)
    elif oneLine <= leftRoom: (hlsLeft, leftRoom)
    elif rightRoom >= MinSidePx + slot and rightRoom >= leftRoom:
      (hlsRight, rightRoom)
    elif leftRoom >= MinSidePx + slot: (hlsLeft, leftRoom)
    else: (hlsOver, viewW)
  let lines = hoverLabelLines(text,
                              max(1, (room - 2 * TabPadPx - slot) div TabCharPx))
  let w = min(hoverLabelWidthPx(lines, icon), max(1, viewW))
  let wanted = case side
    of hlsRight: rightX
    of hlsLeft: leftRoom - w   # flush against the box's left edge
    of hlsOver: 0
  let h = lines.len * HoverLabelPx
  HoverLabelPlace(
    lines: lines, side: side,
    at: PxRect(x: max(0, min(wanted, viewW - w)),
               y: max(0, min(row.y + (row.h - HoverLabelPx) div 2, viewH - h)),
               w: w, h: h))

proc iconElement(r: GpuiRenderer; icon: HoverLabelIcon): GpuiElement =
  ## The leading icon: a fixed square that never shrinks, the gap after it.
  result = r.createElement("img")
  r.setAttribute(result, "src", icon.src)
  r.setAttribute(result, HoverLabelIconAttribute, icon.src)
  r.setStyle(result, "width", $icon.sizePx & "px")
  r.setStyle(result, "height", $icon.sizePx & "px")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "margin-right", $HoverLabelIconGapPx & "px")

proc drawHoverLabel*(r: GpuiRenderer; at: PxRect; text: string;
                     lines: openArray[string] = [];
                     icon = HoverLabelIcon()): GpuiElement =
  ## The label's element, absolutely placed at `at`, for the caller to add
  ## over the window. `text` is its whole text (`HoverLabelAttribute`); with
  ## more than one entry in `lines` the label is those lines stacked, one
  ## `HoverLabelPx` row each, else `text` on one line. `icon` leads the first
  ## line; the further lines are indented under its words.
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $at.x & "px")
  r.setStyle(result, "top", $at.y & "px")
  r.setStyle(result, "width", $max(1, at.w) & "px")
  r.setStyle(result, "height", $max(1, at.h) & "px")
  r.setStyle(result, "flex-direction", "row")
  r.setStyle(result, "items", "center")
  r.setStyle(result, "background-color", chromeOf(crWindowBackground))
  r.setAttribute(result, HoverLabelAttribute, text)
  r.setStyle(result, "padding-left", $TabPadPx & "px")
  r.setStyle(result, "white-space", "nowrap")
  for (k, v) in paneOutlineStyle(true): r.setStyle(result, k, v)
  if lines.len > 1:
    # Wrapped: one row per line, stacked.
    r.setStyle(result, "flex-direction", "column")
    r.setStyle(result, "items", "start")
    for i, l in lines:
      let lb = r.createElement("div")
      r.setAttribute(lb, HoverLabelLineAttribute, l)
      r.setStyle(lb, "height", $HoverLabelPx & "px")
      r.setStyle(lb, "items", "center")
      r.setStyle(lb, "white-space", "nowrap")
      if icon.hasIcon:
        if i == 0:
          r.setStyle(lb, "flex-direction", "row")
          r.appendChild(lb, iconElement(r, icon))
        else:
          r.setStyle(lb, "padding-left", $iconSlotPx(icon) & "px")
      r.appendChild(lb, r.createTextNode(l))
      r.appendChild(result, lb)
  else:
    if icon.hasIcon:
      r.appendChild(result, iconElement(r, icon))
    r.appendChild(result, r.createTextNode(text))
