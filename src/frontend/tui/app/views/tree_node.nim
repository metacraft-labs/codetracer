## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/tree_node.nim — CTUI-7. One row of the variables tree:
## CodeTracer-TUI.md §3.3.4's "node expansion toggles `▶` (collapsed) and `▼`
## (expanded)", "variable name, type annotation, and formatted value", and the
## indentation that says which node a member belongs to.
##
## ## AT `views/` RATHER THAN `components/`, AND SAYING SO
##
## CTUI-7 names this file `app/components/tree_node.nim`. There is no
## `app/components/` directory in this tree and this milestone does not create
## one: CTUI-6 was asked for `app/components/frame_item.nim` and put it in
## `views/` for a reason that has not changed — every pane part CTUI-3, CTUI-5
## and CTUI-6 built lives in `views/`, and inventing a second directory for one
## file would make the layer rule harder to state rather than easier. The same
## decision, recorded the same way.
##
## ## THE MARKER COLUMNS ARE FIXED, AND THAT IS CTUI-6'S LESSON APPLIED
##
##     ▼ [MOD] wide_mapping    Dict     [("key_000", 0), ("key_001"…
##     │ └───┘ └───────────┘   └──┘     └────────────────────────┘
##     │   │         │           │                  │
##     │   │         │           │                  the formatted value
##     │   │         │           the type the engine named
##     │   │         the name, indented by depth
##     │   §3.3.4's `[MOD]`, in a field that is FIVE CELLS WIDE ON EVERY ROW
##     the expander
##
## The `[MOD]` field is blank rather than absent on an unmodified row. Two
## reasons, and the second is the one that matters: the name column then starts
## at the same cell on every row, so a reader scans one edge instead of a ragged
## one; and a Tier-2 case can read the badge out of a real terminal at a column
## it computed from the layout rather than by searching the row for a string —
## which is what `test_real_call_stack.nim` had to learn to do for the two
## cursor columns, after a search matched ordinary source text.
##
## THE INDENT MOVES THE NAME, NEVER THE ROW, for exactly the reason
## `frame_item.FrameRowSpec.indent` records: a badge that appears at column 2 on
## some rows and column 4 on others is not a column anything can read.
##
## ## Pure
##
## Nothing here knows a ViewModel, a debugger or a fetch exists. A row is a
## function of a `TreeRowSpec`, which is a value.

import std/[strutils, unicode]

import ../../../../common/value_presentation
import ../formatters/type_formatters
import ./diff_highlighter
import ./styled_row

export type_formatters, diff_highlighter

type
  TreeRowKind* = enum
    ## What one row of the pane stands for.
    trkScope
      ## A scope root — `LOCALS`, `ARGUMENTS`, … (§3.3.4's "collapsible tree
      ## roots").
    trkVariable
    trkMore
      ## `… 550 more` — the pagination affordance CTUI-7's risk mitigation asks
      ## for by name.
    trkNote
      ## A sentence where members would be: an empty scope, or a scope this
      ## workspace's engine cannot fill. See `app/views/variables.nim`.

  TreeRowSpec* = object
    ## Everything one row is drawn from.
    kind*: TreeRowKind
    name*: string
    typeName*: string
    value*: string
      ## The engine's own rendering, before this module formats it.
    depth*: int
      ## 0 for a scope root, 1 for a top-level variable, deeper for members.
    expandable*: bool
    expanded*: bool
    selected*: bool
      ## The inspection cursor is on this row.
    modified*: bool
      ## §3.3.4: this variable's value changed at the current step.
    focused*: bool
      ## §3.3.4's "upon focus": the row shows the second numeric rendering.
      ## Distinct from `selected` so a test can assert the focus formatting
      ## without a cursor, and so a future host can focus without selecting.
    memberCount*: int
      ## Members this node has, whether or not any are materialised. `-1` when
      ## unknown.
    presented*: PValue
      ## PLAT-2: THE VALUE, not a rendering of it.
      ##
      ## This field replaced `byteBuffer: seq[int]`, and the replacement is the
      ## milestone in one row. `byteBuffer` existed because this pane could only
      ## see `value: string` — so "is this a buffer of bytes?" had to be
      ## answered by re-parsing the members' RENDERED text one directory away
      ## (`variables_binding.byteBufferFor`), and the answer had to be carried
      ## down here as a separate field because the row could not work it out
      ## for itself. With the value present, `presenter.resolve` answers it, in
      ## the same table that answers every other "which presenter" question,
      ## and the row does not carry a second copy of a fact about its own value.
      ##
      ## Nil for a scope header and for a `… n more` marker, which have no
      ## value. `value` above remains, and is what the row shows when
      ## `presented` is nil.
    width*: int

