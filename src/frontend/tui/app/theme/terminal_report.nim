## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/theme/terminal_report.nim — PLAT-71 (CodeTracer-TUI-Terminal-
## Adaptation.md §10): THE ONE FUNCTION that renders the capability profile
## with its reasons, and the glyph test card. Three entry points share it:
## `codetracer-tui --capabilities` (`=json` for bug reports and tests),
## `ct doctor terminal` (the report and the card) and `:terminal-info` (the
## palette's **Terminal: Show Capabilities**, live, in a pane).
##
## Every line names its source (TA-13: in the JSON every axis has a `from`).
## Pure: a function of `TerminalCapabilities`, so the report a user pastes
## into a bug report is exactly what decided their screen.

import std/[json, strutils]

import codetracer_embed

import ./capabilities
import ./degradation
import ../views/glyph_table
import ../views/scrollbar_styles
import ../views/styled_row

export json

proc sourceText(s: CapabilitySource; note = ""): string =
  if note.len > 0: $s & ": " & note else: $s

proc yesNo(b: bool): string = (if b: "on" else: "off")

proc pad(label: string): string =
  label & repeat(' ', max(1, 13 - label.len))

proc profileReport*(caps: TerminalCapabilities): seq[string] =
  ## §10.1's report, one line per axis, each with where it came from.
  let id = caps.identity
  result.add pad("Terminal") & describe(id) & "   (" &
             sourceText(caps.identityFrom, $id.source) & ")"
  let link =
    (if id.remote: "remote" else: "local") &
    (if caps.rttMs >= 0: ", round trip " & $caps.rttMs & " ms" else:
       ", round trip not measured") &
    (if caps.linkConservative: " — slow link: animations off" else: "")
  result.add pad("Link") & link & "   (" & $caps.rttFrom & ")"
  if caps.probeOff:
    result.add pad("Probe") & "off   (" & $caps.probeFrom &
               "): nothing was asked; settings, the cache and the " &
               "environment decided"
  result.add pad("Encoding") &
    (case caps.widths.utf8
     of knYes: "UTF-8 (P0)"
     of knNo: "Latin-1: the terminal decoded U+2026 as three characters (P0)"
     of knUnknown: "not measured") & "   (" & $caps.widthsFrom & ")"
  result.add pad("Widths") & describe(caps.widths)
  result.add pad("") & "ambiguous-wide rule " & yesNo(caps.ambiguousWide) &
             "   (" & sourceText(caps.ambiguousFrom, caps.ambiguousNote) & ")"
  result.add pad("Glyphs") & $caps.tier & "   (" &
             sourceText(caps.bordersFrom, caps.tierNote) & ")"
  result.add pad("") & "modern-unicode " & yesNo(caps.modernUnicode) &
             "   (" & sourceText(caps.modernUnicodeFrom, caps.modernNote) & ")"
  result.add pad("Colours") & $caps.colors & "   (" & $caps.colorsFrom & ")" &
             (if caps.palette == pkTerminal: ", palette terminal" else: "")
  result.add pad("Mouse") & (if caps.mouse: "SGR, any-motion" else: "off") &
             "   (" & $caps.mouseFrom & ")"
  result.add pad("Clipboard") & caps.clipboard & "   (" &
             $caps.clipboardFrom & ")"
  result.add pad("Sync output") & yesNo(caps.synchronizedOutput) & "   (" &
             sourceText(caps.syncFrom, caps.syncNote) & ")"
  result.add pad("Graphemes") &
             (if caps.graphemeMode:
                "DEC 2027 on" & (if caps.graphemeSet: " (set by CodeTracer, " &
                                   "reset on exit)" else: "")
              else: "DEC 2027 not recognised")
  result.add pad("Keyboard") & $caps.keyProtocol & "   (" &
             $caps.keyProtocolFrom & ")"
  result.add pad("Motion") & (if caps.reduceMotion: "reduced" else: "animated") &
             "   (" & $caps.reduceMotionFrom & ")"
  result.add pad("Background") & backgroundNote(caps)
  if caps.remedies.len == 0:
    result.add pad("Remedies") & "none"
  else:
    for i, r in caps.remedies:
      result.add pad(if i == 0: "Remedies" else: "") & r

