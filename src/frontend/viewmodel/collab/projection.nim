## Projection adapters from SharedSessionViewState into panel ViewModel signals.

import std/[options, parseutils, sets]

import isonim/core/signals

import ./[reducer, session_core, types]
import ../viewmodels/[calltrace_vm, state_vm]

proc parseInt64Option(value: string): Option[int64] =
  if value.len == 0:
    return none(int64)
  var parsed: int64
  let consumed = parseBiggestInt(value, parsed, 0)
  if consumed == value.len:
    some(parsed)
  else:
    none(int64)

proc parseStateTab(value: string): StateTab =
  case value
  of "stGlobals": stGlobals
  of "stWatches": stWatches
  else: stLocals

proc projectCalltraceViewState*(state: SharedSessionViewState;
                                vm: CalltraceVM) =
  if vm.isNil:
    return
  vm.selectedEntry.val = parseInt64Option(state.calltrace.selectedEntry.value)
  vm.searchQuery.val = state.calltrace.searchQuery.value

  var nodes = initHashSet[int64]()
  for id in visibleExpansionIds(state.calltrace.expandedNodes):
    let parsed = parseInt64Option(id)
    if parsed.isSome:
      nodes.incl(parsed.get)
  vm.expandedNodes.val = nodes

proc projectStateViewState*(state: SharedSessionViewState; vm: StateVM) =
  if vm.isNil:
    return
  vm.activeTab.val = parseStateTab(state.statePane.activeTab.value)
  vm.selectedPath.val = state.statePane.selectedPath.value

  var paths = initHashSet[string]()
  for path in visibleExpansionIds(state.statePane.expandedPaths):
    paths.incl(path)
  vm.expandedPaths.val = paths

  var watches: seq[string] = @[]
  for watch in visibleWatches(state.statePane):
    watches.add watch.expression
  vm.watchExpressions.val = watches

proc installCalltraceProjection*(core: CollaborativeSessionCore;
                                 vm: CalltraceVM) =
  if core.isNil or vm.isNil:
    return
  core.addProjectionCallback(proc(state: SharedSessionViewState) =
    projectCalltraceViewState(state, vm))

proc installStateProjection*(core: CollaborativeSessionCore; vm: StateVM) =
  if core.isNil or vm.isNil:
    return
  core.addProjectionCallback(proc(state: SharedSessionViewState) =
    projectStateViewState(state, vm))