const
  CollapsedGlyph* = "▶"
  ExpandedGlyph* = "▼"
  LeafGlyph* = " "
    ## §3.3.4 names the first two. A leaf gets a blank in the same column so
    ## the name field does not move.

  ModifiedTag* = "[MOD]"
  ModifiedTagCells* = 5
  DiffFieldCol* = 2
    ## First cell of the `[MOD]` field. Derived by the pane from this constant
    ## rather than written down twice.
  NameFieldCol* = DiffFieldCol + ModifiedTagCells + 1
    ## First cell of the name field: expander, gap, tag, gap.

  IndentCells* = 2
    ## Cells one level of depth indents the NAME by.

  MoreRowPrefix* = "… "
  MoreRowSuffix* = " more"

  ExpanderStyle* = CellStyle(fg: "bright_cyan", bold: true)
  ScopeTitleStyle* = CellStyle(fg: "white", bold: true)
  ScopeCountStyle* = CellStyle(fg: "bright_black")
  NameStyle* = CellStyle(fg: "white")
  TypeStyle* = CellStyle(fg: "bright_black")
  MoreRowStyle* = CellStyle(fg: "bright_black", italic: true)
  NoteStyle* = CellStyle(fg: "bright_black", italic: true)
  SelectedRowBackground* = "bright_black"
    ## The inspection cursor's row highlight. The SAME background
    ## `frame_item.InspectedRowBackground` uses, deliberately: it means the same
    ## thing — "this is the row you are on" — in both panes, and two panes that
    ## spelled one cursor two ways would be two cursors to a reader.

  ReservedTrailingCells* = 1
    ## One cell at the right edge, for the reason `frame_item.nim` records: a
    ## run ending at the last column leaves a terminal in the pending-wrap
    ## state.

  MinimumNameCells* = 6
  MaximumNameCells* = 20
  MaximumTypeCells* = 12
  MinimumValueCells* = 4
    ## Below this the type column is dropped entirely: a row that shows a name
    ## and a type and no value is not a variables pane.
  ByteDumpBytes* = 8
    ## Bytes a byte-buffer summary shows before its `…`.

proc expanderGlyph*(spec: TreeRowSpec): string =
  if not spec.expandable: LeafGlyph
  elif spec.expanded: ExpandedGlyph
  else: CollapsedGlyph

proc diffTagText*(spec: TreeRowSpec): string =
  ## The `[MOD]` field's text — five cells, blank when the row did not change.
  if spec.modified: ModifiedTag else: repeat(' ', ModifiedTagCells)

proc diffTagStyle*(spec: TreeRowSpec): CellStyle =
  if spec.modified: ModifiedTagStyle else: DefaultCellStyle

proc nameStyleFor*(spec: TreeRowSpec): CellStyle =
  ## §3.3.4's "distinct background/foreground accent (Green/Bold)" on the row
  ## whose value changed, applied to the NAME — the field a reader scans.
  case spec.kind
  of trkScope: ScopeTitleStyle
  of trkMore: MoreRowStyle
  of trkNote: NoteStyle
  of trkVariable:
    if spec.modified: ModifiedNameStyle else: NameStyle

proc valueClassOf*(spec: TreeRowSpec): PresentationClass =
  ## What the row's value IS, as the ONE presenter says.
  ##
  ## Was `classifyValue(typeName, value)` — an inference from the SHAPE of an
  ## already-rendered string (`"…"` is a string, `{…}` a struct, `[…]` a
  ## sequence). That inference existed because a string was all this pane had,
  ## and it was wrong in a way nothing could see: a value whose type name was
  ## not recognised and whose rendering carried no recognisable bracket
  ## classified as `vcUnknown` and was painted in the default colour, which is
  ## indistinguishable from a correctly classified one.
  classOf(spec.presented)

proc valueBudget*(spec: TreeRowSpec; cells: int): Budget =
  ## The budget THIS ROW declares. One line, this many cells, and the second
  ## numeric rendering when the row is focused.
  tuiRowBudget(cells, spec.focused)

proc formattedValue*(spec: TreeRowSpec; cells: int): string =
  ## The value as this row shows it, ALREADY FITTED.
  ##
  ## The signature is the deliverable: it takes the cells the row has and
  ## returns what fits. `formattedValue(spec)` used to return an unbounded
  ## string that `treeRow` then handed to `truncateValue` — render everything,
  ## clip afterwards. The presenter now stops at the budget, which is why a
  ## 600-entry mapping costs the width of the column rather than 12 KB.
  ##
  ## §3.3.4's four rules still meet here; they are just no longer implemented
  ## here. A byte buffer is a hex dump (`builtin.byte-buffer`), a compound gets
  ## its type name in front of its member list (`builtin.record`), a focused
  ## number gains its second base (`Budget.annotated`), and a `0x…` literal
  ## loses its padding (`normalisedHexLiteral`) — all inside the pipeline, so
  ## every other surface gets them too.
  if spec.presented.isNil:
    return truncateToCells(spec.value, cells)
  present(spec.presented, spec.valueBudget(cells), measure = terminalMeasure).root.text

proc valueStyleFor*(spec: TreeRowSpec): CellStyle =
  if spec.kind == trkVariable: valueStyle(spec.valueClassOf())
  else: DefaultCellStyle

