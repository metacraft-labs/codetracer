## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/variables.nim — CTUI-7. The right pane of CodeTracer-TUI.md
## §3.3.4: collapsible scope roots for `Locals`, `Arguments`, `Globals`,
## `Return Values` and `Registers`, a hierarchical tree under each, type
## formatters, and the step-to-step diff badge.
##
## ## A PURE FUNCTION OF A VALUE, plus ONE callback, and the callback is the
## ## milestone's contract rather than a convenience
##
## CTUI-7: "child nodes are populated lazily from `StateVM` on expansion."
## A pane that took its whole tree as a value could not honour that — the value
## would have to be the flattened tree, which is the thing that must not exist.
## So the model carries `children`, a `NodeChildren` closure that answers ONE
## node's members over ONE window, and `app/variables_binding.nim` is the only
## module that builds one. Everything else is still a value: which paths are
## open, how far each is paged, where the cursor is, and what the diff says.
##
## `expandNode` calls it; `collapseNode` DROPS what it returned. That second
## half is the one a reviewer should check, and
## `tests/test_variables_tree_expansion.nim` asserts it as
## `heldNodes(path) == 0` rather than as "the rows are gone": a pane that merely
## stopped DRAWING a 600-member node would keep 600 objects alive per collapsed
## node, and on `wide_state` that is the whole point of the exercise.
##
## ## PAGINATION IS A SLICE REQUEST, NOT A FILTER
##
## CTUI-7's risk mitigation: "multi-million-element arrays … slice pagination
## with an explicit `… N more` affordance". So `NodeChildren` takes `(offset,
## limit)` and returns the slice AND the total. A design that fetched the whole
## sequence and showed the first fifty would satisfy every assertion about the
## SCREEN while doing exactly the work the mitigation exists to avoid — which is
## why the suite asserts the number of NODES HELD and not the number of rows
## drawn.
##
## ## FIVE ROOTS, AND THREE OF THEM SAY WHY THEY ARE EMPTY
##
## §3.3.4 names five. Measured against this workspace's ViewModel layer and
## engine on 2026-09-06, only one of them can be filled today, and the pane says
## so ON SCREEN rather than rendering four empty trees that look correct:
##
##   * `Locals` — `store.locals.locals`, written by
##     `ReplayDataStore.applyLocalsResponse` from the `ct/load-locals` answer.
##     REAL.
##   * `Watches` — `store.locals.watches`, written by the same function from the
##     same answer. REAL, and not one of §3.3.4's five: it is `StateVM`'s own
##     third tab and dropping it would leave this pane's ViewModel with a data
##     source that appears nowhere.
##   * `Globals` — `store.locals.globals` EXISTS and nothing in this repository
##     writes it from a backend response (grep, 2026-09-06: one read in
##     `state_vm`, one test assignment, and the collab signal serialiser). The
##     same shape CTUI-5 found in `PointListVM.points`. On Python the engine
##     folds module-level names into the locals answer anyway, which is why
##     `__name__` and `main` appear under `Locals` on `calc`.
##   * `Arguments` — no ViewModel surface and no wire field. `ct/load-locals`
##     does not distinguish a parameter from a local, and `CallLine.args` is
##     never populated by `headless_session.parseCallLine`.
##   * `Return values` — no surface at all.
##   * `Registers` — projected ONLY by the MCR emulator backend
##     (`dap_handler.rs`'s `TraceKind::Emulator` arm of `variables`, over
##     `replay.load_locals`'s named registers). Every fixture in CTUI-1's corpus
##     is a CTFS trace, so no recording in this workspace reaches that arm.
##
## An unavailable root renders its REASON, which is `docs/tui-testing.md`'s rule
## about prerequisites applied to a screen: an empty tree and an unfillable one
## are different answers and only the second one is true.

import std/[strutils, tables]

import isonim_tui

import ../../../../common/value_presentation
import ../layout/profile
import ./styled_row
import ./tree_node

export tree_node, styled_row, profile