proc axis(value: JsonNode; source: CapabilitySource; note = ""): JsonNode =
  result = %*{"value": value, "from": $source}
  if note.len > 0:
    result["note"] = %note

proc profileJson*(caps: TerminalCapabilities): JsonNode =
  ## `--capabilities=json`: the same report as data. EVERY AXIS HAS A
  ## `from` (TA-13).
  let id = caps.identity
  var widths = newJObject()
  for p in WidthProbe:
    widths[$p] = %caps.widths.answered[p]
  result = %*{
    "identity": axis(%*{"name": id.name, "version": id.version,
                        "via": id.via, "remote": id.remote,
                        "endToEnd": id.endToEnd, "source": $id.source},
                     caps.identityFrom),
    "colors": axis(%($caps.colors), caps.colorsFrom),
    "palette": axis(%($caps.palette), csFlag),
    "mode": axis(%(if caps.mode == dmLight: "light" else: "dark"),
                 (if caps.modeFrom == bsFlag: csFlag
                  elif caps.modeFrom == bsDefault: csDefault
                  elif caps.modeFrom == bsColorFgBg: csEnvironment
                  else: csProbe), backgroundNote(caps)),
    "tier": axis(%($caps.tier), caps.bordersFrom, caps.tierNote),
    "modernUnicode": axis(%caps.modernUnicode, caps.modernUnicodeFrom,
                          caps.modernNote),
    "widths": axis(%*{"answered": widths, "utf8": $caps.widths.utf8,
                      "ambiguous": $caps.widths.ambiguous,
                      "blockAmbig": $caps.widths.blockAmbig,
                      "unicode13": $caps.widths.unicode13,
                      "pictoWide": $caps.widths.pictoWide,
                      "wideOk": $caps.widths.wideOk,
                      "clusters": $caps.widths.clusters},
                   caps.widthsFrom),
    "ambiguousWide": axis(%caps.ambiguousWide, caps.ambiguousFrom,
                          caps.ambiguousNote),
    "mouse": axis(%caps.mouse, caps.mouseFrom),
    "keyProtocol": axis(%($caps.keyProtocol), caps.keyProtocolFrom),
    "syncOutput": axis(%caps.synchronizedOutput, caps.syncFrom, caps.syncNote),
    "graphemeMode": axis(%caps.graphemeMode,
                         (if caps.graphemeMode: csProbe else: csDefault)),
    "clipboard": axis(%caps.clipboard, caps.clipboardFrom),
    "rttMs": axis(%caps.rttMs, caps.rttFrom),
    "linkConservative": axis(%caps.linkConservative, caps.rttFrom),
    "reduceMotion": axis(%caps.reduceMotion, caps.reduceMotionFrom),
    "probe": axis(%(not caps.probeOff), caps.probeFrom),
    "remedies": axis(%caps.remedies, csDefault)}

# ---------------------------------------------------------------------------
# The glyph test card (§10.3)
# ---------------------------------------------------------------------------

const
  CardRuler* = "0123456789012345678901234567890123456789"
    ## Every card row is laid over this ruler: a glyph drawn wider than it
    ## measures pushes its closing bracket, which the user SEES even where
    ## the measurement agreed with a wrong font.
  CardLegacyLabel* = "if any of these is a box, a blank or a different " &
                     "shape, keep modern-unicode off"
  CardRows*: array[6, (string, string)] = [
    ("markers", "[…] [‹] [›]   [~] [<] [>]"),
    ("dividers", "[▏] [│] [━] [┃] [╹] [╻] [╼] [╾] [╽] [╿]"),
    ("joins", "[┌─┬─┐] [├─┼─┤] [└─┴─┘]"),
    ("blocks", "[▁▂▃▄▅▆▇█] [▏▎▍▌▋▊▉█] [▐] [▕]"),
    ("legacy", "[🮇] [🮂] [🭰] [🭻]"),
    ("marks", "[▸] [▹] [▶] [▼] [●] [○] [◆] [▲] [█] [·] [┊]")]
    ## Rows 1–4 and 6 of §10.3. Row 5 (the scrollbars) and row 7 (colour)
    ## are built from the tables below, so the card shows what CodeTracer
    ## would actually draw.