proc fieldWidths*(width: int): tuple[name, typ, value: int] =
  ## How the cells after the fixed prefix are shared between name, type and
  ## value.
  ##
  ## Reported rather than recomputed by the caller, because a Tier-1 assertion
  ## about which column a field lands in and the paint of that field have to
  ## agree — the drift `frame_item.FrameItem.locationCol` exists to prevent.
  let remaining = width - NameFieldCol - ReservedTrailingCells
  if remaining <= 0:
    return (0, 0, 0)
  var name = min(max(remaining div 3, MinimumNameCells), MaximumNameCells)
  name = min(name, remaining)
  var typ = min(remaining div 5, MaximumTypeCells)
  var value = remaining - name - typ - 2
  if value < MinimumValueCells:
    # The type annotation is the field a narrow pane can do without: a name and
    # a value answer "what is it now", and the type is a detail the focused row
    # and the tree's own shape already carry.
    typ = 0
    value = remaining - name - 1
  if value < 0:
    value = 0
  (name, typ, value)

proc moreRowText*(remaining: int): string =
  ## `… 550 more`.
  MoreRowPrefix & $remaining & MoreRowSuffix

proc treeRow*(spec: TreeRowSpec): StyledRow =
  ## One row of the pane, exactly `spec.width` cells wide.
  ##
  ## Built as spans and fitted, never by string concatenation with an `align`
  ## at the end: a span is what carries the style, and the fixed marker columns
  ## are only fixed if every field before them is measured in cells.
  result = @[]
  let width = spec.width
  if width <= 0:
    return

  var spans: seq[StyledSpan] = @[]
  var used = 0

  # The parameters are NOT called `text` and `style`, for the reason
  # `frame_item.frameItemRow` records: a template substitutes identifiers inside
  # object-constructor field names too.
  template put(spanText: string; spanStyle: CellStyle) =
    if used < width:
      let fitted = truncateToCells(spanText, width - used)
      if fitted.len > 0:
        spans.add StyledSpan(text: fitted, style: spanStyle)
        used += cellWidthOf(fitted)

  put(expanderGlyph(spec), (if spec.expandable: ExpanderStyle
                            else: DefaultCellStyle))
  put(" ", DefaultCellStyle)
  put(diffTagText(spec), diffTagStyle(spec))
  put(" ", DefaultCellStyle)

  let widths = fieldWidths(width)
  let indent = repeat(' ', max(0, spec.depth - 1) * IndentCells)

  case spec.kind
  of trkScope:
    # A scope root spans the whole row: its title and, muted, how many members
    # it has. There is no value column to share with.
    put(spec.name.toUpperAscii(), ScopeTitleStyle)
    if spec.memberCount >= 0:
      put(" " & $spec.memberCount, ScopeCountStyle)
  of trkMore:
    put(indent & moreRowText(spec.memberCount), MoreRowStyle)
  of trkNote:
    put(indent & spec.name, NoteStyle)
  of trkVariable:
    let nameText = indent & spec.name
    put(truncateToCells(nameText, widths.name), nameStyleFor(spec))
    if used < NameFieldCol + widths.name:
      put(repeat(' ', NameFieldCol + widths.name - used), DefaultCellStyle)
    put(" ", DefaultCellStyle)
    if widths.typ > 0:
      let typeText = truncateToCells(spec.typeName, widths.typ)
      put(typeText, TypeStyle)
      let typeEnd = NameFieldCol + widths.name + 1 + widths.typ
      if used < typeEnd:
        put(repeat(' ', typeEnd - used), DefaultCellStyle)
      put(" ", DefaultCellStyle)
    put(formattedValue(spec, widths.value), valueStyleFor(spec))

  if used < width:
    put(repeat(' ', width - used), DefaultCellStyle)

  if spec.selected:
    # Applied last so it keeps every foreground the fields above decided — the
    # same order and the same reason as `source_pane`'s execution-line
    # highlight and `frame_item`'s inspected row.
    #
    # BUT NOT OVER A SPAN THAT ALREADY HAS A BACKGROUND, which is a correction
    # this module made after the Tier-2 case was written rather than a
    # precaution: `[MOD]` is a BADGE — black on green — and the first draft
    # painted the cursor's `bright_black` straight over it, so the one row that
    # was both selected and changed lost the marker §3.3.4 exists to show, on
    # exactly the row a reader looks at first. That is CTUI-6's expander-column
    # defect in a different pane.
    for i in 0 ..< spans.len:
      if spans[i].style.bg.len == 0:
        spans[i].style = spans[i].style.withBackground(SelectedRowBackground)

  result = spans

proc treeRowText*(spec: TreeRowSpec): string =
  ## The row as text, derived from the spans — so a Tier-2 `regionText` read and
  ## a Tier-1 cell read cannot disagree about what the row says.
  rowText(treeRow(spec))

proc nameFieldColumn*(): int =
  ## Where a row's name starts. A proc rather than a bare constant so a caller
  ## reads it from this module instead of adding two constants together itself.
  NameFieldCol

proc diffFieldColumn*(): int =
  DiffFieldCol
