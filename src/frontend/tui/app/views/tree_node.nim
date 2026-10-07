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
## ## THE ROW, SINCE PLAT-49
##
##     L ▼ wide_mapping    Dict     [("key_000", 0), ("key_001"…
##     │ │ └───────────┘   └──┘     └──────────────────────────────┘
##     │ │       │           │                  │
##     │ │       │           │                  the formatted value (in the
##     │ │       │           │                  changed-value accent when the
##     │ │       │           │                  step changed it — PLAT-51)
##     │ │       │           the type the engine named
##     │ │       the name
##     │ the expander, right before the name it opens (indented by depth with it)
##     the row's CATEGORY TAG (`state_vm.categoryTag`), colour-coded
##
## The user's direction (2026-10-01): no unexplained first column — the
## expander used to sit alone in column 0 with a blank five-cell `[MOD]` field
## after it on every row — and no separator row per category. So a row now
## starts with the one-letter tag of the group it belongs to and the expander
## sits against the name. (The `[MOD]` badge that ended the row is DROPPED,
## PLAT-51 — the user, 2026-10-05: a changed value is styled as the desktop
## styles it, `diff_highlighter.ChangedValueStyle` on the VALUE, with no
## badge; the five cells it reserved went to the value.)
##
## THE INDENT MOVES THE EXPANDER AND THE NAME, NEVER THE TAG, for
## the reason `frame_item.FrameRowSpec.indent` records: a marker that appears
## at one column on some rows and another on others is not a column anything
## can read.
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
    trkHistory
      ## PLAT-51: one entry of a variable's VALUE HISTORY, under its row as
      ## the desktop shows it (`div.ct-history-inline-row`): the tick and the
      ## value. A NAVIGATION ROW — a click goes to that moment.
    trkOrigin
      ## PLAT-51: one hop of a variable's VALUE ORIGIN chain, under its row
      ## (the desktop's `div.ct-origin-inline-chain-hop`).
    trkAddWatch
      ## PLAT-51: the Watches group's "Add watch expression…" row — the
      ## desktop's watch field, as a row that opens the prompt.

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
    visualisers*: seq[Visualiser]
      ## PLAT-12: the per-type visualisers this session's checkout declared,
      ## in §5.4's order.
      ##
      ## THE ZERO VALUE IS `@[]` AND THAT IS THE PRE-PLAT-12 BEHAVIOUR, exactly.
      ## `withVisualisers(@[])` returns `BuiltinPresenters`, so a row built by
      ## anything that does not know about this field — every existing suite,
      ## `provenanceOf`'s two synthetic specs, a storybook fixture — renders
      ## byte-for-byte what it rendered before. That is why the field carries
      ## the LIST rather than a `PresenterSet`: a zero-valued `PresenterSet`
      ## has no built-in rules either, and a row that quietly resolved every
      ## value to `builtin.none` would still render, just wrongly.
    width*: int
    tag*: string
      ## PLAT-49: the row's category tag (one letter), painted first in
      ## `tagRole`. "" draws a blank cell in its place.
    tagRole*: SemanticRole
    controls*: bool
      ## PLAT-51: the row carries the desktop's value controls at its end —
      ## the history button (K40) and the origin badge (K41) — and, for a
      ## watch, its remove control.
    historyOpen*, originOpen*: bool
      ## Whether the row's history / origin is shown under it (the control is
      ## drawn lit).
    watch*: bool
      ## The row is a watch expression: its remove control is drawn.
    nameCells*: int
      ## PLAT-51: the name column's width the user dragged its separator to
      ## (the desktop's column resize), 0 for the default share.

