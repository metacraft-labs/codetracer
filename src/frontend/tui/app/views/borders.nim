## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/borders.nim — CTUI-11, rebuilt on PLAT-71's glyph table. The
## Unicode and ASCII BORDER SETS, as a view onto `glyph_table.ChromeGlyphs`.
##
## Since PLAT-71 (CodeTracer-TUI-Terminal-Adaptation.md §6) the glyphs are
## the glyph table's, by role and by tier, and every view draws its chrome
## from it directly (`g.glyphText(role)`). This module keeps the two-valued
## `BorderSet` the callers that ask "ASCII or not" were written against, read
## out of the table's extended and ASCII columns, and the ASCII stand-in of
## every chrome glyph (`asciiFor`) DERIVED from the table — so a set, the
## table and the stand-ins cannot disagree.
##
## What it no longer is: the input of a pass over the composited frame. That
## pass (`degradation.degradeText`) rewrote program text along with the
## chrome — a `●` in a string literal became `*` — and is gone: content is
## drawn as recorded (principle 5, TA-7).
##
## §6.3 of CodeTracer-TUI.md names two sets — `┌ ─ │ └ ▼ ●` and `+ - | * >` —
## and both are still what `UnicodeBorders` and `AsciiBorders` say; this
## front-end distinguishes more states than five marks, which is why the
## sets are larger.

import std/tables

import ../theme/capabilities
import ./glyph_table
import codetracer_embed
import ./scrollbar_styles
import ./styled_row

export capabilities, glyph_table

type
  BorderSet* = object
    ## One complete glyph set. A value rather than a module of constants so a
    ## view takes the set it was handed instead of asking which mode is
    ## current — the same reason `TerminalCapabilities` is one value.
    ##
    ## PLAT-71: A VIEW ONTO THE GLYPH TABLE (`glyph_table.ChromeGlyphs`), not
    ## a table of its own — every field below is read out of it for one
    ## profile, so the two cannot disagree.
    topLeft*: string
    topRight*: string
    bottomLeft*: string
    bottomRight*: string
    horizontal*: string
      ## The rule a pane title trails, and the timeline's track.
    vertical*: string
      ## The column a pane draws on its right-hand edge.
    teeLeft*: string
    teeRight*: string
    teeTop*: string
    teeBottom*: string
    cross*: string
    breakpoint*: string
      ## §3.3.2's verified breakpoint dot.
    breakpointDisabled*: string
    tracepoint*: string
    collapsed*: string
      ## §3.3.3's collapsed tree node.
    expanded*: string
    needle*: string
      ## §3.3.5's execution marker on the timeline scrubber.
    span*: string
      ## The timeline's call-span fill.
    ellipsis*: string
      ## What a truncated field ends with. ONE CELL in both sets — `...` would
      ## be three and would not fit where the Unicode glyph did.
    dotFill*: string
    dashFill*: string

func borderSetOf*(p: GlyphProfile): BorderSet =
  ## The set a glyph profile draws.
  func g(role: GlyphRole): string =
    let s = p.glyph(role)
    if s == RvSpace: " " else: s
  BorderSet(
    topLeft: g(grBoxTopLeft), topRight: g(grBoxTopRight),
    bottomLeft: g(grBoxBottomLeft), bottomRight: g(grBoxBottomRight),
    horizontal: g(grBoxHorizontal), vertical: g(grBoxVertical),
    # The tees exist only as `+` on the ASCII tier; Unicode screens draw no
    # tee today (see the module header), so the cross stands in for them.
    teeLeft: (if p.tier == tierAscii or p.ambiguousWide: "+" else: "├"),
    teeRight: (if p.tier == tierAscii or p.ambiguousWide: "+" else: "┤"),
    teeTop: (if p.tier == tierAscii or p.ambiguousWide: "+" else: "┬"),
    teeBottom: (if p.tier == tierAscii or p.ambiguousWide: "+" else: "┴"),
    cross: g(grBoxCross),
    breakpoint: g(grBreakpoint), breakpointDisabled: g(grBreakpointDisabled),
    tracepoint: g(grTracepoint), collapsed: g(grTreeCollapsed),
    expanded: g(grTreeExpanded), needle: g(grNeedle), span: g(grSpan),
    ellipsis: g(grTruncation), dotFill: g(grDotFill), dashFill: g(grDashFill))

