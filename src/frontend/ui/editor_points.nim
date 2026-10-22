## ui/editor_points.nim — the web editor's points, read from the session store.
##
## The gutter (`ui/trace.editorLineNumber`) and the editor (`ui/editor`) both
## draw breakpoints, and both read them here: the session store's point rows
## (`sdk/breakpoints` is their one producer), turned into the per-line mark
## every editor surface uses (`editor_surface.editorPointsOf` and
## `editor_rows.markFor`). The terminal and GPUI draw the same marks from the
## same rows, so a line marked on one front-end is marked on all of them
## (Shared-DOM-Front-Ends D7.4 (a)).
##
## A module of its own because the gutter's module (`trace`) is imported by
## the editor's, so the store the editor is handed cannot be reached from the
## gutter except through a third module both import.

import std/options

import isonim/core/signals

import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/sdk/breakpoints
import ../view_vocabulary/editor_surface

export breakpoints, editor_surface

var pointStore: ReplayDataStore
  ## The session store the editor shows; nil before the renderer has one.

proc setEditorPointStore*(store: ReplayDataStore) =
  pointStore = store

proc editorPointStore*(): ReplayDataStore =
  pointStore

proc gutterMarkFor*(path: string; line: int): EditorMark =
  ## The mark on `path:line` — the one the terminal and GPUI draw for it.
  if pointStore.isNil:
    return emNone
  markFor(editorPointsOf(pointStore.pointList.rows.val), path, line)

proc anchoredBreakpointsIn*(path: string): seq[BreakpointSpec] =
  ## `path`'s armed breakpoints anchored at a column (Column-Aware Navigation
  ## M6), which the editor marks at the column as well as in the gutter.
  if pointStore.isNil:
    return
  for sp in heldBreakpoints(pointStore, path):
    if sp.enabled and sp.column > 0:
      result.add sp

proc breakpointOn*(path: string; line: int): Option[BreakpointSpec] =
  ## The breakpoint on `path:line`, armed or not.
  if pointStore.isNil: none(BreakpointSpec)
  else: breakpointAt(pointStore, path, line)

proc breakpointsInFile*(path: string): seq[BreakpointSpec] =
  if not pointStore.isNil:
    result = heldBreakpoints(pointStore, path)

proc anyBreakpoints*(): bool =
  not pointStore.isNil and breakpointFiles(pointStore).len > 0
