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
  ui_imports, auto_hide, session_viewmodels, ../[types, communication]

import std/json
# `Signal.val` is a template, so reading an `ErrorsVM` signal here needs the
# module in scope even though the type arrives through `errors_vm` — the same
# reason `ui/build.nim` imports it.
import isonim/core/signals
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  BuildProblemLine, BuildLineSeverity, ProblemFilterTag,
  blsNone, blsError, blsWarning, blsInfo, pfAll, pfErrors, pfWarnings
from ../viewmodel/viewmodels/errors_vm import
  ErrorsVM, createErrorsVM, setProblems, appendProblem, clearProblems,
  setFilter, setGroupByFile, toggleGroupByFile, jumpToProblem,
  ErrorNavOutcome, enoEmpty, enoMoved, enoWrapped,
  gotoNextError, gotoPreviousError, highlightFirstError
from ../viewmodel/viewmodels/build_diagnostics import resolvedPath
from isonim/web/dom_api import nil

# The session's ViewModel and the registered component, so the legacy
# event-bus handlers can feed the one and replay the other. The pane's view
# is mounted by the panel host (`ui/panel_host`).
var errorsVMInstance*: ErrorsVM
var errorsComponentRef: ErrorsComponent

proc installErrorsVMCallbacks*(vm: ErrorsVM)
proc syncLegacyErrorsIntoVM*(self: ErrorsComponent)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initErrorsVMFromSession*(vm: ErrorsVM) =
  ## Hand the pane the session's `ErrorsVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ## Problems the shown tab's component already holds are replayed into it
  ## once, when the ViewModel is first handed over.
  errorsVMInstance = vm
  installErrorsVMCallbacks(errorsVMInstance)
  if firstBinding(vm):
    let component = data.shownTabComponent(Content.BuildErrors)
    if not component.isNil:
      syncLegacyErrorsIntoVM(ErrorsComponent(component))

proc revealProblemsPanel*() =
  ## Bring the Problems pane on screen **without focusing it**.
  ##
  ## EMT-D21: revealing is not focusing. ``openLayoutTab`` activates the tab
  ## in the GoldenLayout tree and ``revealOverlay`` un-hides a pinned
  ## auto-hide panel; neither moves keyboard focus, and neither is allowed
  ## to start doing so. The two cases are both handled because the Problems
  ## pane can live in either place depending on the user's layout, and a
  ## reveal that only worked in one would make `next error` conditional on
  ## layout — the thing EMT-D22.4 rules out.
  if data.isNil or data.ui.layout.isNil:
    return
  if data.ui.componentMapping[Content.BuildErrors].len > 0:
    data.openLayoutTab(Content.BuildErrors)
  if not autoHideState.isNil:
    let panel = autoHideState.findPanelByContent(Content.BuildErrors)
    if not panel.isNil:
      # Revealing a panel the auto-hide layer rebuilt mounts it through the
      # panel host (`onPanelShown` -> `mountPaneForState`).
      revealOverlay(panel)

var desktopBuildDirectory*: string
  ## The directory the current build runs in when it is a task with its own
  ## `cwd` (`ui/build.startDesktopBuild`), "" for the project folder.

proc desktopResolvedPath*(path: string): string =
  ## Where a diagnostic's file is on the desktop: an absolute path as written;
  ## a relative one against the folder Edit mode opened
  ## (`data.startOptions.folder`) — the desktop has no action working
  ## directory for an IPC-fed build, and the folder is the one a build of the
  ## project runs in (Edit-Mode-Toolbar.md EMT-A36; the native front-ends
  ## resolve against the build's own directory,
  ## `viewmodels/build_diagnostics.resolvedPath`, the same rule).
  ##
  ## Until PLAT-56 the path went to `openLocation` as the compiler wrote it,
  ## and a relative one opened nothing (codetracer-pm issue
  ## `2026-10-26-desktop-problems-row-ignores-relative-paths`).
  if desktopBuildDirectory.len > 0:
    # A task's own directory (Build-Output-Pane.md §3.6, EMT-A36).
    return resolvedPath(path, desktopBuildDirectory)
  if data.isNil or data.startOptions.folder.isNil or
     data.startOptions.folder.len == 0:
    return path
  resolvedPath(path, $data.startOptions.folder)

proc installErrorsVMCallbacks*(vm: ErrorsVM) =
  ## Wire the Problems pane to the editor.
  ##
  ## Before this existed, ``ErrorsVM.jumpToProblem`` dispatched
  ## ``ct/jump-location``, which `backend/dap_dialect.md` §7 records as one of
  ## nine commands with **no engine implementation** — so clicking a build
  ## error was a silent no-op in production while the mock-backend view tests
  ## stayed green. This is the same treatment ``installSearchVMCallbacks``
  ## (`ui/search_results.nim:158`) already gives the Find in Files pane, and
  ## it reaches the editor through the same live ``data.openLocation``.
  if vm.isNil:
    return
  vm.onJumpToProblem = proc(path: string, line: int, col: int) =
    discard data.openLocation(cstring(desktopResolvedPath(path)), line, col)
  vm.onRevealPanel = proc() =
    revealProblemsPanel()

