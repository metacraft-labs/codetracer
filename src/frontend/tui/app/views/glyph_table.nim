## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/glyph_table.nim — CodeTracer-TUI-Terminal-Adaptation.md §6.3:
## THE ONE GLYPH TABLE every piece of terminal chrome is drawn from, keyed by
## ROLE and by TIER.
##
## ## What a view asks for
##
## A role — "truncation marker", "tree collapsed", "breakpoint" — never a code
## point. `glyph(profile, role)` answers with the glyph the terminal's
## profile can show:
##
##   * `extended` — the full Box Drawing and Block Elements ranges;
##   * `basic` — the WGL4 / CP437 drawing set a mainstream monospace font
##     carries (no eighths, no heavy or half lines, `►` for `▸`, `♦` for `◆`);
##   * `ascii` — U+0020–U+007E;
##   * and, on any tier, the AMBIGUOUS-WIDE column (§6.2): where East Asian
##     Width `A` glyphs are drawn two cells wide, a one-cell role may use only
##     a glyph that is NOT `A`, or ASCII, or a reverse-video space (`RvSpace`).
##
## Every chrome code point of `tui/app/views/` is in this table (or in the
## scrollbar part of it, `scrollbar_styles.nim`, §6.4) ONCE, as data. A source
## gate (`tests/test_plat71_glyph_table.nim`, TA-6) forbids chrome code
## points anywhere else under `tui/app/views/`.
##
## ## What it never does
##
## It never rewrites program text (principle 5). Until this table the ASCII
## tier was a pass over the whole composited frame (`degradation.degradeText`)
## that also rewrote a `●` or a `─` in a recorded string literal; now a view
## draws the tier's glyph itself and content is drawn as recorded (TA-7).

import std/strutils

import ../theme/terminal_profile

export terminal_profile

type
  GlyphRole* = enum
    ## The roles §6.3 names, and the rest of the chrome this front-end draws.
    grTruncation = "truncation marker"
    grOverflowLeft = "overflow left"
    grOverflowRight = "overflow right"
    grDividerV = "pane divider, vertical"
    grDividerH = "pane divider, horizontal"
    grExecPointer = "execution pointer mark"
    grInspectPointer = "inspection pointer mark"
    grTreeCollapsed = "tree collapsed"
    grTreeExpanded = "tree expanded"
    grBreakpoint = "breakpoint"
    grBreakpointDisabled = "breakpoint disabled"
    grTracepoint = "tracepoint"
    grNeedle = "timeline needle"
    grSpan = "timeline span"
    grDotFill = "dotted fill"
    grDashFill = "dashed fill"
    grFieldEdgeLeft = "field edge left"
    grFieldEdgeRight = "field edge right"
    grBoxTopLeft = "box top left"
    grBoxTopRight = "box top right"
    grBoxBottomLeft = "box bottom left"
    grBoxBottomRight = "box bottom right"
    grBoxVertical = "box vertical"
    grBoxHorizontal = "box horizontal"
    grBoxCross = "box cross"
    grSortAscending = "sort ascending"
    grSortDescending = "sort descending"
    grLoading = "loading"
    grSeparator = "separator dot"
    grClose = "close"
    grHistory = "history control"
    grOriginControl = "origin control"
    grRemoveWatch = "remove watch"
    grHistoryEntry = "history entry"
    grOmnibar = "omnibar"
    grStatusOk = "status ok"
    grStatusError = "status error"
    grStatusStopped = "status stopped"
    grPaletteFunction = "palette function"
    grPaletteFile = "palette file"
    grOpenMarker = "open file marker"
    grMenuButton = "menu button"
    grStatusRunning = "status running"
    grTabClose = "tab close"
    grCallExpanded = "call trace expanded"
    grCallCollapsed = "call trace collapsed"
    grCallLeaf = "call trace leaf"

  GlyphColumn* = enum
    gcolExtended = "extended"
    gcolBasic = "basic"
    gcolAscii = "ascii"
    gcolAmbiguous = "ambiguous-wide"

  GlyphProfile* = object
    ## What the glyph table needs to know about the terminal: a pure
    ## function of `TerminalCapabilities` (`glyphProfileOf`). The ZERO VALUE
    ## is the extended, narrow, classic screen.
    tier*: ChromeTier
    ambiguousWide*: bool
    modernUnicode*: bool