const
  CollapsedGlyph* = "▶"
  ExpandedGlyph* = "▼"
  LeafGlyph* = " "
    ## §3.3.4 names the first two. A leaf gets a blank in the same column so
    ## the name field does not move.

  TagCells = 1
    ## The category tag's field: one cell, then a gap.
  HistoryControlGlyph* = "↺"
    ## PLAT-51 (K40): the value-history button, one cell (U+21BA, no emoji
    ## presentation); `h` on the ASCII tier.
  OriginControlGlyph* = "⇠"
    ## PLAT-51 (K41): the value-origin badge (U+21E0); `<` on the ASCII tier.
  RemoveWatchGlyph* = "×"
    ## PLAT-51: a watch's remove control (U+00D7); `x` on the ASCII tier.
  ControlCells* = 3
    ## The controls' field at the row's end: history, origin, remove (blank
    ## for a non-watch), before the reserved trailing cell.
  HistoryEntryGlyph* = "↳"
  OriginHopGlyph* = "⇠"
  AddWatchText* = "+ Add watch expression…"
  ControlStyle* = CellStyle(role: srChromeMuted)
  ControlLitStyle* = CellStyle(role: srChromeAccent, bold: true)
  HistoryTickStyle* = CellStyle(role: srChromeMuted)
  NameFieldCol* = TagCells + 1 + 2
    ## First cell of a top-level row's name: tag, gap, expander, gap.

  IndentCells* = 2
    ## Cells one level of depth indents the NAME by.

  MoreRowPrefix* = "… "
  MoreRowSuffix* = " more"

  ExpanderStyle* = CellStyle(role: srChromeAccent)
  ScopeTitleStyle* = CellStyle(role: srChromeTitle)
  ScopeCountStyle* = CellStyle(role: srChromeMuted)
  NameStyle* = CellStyle(role: srChromeText)
  TypeStyle* = CellStyle(role: srChromeMuted)
  MoreRowStyle* = CellStyle(role: srChromeMuted, italic: true)
  NoteStyle* = CellStyle(role: srChromeMuted, italic: true)
  SelectedRowBackground* = srSurfaceSelection
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

proc nameStyleFor*(spec: TreeRowSpec): CellStyle =
  ## The name's style. (PLAT-51: the changed-value accent is on the VALUE, as
  ## the desktop's `.value-changed` paints it, not on the name.)
  case spec.kind
  of trkScope: ScopeTitleStyle
  of trkMore, trkAddWatch: MoreRowStyle
  of trkNote, trkOrigin: NoteStyle
  of trkVariable, trkHistory: NameStyle

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

proc presentation*(spec: TreeRowSpec; cells: int): Presentation =
  ## The whole presentation this row's value produced, not only its text.
  ##
  ## PLAT-12 needs three things off it that a string cannot carry — the
  ## attribution (WHICH visualiser rendered the row), the media gaps (what a
  ## declaration asked for that this surface could not draw), and the node's
  ## kind — and `formattedValue` below now calls this rather than `present`
  ## directly, so the row's text and the row's provenance are the SAME
  ## presentation rather than two renderings that could differ. The same value
  ## at two budgets is two byte strings, which is precisely the confusion
  ## `Budget.name` exists to prevent, and it applies within one row too.
  present(spec.presented, spec.valueBudget(cells),
          measure = terminalMeasure,
          presenters = withVisualisers(spec.visualisers))

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
  spec.presentation(cells).root.text

proc valueStyleFor*(spec: TreeRowSpec): CellStyle =
  ## The value's style: its presentation class's, or — on a row whose value
  ## the step changed — the shared changed-value accent (PLAT-51,
  ## CodeTracer-TUI.md §3.3.4: no `[MOD]` badge).
  if spec.kind != trkVariable: DefaultCellStyle
  elif spec.modified: ChangedValueStyle
  else: valueStyle(spec.valueClassOf())

proc fieldWidths*(width: int; nameCells = 0): tuple[name, typ, value: int] =
  ## How the cells after the fixed prefix are shared between name, type and
  ## value.
  ##
  ## Reported rather than recomputed by the caller, because a Tier-1 assertion
  ## about which column a field lands in and the paint of that field have to
  ## agree — the drift `frame_item.FrameItem.locationCol` exists to prevent.
  let remaining = width - NameFieldCol - ReservedTrailingCells -
                  (ControlCells + 1)
  if remaining <= 0:
    return (0, 0, 0)
  var name = min(max(remaining div 3, MinimumNameCells), MaximumNameCells)
  if nameCells > 0:
    # PLAT-51: the width the user dragged the separator to, kept inside the
    # row (a value field of at least `MinimumValueCells` survives).
    name = max(MinimumNameCells,
               min(nameCells, remaining - MinimumValueCells - 1))
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

