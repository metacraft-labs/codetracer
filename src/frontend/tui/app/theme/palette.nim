## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/palette.nim — a role, on a tier, in a mode: the colours it paints.
##
## ## Every rung is DERIVED from the token hex
##
## PLAT-46 deliverable 6. There is one table of colours in this front-end and it
## is not here: it is `design_tokens.DesignTokenHex`, generated from the design
## system. Each rung below is a FUNCTION of a role's token hex —
##
##   * truecolor  — the hex itself;
##   * 256        — the nearest xterm-256 entry (indices 16..255) in OKLab;
##   * 16         — the nearest of xterm's sixteen defaults in OKLab WITHIN
##                  the colour's family: a hue to the nearest chromatic entry,
##                  a grey to the nearest grey (`nearestAnsi16Family`);
##   * terminal   — the sixteen SYMBOLIC indices only, from the same 16-colour
##                  derivation, with neutral text on the terminal's DEFAULT
##                  foreground and region surfaces on its DEFAULT background;
##   * monochrome — no colour; the role's `mono` attributes.
##
## — so changing a token moves every rung, and no rung can be stale. The
## derived table is computed ONCE at module initialisation (`let`, because the
## OKLab arithmetic uses `cbrt`/`pow`, which is cheaper to run once than to
## trust to the VM) and is a cache of the function, never a second source.

import std/strutils

import ./capabilities
import ./cell_style
import ./colour_math
import ./roles

export cell_style

type
  RoleColours* = object
    ## One role's colours at every coloured rung, in one mode.
    fgRgb*, bgRgb*: string
    fg256*, bg256*: string
    fg16*, bg16*: string
    fgTerm*, bgTerm*: string

const
  TextLightnessBand* = 0.2
    ## How close (in OKLab L) a neutral foreground must be to the mode's body
    ## text to be painted as the terminal's default foreground.

proc indexedSpelling(i: int): string = "indexed:" & $i

proc terminalForeground(c: Rgb8; mode: DesignMode): string =
  ## A foreground on the terminal palette.
  if chroma(c) >= NeutralChroma:
    return AnsiNames[nearestAnsi16Family(c)]
  let text = parseHexColour(tokenHex(dtColorsUiTextPrimaryBody, mode))
  if abs(toOklab(c).l - toOklab(text).l) <= TextLightnessBand:
    ""
  else:
    "bright_black"

proc deriveColours*(role: SemanticRole; mode: DesignMode): RoleColours =
  ## Every coloured rung of one role, from its token hexes. THE derivation.
  let s = spec(role)
  if s.hasFg:
    let hex = tokenHex(s.fg, mode)
    let c = parseHexColour(hex)
    result.fgRgb = hex
    result.fg256 = indexedSpelling(nearestXterm256(c))
    result.fg16 = AnsiNames[nearestAnsi16Family(c)]
    result.fgTerm = terminalForeground(c, mode)
  if s.hasBg:
    let hex = tokenHex(s.bg, mode)
    let c = parseHexColour(hex)
    result.bgRgb = hex
    result.bg256 = indexedSpelling(nearestXterm256(c))
    result.bg16 = AnsiNames[nearestAnsi16Family(c)]
    # A REGION surface is the terminal's own background under
    # `--palette=terminal`; a HIGHLIGHT (selection, current line, search
    # match, a tag) keeps an index, or it would stop being a highlight.
    result.bgTerm = if s.baseSurface: "" else: AnsiNames[nearestAnsi16Family(c)]

let RoleColourTable*: array[DesignMode, array[SemanticRole, RoleColours]] =
  block:
    var t: array[DesignMode, array[SemanticRole, RoleColours]]
    for mode in DesignMode:
      for role in SemanticRole:
        t[mode][role] = deriveColours(role, mode)
    t

type
  ColourRung* = enum
    ## The coloured rungs a role can be resolved on.
    crTrueColor, crAnsi256, crAnsi16, crTerminal

