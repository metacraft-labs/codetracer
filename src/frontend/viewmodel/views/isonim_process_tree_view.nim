## IsoNim view for the multi-process session sidebar (spec
## `GUI/Debugging-Features/Value-Origin-Tracking.md` §14.8: "A **process
## tree** in the side bar listing each trace's role + thread count").
##
## The model mirrors `SessionViewModel.processTree.entries` — one record
## per `[[trace]]` row in the session's `session.toml`, as reported by
## the backend's `ct/listProcesses` payload
## (`db-backend/src/dap_server.rs::build_ct_list_processes_response`).
## Nothing here derives or invents rows: a role shown in the tree is a
## role the loaded session actually holds.
##
## DOM contract
## ------------
##
##   <aside id="ct-process-tree" class="ct-process-tree" role="tree"
##          aria-label="Session processes">
##     <div class="ct-process-tree-header">Processes</div>
##     <div class="ct-process-tree-entry [active]" role="treeitem"
##          data-process-role="backend"
##          data-recording-id="018f…"
##          aria-selected="true">
##       <span class="ct-process-tree-role">backend</span>
##       <span class="ct-process-tree-name">backend.ct</span>
##       <span class="ct-process-tree-threads">1 thread</span>
##     </div>
##     …
##   </aside>
##
## `data-process-role` is *the* stable selector for a process row (M42
## deliverable: "Settle on ONE attribute name"). It deliberately does
## not reuse the `data-role` attribute the Origin Chain breadcrumb chips
## emit (`ui/isonim_origin_chain.nim`) — those chips carry the same role
## tokens, so sharing an attribute would make "the backend process row"
## and "the backend breadcrumb chip" indistinguishable to any selector.
##
## Clicking a row dispatches `SessionViewModel.onSwitchProcess`, which
## rotates the active recording, its `StateVM`, and the host's DAP
## routing thread id.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The browser instantiation needs the WebRenderer procs in scope.
  import isonim/web/web_renderer

export signals, computation, components

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  ProcessTreeEntryRecord* = object
    ## One row of the tree. A flattened projection of
    ## `session_vm.ProcessTreeEntry` so this module stays free of a
    ## SessionViewModel dependency and remains renderable from a test
    ## with hand-built records.
    recordingId*: string
    role*: string
    displayName*: string
    threadCount*: int
    active*: bool

  ProcessTreeModel* = object
    entries*: seq[ProcessTreeEntryRecord]

  ProcessTreeCallbacks* = object
    onSelectProcess*: proc(recordingId: string)

const
  ProcessTreeHostId* = "ct-process-tree"
  ProcessTreeRootClass* = "ct-process-tree"
  ProcessTreeEntryClass* = "ct-process-tree-entry"
  ProcessTreeEntryActiveClass* = "ct-process-tree-entry active"

# ---------------------------------------------------------------------------
# Pure helpers (renderer-independent, unit-testable)
# ---------------------------------------------------------------------------

proc entryClass*(active: bool): string =
  if active: ProcessTreeEntryActiveClass else: ProcessTreeEntryClass

proc threadCountLabel*(threadCount: int): string =
  ## "1 thread" / "N threads" — §14.8 asks the row to show the trace's
  ## thread count next to its role.
  if threadCount == 1: "1 thread" else: $threadCount & " threads"

proc entryTitle*(entry: ProcessTreeEntryRecord): string =
  ## Hover text: the recording id is the only globally unique handle a
  ## user can correlate with `session.toml`, but it is far too long for
  ## the row itself.
  entry.displayName & " (" & entry.recordingId & ")"

proc shouldRenderTree*(model: ProcessTreeModel): bool =
  ## §14.8 describes the tree as a multi-process affordance. A session
  ## with a single recording has nothing to switch between, so the tree
  ## stays out of the way entirely rather than showing a one-row list
  ## that can never do anything.
  model.entries.len > 1

proc invokeSelect(callbacks: ProcessTreeCallbacks; recordingId: string) =
  if not callbacks.onSelectProcess.isNil:
    callbacks.onSelectProcess(recordingId)

proc selectHandler(callbacks: ProcessTreeCallbacks; recordingId: string): proc() =
  ## The click handler of one process row: select `recordingId`.
  ##
  ## A FACTORY, because the rows are built in a `for` loop and Nim closures
  ## capture by reference: a `let` in the loop body is ONE variable for the
  ## whole loop, so the inline closure this replaces made every row select
  ## the LAST process (codetracer#860 sweep;
  ## https://nim-lang.org/docs/manual.html#procedures-closures).
  result = proc() = callbacks.invokeSelect(recordingId)

# ---------------------------------------------------------------------------
# Shared markup
# ---------------------------------------------------------------------------

proc renderProcessTree*[R, N](
    r: R;
    model: ProcessTreeModel;
    callbacks: ProcessTreeCallbacks = ProcessTreeCallbacks()): N =
  ## The tree, for every renderer (Shared-DOM-Front-Ends D6).
  ui(r):
    tdiv(
        id = ProcessTreeHostId,
        class = ProcessTreeRootClass,
        role = "tree",
        `aria-label` = "Session processes"):
      tdiv(class = "ct-process-tree-header"):
        text "Processes"
      for entryIndex in 0 ..< model.entries.len:
        let entry = model.entries[entryIndex]
        # The handler takes the id as a factory argument: a closure over a
        # loop-body `let` would share one variable across every row.
        let selectedRecordingId = entry.recordingId
        tdiv(
            class = entryClass(entry.active),
            role = "treeitem",
            title = entryTitle(entry),
            `data-process-role` = entry.role,
            `data-recording-id` = entry.recordingId,
            `aria-selected` = (if entry.active: "true" else: "false"),
            onclick = selectHandler(callbacks, selectedRecordingId)):
          span(class = "ct-process-tree-role"):
            text entry.role
          span(class = "ct-process-tree-name"):
            text entry.displayName
          span(class = "ct-process-tree-threads"):
            text threadCountLabel(entry.threadCount)

proc renderProcessTreeInto*[R, N](
    r: R;
    container: N;
    model: ProcessTreeModel;
    callbacks: ProcessTreeCallbacks = ProcessTreeCallbacks()) =
  ## Clear `container` and render the current tree inside it — nothing when
  ## the session has a single process (`shouldRenderTree`).
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild
  r.clearChildren(container)
  if not shouldRenderTree(model):
    return
  r.appendChild(container, renderProcessTree[R, N](r, model, callbacks))
