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

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

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

# ---------------------------------------------------------------------------
# Shared markup
# ---------------------------------------------------------------------------

template renderProcessTreeImpl(
    r: untyped;
    model: ProcessTreeModel;
    callbacks: ProcessTreeCallbacks): untyped =
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
        # Capture the id by value: the closure outlives this loop turn.
        let selectedRecordingId = entry.recordingId
        tdiv(
            class = entryClass(entry.active),
            role = "treeitem",
            title = entryTitle(entry),
            `data-process-role` = entry.role,
            `data-recording-id` = entry.recordingId,
            `aria-selected` = (if entry.active: "true" else: "false"),
            onclick = proc() =
              callbacks.invokeSelect(selectedRecordingId)):
          span(class = "ct-process-tree-role"):
            text entry.role
          span(class = "ct-process-tree-name"):
            text entry.displayName
          span(class = "ct-process-tree-threads"):
            text threadCountLabel(entry.threadCount)

# ---------------------------------------------------------------------------
# MockRenderer
# ---------------------------------------------------------------------------

proc renderProcessTree*(
    r: MockRenderer;
    model: ProcessTreeModel;
    callbacks: ProcessTreeCallbacks = ProcessTreeCallbacks()): MockNode =
  renderProcessTreeImpl(r, model, callbacks)

# ---------------------------------------------------------------------------
# WebRenderer (browser only)
# ---------------------------------------------------------------------------

when defined(js):
  proc renderProcessTree*(
      r: WebRenderer;
      model: ProcessTreeModel;
      callbacks: ProcessTreeCallbacks = ProcessTreeCallbacks()):
        isonim_dom.Element =
    renderProcessTreeImpl(r, model, callbacks)

  proc renderProcessTreeInto*(
      container: isonim_dom.Element;
      model: ProcessTreeModel;
      callbacks: ProcessTreeCallbacks = ProcessTreeCallbacks()) =
    ## Clear `container` and render the current tree inside it.
    ##
    ## A fresh `WebRenderer` per pass keeps IsoNim's reactive effects
    ## scoped to that pass rather than accumulating across re-renders —
    ## the same discipline `mountToggleInto` follows.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)
    if not shouldRenderTree(model):
      return
    let r = WebRenderer()
    let el = renderProcessTree(r, model, callbacks)
    discard isonim_dom.appendChild(containerNode, isonim_dom.Node(el))