proc rungOf*(depth: ColorDepth; palette: PaletteKind): ColourRung =
  if palette == pkTerminal: crTerminal
  else:
    case depth
    of cdTrueColor: crTrueColor
    of cdAnsi256: crAnsi256
    else: crAnsi16

proc coloursOn(c: RoleColours; rung: ColourRung): (string, string) =
  case rung
  of crTrueColor: (c.fgRgb, c.bgRgb)
  of crAnsi256: (c.fg256, c.bg256)
  of crAnsi16: (c.fg16, c.bg16)
  of crTerminal: (c.fgTerm, c.bgTerm)

proc effectiveAppearance(role: SemanticRole; mode: DesignMode;
                         rung: ColourRung; guarded: bool):
                        (string, string, set[RoleAttr]) =
  let (fg, bg) = coloursOn(RoleColourTable[mode][role], rung)
  (fg, bg, (if guarded: spec(role).mono else: spec(role).attrs))

let CollapsedOnRung*: array[DesignMode, array[ColourRung,
                                              array[SemanticRole, bool]]] =
  # THE COLLAPSE GUARD. A derived rung can merge two states of one group — the
  # 16-colour rung does it to pastel neighbours, the terminal palette to every
  # neutral. Where it does, BOTH roles paint that rung with their MONOCHROME
  # attributes instead of their colour-rung ones, and the monochrome table is
  # the one CTUI-11's property already keeps distinct within every group. The
  # marking runs to a fixpoint, because giving one role its monochrome weight
  # can land it on a third role's appearance. Roles the palette keeps apart
  # are untouched, so the design's 24-bit screen is exactly the design.
  #
  # This is what lets the distinguishability property be stated over EVERY
  # rung (`app/tests/test_degraded_style_tables.nim`), not only monochrome.
  block:
    var t: array[DesignMode, array[ColourRung, array[SemanticRole, bool]]]
    var members: array[DistinctionGroup, seq[SemanticRole]]
    for r in SemanticRole:
      members[spec(r).group].add r
    for mode in DesignMode:
      for rung in ColourRung:
        var changed = true
        while changed:
          changed = false
          for a in SemanticRole:
            let ga = spec(a).group
            if ga in {dgNone, dgSurface}:
              continue
            for b in members[ga]:
              if a >= b:
                continue
              if t[mode][rung][a] and t[mode][rung][b]:
                continue
              if effectiveAppearance(a, mode, rung, t[mode][rung][a]) ==
                 effectiveAppearance(b, mode, rung, t[mode][rung][b]):
                t[mode][rung][a] = true
                t[mode][rung][b] = true
                changed = true
    t

proc roleColours*(role: SemanticRole; depth: ColorDepth; mode: DesignMode;
                  palette = pkDesign): (string, string) =
  ## `(fg, bg)` spellings for one role on one tier. "" means "not painted by
  ## this role" (or, under the terminal palette, the terminal's default).
  let c = RoleColourTable[mode][role]
  if depth == cdMonochrome:
    return ("", "")
  if palette == pkTerminal:
    return (c.fgTerm, c.bgTerm)
  case depth
  of cdTrueColor: (c.fgRgb, c.bgRgb)
  of cdAnsi256: (c.fg256, c.bg256)
  of cdAnsi16: (c.fg16, c.bg16)
  of cdMonochrome: ("", "")

proc addAttrs(s: var CellStyle; attrs: set[RoleAttr]) =
  if raBold in attrs: s.bold = true
  if raItalic in attrs: s.italic = true
  if raUnderline in attrs: s.underline = true
  if raReverse in attrs: s.reverse = true

