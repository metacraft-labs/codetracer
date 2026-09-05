## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/gutter.nim — CTUI-5. The left edge of the source pane:
## CodeTracer-TUI.md §3.3.2's line numbers, breakpoint and tracepoint
## indicators, and the execution pointer.
##
## ## What §3.3.2 asks for, verbatim, and where each piece is
##
##   * "Right-aligned line number gutter with muted styling" — `gcLineNumber`,
##     `bright_black`. NOT `dim`: see `app/views/styled_row.nim`'s header —
##     libvterm has no dim bit, so a dim line number is a style the cross-tier
##     equality cannot check, and a muted colour is one it can.
##   * "Indicators in column 1 to 2: `●` (Red) active breakpoint, `◆` (Cyan)
##     active tracepoint, `○` (Muted) disabled breakpoint" — `GutterMark`, one
##     cell, at the pane's own first column.
##   * "`-->` (Bright Yellow/Cyan): current execution statement" — three cells,
##     between the number and the text, `bright_yellow` and bold. The
##     specification offers two colours; yellow is taken because cyan is
##     already the tracepoint's and two things in one gutter must not share a
##     colour.
##   * "Background highlight on current active execution line" — not painted
##     here. It is a property of the WHOLE row including the code, so
##     `app/views/source_pane.nim` applies it with `StyledGrid.restyle` after
##     both the gutter and the highlighter have decided their foregrounds.
##
## ## The gutter is a FUNCTION OF A VALUE, and that is what makes the
## ## fine-grained-subscription contract measurable
##
## `gutterRow` takes a `GutterLineSpec` — one line's number, mark, execution
## flag and provenance — and returns a `StyledRow`. No ViewModel, no signal, no
## renderer. CTUI-5's contract is that "changing the execution line
## re-evaluates the gutter and pointer cells, not the text buffer", and the way
## that is asserted is by re-composing two frames and counting the compositor's
## dirty regions and emitted bytes. That only means anything if the gutter for
## an UNCHANGED line is byte-identical between the two frames, which a pure
## function of the line's own value guarantees and a closure over a signal
## would not.
##
## ## Width is derived, not chosen
##
## `gutterWidth` is `mark + number + gap + pointer + gap`. The number's width
## comes from the file's own length (or, in heatmap mode, from the largest
## execution count), so a 117-line file gets a 3-column number field and a
## 12 000-line file gets 5 — and the code column moves with it rather than the
## numbers being truncated. A minimum of two digits keeps the gutter from
## twitching between 9 and 10 lines of a freshly opened file.

import std/strutils

import ./styled_row

type
  GutterMark* = enum
    ## §3.3.2's three indicators, plus the absence of one.
    gmNone
    gmBreakpoint          ## `●`, red — an active breakpoint
    gmBreakpointDisabled  ## `○`, muted — a disabled breakpoint
    gmTracepoint          ## `◆`, cyan — a tracepoint: records without stopping

  GutterMode* = enum
    ## Which number the gutter shows.
    gutLineNumbers
      ## §3.3.2's default: the line's own number.
    gutExecutionCounts
      ## §3.3.2's "Execution Frequency Heatmap (Optional Gutter Mode)": how
      ## often the line ran, coloured on a flame spectrum by
      ## `app/views/heatmap.nim`.

  GutterProvenance* = enum
    ## How much the pane may claim about the text beside this gutter.
    ##
    ## A gutter concern rather than only a header one, because CTUI-5's
    ## contract is that "a file served `savUnverified` must not look identical
    ## to one served `savVerified`", and a marker that lives only in a title
    ## row is off screen for a reader looking at line 400. The line numbers are
    ## the one thing on every row of the pane.
    gpVerified     ## the recording's own copy
    gpUnverified   ## a working-tree read, or a revision that could not be
                   ## confirmed
    gpAbsent       ## no source of any kind for this path

  GutterLineSpec* = object
    ## Everything one line's gutter is decided from.
    line*: int
      ## The 1-based source line. Shown in `gutLineNumbers` mode.
    numberText*: string
      ## What the number FIELD shows. Empty means "use `line`"; heatmap mode
      ## fills it with an execution count. A string rather than an int because
      ## the two modes format differently and a formatter with a mode flag in
      ## it is one branch further from the caller than it needs to be.
    numberStyle*: CellStyle
      ## The number field's style. Defaulted by `gutterRow` from `provenance`
      ## when left unset; heatmap mode supplies the flame colour.
    mark*: GutterMark
    isExecutionLine*: bool
    provenance*: GutterProvenance
    numberWidth*: int
      ## Cells reserved for the number field. `gutterWidth` is derived from
      ## this, so the two cannot disagree.