type
  ScopeKind* = enum
    ## §3.3.4's "collapsible tree roots", plus `Watches`. Declaration order is
    ## the order they are drawn in.
    skLocals = "Locals"
    skArguments = "Arguments"
    skGlobals = "Globals"
    skReturnValues = "Return values"
    skRegisters = "Registers"
    skWatches = "Watches"

  ScopeAvailability* = enum
    savaAvailable
    savaUnsupported
      ## Nothing in this workspace can fill this root. The pane prints `note`.

  VarNode* = object
    ## One node of the tree, as a value.
    ##
    ## `path` is the key everything else is keyed by: the expansion set, the
    ## page table, the held-children table and the diff. Built by
    ## `childPath` so the scheme has one definition.
    path*: string
    name*: string
    typeName*: string
    value*: string
      ## The presenter's answer at the `tui-value` budget. Carried for the rows
      ## that have no `presented` (a scope header, a `… n more` marker) and as
      ## what a diff compares; `tree_node.formattedValue` re-presents from
      ## `presented` at the ROW's budget, so nothing here reformats and two
      ## panes cannot disagree.
    memberCount*: int
      ## Members this node has. `0` for a leaf.
    presented*: PValue
      ## PLAT-2: the normalised value, so the row can ask the presenter for a
      ## rendering that fits its own column. Replaced `byteBuffer: seq[int]` —
      ## see `tree_node.TreeRowSpec.presented` for why that field existed and
      ## why it does not need to.

  NodeChildren* = proc(path: string; offset, limit: int):
      tuple[nodes: seq[VarNode]; total: int] {.closure.}
    ## THE LAZY POPULATION SEAM. Answers one node's members over one window.
    ##
    ## Returns the TOTAL as well as the slice, because `… N more` has to say a
    ## number the pane never counted for itself — a pane that inferred "there
    ## are more" from a full page would say nothing on a node with exactly
    ## `pageSize` members and would never be able to name `N`.

  Scope* = object
    kind*: ScopeKind
    availability*: ScopeAvailability
    note*: string
      ## Why this root cannot be filled. Empty when it can.

  VariablesRowKind* = enum
    vrkScope
    vrkVariable
    vrkMore
    vrkNote

  VariablesRow* = object
    ## One row of the pane, before it is painted.
    kind*: VariablesRowKind
    scope*: ScopeKind
    node*: VarNode
    depth*: int
    expandable*: bool
    expanded*: bool
    remaining*: int
      ## For `vrkMore`: how many members are still unshown.
    note*: string

  VariablesModel* = object
    ## Everything the pane shows.
    scopes*: seq[Scope]
    expanded*: seq[string]
      ## Open paths — scope roots included, since a scope IS a node here.
    selected*: string
      ## THE INSPECTION CURSOR, as a path. A path rather than a row index
      ## because rows move when a node above them is opened, and a cursor that
      ## jumped to another variable when an unrelated node was expanded would
      ## be the same class of defect as CTUI-6's conflated cursors.
    focused*: string
      ## §3.3.4's "upon focus". Normally equal to `selected`; kept separate so
      ## a test can assert the focused formatting without moving a cursor.
    scrollTop*: int
    pageSize*: int
    diff*: VariableDiff
    tickLabel*: string
      ## What the title row says the pane is showing. A label rather than the
      ## tick itself so the pane does not have to know what a tick is.
    children*: NodeChildren
    held: Table[string, seq[VarNode]]
      ## Materialised members, per open path. PRIVATE: the only ways in are
      ## `expandNode` / `expandMore`, and the only way out is `collapseNode`,
      ## so "released on collapse" is a property of this module rather than of
      ## its callers.
    totals: Table[string, int]
    populations*: int
      ## How many times `children` has been called. Asserted by the expansion
      ## suite: a re-expansion that did no work — the CTUI-4 shape, where the
      ## second side of a comparison finds the state already there — would
      ## leave this number where it was.

  VariablesScreen* = object
    ## One painted pane, plus the counts and coordinates a test asserts on.
    rows*: seq[StyledRow]
    area*: CellArea
    visible*: seq[VariablesRow]
    bodyHeight*: int
    totalRows*: int
    scopeRows*: int
    variableRows*: int
    moreRows*: int
    noteRows*: int
    modifiedRows*: int
    diffColumn*: int
      ## Screen column of the `[MOD]` field's first cell. REPORTED rather than
      ## recomputed by the caller, for the reason `frame_item.FrameItem`
      ## records: a Tier-2 case reads a cell at this column and a drift between
      ## the two arithmetics would move the read, not the badge.
    nameColumn*: int