proc resolvePlain(style: CellStyle; depth: ColorDepth; mode: DesignMode;
                  palette = pkDesign): CellStyle =
  ## A painted style with its ROLES put onto a tier: `role` and `surface`
  ## become `fg`/`bg` spellings and attributes, and are cleared.
  ##
  ## Precedence, and why:
  ##   * the role's own background (a tag, a search match) beats the surface —
  ##     it is painted ON the surface;
  ##   * a surface paints the background only where nothing else did, and
  ##     lends its TEXT colour to a cell whose role names none — a padding
  ##     space or an unrolled glyph — so no text ever falls back to the
  ##     terminal's default foreground on a background the design chose;
  ##   * literal `fg`/`bg` (content: the frame viewer's pixels) are kept and
  ##     projected by the caller.
  ##
  ## Monochrome keeps the view's attributes, adds each role's `mono` set and
  ## paints no colour at all.
  result = CellStyle(fg: style.fg, bg: style.bg, bold: style.bold,
                     italic: style.italic, underline: style.underline,
                     reverse: style.reverse)
  if style.role == srNone and style.surface == srNone:
    return
  if depth == cdMonochrome:
    result.fg = ""
    result.bg = ""
    result.addAttrs(spec(style.role).mono)
    result.addAttrs(spec(style.surface).mono)
    return
  if style.role != srNone:
    let (fg, bg) = roleColours(style.role, depth, mode, palette)
    if spec(style.role).hasFg: result.fg = fg
    if spec(style.role).hasBg: result.bg = bg
    if CollapsedOnRung[mode][rungOf(depth, palette)][style.role]:
      result.addAttrs(spec(style.role).mono)
    else:
      result.addAttrs(spec(style.role).attrs)
  if style.surface != srNone:
    let s = spec(style.surface)
    let (fg, bg) = roleColours(style.surface, depth, mode, palette)
    if s.hasBg and result.bg.len == 0 and not spec(style.role).hasBg:
      result.bg = bg
    if s.hasFg and result.fg.len == 0 and not spec(style.role).hasFg:
      result.fg = fg
    result.addAttrs(s.attrs)

proc rgbOfSpelling(spelling: string; ok: var bool): Rgb8 =
  ## A resolved colour spelling as RGB: `#rrggbb` or `indexed:N`. Anything
  ## else (an ANSI name, "" for the terminal's own colour) is not known here.
  ok = false
  if spelling.len == 7 and spelling[0] == '#':
    result = parseHexColour(spelling, ok)
  elif spelling.startsWith("indexed:"):
    try:
      let i = parseInt(spelling["indexed:".len .. ^1])
      if i >= 0 and i <= 255:
        ok = true
        result = xterm256Rgb(i)
    except ValueError:
      discard

func blendHalf*(fg, bg: Rgb8): Rgb8 =
  ## `fg` at opacity 0.5 over `bg` — the desktop's `opacity: 0.5`, composited
  ## as a browser composites it (per sRGB channel, rounded half up).
  (r: (fg.r + bg.r + 1) div 2, g: (fg.g + bg.g + 1) div 2,
   b: (fg.b + bg.b + 1) div 2)

proc resolveRoles*(style: CellStyle; depth: ColorDepth; mode: DesignMode;
                   palette = pkDesign): CellStyle =
  ## `resolvePlain`, and then `dim` (see `CellStyle.dim`): on a colour rung of
  ## the design palette the foreground is blended halfway toward the cell's
  ## resolved background, computed at 24 bits and then put on the rung (the
  ## nearest xterm-256 entry, or of the sixteen); where either colour is the
  ## terminal's own, the cell is SGR 2 instead.
  var plain = style
  plain.dim = false
  result = resolvePlain(plain, depth, mode, palette)
  if not style.dim:
    return
  if depth == cdMonochrome or palette == pkTerminal:
    result.dim = true
    return
  let tc = resolvePlain(plain, cdTrueColor, mode, palette)
  var okFg, okBg = false
  let fg = rgbOfSpelling(tc.fg, okFg)
  let bg = rgbOfSpelling(tc.bg, okBg)
  if not (okFg and okBg):
    result.dim = true
    return
  let mixed = blendHalf(fg, bg)
  result.fg =
    case depth
    of cdTrueColor: hexOf(mixed)
    of cdAnsi256: indexedSpelling(nearestXterm256(mixed))
    of cdAnsi16: AnsiNames[nearestAnsi16Family(mixed)]
    of cdMonochrome: ""
