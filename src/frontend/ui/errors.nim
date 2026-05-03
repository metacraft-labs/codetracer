## BP-M4: Problems panel -- a structured, filterable list of build errors
## and warnings, similar to the Problems panel in VS Code.
##
## ---------------------------------------------------------------------------
## ViewModel layer -- IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_errors_view.nim``) that mounts directly
## into the GoldenLayout container.  The legacy ``ErrorsComponent``
## retains its identity so existing wiring (auto-hide, status bar
## summaries, layout component lookups) keeps working; the panel data is
## sourced from the build pipeline (via ``buildComponent(0).build.problems``)
## and mirrored into an ``ErrorsVM`` whose signals drive the IsoNim
## view.
## ---------------------------------------------------------------------------

import
  ui_imports, ../[types, communication]

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  BuildProblemLine, BuildLineSeverity, ProblemFilterTag,
  blsNone, blsError, blsWarning, blsInfo, pfAll, pfErrors, pfWarnings
from ../viewmodel/viewmodels/errors_vm import
  ErrorsVM, createErrorsVM, setProblems, appendProblem, clearProblems,
  setFilter, setGroupByFile, toggleGroupByFile, jumpToProblem
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_errors_view import mountIsoNimErrors

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by the build, terminal-output and event-log
# migrations.
var errorsVMInstance*: ErrorsVM
var errorsVMStore: ReplayDataStore
var errorsComponentRef: ErrorsComponent
var isoNimErrorsMounted*: bool = false

proc tryMountIsoNimErrorsPanel*()

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initErrorsVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel ``ErrorsVM`` using an externally-provided
  ## ``ReplayDataStore`` (typically the shared store from
  ## ``SessionViewModel``).  If a stub-backed instance already exists
  ## (created by ``initErrorsVM`` before the real backend was available)
  ## it is replaced so the panel uses the real backend.
  if errorsVMInstance != nil:
    clog "ErrorsVM: replacing existing instance with shared-store version"
    isoNimErrorsMounted = false
  errorsVMStore = store
  errorsVMInstance = createErrorsVM(store)
  clog "ErrorsVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimErrorsPanel()

proc initErrorsVM*() =
  ## Lazily create the parallel ``ErrorsVM`` backed by a stub
  ## ``BackendService``.  Fallback when no shared store has been
  ## provided via ``initErrorsVMWithStore``.
  if errorsVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  errorsVMStore = createReplayDataStore(stubBackend)
  errorsVMInstance = createErrorsVM(errorsVMStore)
  clog "ErrorsVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimErrorsPanel()

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  E2E tests
  ## inject objects directly into the legacy ``build`` record without
  ## populating every field, so cstring fields can land as ``null`` /
  ## ``undefined`` in JS -- naive ``$`` would throw inside
  ## ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc problemSeverityToVM(sev: ProblemSeverity): BuildLineSeverity =
  ## Convert a legacy ``ProblemSeverity`` value into the
  ## platform-neutral ``BuildLineSeverity`` consumed by the IsoNim
  ## view.  Mirrors the conversion ``build.nim`` does for
  ## ``BuildSeverity`` -> ``BuildLineSeverity``.
  case sev
  of ProbError:   blsError
  of ProbWarning: blsWarning
  of ProbInfo:    blsInfo

proc problemFilterToVM(filter: ProblemFilter): ProblemFilterTag =
  ## Convert the legacy ``ProblemFilter`` enum (kept for backward
  ## compatibility on ``ErrorsComponent``) into the VM's
  ## ``ProblemFilterTag``.
  case filter
  of FilterAll:      pfAll
  of FilterErrors:   pfErrors
  of FilterWarnings: pfWarnings

proc syncLegacyErrorsIntoVM*(self: ErrorsComponent) =
  ## Mirror the legacy ``self.data.buildComponent(0).build.problems``
  ## list into the IsoNim ``ErrorsVM``.  Used by the layout when the
  ## panel container becomes visible (or is rebuilt) so the panel
  ## reflects every problem already accumulated by the build pipeline.
  ## Per-row updates go through ``appendProblem`` directly (called from
  ## ``build.nim``); this proc covers the bulk-replace scenario.
  if errorsVMInstance.isNil or self.isNil or self.data.isNil:
    return
  let buildComp = self.data.buildComponent(0)
  if buildComp.isNil:
    errorsVMInstance.setProblems(@[])
    return

  var rows: seq[BuildProblemLine] = @[]
  for prob in buildComp.build.problems:
    rows.add(BuildProblemLine(
      severity: problemSeverityToVM(prob.severity),
      path: safeStr(prob.path),
      line: prob.line,
      col: prob.col,
      message: safeStr(prob.message)))
  errorsVMInstance.setProblems(rows)
  errorsVMInstance.setFilter(problemFilterToVM(self.filter))
  errorsVMInstance.setGroupByFile(self.groupByFile)

proc tryMountIsoNimErrorsPanel*() =
  ## Mount the IsoNim errors view into the GoldenLayout-managed (or
  ## standalone auto-hide) container.  The container's id is
  ## ``errorsComponent-{id}``; the errors panel is a singleton (id
  ## always 0) but we still resolve through the registered component's
  ## id field for symmetry with the other IsoNim mounts.
  ##
  ## Safe to call multiple times -- mounts only once.  Retries until the
  ## DOM container appears (capped at 200 attempts, ~2 s) since
  ## GoldenLayout creates the host slightly after the layout state
  ## changes.
  if isoNimErrorsMounted or errorsVMInstance.isNil:
    return
  if errorsComponentRef.isNil:
    return

  let key = cstring("errorsComponent-" & $errorsComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimErrorsMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimErrorsPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    # Replace any prior content (the layout bridge may have planted a
    # stub element before the IsoNim mount fires).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimErrorsMounted = true
    try:
      mountIsoNimErrors(container, errorsVMInstance)
    except:
      cerror "tryMountIsoNimErrorsPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

    # Re-sync any data the legacy ``build`` record already carries so
    # the freshly-mounted view reflects the latest problems list.
    if not errorsComponentRef.isNil:
      syncLegacyErrorsIntoVM(errorsComponentRef)

  doMount()

proc syncErrorsAppendProblem*(problem: BuildProblemLine) =
  ## Push a single problem row into the ``ErrorsVM``.  Called from
  ## ``ui/build.nim::appendBuild`` so structured diagnostics flow
  ## through both view-models without coupling them at the type level.
  ## A no-op when the VM has not been bootstrapped yet (e.g. during
  ## early register-time wiring before ``configureMiddleware`` runs).
  if errorsVMInstance.isNil:
    return
  errorsVMInstance.appendProblem(problem)

proc syncErrorsClear*() =
  ## Reset the ErrorsVM problem list.  Mirrors the legacy
  ## ``BuildVM.clearOutput`` path -- when a new build starts the
  ## previous problem rows should not bleed into the next.
  if errorsVMInstance.isNil:
    return
  errorsVMInstance.clearProblems()

# ErrorsComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths; all real
# DOM construction happens in ``viewmodel/views/isonim_errors_view.nim``.

method register*(self: ErrorsComponent, api: MediatorWithSubscribers) =
  ## Register the ErrorsComponent with the mediator.  Bring up the
  ## IsoNim ErrorsVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initErrorsVM()
  if errorsComponentRef.isNil:
    errorsComponentRef = self
    tryMountIsoNimErrorsPanel()
