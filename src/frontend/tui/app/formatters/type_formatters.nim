## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/formatters/type_formatters.nim — CTUI-7's "Type Formatters",
## AFTER PLAT-2.
##
## ## WHAT THIS MODULE IS NOW, AND WHAT IT USED TO BE
##
## It used to be a 514-line value formatter: it classified a value by the SHAPE
## of an already-rendered string, produced hexadecimal companions, normalised
## `0x…` padding, dumped byte buffers, summarised structs and truncated to
## cells. Every one of those is a decision about how a VALUE reads, and the
## other five surfaces in this product each made the same decisions differently
## — which is the problem PLAT-2 exists to remove.
##
## All of it moved to `src/common/value_presentation/`, where one
## implementation serves the state panel, tracepoint output, flow, the
## scratchpad, the event log and this pane. What is left here is the part that
## is genuinely TERMINAL:
##
##   * `terminalMeasure` — how wide a string is IN CELLS. A cell is a fact
##     about a terminal; the DOM has no cells. The presenter takes the measure
##     as a parameter precisely so the truncation can stay in the presenter
##     while being accurate on a medium the presenter knows nothing about.
##   * `valueStyle` — which COLOUR a `PresentationClass` is drawn in. `cyan` is
##     a terminal fact. The class is not, and it comes from the pipeline.
##   * `stringDetail` — the "expandable details" §3.3.4 asks for beside a
##     truncated string. Left here rather than moved because it is a fact about
##     what THIS PANE offers a reader who cannot see the whole value, and no
##     other surface has that affordance yet. If a second one grows it, it
##     moves.
##
## ## WHY THE HEX/DECIMAL PAIR IS NOT HERE ANY MORE
##
## §3.3.4 asks for "numeric types formatted in decimal and hexadecimal
## simultaneously upon focus", and it is now
## `Budget.annotated` — see `surfaces.tuiRowBudget`. That is not a relocation
## for tidiness: the pair is a question about how much room the surface has,
## and expressing it as a budget is what let the same rule become available to
## every other surface without any of them reimplementing it.

import std/unicode

import isonim_tui  # `displayWidth` — the terminal's own idea of a glyph's width

import ../views/styled_row
import ../../../../common/value_presentation

export PresentationClass

const
  NumberStyle* = CellStyle(fg: "cyan")
  StringStyle* = CellStyle(fg: "bright_green")
    ## BRIGHT green rather than plain green, deliberately: plain green + bold is
    ## §3.3.4's diff accent (`diff_highlighter.ModifiedNameStyle`), and a string
    ## VALUE painted in the same colour as a CHANGED NAME would make the one
    ## thing this pane says loudest ambiguous on a screenshot.
  BooleanStyle* = CellStyle(fg: "magenta")
  PointerStyle* = CellStyle(fg: "bright_blue")
  CompoundStyle* = CellStyle(fg: "yellow")
  NoneStyle* = CellStyle(fg: "bright_black")
  ErrorStyle* = CellStyle(fg: "red")
  OpaqueStyle* = CellStyle(fg: "bright_black")
  MediaStyle* = CellStyle(fg: "bright_magenta")
  DefaultValueStyle* = CellStyle(fg: "white")

const TerminalAmbiguousWidth* = awNarrow
  ## The ambiguous-width policy this front-end measures under, FIXED.
  ##
  ## `isonim_tui`'s `displayWidth(s)` reads a thread-local
  ## (`text/width.ambiguousWidth`, settable at runtime by
  ## `setAmbiguousWidth`), which makes the cell width of a rendering depend on
  ## mutable global state. PLAT-2's purity requirement caught it: `func
  ## terminalMeasure` calling that spelling does not compile, with
  ## `'terminalMeasure' calls '.sideEffect' 'displayWidth'`.
  ##
  ## That is not a false positive. A value whose rendering is clipped at a
  ## width the process can change underneath it is not byte-identical across
  ## runs, and byte-identity is what this pane's snapshot tests and CTUI-2's
  ## cross-tier equivalence rest on. So the policy is named here, as a
  ## constant, and passed explicitly to `isonim_tui`'s `func` overload — added
  ## for this (see `isonim-tui/src/isonim_tui/text/width.nim`). `awNarrow` is
  ## the library's own default, so nothing on screen moves.

func terminalMeasure*(s: string): int {.gcsafe, raises: [].} =
  ## `s` in terminal CELLS — the measure this front-end hands the presenter.
  ##
  ## The effect annotations are `PresentationMeasure`'s, and the requirement is
  ## the point: the presenter accepts exactly one proc value from a front-end,
  ## and it must be pure, or a front-end could make every presentation impure
  ## through the one hole in the pipeline.
  displayWidth(s, TerminalAmbiguousWidth)

func valueStyle*(class: PresentationClass): CellStyle =
  ## The colour a value of this class is drawn in.
  ##
  ## THE ONLY MEDIUM-SPECIFIC MAPPING LEFT IN THIS MODULE, and the reason the
  ## class enum lives in the platform-agnostic package rather than here: the
  ## web renderer has the same table with CSS class names in it, and the two
  ## have to be keyed on the same thing or "the same value renders consistently
  ## across surfaces" is a claim about text only.
  case class
  of pcInteger, pcHexLiteral, pcFloat: NumberStyle
  of pcString, pcChar: StringStyle
  of pcBoolean, pcEnum: BooleanStyle
  of pcPointer: PointerStyle
  of pcRecord, pcSequence, pcTuple, pcMap, pcVariant, pcByteBuffer: CompoundStyle
  of pcNone: NoneStyle
  of pcError: ErrorStyle
  of pcFunction, pcOpaque: OpaqueStyle
  of pcMedia: MediaStyle
  of pcUnknown: DefaultValueStyle

func stringDetail*(value: string): string =
  ## The "expandable details" §3.3.4 asks for beside a truncated string: how
  ## long the whole thing is. In CHARACTERS, which is what a reader of a
  ## program means, rather than in bytes.
  var body = value
  if body.len >= 2 and body[0] == '"' and body[^1] == '"':
    body = body[1 ..< body.high]
  $body.runeLen & " chars"
