## views/state_view.nim
##
## View-state extraction for the State (locals / globals / watches) panel.
##
## Provides `StateViewState` and `VariableViewState`, plain data objects
## that capture the current state of the StateVM as renderer-agnostic
## snapshots.  Any view layer (Karax, IsoNim `ui`, TUI) can call
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

import std/[sets, tables]

import isonim/core/[signals, computation]

import ../store/types as store_types
import ../viewmodels/state_vm
import ../../../common/types

type
  VariableHistoryRowView* = object
    locationTicks*: BiggestInt
    valueText*: string
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

  StateViewState* = object
    ## Renderer-agnostic snapshot of the state panel.
    ##
    ## Fields:
    ##   activeTab          — which tab is selected ("Locals", "Globals", "Watches")
    ##   variables          — flat list of visible variable rows
    ##   isLoading          — whether the panel is waiting for data
    ##   watchInputVisible  — whether the watch-expression input is shown
    activeTab*: string
    variables*: seq[VariableViewState]
    isLoading*: bool
    watchInputVisible*: bool

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tabToString(tab: StateTab): string =
  ## Convert a StateTab enum value to a display string.
  case tab
  of stLocals:  "Locals"
  of stGlobals: "Globals"
  of stWatches: "Watches"

proc flattenVariables(
    variables: seq[store_types.Variable];
    expandedPaths: HashSet[string];
    expandedHistories: HashSet[string];
    valueHistory: Table[string, seq[HistoryResult]];
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
    var historyRows: seq[VariableHistoryRowView] = @[]
    if histExpanded and valueHistory.hasKey(path):
      for r in valueHistory[path]:
        let txt = if r.value != nil: r.value.textRepr else: ""
        historyRows.add VariableHistoryRowView(locationTicks: r.location.rrTicks, valueText: txt)

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
    )
    # Only recurse into children when the node is expanded and has
    # children to show.
    if expanded and v.hasChildren and v.children.len > 0:
      flattenVariables(v.children, expandedPaths, expandedHistories, valueHistory, depth + 1, path, result)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc getStateViewState*(vm: StateVM): StateViewState =
  ## Extract the current view state from the StateVM.
  ##
  ## Reads each signal/memo once and flattens the variable tree
  ## according to which paths are currently expanded.  The watch
  ## input is visible when the user is on the Watches tab.
  let tab = vm.activeTab.val
  let variables = vm.currentVariables.val
  let expandedPaths = vm.expandedPaths.val
  let expandedHistories = vm.expandedHistories.val
  let valueHistory = vm.valueHistory.val

  var flatVars: seq[VariableViewState] = @[]
  flattenVariables(variables, expandedPaths, expandedHistories, valueHistory, depth = 0,
                   parentPath = "", result = flatVars)

  StateViewState(
    activeTab: tabToString(tab),
    variables: flatVars,
    isLoading: vm.isLoading.val,
    watchInputVisible: tab == stWatches,
  )