proc controlColumn*(width: int): int =
  ## PLAT-51: where the value controls start in a row `width` cells wide —
  ## the history button, then the origin badge, then a watch's remove
  ## control — before the reserved trailing cell.
  width - ReservedTrailingCells - ControlCells

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

  # THE CATEGORY TAG, then a gap.
  put((if spec.tag.len > 0: spec.tag else: " "),
      (if spec.tag.len > 0: CellStyle(role: spec.tagRole)
       else: DefaultCellStyle))
  put(" ", DefaultCellStyle)

  let widths = fieldWidths(width, spec.nameCells)
  let indent = repeat(' ', max(0, spec.depth - 1) * IndentCells)

  case spec.kind
  of trkScope:
    # A scope root spans the whole row: its title and, muted, how many members
    # it has. (The variables pane no longer emits one, PLAT-49; kept for a
    # caller that builds its own spec.)
    put(expanderGlyph(spec), (if spec.expandable: ExpanderStyle
                              else: DefaultCellStyle))
    put(" ", DefaultCellStyle)
    put(spec.name.toUpperAscii(), ScopeTitleStyle)
    if spec.memberCount >= 0:
      put(" " & $spec.memberCount, ScopeCountStyle)
  of trkMore:
    put(indent & "  " & moreRowText(spec.memberCount), MoreRowStyle)
  of trkNote:
    put(indent & "  " & spec.name, NoteStyle)
  of trkHistory:
    # `name` is the tick label, `value` the value at it.
    put(indent & "  " & HistoryEntryGlyph & " ", ControlStyle)
    put(spec.name & "  ", HistoryTickStyle)
    put(spec.value, NameStyle)
  of trkOrigin:
    put(indent & "  " & OriginHopGlyph & " ", ControlStyle)
    put(spec.name, NoteStyle)
  of trkAddWatch:
    put(indent & "  " & AddWatchText, MoreRowStyle)
  of trkVariable:
    # The expander sits against the name, both moved by the indent; the name
    # FIELD still ends at one column on every row so type and value align.
    put(indent, DefaultCellStyle)
    put(expanderGlyph(spec), (if spec.expandable: ExpanderStyle
                              else: DefaultCellStyle))
    put(" ", DefaultCellStyle)
    let nameEnd = NameFieldCol + widths.name
    put(truncateToCells(spec.name, max(0, nameEnd - used)),
        nameStyleFor(spec))
    if used < nameEnd:
      put(repeat(' ', nameEnd - used), DefaultCellStyle)
    put(" ", DefaultCellStyle)
    if widths.typ > 0:
      let typeText = truncateToCells(spec.typeName, widths.typ)
      put(typeText, TypeStyle)
      let typeEnd = nameEnd + 1 + widths.typ
      if used < typeEnd:
        put(repeat(' ', typeEnd - used), DefaultCellStyle)
      put(" ", DefaultCellStyle)
    put(formattedValue(spec, widths.value), valueStyleFor(spec))
    if spec.controls:
      # PLAT-51: the desktop's value controls, at one computed column on
      # every row (`controlColumn`) so a click reads them where they are.
      let at = controlColumn(width)
      if at > used:
        put(repeat(' ', at - used), DefaultCellStyle)
      if used == at:
        put(HistoryControlGlyph,
            if spec.historyOpen: ControlLitStyle else: ControlStyle)
        put(OriginControlGlyph,
            if spec.originOpen: ControlLitStyle else: ControlStyle)
        put((if spec.watch: RemoveWatchGlyph else: " "), ControlStyle)

  if used < width:
    put(repeat(' ', width - used), DefaultCellStyle)

  if spec.selected:
    # Applied last so it keeps every foreground the fields above decided — the
    # same order and the same reason as `source_pane`'s execution-line
    # highlight and `frame_item`'s inspected row.
    #
    # BUT NOT OVER A SPAN THAT ALREADY HAS A BACKGROUND (CTUI-6's
    # expander-column defect: a span with its own ground keeps it).
    for i in 0 ..< spans.len:
      if not spans[i].style.hasOwnBackground:
        spans[i].style = spans[i].style.withBackground(SelectedRowBackground)

  result = spans

proc treeRowText*(spec: TreeRowSpec): string =
  ## The row as text, derived from the spans — so a Tier-2 `regionText` read and
  ## a Tier-1 cell read cannot disagree about what the row says.
  rowText(treeRow(spec))

proc nameFieldColumn*(): int =
  ## Where a top-level row's name starts. A proc rather than a bare constant
  ## so a caller reads it from this module instead of adding two constants
  ## together itself.
  NameFieldCol

proc valueFieldColumn*(width: int; nameCells = 0): int =
  ## Where a top-level row's VALUE starts in a row `width` cells wide — the
  ## cell a changed value's accent begins at (PLAT-51), reported so a Tier-2
  ## case reads the colour where the paint put it.
  let w = fieldWidths(width, nameCells)
  NameFieldCol + w.name + 1 + (if w.typ > 0: w.typ + 1 else: 0)

proc nameSeparatorColumn*(width: int; nameCells = 0): int =
  ## PLAT-51: the cell between the name field and the type / value fields —
  ## the column separator a drag resizes (the desktop's column resize).
  NameFieldCol + fieldWidths(width, nameCells).name