proc gotoNextBuildError*() =
  ## The ``aGotoNextError`` action.
  if errorsVMInstance.isNil:
    return
  discard errorsVMInstance.gotoNextError()

proc gotoPreviousBuildError*() =
  ## The ``aGotoPreviousError`` action.
  if errorsVMInstance.isNil:
    return
  discard errorsVMInstance.gotoPreviousError()

proc highlightFirstBuildError*() =
  ## Select the first error after a failed build, without moving focus.
  ## Called from ``build.onBuildCode`` and from the wasm producer's failure
  ## path — the two places a build can fail.
  if errorsVMInstance.isNil:
    return
  discard errorsVMInstance.highlightFirstError()

proc highlightFirstBuildErrorIn*(vm: ErrorsVM) =
  ## Select the first error of `vm` — the Problems pane of the tab whose build
  ## failed — without moving focus (EMT-D21).
  if vm.isNil:
    return
  discard vm.highlightFirstError()

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
  if self.isNil or self.data.isNil:
    return
  # THIS TAB'S ViewModel, mirroring this tab's Build component's record.
  let ownVM = ownPaneVM(self, errorsVMInstance, errorsVM)
  if ownVM.isNil:
    return
  let ownTab = data.sessionOfComponent(self)
  let buildComp =
    if ownTab.isNil or ownTab.ui.isNil or
       ownTab.ui.componentMapping[Content.Build].isNil or
       not ownTab.ui.componentMapping[Content.Build].hasKey(0):
      self.data.buildComponent(0)
    else:
      BuildComponent(ownTab.ui.componentMapping[Content.Build][0])
  if buildComp.isNil:
    ownVM.setProblems(@[])
    return

  # AN EMPTY LEGACY RECORD DOES NOT MEAN "NO PROBLEMS".
  #
  # This proc mirrors `buildComponent(0).build.problems`, which only the
  # DESKTOP producer fills (`ui/build.nim`'s `CODETRACER::build-*` handlers).
  # The browser's producer is `viewmodels/noir_build_producer.nim`, which feeds
  # the VMs directly and never touches the legacy record — so on the web arm
  # this list is permanently empty.
  #
  # It is called when the session's ViewModel is installed. Without this guard, revealing the Problems pane
  # after a failed browser build ERASED the diagnostics that build had just
  # produced: measured as a pane that reported "no errors" while the compiler's
  # rows were sitting in the VM a moment earlier.
  if buildComp.build.problems.len == 0 and
     ownVM.problems.val.len > 0:
    ownVM.setFilter(problemFilterToVM(self.filter))
    ownVM.setGroupByFile(self.groupByFile)
    return

  var rows: seq[BuildProblemLine] = @[]
  for prob in buildComp.build.problems:
    rows.add(BuildProblemLine(
      severity: problemSeverityToVM(prob.severity),
      path: safeStr(prob.path),
      line: prob.line,
      col: prob.col,
      message: safeStr(prob.message)))
  # ALREADY THESE ROWS: the build fed them one by one, and replacing them
  # would reset the selection — the failed build's highlight (EMT-D21) was
  # wiped whenever the panel was revealed after the build ended (measured by
  # the PLAT-55 capture, intermittently, by when the reveal landed).
  if ownVM.problems.val != rows:
    ownVM.setProblems(rows)
  ownVM.setFilter(problemFilterToVM(self.filter))
  ownVM.setGroupByFile(self.groupByFile)

proc syncErrorsAppendProblemInto*(vm: ErrorsVM; problem: BuildProblemLine) =
  ## Push a single problem row into `vm` — the ErrorsVM of the tab whose
  ## build produced it (`ui/build.nim`), shown or not.
  if vm.isNil:
    return
  vm.appendProblem(problem)

proc syncErrorsClearInto*(vm: ErrorsVM) =
  ## Reset `vm`'s problem list as its tab's next build starts.
  if vm.isNil:
    return
  vm.clearProblems()

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

# ErrorsComponent.render() removed: the pane's view
# (``viewmodel/views/isonim_errors_view.nim``) is mounted by the panel host.

method register*(self: ErrorsComponent, api: MediatorWithSubscribers) =
  ## Register the ErrorsComponent with the mediator. Its handlers feed the
  ## session's `ErrorsVM` once `initErrorsVMFromSession` has installed it.
  self.api = api
  if errorsComponentRef.isNil:
    errorsComponentRef = self