proc scrollbarCardRows*(): seq[string] =
  ## Row 5: every thickness on every column of the scrollbar table, at rest
  ## and widened, vertical then horizontal.
  for tier in GlyphTier:
    var line = alignLeft($tier, 30)
    for thickness in BarThickness:
      let looks = ScrollbarGlyphs[tier][thickness]
      proc shown(g: string): string = (if g == RvSpace: "█" else: g)
      line.add $thickness & " [" &
        shown(looks.rest[axVertical].thumb.byMask[^1]) &
        shown(looks.widened[axVertical].thumb.byMask[^1]) & "] [" &
        shown(looks.rest[axHorizontal].thumb.byMask[^1]) &
        shown(looks.widened[axHorizontal].thumb.byMask[^1]) & "]  "
    result.add line.strip(leading = false)

proc roleCardRows*(): seq[string] =
  ## Row 6, from the glyph table: each column of every gutter and tree mark.
  for col in GlyphColumn:
    var line = alignLeft($col, 16)
    for role in [grExecPointer, grInspectPointer, grTreeCollapsed,
                 grTreeExpanded, grBreakpoint, grBreakpointDisabled,
                 grTracepoint, grTruncation]:
      let g = ChromeGlyphs[role][col]
      line.add "[" & (if g == RvSpace: " " else: g) & "]"
    result.add line

proc glyphTestCard*(caps: TerminalCapabilities): seq[StyledRow] =
  ## §10.3's card as styled rows: the glyph rows over a ruler, the scrollbar
  ## and mark rows from the tables, and the colour row (a 24-bit gradient
  ## beside its 256- and 16-colour projections, then the attributes).
  proc plain(s: string): StyledRow = @[StyledSpan(text: s)]
  result.add plain("Glyph test card — does every closing ] line up?")
  result.add plain("           " & CardRuler)
  for (label, row) in CardRows:
    result.add plain(alignLeft(label, 11) & row)
  result.add plain("           " & CardLegacyLabel)
  result.add plain("scrollbars (per column: rest+widened vertical, " &
                   "rest+widened horizontal)")
  for r in scrollbarCardRows():
    result.add plain("  " & r)
  result.add plain("marks (per glyph-table column)")
  for r in roleCardRows():
    result.add plain("  " & r)
  # Row 7: colour. Banding shows the real depth.
  for depth in [cdTrueColor, cdAnsi256, cdAnsi16]:
    var row: StyledRow = @[StyledSpan(text: alignLeft($depth, 11))]
    for i in 0 ..< 24:
      let v = (i * 255) div 23
      let hex = "#" & toHex(v, 2).toLowerAscii & toHex(80, 2).toLowerAscii &
                toHex(255 - v, 2).toLowerAscii
      var style = CellStyle(bg: hex)
      if depth != cdTrueColor:
        style = projectStyle(style, depth)
      row.add StyledSpan(text: " ", style: style)
    result.add row
  result.add @[StyledSpan(text: "attributes "),
               StyledSpan(text: "bold", style: CellStyle(bold: true)),
               StyledSpan(text: " "),
               StyledSpan(text: "italic", style: CellStyle(italic: true)),
               StyledSpan(text: " "),
               StyledSpan(text: "underline", style: CellStyle(underline: true)),
               StyledSpan(text: " "),
               StyledSpan(text: "reverse", style: CellStyle(reverse: true))]
  result.add plain("this terminal: " & $caps.tier & " tier, modern-unicode " &
                   yesNo(caps.modernUnicode) & " — answer y or n in " &
                   ":terminal-info to set modern-unicode for this terminal")
