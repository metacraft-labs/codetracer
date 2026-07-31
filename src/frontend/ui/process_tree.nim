## ui/process_tree.nim
##
## Host wiring for the multi-process session sidebar (spec
## `GUI/Debugging-Features/Value-Origin-Tracking.md` §14.8).
##
## Two halves meet here, and neither is useful alone:
##
## 1. **Feeding the model.** The backend dispatches a `ct/listProcesses`
##    DAP *event* once per session load
##    (`db-backend/src/dap_server.rs::dispatch_session_load_event`)
##    carrying one row per `[[trace]]` in the session's `session.toml`.
##    `consumeListProcessesEvent` decodes it into
##    `SessionViewModel.processTree`. Before M42 that event reached the
##    renderer and was dropped on the floor because no `CtEventKind`
##    mapped to it, so `processTree.entries` was empty in every real
##    session no matter how many recordings the backend had loaded.
##
## 2. **Drawing it.** `mountProcessTree` installs one reactive effect
##    over `processTree.entries` + `activeProcessRecordingId` and
##    re-renders `viewmodel/views/isonim_process_tree_view` into a host
##    element tiled into `#auto-hide-layout-row`.
##
## Clicking a row calls `SessionViewModel.onSwitchProcess`, whose host
## bridge (installed by `ui_js.nim`) re-points the DAP routing thread id
## and runs the newly selected recording to its entry point so the
## editor and State Pane follow.

import std/json

import isonim/core/[signals, computation]

import ../viewmodel/session_vm
import ../viewmodel/views/isonim_process_tree_view

const ProcessTreeHostElementId* = "ct-process-tree-host"
  ## Stable wrapper the reactive effect renders into. Distinct from the
  ## view's own root id (`ct-process-tree`) so the wrapper can stay in
  ## the layout flow across re-renders while the tree itself is torn
  ## down and rebuilt.

proc processTreeModel*(session: SessionViewModel): ProcessTreeModel =
  ## Project the SessionViewModel's process tree into the view's flat
  ## record shape. Reads both reactive sources, so calling this inside
  ## an effect subscribes to entry-list changes *and* active-recording
  ## changes.
  if session.isNil or session.processTree.isNil:
    return ProcessTreeModel()
  let activeId = session.activeProcessRecordingId.val
  var records = newSeq[ProcessTreeEntryRecord]()
  for entry in session.processTree.entries.val:
    records.add(ProcessTreeEntryRecord(
      recordingId: entry.recordingId,
      role: entry.role,
      displayName: entry.displayName,
      threadCount: int(entry.threadCount),
      active: entry.recordingId == activeId,
    ))
  ProcessTreeModel(entries: records)

proc processTreeCallbacks*(session: SessionViewModel): ProcessTreeCallbacks =
  ## Click handler: rotate the active recording through the
  ## SessionViewModel so the `stateVM` alias, the derived signals and
  ## the host bridge all move together.
  ProcessTreeCallbacks(
    onSelectProcess: proc(recordingId: string) =
      if not session.isNil:
        session.onSwitchProcess(recordingId)
  )

proc consumeListProcessesEvent*(session: SessionViewModel; body: JsonNode) =
  ## Production consumer of the `ct/listProcesses` payload — the piece
  ## M42 exists to add. Accepts both the session-load event body and a
  ## request response body; the backend builds them from the same
  ## `build_ct_list_processes_response`, so one decoder serves both.
  if session.isNil:
    return
  session.applyListProcessesResponse(body)

when defined(js):
  import isonim/web/dom_api as isonim_dom

  proc bodyOf(d: isonim_dom.Document): isonim_dom.Node {.importjs: "#.body".}
    ## `isonim/web/dom_api` exposes no `document.body` accessor.

  var processTreeHost: isonim_dom.Element
  var processTreeEffectInstalled = false

  proc ensureProcessTreeHost(): isonim_dom.Element =
    ## Return the singleton host, creating it on first use.
    ##
    ## Preferred placement is as the first flex item of
    ## `#auto-hide-layout-row`, so the tree tiles beside the
    ## GoldenLayout container exactly the way the auto-hide side strips
    ## do rather than floating over the content. When that row is absent
    ## (shells other than the Electron app) we fall back to the document
    ## body so the surface still mounts instead of silently vanishing.
    if not isonim_dom.isNodeNil(isonim_dom.Node(processTreeHost)):
      return processTreeHost
    let existing = isonim_dom.getElementById(
      isonim_dom.document, cstring(ProcessTreeHostElementId))
    if not isonim_dom.isNodeNil(isonim_dom.Node(existing)):
      processTreeHost = existing
      return processTreeHost
    let host = isonim_dom.createElement(isonim_dom.document, cstring"div")
    isonim_dom.setAttribute(
      host, cstring"id", cstring(ProcessTreeHostElementId))
    let row = isonim_dom.getElementById(
      isonim_dom.document, cstring"auto-hide-layout-row")
    if not isonim_dom.isNodeNil(isonim_dom.Node(row)):
      isonim_dom.insertBefore(
        isonim_dom.Node(row), isonim_dom.Node(host), row.firstChild)
    else:
      let body = bodyOf(isonim_dom.document)
      if isonim_dom.isNodeNil(body):
        return nil
      isonim_dom.appendChild(body, isonim_dom.Node(host))
    processTreeHost = host
    host

  proc mountProcessTree*(session: SessionViewModel) =
    ## Install the reactive render effect. Idempotent — repeated calls
    ## (the State Pane bootstrap re-runs on a stub → shared-store
    ## upgrade) do not stack effects.
    if session.isNil or session.processTree.isNil:
      return
    if processTreeEffectInstalled:
      return
    processTreeEffectInstalled = true
    let callbacks = session.processTreeCallbacks()
    createEffect proc() =
      let model = session.processTreeModel()
      let host = ensureProcessTreeHost()
      if isonim_dom.isNodeNil(isonim_dom.Node(host)):
        return
      renderProcessTreeInto(host, model, callbacks)

else:
  proc mountProcessTree*(session: SessionViewModel) =
    ## Native builds have no DOM; the model-side wiring above is still
    ## exercised by the ViewModel tests.
    discard