const
  ProvenanceBudgetCells* = 40
    ## The cell budget `provenanceOf` presents the cursor's value under.
    ##
    ## A CONSTANT rather than the pane's actual value column, and the reason is
    ## the question being answered: "which presenter drew this" is a fact about
    ## the RESOLUTION, and the resolution does not depend on the width. What
    ## does depend on the width is whether the presenter had to clip, which
    ## `describeAttribution` reports as `truncated` — so a budget that changed
    ## with the pane would make that word flicker as the reader resized. 40 is
    ## the width at which the corpus suite exercises `tui-row`.
  MinimumRuleCells* = 4
    ## Cells the trailing rule keeps for itself. Below this the title stops
    ## looking like a titled pane, so the provenance is dropped instead.
  VariablesTitle* = "VARIABLES"
    ## Contains the string CTUI-3's own pane title produced
    ## (`shell.paneTitle(paneState)` uppercased), so every CTUI-3 assertion that
    ## reads `VARIABLES` off a shell row still reads it once this pane fills
    ## that rectangle.
  PaneRule* = "─"
  DefaultPageSize* = 100
    ## Members materialised per expansion step.
    ##
    ## Comfortably more than any terminal shows at once, so paging is invisible
    ## on an ordinary struct, and far less than `wide_state`'s 600 — which is
    ## what makes the pagination suite's assertion a real one rather than a
    ## restatement of the fixture's size.
  ScopePathPrefix* = "@"
    ## A scope's path. Prefixed so it cannot collide with a variable named
    ## `Locals`, and so `variables_binding` can strip it when publishing the
    ## expansion set into `StateVM.expandedPaths`, which the desktop keys by the
    ## variable path alone.

  TitleStyle* = CellStyle(fg: "white", bold: true)
  TitleDetailStyle* = CellStyle(fg: "bright_black")
  RuleStyle* = CellStyle(fg: "bright_black")
  EmptyPaneText* = "no variables reported"
  EmptyPaneStyle* = CellStyle(fg: "bright_black", italic: true)

proc scopePath*(kind: ScopeKind): string =
  ScopePathPrefix & $kind

proc childPath*(parent, name: string): string =
  ## THE ONE DEFINITION of the path scheme: `parent.name`, dot separated,
  ## which is the key `StateVM.expandedPaths` and `StateVM.valueHistory` are
  ## already keyed by (`VariableViewState.path`).
  if parent.len == 0: name else: parent & "." & name

proc variablePathOf*(path: string): string =
  ## A path with its `@Scope.` prefix removed — what the desktop's
  ## `expandedPaths` holds. "" for a scope root itself.
  if not path.startsWith(ScopePathPrefix):
    return path
  let dot = path.find('.')
  if dot < 0: "" else: path[dot + 1 .. ^1]

proc initVariablesModel*(scopes: seq[Scope] = @[];
                         children: NodeChildren = nil;
                         expanded: seq[string] = @[];
                         selected = ""; focused = "";
                         scrollTop = 0;
                         pageSize = DefaultPageSize;
                         diff = VariableDiff();
                         tickLabel = ""): VariablesModel =
  VariablesModel(
    scopes: scopes, expanded: expanded, selected: selected,
    focused: (if focused.len > 0: focused else: selected),
    scrollTop: scrollTop, pageSize: max(1, pageSize), diff: diff,
    tickLabel: tickLabel, children: children,
    held: initTable[string, seq[VarNode]](),
    totals: initTable[string, int](), populations: 0)

proc isEmpty*(model: VariablesModel): bool =
  ## Whether the pane has anything to show at all. A model with no scopes is a
  ## session that has not stopped anywhere yet, and the shell leaves the
  ## rectangle to CTUI-3's plain title row for it.
  model.scopes.len == 0

proc isExpanded*(model: VariablesModel; path: string): bool =
  path in model.expanded