const
  UnicodeBorders* = borderSetOf(GlyphProfile(tier: tierExtended))
    ## The set every pane in this tree already paints, read out of the glyph
    ## table's extended column.

  AsciiBorders* = borderSetOf(GlyphProfile(tier: tierAscii))
    ## §6.3's fallback, the glyph table's ASCII column. `+`, `-`, `|`, `*` and
    ## `>` are the five the section names, at the five meanings it gives them;
    ## the rest exist because this front-end has more states than one marker
    ## can carry.

proc borderSet*(mode: BorderMode): BorderSet =
  ## The set for a resolved border mode. The one place a `BorderMode` becomes
  ## glyphs.
  case mode
  of bmUnicode: UnicodeBorders
  of bmAscii: AsciiBorders

proc borderSet*(caps: TerminalCapabilities): BorderSet =
  ## The set for a whole resolved capability value, for a caller that has one.
  borderSet(caps.borders)

proc buildAsciiTable(): Table[string, string] =
  ## Every chrome glyph this tree can paint and its one-cell ASCII stand-in,
  ## DERIVED: the glyph table's extended and basic columns map to its ASCII
  ## column, then the scrollbar table's glyphs to the ASCII thumb (`#`) or
  ## track (`|` / `-`). The first mapping of a glyph wins, so a divider's `▕`
  ## stays `|` although a hairline thumb is drawn with it too.
  result = initTable[string, string]()
  for role in GlyphRole:
    let ascii = ChromeGlyphs[role][gcolAscii]
    for col in [gcolExtended, gcolBasic, gcolAmbiguous]:
      let g = ChromeGlyphs[role][col]
      if g != ascii and g != RvSpace and g notin result:
        result[g] = ascii
  # The tees, which only `borderSetOf` spells.
  for tee in ["├", "┤", "┬", "┴"]:
    if tee notin result: result[tee] = "+"
  for tier in [gtClassic, gtModern, gtBasic, gtAmbiguousModern]:
    for thickness in BarThickness:
      for looks in [ScrollbarGlyphs[tier][thickness].rest,
                    ScrollbarGlyphs[tier][thickness].widened]:
        for axis in BarAxis:
          let track = looks[axis].track
          if track notin result and track.len > 0 and ord(track[0]) >= 0x80:
            result[track] = (if axis == axVertical: "|" else: "-")
          for set in [looks[axis].thumb.byMask, looks[axis].thumb.joined]:
            for g in set:
              if g.len > 0 and ord(g[0]) >= 0x80 and g != RvSpace and
                 g notin result:
                result[g] = "#"
  for g in RightEighthsModern:
    if g.len > 0 and g notin result: result[g] = "#"
  for g in UpperEighthsModern:
    if g.len > 0 and g notin result: result[g] = "#"

let AsciiFallbackTable* = buildAsciiTable()
  ## Exported so a test can assert its SIZE and its one-cell-to-one-cell
  ## widths. The terminal no longer uses it to rewrite a frame — a view draws
  ## the tier's glyph itself (`glyph_table`) and program text is never
  ## transliterated (Terminal-Adaptation principle 5).

proc asciiFor*(rune: string): string =
  ## The ASCII stand-in for one chrome glyph, or the rune unchanged.
  AsciiFallbackTable.getOrDefault(rune, rune)

proc glyphFor*(rune: string; mode: BorderMode): string =
  ## `rune` as this border mode spells it.
  case mode
  of bmUnicode: rune
  of bmAscii: asciiFor(rune)

func glyphProfileOf*(caps: TerminalCapabilities): GlyphProfile =
  ## The glyph table's view of a resolved profile (Terminal-Adaptation §6).
  ##
  ## A value whose `borders` says ASCII is the ASCII tier whatever its `tier`
  ## field holds: a capability set built by hand with only `borders` (the
  ## pre-PLAT-71 spelling) means the same screen it always meant.
  GlyphProfile(tier: (if caps.borders == bmAscii: tierAscii else: caps.tier),
               ambiguousWide: caps.ambiguousWide,
               modernUnicode: caps.modernUnicode)

func ambiguousPolicyOf*(caps: TerminalCapabilities): AmbiguousWidth =
  ## The width policy every width in the frame is computed under (§6.6).
  if caps.ambiguousWide: awWide else: awNarrow