const
  GutterMarkCells* = 1
    ## §3.3.2's "column 1 to 2" is one glyph and the space after it; the space
    ## belongs to the number field's right alignment, so the mark itself is one
    ## cell.
  GutterPointerCells* = 3
    ## `-->`.
  GutterGapCells* = 1
  MinGutterNumberCells* = 2

  BreakpointGlyph* = "●"
  BreakpointDisabledGlyph* = "○"
  TracepointGlyph* = "◆"
  ExecutionPointerGlyph* = "-->"
  NoPointerGlyph* = "   "
    ## Three spaces, so the code column does not move when the pointer leaves a
    ## line. A gutter that shrank on every line but one would make a step look
    ## like a horizontal jump.

  BreakpointStyle* = CellStyle(fg: "red", bold: true)
  BreakpointDisabledStyle* = CellStyle(fg: "bright_black")
  TracepointStyle* = CellStyle(fg: "cyan", bold: true)
  ExecutionPointerStyle* = CellStyle(fg: "bright_yellow", bold: true)
  VerifiedLineNumberStyle* = CellStyle(fg: "bright_black")
  UnverifiedLineNumberStyle* = CellStyle(fg: "yellow")
    ## THE PROVENANCE TINT. `savUnverified` source is rendered — CTUI-4's seam
    ## says it must be — but it is never rendered as though it were the
    ## recording's own copy, and this is the half of that distinction which is
    ## visible on every row.
  AbsentLineNumberStyle* = CellStyle(fg: "red")
  ExecutionLineBackground* = "blue"
    ## §3.3.2's "background highlight on current active execution line".
    ## Applied by `source_pane.nim` over the whole row.

proc digitCount*(n: int): int =
  ## How many decimal digits `n` needs. Zero and negatives count as one.
  if n <= 9: return 1
  var v = n
  while v > 0:
    inc result
    v = v div 10

proc gutterNumberWidth*(largestNumber: int): int =
  ## Cells the number field needs for the largest value it will show.
  max(MinGutterNumberCells, digitCount(max(0, largestNumber)))

proc gutterWidth*(numberWidth: int): int =
  ## Total cells the gutter occupies, derived from the number field.
  GutterMarkCells + max(0, numberWidth) + GutterGapCells +
    GutterPointerCells + GutterGapCells

proc markGlyph*(mark: GutterMark): string =
  case mark
  of gmNone: " "
  of gmBreakpoint: BreakpointGlyph
  of gmBreakpointDisabled: BreakpointDisabledGlyph
  of gmTracepoint: TracepointGlyph

proc markStyle*(mark: GutterMark): CellStyle =
  case mark
  of gmNone: DefaultCellStyle
  of gmBreakpoint: BreakpointStyle
  of gmBreakpointDisabled: BreakpointDisabledStyle
  of gmTracepoint: TracepointStyle

proc lineNumberStyle*(provenance: GutterProvenance): CellStyle =
  case provenance
  of gpVerified: VerifiedLineNumberStyle
  of gpUnverified: UnverifiedLineNumberStyle
  of gpAbsent: AbsentLineNumberStyle

proc initGutterLineSpec*(line: int; numberWidth: int;
                         mark = gmNone; isExecutionLine = false;
                         provenance = gpVerified;
                         numberText = "";
                         numberStyle = DefaultCellStyle): GutterLineSpec =
  ## A spec with the defaults every caller would otherwise repeat.
  GutterLineSpec(line: line, numberText: numberText, numberStyle: numberStyle,
                 mark: mark, isExecutionLine: isExecutionLine,
                 provenance: provenance, numberWidth: numberWidth)

proc gutterRow*(spec: GutterLineSpec): StyledRow =
  ## One line's gutter, as styled spans, exactly `gutterWidth(spec.numberWidth)`
  ## cells wide.
  ##
  ## Four spans, always the same four, whatever the line: the mark, the number,
  ## the gap, the pointer, the gap. Always-the-same-shape matters for the
  ## emission budget — the compositor's strip cache is keyed per entry, and a
  ## gutter whose SPAN COUNT changed when a breakpoint appeared would
  ## invalidate every entry on the row rather than one.
  result = @[]
  result.add StyledSpan(text: markGlyph(spec.mark), style: markStyle(spec.mark))

  let number =
    if spec.numberText.len > 0: spec.numberText
    else: $spec.line
  let numStyle =
    if spec.numberStyle.isDefault: lineNumberStyle(spec.provenance)
    else: spec.numberStyle
  result.add StyledSpan(text: padLeft(number, spec.numberWidth),
                        style: numStyle)
  result.add StyledSpan(text: repeat(' ', GutterGapCells),
                        style: DefaultCellStyle)

  if spec.isExecutionLine:
    result.add StyledSpan(text: ExecutionPointerGlyph,
                          style: ExecutionPointerStyle)
  else:
    result.add StyledSpan(text: NoPointerGlyph, style: DefaultCellStyle)
  result.add StyledSpan(text: repeat(' ', GutterGapCells),
                        style: DefaultCellStyle)