proc heldNodes*(model: VariablesModel; path: string): int =
  ## How many of `path`'s members are MATERIALISED right now.
  ##
  ## The number `tests/test_variables_tree_expansion.nim` asserts is zero after
  ## a collapse. See this module's header on why the row count is not that
  ## assertion.
  if model.held.hasKey(path): model.held[path].len else: 0

proc heldNodeTotal*(model: VariablesModel): int =
  ## Every materialised node in the model, over every open path.
  for _, nodes in model.held:
    result += nodes.len

proc memberTotal*(model: VariablesModel; path: string): int =
  ## How many members `path` has according to the last answer, or -1 when the
  ## node has never been expanded.
  if model.totals.hasKey(path): model.totals[path] else: -1

proc childrenOf*(model: VariablesModel; path: string): seq[VarNode] =
  if model.held.hasKey(path): model.held[path] else: @[]

# ---------------------------------------------------------------------------
# Expansion
# ---------------------------------------------------------------------------

proc fetchInto(model: var VariablesModel; path: string; offset, limit: int) =
  ## One call through the seam, appended to what is already held.
  if model.children.isNil:
    return
  inc model.populations
  let answer = model.children(path, offset, limit)
  model.totals[path] = answer.total
  if not model.held.hasKey(path):
    model.held[path] = @[]
  for node in answer.nodes:
    model.held[path].add node

proc expandNode*(model: var VariablesModel; path: string) =
  ## Open `path` and materialise its FIRST PAGE.
  ##
  ## Idempotent in the expansion set and NOT idempotent in the fetch: re-opening
  ## a node that was collapsed queries again, which is what "released rather
  ## than hidden" means from the other side.
  if path notin model.expanded:
    model.expanded.add path
  if model.held.hasKey(path) and model.held[path].len > 0:
    return
  model.held[path] = @[]
  model.fetchInto(path, 0, model.pageSize)

proc expandMore*(model: var VariablesModel; path: string): int =
  ## Materialise the NEXT page of `path`'s members. Returns how many arrived.
  ##
  ## The `… N more` row's action. Returns the count so a caller can tell "the
  ## page was empty because the node ended" from "the seam answered nothing",
  ## which are different failures.
  if path notin model.expanded:
    return 0
  let before = model.heldNodes(path)
  let total = model.memberTotal(path)
  if total >= 0 and before >= total:
    return 0
  model.fetchInto(path, before, model.pageSize)
  model.heldNodes(path) - before

proc releaseSubtree(model: var VariablesModel; path: string) =
  ## Drop `path`'s members and every descendant's, recursively.
  ##
  ## RECURSIVE ON PURPOSE. A collapse that released one level would leave a
  ## grandchild's page alive under a node nothing can reach, which is a leak
  ## that no screen shows and no row count finds.
  if not model.held.hasKey(path):
    return
  var descendants: seq[string] = @[]
  for node in model.held[path]:
    descendants.add node.path
  model.held.del(path)
  model.totals.del(path)
  for child in descendants:
    model.releaseSubtree(child)

proc collapseNode*(model: var VariablesModel; path: string) =
  ## Close `path` and RELEASE what it held.
  var kept: seq[string] = @[]
  for p in model.expanded:
    if p != path and not p.startsWith(path & "."):
      kept.add p
  model.expanded = kept
  model.releaseSubtree(path)

proc toggleNode*(model: var VariablesModel; path: string): bool =
  ## Open a closed node or close an open one. Returns whether it is now open.
  if model.isExpanded(path):
    model.collapseNode(path)
    false
  else:
    model.expandNode(path)
    true

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

proc appendNodeRows(model: VariablesModel; scope: ScopeKind; path: string;
                    depth: int; rows: var seq[VariablesRow]) =
  ## The rows for the materialised members of `path`, and their members.
  let members = model.childrenOf(path)
  for node in members:
    let open = model.isExpanded(node.path)
    rows.add VariablesRow(kind: vrkVariable, scope: scope, node: node,
                          depth: depth, expandable: node.memberCount > 0,
                          expanded: open)
    if open:
      model.appendNodeRows(scope, node.path, depth + 1, rows)
  let total = model.memberTotal(path)
  if total > members.len:
    rows.add VariablesRow(kind: vrkMore, scope: scope, depth: depth,
                          remaining: total - members.len,
                          node: VarNode(path: path))

