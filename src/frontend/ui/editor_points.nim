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
from ../viewmodel/viewmodels/editor_vm import EditorVM
from ../viewmodel/viewmodels/state_vm import StateVM
from ../viewmodel/viewmodels/flow_vm import FlowVM
from ../viewmodel/viewmodels/flow_layout import FlowLayoutWindow
from ../viewmodel/viewmodels/scratchpad_vm import ScratchpadVM, addValue
from ../../common/value_presentation/surfaces import FlowBudget

export breakpoints, editor_surface

var pointStore: ReplayDataStore
  ## The session store the editor shows; nil before the renderer has one.
var sessionEditor: EditorVM
var sessionState: StateVM
var sessionFlow: FlowVM
var sessionScratchpad: ScratchpadVM
  ## The session's ViewModels the editor's surface reads
  ## (`webEditorSurface`); nil until the renderer has a session.

const WebEditorMedium* = "web"
  ## The medium the web editor's surface is built for.

proc sessionFlowWindows*(): seq[FlowLayoutWindow] =
  ## The session's current flow window, one per editor view
  ## (`FlowVM.layoutWindows`), loaded per stop by the session's stop loader
  ## (`spFlow`); empty before a session is attached. Read inside an effect,
  ## it subscribes to the window.
  if sessionFlow.isNil: @[] else: sessionFlow.layoutWindows.val

proc setEditorSessionVMs*(editor: EditorVM; state: StateVM; flow: FlowVM;
                          scratchpad: ScratchpadVM = nil) =
  sessionEditor = editor
  sessionState = state
  sessionFlow = flow
  sessionScratchpad = scratchpad

proc valueInScope*(name: string): Option[string] =
  ## The value of `name` in scope at the stop, presented on one line — what
  ## the editor shows for a clicked name (Editor-Pane.md gesture 5): the
  ## session's `StateVM`, which every front-end's values come from.
  if name.len == 0:
    return none(string)
  for v in inlineValuesOf(sessionState, FlowBudget):
    if v.name == name:
      return some(v.value)
  none(string)

proc addToScratchpad*(name, valueText: string): bool =
  ## Pin `name = valueText` to the session's scratchpad; false when there is
  ## no session scratchpad.
  if sessionScratchpad.isNil:
    return false
  sessionScratchpad.addValue(ScratchpadValueEntry(expression: name,
                                                  valueText: valueText))
  true

proc editorStop*(): StopLocation =
  ## The debugger's stop as an editor shows it (`ReplayDataStore.stop`).
  if pointStore.isNil: StopLocation(frameOffset: -1)
  else: pointStore.stop.val

proc webEditorSurface*(path: string; firstLine, lastLine: int;
                       lineText: proc(line: int): string): EditorSurface =
  ## The web editor's surface over `firstLine .. lastLine` of `path`, whose
  ## text Monaco holds — `editor_surface.editorSurfaceForView`, the rules the
  ## terminal and GPUI draw with.
  editorSurfaceForView(path, firstLine, lastLine, lineText, pointStore,
                       sessionEditor, sessionState, sessionFlow, FlowBudget,
                       WebEditorMedium)

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