const
  RvSpace* = "\x1b[rv]"
    ## A reverse-video space: a space drawn in reversed colours, one cell in
    ## every terminal (§6.2). Never written to a terminal as these bytes —
    ## `paintGlyph` and the scrollbar painter draw it as `" "` with
    ## `reverse` set.

  ChromeGlyphs*: array[GlyphRole, array[GlyphColumn, string]] = [
    # role                 extended  basic   ascii  ambiguous-wide
    grTruncation:          ["…",      "…",    "~",   "…"],
      # OQ-T2: under ambiguous-wide the marker is `…` DRAWN AS TWO CELLS; the
      # layout measures it with the wide policy (`markerCells`).
    grOverflowLeft:        ["‹",      "‹",    "<",   "‹"],
    grOverflowRight:       ["›",      "›",    ">",   "›"],
    grDividerV:            ["▏",      "│",    "|",   "|"],
    grDividerH:            ["─",      "─",    "-",   "-"],
    grExecPointer:         ["▸",      "►",    ">",   "▸"],
    grInspectPointer:      ["▹",      ">",    ")",   "▹"],
    grTreeCollapsed:       ["▶",      "►",    ">",   "▸"],
    grTreeExpanded:        ["▼",      "▼",    "v",   "▾"],
    grBreakpoint:          ["●",      "●",    "*",   "*"],
    grBreakpointDisabled:  ["○",      "○",    "o",   "o"],
    grTracepoint:          ["◆",      "♦",    "+",   "+"],
    grNeedle:              ["▲",      "▲",    "^",   "^"],
    grSpan:                ["█",      "█",    "#",   RvSpace],
    grDotFill:             ["·",      "·",    ".",   "."],
    grDashFill:            ["┊",      ":",    ":",   "╎"],
    grFieldEdgeLeft:       ["▕",      "│",    "|",   "|"],
    grFieldEdgeRight:      ["▏",      "│",    "|",   "|"],
    grBoxTopLeft:          ["┌",      "┌",    "+",   "+"],
    grBoxTopRight:         ["┐",      "┐",    "+",   "+"],
    grBoxBottomLeft:       ["└",      "└",    "+",   "+"],
    grBoxBottomRight:      ["┘",      "┘",    "+",   "+"],
    grBoxVertical:         ["│",      "│",    "|",   "|"],
    grBoxHorizontal:       ["─",      "─",    "-",   "-"],
    grBoxCross:            ["┼",      "┼",    "+",   "+"],
    grSortAscending:       ["▲",      "▲",    "^",   "▴"],
    grSortDescending:      ["▼",      "▼",    "v",   "▾"],
    grLoading:             ["⋯",      "·",    ".",   "⋯"],
    grSeparator:           ["·",      "·",    ".",   "."],
    grClose:               ["✕",      "x",    "x",   "✕"],
    grHistory:             ["↺",      "H",    "H",   "↺"],
    grOriginControl:       ["⇠",      "<",    "<",   "⇠"],
    grRemoveWatch:         ["×",      "×",    "x",   "x"],
    grHistoryEntry:        ["↳",      "-",    "-",   "↳"],
    grOmnibar:             ["⌕",      "/",    "/",   "⌕"],
    grStatusOk:            ["✓",      "+",    "+",   "✓"],
    grStatusError:         ["✗",      "x",    "x",   "✗"],
    grStatusStopped:       ["■",      "■",    "#",   "#"],
    grPaletteFunction:     ["ƒ",      "ƒ",    "f",   "ƒ"],
    grPaletteFile:         ["▤",      "□",    "#",   "#"],
    grOpenMarker:          ["•",      "•",    "*",   "*"],
    grMenuButton:          ["≡",      "≡",    "=",   "="],
    grStatusRunning:       ["⟳",      "*",    "*",   "⟳"],
    grTabClose:            ["×",      "×",    "x",   "x"],
    grCallExpanded:        ["▾",      "▼",    "v",   "▾"],
    grCallCollapsed:       ["▸",      "►",    ">",   "▸"],
    grCallLeaf:            ["·",      "·",    ".",   "."]]

  DefaultGlyphs* = GlyphProfile()
    ## Extended, narrow, classic: the screen before profiles.

func columnOf*(p: GlyphProfile): GlyphColumn =
  ## The column a profile draws from: ASCII wins (it is narrow everywhere),
  ## then the ambiguous-wide rule, then the tier.
  if p.tier == tierAscii: gcolAscii
  elif p.ambiguousWide: gcolAmbiguous
  elif p.tier == tierBasic: gcolBasic
  else: gcolExtended

func glyph*(p: GlyphProfile; role: GlyphRole): string =
  ## The glyph `role` is drawn with on this profile.
  ChromeGlyphs[role][p.columnOf]

func canonical*(role: GlyphRole): string =
  ## The extended glyph — the spelling a view's published constant keeps.
  ChromeGlyphs[role][gcolExtended]

func markerCells*(p: GlyphProfile): int =
  ## How many cells the truncation marker takes: two under ambiguous-wide
  ## (OQ-T2), else one.
  if p.tier != tierAscii and p.ambiguousWide: 2 else: 1

func pointerField*(p: GlyphProfile; role: GlyphRole): string =
  ## A gutter pointer field: the mark with a cell either side.
  " " & p.glyph(role) & " "

proc allChromeCodePoints*(): seq[string] =
  ## Every non-ASCII glyph this table can produce — what the source gate
  ## (TA-6) forbids outside it.
  for role in GlyphRole:
    for col in GlyphColumn:
      let g = ChromeGlyphs[role][col]
      var ascii = true
      for c in g:
        if ord(c) >= 0x80: ascii = false
      if not ascii and g != RvSpace and g notin result:
        result.add g

const ProsePunctuation* = [("…", "~"), ("—", "-"), ("–", "-"), ("·", "."),
                           ("›", ">"), ("‹", "<"), ("→", ">")]
  ## The typographic punctuation CodeTracer's own messages use, and its
  ## one-cell ASCII stand-in.

func asciiProse*(text: string): string =
  ## A CodeTracer-authored sentence (a status-line note) on the ASCII tier:
  ## its typographic punctuation as ASCII, one cell for one cell. NEVER
  ## applied to program content — only to text CodeTracer wrote.
  result = text
  for (u, a) in ProsePunctuation:
    result = result.replace(u, a)