proc paneRows*(model: VariablesModel): seq[VariablesRow] =
  ## Every row the pane would show if it were tall enough, in order.
  result = @[]
  for scope in model.scopes:
    let path = scopePath(scope.kind)
    let open = model.isExpanded(path)
    result.add VariablesRow(
      kind: vrkScope, scope: scope.kind, depth: 0,
      expandable: scope.availability == savaAvailable, expanded: open,
      node: VarNode(path: path, name: $scope.kind,
                    memberCount: model.memberTotal(path)))
    if scope.availability == savaUnsupported:
      result.add VariablesRow(kind: vrkNote, scope: scope.kind, depth: 1,
                              note: scope.note)
      continue
    if not open:
      continue
    if model.memberTotal(path) == 0:
      result.add VariablesRow(kind: vrkNote, scope: scope.kind, depth: 1,
                              note: "empty at this position")
      continue
    model.appendNodeRows(scope.kind, path, 1, result)

proc rowOfPath*(rows: openArray[VariablesRow]; path: string): int =
  ## The row showing `path`, or -1.
  result = -1
  for i, row in rows:
    if row.kind in {vrkScope, vrkVariable} and row.node.path == path:
      return i

proc rowSpecFor*(model: VariablesModel; row: VariablesRow;
                 width: int): TreeRowSpec =
  ## The `tree_node` spec for one row of this model.
  ##
  ## The ONE place that decides which markers a row carries, so "the cursor is
  ## on the selected path" and "the badge is on a changed variable" are one rule
  ## rather than two copies of it.
  case row.kind
  of vrkScope:
    TreeRowSpec(kind: trkScope, name: $row.scope, depth: 0,
                expandable: row.expandable, expanded: row.expanded,
                selected: model.selected == row.node.path,
                memberCount: row.node.memberCount, width: width)
  of vrkNote:
    TreeRowSpec(kind: trkNote, name: row.note, depth: 1, memberCount: -1,
                width: width)
  of vrkMore:
    TreeRowSpec(kind: trkMore, depth: row.depth, memberCount: row.remaining,
                width: width)
  of vrkVariable:
    TreeRowSpec(
      kind: trkVariable, name: row.node.name, typeName: row.node.typeName,
      value: row.node.value, depth: row.depth,
      expandable: row.expandable, expanded: row.expanded,
      selected: model.selected == row.node.path,
      modified: model.diff.isModified(variablePathOf(row.node.path)),
      focused: model.focused == row.node.path,
      memberCount: row.node.memberCount, presented: row.node.presented,
      width: width)

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc selectedPresented*(model: VariablesModel): PValue =
  ## The recorded value under the inspection cursor, or `nil`.
  ##
  ## Nil for a scope header, for a `… n more` marker, for a note, and when
  ## nothing is selected — none of which is a value.
  if model.selected.len == 0:
    return nil
  for row in model.paneRows():
    if row.kind == vrkVariable and row.node.path == model.selected:
      return row.node.presented
  nil

proc provenanceOf*(model: VariablesModel): string =
  ## PLAT-2 deliverable 4, made reachable: WHICH PRESENTER rendered the value
  ## under the inspection cursor, in one line.
  ##
  ## ## WHY THIS EXISTS, AND WHY HERE
  ##
  ## `Attribution` has ridden every `Presentation` since PLAT-2 and
  ## `describeAttribution` has rendered it since PLAT-2, and until now NOTHING
  ## IN THE PRODUCT CALLED EITHER. Project-Definitions §5.4's reason for the
  ## field is that "a formatting layer that cannot explain itself becomes
  ## untrustworthy the first time it is wrong" — which is a claim about a
  ## reader, so a field only a test can reach does not satisfy it.
  ##
  ## The variables pane is where it belongs rather than a new command or a new
  ## key, and that is a decision rather than a convenience. §4.2's key table
  ## and §4.3's sixteen commands are PUBLISHED sets asserted against the
  ## specification in BOTH directions: `tests/test_gdb_command_surface.nim`
  ## parses §4.3 and asserts `CommandKind` and the published rows are equal as
  ## sequences (so a seventeenth command with no row, or a row with no command,
  ## is red), and `tests/test_keymap_no_conflicts.nim` parses §4.2's 33 rows
  ## and asserts the three non-§4.2 actions by name. Adding a seventeenth
  ## command or a fourth such action to surface a debugging detail would be a
  ## specification change made sideways. The pane's title row
  ## already carries muted DETAIL spans — the name count, the changed count,
  ## the tick label — and "which presenter drew the row you are on" is exactly
  ## that kind of detail.
  ##
  ## THE BUDGET IS THE ROW'S. The same value at two budgets is two different
  ## byte strings, so an attribution that named a budget the reader is not
  ## looking at would be answering a different question; `describeAttribution`
  ## prints the budget name for that reason and this passes the one the pane
  ## actually painted with.
  let presented = model.selectedPresented()
  if presented.isNil:
    return ""
  let spec = TreeRowSpec(kind: trkVariable, presented: presented,
                         focused: model.focused == model.selected)
  describeAttribution(
    present(presented, spec.valueBudget(ProvenanceBudgetCells),
            measure = terminalMeasure))

