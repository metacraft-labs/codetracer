## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header. This module reaches `isonim_tui` and the theme.
##
## app/views/frame_overlay.nim — PLAT-47 deliverable 6. **A frame's overlays
## as `isonim_tui` nodes.**
##
## A drag's drop zone is drawn as `isonim_tui`'s tint overlay
## (`isonim_tui/overlay`): the cells of the region the drop would occupy keep
## their glyphs and move their colours toward the drop indicator's; the
## insertion caret of a join is the same, stronger; the ghost label is an
## absolutely placed label above both. This module turns the frame's
## `FrameOverlay` values into those nodes for one terminal — its mode, its
## palette and its depth — and is the one place both composition paths call:
## the shipped driver (`host/terminal_driver.composite`) and the Tier-1
## harness (`views/shell.renderShellTree`).

import std/strutils

import isonim_tui

import ../theme/capabilities
import ../theme/palette
import ./styled_row

const
  DropTintAlpha* = 0.35
    ## How far a drop zone's cells move toward the drop tint.
  DropCaretAlpha* = 0.85
    ## The insertion caret: almost the tint itself.
  OverlayLayer = 5
  CaretLayer = 6
  LabelLayer = 7

proc hexRgb(s: string): isonim_tui.Color =
  if s.len == 7 and s[0] == '#':
    try:
      return rgbColor(uint8(parseHexInt(s[1 .. 2])),
                      uint8(parseHexInt(s[3 .. 4])),
                      uint8(parseHexInt(s[5 .. 6])))
    except ValueError:
      discard
  defaultColor()

proc overlayDepthOf(depth: ColorDepth): OverlayDepth =
  case depth
  of cdMonochrome: odMono
  of cdAnsi16: od16
  of cdAnsi256: od256
  of cdTrueColor: odTrueColor

proc overlaySpecOf*(o: FrameOverlay; caps: TerminalCapabilities): OverlaySpec =
  ## A tint or caret as `isonim_tui`'s overlay: the drop indicator's colour
  ## and the panel's own text and ground as the base a default cell blends
  ## from, all resolved by ROLE for this terminal's mode, and the blend
  ## quantised to this terminal's depth — so a 256-colour terminal is sent a
  ## palette index and a monochrome one only reverse video.
  let tint = resolveRoles(CellStyle(surface: srSurfaceDropIndicator),
                          cdTrueColor, caps.mode, caps.palette)
  let base = resolveRoles(CellStyle(role: srSurfacePanel,
                                    surface: srSurfacePanel),
                          cdTrueColor, caps.mode, caps.palette)
  OverlaySpec(top: o.row, left: o.col, width: o.width, height: o.height,
              color: hexRgb(tint.bg),
              alpha: (if o.kind == foCaret: DropCaretAlpha else: DropTintAlpha),
              reverse: o.kind == foCaret and caps.colors == cdMonochrome,
              baseFg: hexRgb(base.fg), baseBg: hexRgb(base.bg),
              depth: overlayDepthOf(caps.colors),
              layer: (if o.kind == foCaret: CaretLayer else: OverlayLayer))

proc overlayNodes*(r: TerminalRenderer; overlays: seq[FrameOverlay];
                  caps: TerminalCapabilities): seq[TerminalNode] =
  for o in overlays:
    case o.kind
    of foTint, foCaret:
      result.add r.overlayNode(overlaySpecOf(o, caps))
    of foLabel:
      let style = resolveRoles(o.style, caps.colors, caps.mode, caps.palette)
      let node = r.createElement("div")
      r.setStyle(node, "position", "absolute")
      r.setStyle(node, "top", $o.row)
      r.setStyle(node, "left", $o.col)
      r.setStyle(node, "layer", $LabelLayer)
      if style.fg.len > 0: r.setStyle(node, "color", style.fg)
      if style.bg.len > 0: r.setStyle(node, "background-color", style.bg)
      for a in style.attrNames():
        r.setStyle(node, a, "true")
      r.appendChild(node, r.createTextNode(o.text))
      result.add node


const HarnessOverlayCaps* = TerminalCapabilities(
  colors: cdAnsi16, borders: bmUnicode, mouse: true, mode: dmDark,
  palette: pkDesign, theme: utDark)
  ## The terminal a tree built for the Tier-1 harness stands for: the
  ## 16-colour Dark rung `styled_row.styledRowNode` resolves rows at.
