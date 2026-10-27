## views/state_view.nim
##
## View-state extraction for the State (locals / globals / watches) panel.
##
## Provides `StateViewState` and `VariableViewState`, plain data objects
## that capture the current state of the StateVM as renderer-agnostic
## snapshots.  Any view layer (IsoNim `ui`, TUI) can call
## `getStateViewState` to obtain a flat structure suitable for rendering.
##
## Variables are flattened into a list with depth information so that
## renderers do not need to walk a recursive tree — they can iterate
## the flat list and indent by `depth`.
##
## Usage:
##   let vs = getStateViewState(session.stateVM)
##   for v in vs.variables:
##     echo "  ".repeat(v.depth) & v.name & " = " & v.value

import std/[sets, strutils, tables]

import isonim/core/[signals, computation]

import ../store/types as store_types
import ../viewmodels/state_vm
from ../viewmodels/table_overflow import fullValueText

type
  VariableHistoryRowView* = state_vm.ValueHistoryRow
    ## One value-history row as the renderer sees it. Alias of the VM's
    ## already-normalised `ValueHistoryRow` — the view layer performs no
    ## further reduction, so keeping a second structurally identical
    ## object here would only invite the two to drift apart.

  VariableViewState* = object
    ## Renderer-agnostic snapshot of a single variable row.
    ##
    ## Fields:
    ##   name        — variable name (leaf name, e.g. "x")
    ##   path        — dot-separated full path (e.g. "parent.x") for expand toggle
    ##   value       — display string for the variable's value
    ##   typeName    — type annotation (e.g. "int", "string")
    ##   isExpanded  — whether the variable's children are visible
    ##   hasChildren — whether the variable has child entries
    ##   depth       — nesting level (0 = top-level)
    name*: string
    path*: string
    value*: string
    typeName*: string
    isExpanded*: bool
    hasChildren*: bool
    depth*: int
    isHistoryExpanded*: bool
    history*: seq[VariableHistoryRowView]
    moreElements*: bool
      ## The locals budget cut this collection short: `heldElements` of
      ## `elementsTotal` are held, and `StateVM.loadMore` fetches the next.
    heldElements*: int
    elementsTotal*: int
    isWatch*: bool
      ## A watched expression's row (a row of the same list as the variables,
      ## Variable-State-Pane.md § Decisions, 2026-10-24).
    watchInvalid*: bool
      ## The stop cannot answer this watch; `value` says why.
    watchPending*: bool
      ## The watch's value has not arrived yet.

  StateViewState* = object
    ## Renderer-agnostic snapshot of the state panel.
    ##
    ## Fields:
    ##   variables          — the one list: locals, globals, then watches
    ##   isLoading          — whether the panel is waiting for data
    variables*: seq[VariableViewState]
    isLoading*: bool

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc flattenVariables(
    variables: seq[store_types.Variable];
    expandedPaths: HashSet[string];
    expandedHistories: HashSet[string];
    valueHistory: Table[string, seq[ValueHistoryRow]];
    depth: int;
    parentPath: string;
    result: var seq[VariableViewState]) =
  ## Recursively flatten a tree of Variables into a flat list of
  ## VariableViewState entries.  Only children of expanded nodes are
  ## included, so the output matches what a renderer should display.
  ##
  ## `parentPath` is used to construct the full path for each variable
  ## (e.g. "parent.child") so it can be looked up in `expandedPaths`.
  for v in variables:
    let path = if parentPath.len == 0: v.name
               else: parentPath & "." & v.name
    let expanded = path in expandedPaths
    let histExpanded = path in expandedHistories
    # The history rows are only carried when the row is expanded, so a
    # collapsed row renders an empty container (and the view's
    # ``indexEach`` truncates any rows left over from a previous
    # expansion).
    var historyRows: seq[VariableHistoryRowView] = @[]
    if histExpanded and valueHistory.hasKey(path):
      historyRows = valueHistory[path]

    result.add VariableViewState(
      name: v.name,
      path: path,
      value: v.value,
      typeName: v.typeName,
      isExpanded: expanded,
      hasChildren: v.hasChildren,
      depth: depth,
      isHistoryExpanded: histExpanded,
      history: historyRows,
      moreElements: v.moreElements,
      heldElements: v.children.len,
      elementsTotal: v.elementsTotal,
      isWatch: v.isWatch and depth == 0,
      watchInvalid: depth == 0 and v.isInvalidWatch,
      watchPending: depth == 0 and v.isPendingWatch,
    )
    # Only recurse into children when the node is expanded and has
    # children to show.
    if expanded and v.hasChildren and v.children.len > 0:
      flattenVariables(v.children, expandedPaths, expandedHistories, valueHistory, depth + 1, path, result)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc fullValueOf*(vm: StateVM; path: string): string =
  ## PLAT-70 Part B: the WHOLE value of the variable at `path` (child names
  ## joined with `.`, `VariableViewState.path`) — `table_overflow.fullValueText`,
  ## the same text on every front-end. Asked for by the desktop's table pass
  ## only for a cell it found CUT, so a row that fits never pays for it and the
  ## rows the view receives carry no second copy of every value.
  let parts = path.split('.')
  var level = vm.currentVariables.val
  for i, part in parts:
    var found = false
    for v in level:
      if v.name == part:
        if i == parts.high:
          return fullValueText(v.presented, v.value)
        level = v.children
        found = true
        break
    if not found:
      return ""
  ""

proc getStateViewState*(vm: StateVM): StateViewState =
  ## Extract the current view state from the StateVM.
  ##
  ## Reads each signal/memo once and flattens the variable tree
  ## according to which paths are currently expanded.
  let variables = vm.currentVariables.val
  let expandedPaths = vm.expandedPaths.val
  let expandedHistories = vm.expandedHistories.val
  let valueHistory = vm.valueHistory.val

  var flatVars: seq[VariableViewState] = @[]
  flattenVariables(variables, expandedPaths, expandedHistories, valueHistory, depth = 0,
                   parentPath = "", result = flatVars)

  StateViewState(
    variables: flatVars,
    isLoading: vm.isLoading.val,
  )