proc provenanceBadgeOf*(model: VariablesModel): string =
  ## The short form — `via builtin.record` — for a title row with too few
  ## cells for the full line. See `vocabulary.attributionBadge` on why a
  ## caller short of room shows the shortest TRUE answer rather than a clipped
  ## one.
  let presented = model.selectedPresented()
  if presented.isNil:
    return ""
  let spec = TreeRowSpec(kind: trkVariable, presented: presented,
                         focused: model.focused == model.selected)
  attributionBadge(
    present(presented, spec.valueBudget(ProvenanceBudgetCells),
            measure = terminalMeasure))

proc fitProvenance*(model: VariablesModel; width, usedByTitle: int): string =
  ## The longest TRUE provenance that fits, or "".
  ##
  ## Three answers, in order: the full `describeAttribution` line, the short
  ## `via <presenter>` badge, and nothing. Never a clipped line — see
  ## `vocabulary.attributionBadge`.
  let room = width - usedByTitle - MinimumRuleCells
  if room <= 0:
    return ""
  let full = model.provenanceOf()
  if full.len == 0:
    return ""
  if cellWidthOf("  " & full) <= room:
    return "  " & full
  let badge = model.provenanceBadgeOf()
  if cellWidthOf("  " & badge) <= room:
    return "  " & badge
  ""

proc titleRowSpans*(model: VariablesModel; width: int): StyledRow =
  ## `VARIABLES 22 name(s) 1 changed  builtin.record tier=builtin … ────`.
  ##
  ## The two numbers are the facts the suites assert against data they derived
  ## themselves: how many top-level names the engine reported for the FIRST
  ## available scope, and how many of them this step changed. The trailing
  ## detail is PLAT-2 deliverable 4's affordance; see `provenanceOf`.
  result = @[]
  if width <= 0:
    return
  var names = -1
  for scope in model.scopes:
    if scope.availability == savaAvailable:
      names = model.memberTotal(scopePath(scope.kind))
      break
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: VariablesTitle, style: TitleStyle)
  if names >= 0:
    parts.add StyledSpan(text: " " & $names & " name(s)",
                         style: TitleDetailStyle)
  let changed = model.diff.modifiedPaths().len
  if changed > 0:
    parts.add StyledSpan(text: " " & $changed & " changed",
                         style: TitleDetailStyle)
  if model.tickLabel.len > 0:
    parts.add StyledSpan(text: " " & model.tickLabel, style: TitleDetailStyle)
  var used = 0
  # The provenance is fitted BEFORE the rule rather than truncated with the
  # rest: `fitProvenance` chooses the longest form that fits and drops the span
  # entirely when neither does, so what the pane shows is always a presenter id
  # a reader can grep for.
  var titleCells = 0
  for part in parts:
    titleCells += cellWidthOf(part.text)
  let provenance = fitProvenance(model, width, titleCells)
  if provenance.len > 0:
    parts.add StyledSpan(text: provenance, style: TitleDetailStyle)
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)
  if used < width:
    result.add StyledSpan(text: " ", style: DefaultCellStyle)
    inc used
  if used < width:
    result.add StyledSpan(text: repeatGlyph(PaneRule, width - used),
                          style: RuleStyle)

