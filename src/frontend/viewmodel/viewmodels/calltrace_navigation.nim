## viewmodels/calltrace_navigation.nim — moving through the call trace from
## the keyboard, in the ViewModel.
##
## The desktop's call-trace component handled Up / Down / Left / Right /
## Enter / Page Up / Page Down / Home / End itself, over its own copy of the
## lines (Shared-DOM-Front-Ends D1). These are the same moves over the one
## section the store holds, so every front-end that routes those keys to the
## pane gets them: the selection is `CalltraceVM.selectedEntry` (a trace
## index), and a selection that leaves the section held scrolls the viewport
## so the auto-load fetches it.
##
## A module of its own rather than more procs on `CalltraceVM`, because it is
## only a client of that VM's public surface.

import std/options

import isonim/core/[signals, computation]

import ../store/[replay_data_store, types]
import ../viewport
import ./calltrace_vm

proc heldAt(vm: CalltraceVM; index: int64): Option[CallLine] =
  ## The held line with trace index `index`.
  let start = vm.store.calltrace.startLineIndex.val
  let lines = vm.store.calltrace.lines.val
  let at = index - start
  if at >= 0 and at < lines.len.int64:
    some(lines[at.int])
  else:
    none(CallLine)

proc anchor(vm: CalltraceVM): int64 =
  ## The selection, or the first visible row when nothing is selected.
  let sel = vm.selectedEntry.val
  if sel.isSome: sel.get
  else: vm.store.calltrace.startLineIndex.val

proc keepVisible(vm: CalltraceVM; index: int64) =
  ## Scroll so `index` is on screen; the window that shows it is then loaded.
  let v = vm.viewport.val
  if v.rows <= 0:
    return
  let i = index.int
  if i < v.firstRow:
    vm.setViewport(v.scrolledTo(i))
  elif i >= v.firstRow + v.rows:
    vm.setViewport(v.scrolledTo(i - v.rows + 1))

proc selectIndex*(vm: CalltraceVM; index: int64) =
  ## Select the call at trace `index`, clamped to the trace, and keep it in
  ## view.
  let total = vm.store.calltrace.totalCallsCount.val.int64
  if total <= 0:
    return
  let clamped = max(0'i64, min(index, total - 1))
  vm.selectEntry(some(clamped))
  vm.keepVisible(clamped)

proc moveSelection*(vm: CalltraceVM; delta: int) =
  ## Up (`-1`) and Down (`+1`); Page Up / Down move by the pane's rows.
  if vm.selectedEntry.val.isNone:
    vm.selectIndex(vm.anchor)
  else:
    vm.selectIndex(vm.anchor + delta.int64)

proc pageSelection*(vm: CalltraceVM; direction: int) =
  ## Page Up (`-1`) / Page Down (`+1`): one pane's height.
  let rows = max(1, vm.viewport.val.rows - 1)
  vm.moveSelection(direction * rows)

proc selectFirst*(vm: CalltraceVM) = vm.selectIndex(0)
proc selectLast*(vm: CalltraceVM) =
  vm.selectIndex(vm.store.calltrace.totalCallsCount.val.int64 - 1)

proc selectParent*(vm: CalltraceVM) =
  ## Left: the call that called the selected one — the nearest held line
  ## before it with a smaller depth.
  let here = vm.heldAt(vm.anchor)
  if here.isNone:
    return
  var i = here.get.index - 1
  let start = vm.store.calltrace.startLineIndex.val
  while i >= start:
    let line = vm.heldAt(i)
    if line.isSome and line.get.depth < here.get.depth:
      vm.selectIndex(i)
      return
    dec i

proc selectFirstChild*(vm: CalltraceVM) =
  ## Right: into the selected call. A collapsed call with children is
  ## expanded first (its children then arrive with the section); an expanded
  ## one selects its first child.
  let here = vm.heldAt(vm.anchor)
  if here.isNone or not here.get.hasChildren:
    return
  if not here.get.isExpanded:
    vm.toggleExpandCallChildren(here.get.index)
    return
  let next = vm.heldAt(here.get.index + 1)
  if next.isSome and next.get.depth > here.get.depth:
    vm.selectIndex(next.get.index)

proc activateSelected*(vm: CalltraceVM) =
  ## Enter: go to the selected call, as a click on its row does.
  let sel = vm.selectedEntry.val
  if sel.isSome:
    vm.doubleClickEntry(sel.get)