proc titleRowText*(model: VariablesModel; width: int): string =
  rowText(titleRowSpans(model, width))

proc clampScrollTop*(scrollTop, totalRows, bodyHeight: int): int =
  ## The first visible row, clamped so the body never runs off either end.
  if scrollTop < 0: 0
  elif bodyHeight <= 0: 0
  elif totalRows <= bodyHeight: 0
  elif scrollTop > totalRows - bodyHeight: totalRows - bodyHeight
  else: scrollTop

proc paintVariables*(g: var StyledGrid; area: CellArea;
                     model: VariablesModel): VariablesScreen =
  ## Paint the pane into `area` of `g`, and report what it painted.
  result = VariablesScreen(
    rows: @[], area: area, visible: @[], bodyHeight: 0, totalRows: 0,
    scopeRows: 0, variableRows: 0, moreRows: 0, noteRows: 0, modifiedRows: 0,
    diffColumn: area.col + diffFieldColumn(),
    nameColumn: area.col + nameFieldColumn())
  if area.width <= 0 or area.height <= 0:
    return

  var spanAt = area.col
  for span in titleRowSpans(model, area.width):
    g.paint(area.row, spanAt, span.text, span.style)
    spanAt += cellWidthOf(span.text)

  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let bodyHeight = area.height - 1
  result.bodyHeight = bodyHeight
  let rows = model.paneRows()
  result.totalRows = rows.len

  if rows.len == 0:
    g.paint(area.row + 1, area.col,
            truncateToCells(EmptyPaneText, area.width), EmptyPaneStyle)
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let top = clampScrollTop(model.scrollTop, rows.len, bodyHeight)
  for i in 0 ..< bodyHeight:
    let rowIndex = top + i
    if rowIndex >= rows.len:
      break
    let screenRow = area.row + 1 + i
    let modelRow = rows[rowIndex]
    let spec = rowSpecFor(model, modelRow, area.width)
    var at = area.col
    for span in treeRow(spec):
      g.paint(screenRow, at, span.text, span.style)
      at += cellWidthOf(span.text)
    result.visible.add modelRow
    case modelRow.kind
    of vrkScope: inc result.scopeRows
    of vrkVariable: inc result.variableRows
    of vrkMore: inc result.moreRows
    of vrkNote: inc result.noteRows
    if spec.modified:
      inc result.modifiedRows

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc variablesScreen*(model: VariablesModel;
                      width, height: int): VariablesScreen =
  ## The pane on a screen of its own — the shape a Tier-1 test and the
  ## `app_variables` snapshot app both use.
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintVariables(g, area, model)

proc variablesRows*(model: VariablesModel;
                    width, height: int): seq[StyledRow] =
  variablesScreen(model, width, height).rows

proc variablesText*(model: VariablesModel; width, height: int): seq[string] =
  ## The pane as plain text, one string per row. What a Tier-2 `regionText`
  ## read is compared against.
  result = @[]
  for row in variablesRows(model, width, height):
    result.add rowText(row)

proc bodyRowForPath*(screen: VariablesScreen; path: string): int =
  ## The SCREEN row showing `path`, or -1 when it is scrolled out.
  ##
  ## Derived from what was actually painted rather than recomputed from the
  ## model, so a test that reads a row and a pane that painted it cannot
  ## disagree about which row that was.
  result = -1
  for i, row in screen.visible:
    if row.kind in {vrkScope, vrkVariable} and row.node.path == path:
      return screen.area.row + 1 + i

proc pathAtScreenRow*(screen: VariablesScreen; screenRow: int): string =
  ## The path a screen row shows, or "" outside the body.
  let i = screenRow - screen.area.row - 1
  if i < 0 or i >= screen.visible.len:
    return ""
  let row = screen.visible[i]
  if row.kind in {vrkScope, vrkVariable}: row.node.path else: ""

proc renderVariablesTree*(model: VariablesModel; r: TerminalRenderer;
                          width, height: int): TerminalNode =
  ## The pane as a component tree: one `div` per row, styled spans inside.
  styledRowsTree(r, variablesRows(model, width, height))
