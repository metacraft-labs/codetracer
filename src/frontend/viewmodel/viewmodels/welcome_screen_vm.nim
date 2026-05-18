## viewmodels/welcome_screen_vm.nim
##
## WelcomeScreenVM — ViewModel for the Welcome Screen.
##
## The Welcome Screen is the first surface the IDE shows when launched
## without a trace argument.  The legacy ``WelcomeScreenComponent``
## (see ``frontend/ui/welcome_screen.nim``) implemented it via a Karax
## ``method render`` that:
##
## - Held the recent-traces and recent-folders lists on the component
##   instance (``self.data.recentTraces`` / ``self.data.recentFolders``).
## - Held the start-options buttons as a stateful ``seq`` with a
##   per-option ``hovered`` flag mutated by ``onmouseover`` /
##   ``onmouseleave`` handlers.
## - Switched between three mutually-exclusive surfaces via three
##   ``bool`` flags (``welcomeScreen`` / ``newRecordScreen`` /
##   ``openOnlineTrace``).
## - Stored the new-record form state on the component instance under
##   ``newRecord`` (executable / args / workDir / outputFolder /
##   defaultOutputFolder + a ``RecordScreenFormValidator``).
##
## This ViewModel mirrors the same concepts in a platform-neutral,
## reactive shape so headless tests can drive the same flows the
## ``welcome-screen/*.spec.ts`` files assert.  Three GUI specs live in
## the welcome-screen directory (per
## ``.agents/gui-vm-test-pairing-audit.txt`` Cluster B):
##
##   - ``welcome_screen.spec.ts``   (7 tests)  — recent-traces /
##     recent-folders / start-options / hover tooltip.
##   - ``edit_mode.spec.ts``        (4 tests)  — edit-mode swap, no
##     welcome surface, file-system panel becomes available.
##   - ``launch_config.spec.ts``   (10 tests)  — Debug submenu /
##     Launch Configurations entries / clickable items / Python:
##     Fibonacci + Ruby: Fibonacci entries.
##
## Reactive surface (per the audit's §3.2 signal listing):
## - ``recentTraces``    — list of recently captured traces (oldest
##                         first; the legacy view renders newest at
##                         the top after sorting upstream).
## - ``recentFolders``   — list of recently opened project folders.
## - ``startOptions``    — start-options buttons in render order.
## - ``hoveredTrace``    — ``Option[int]`` of the currently-hovered
##                         trace ``id`` (the legacy view used a
##                         per-trace tooltip; mirroring it as one
##                         signal lets a single render-effect drive
##                         the ``recent-trace-tooltip`` visibility).
## - ``hoveredOption``   — ``Option[string]`` of the currently-hovered
##                         option ``key``.  Mirrors the legacy
##                         ``WelcomeScreenOption.hovered`` field but
##                         derived from one signal so option records
##                         stay immutable.
## - ``editMode``        — ``true`` when the IDE is in edit mode (no
##                         welcome surface; main UI shown).  Mirrors
##                         the GUI spec's ``launchMode = "edit"``
##                         path.
## - ``mode``            — currently active welcome surface
##                         (``wsmWelcome`` / ``wsmNewRecord`` /
##                         ``wsmOnlineTrace`` / ``wsmEdit``).
## - ``loading``         — overlay flag while a trace is loading after
##                         a recent-trace click (mirrors
##                         ``self.loading`` on the legacy component).
## - ``loadingTraceId``  — id of the trace currently being loaded
##                         (matches the legacy ``loadingTrace``
##                         pointer; ``-1`` means "no trace being
##                         loaded").
## - ``launchConfig``    — reactive ``LaunchConfigState`` carrying the
##                         configs list, the currently selected slug,
##                         and the ``editFolderPath`` fixture
##                         parameter.
## - ``newRecord``       — reactive ``NewRecordFormState`` (executable
##                         / args / workDir / outputFolder /
##                         defaultOutputFolder).
##
## Derived:
## - ``hasRecentTraces``  — convenience memo for the empty-state
##                          fallback in ``recentProjectsView``.
## - ``hasRecentFolders`` — convenience memo for the empty-state
##                          fallback in ``recentFoldersView``.
## - ``activeStartOptions`` — start-options filtered to the
##                            non-inactive entries (the legacy view
##                            still renders inactive ones with a
##                            modifier; this memo lets headless
##                            tests assert on the click-effective
##                            list separately).
## - ``selectedLaunchConfig`` — convenience memo of the launch-config
##                              entry whose slug matches
##                              ``launchConfig.selectedSlug``.
##
## The VM never imports the legacy ``frontend/types`` ref-object
## bestiary so the same code compiles on native and JS without
## touching ``cstring`` / ``langstring``.  The legacy bridge
## (``ui/welcome_screen.nim``, future iteration) is responsible for
## translating ``Trace`` / ``RecentFolder`` / ``WelcomeScreenOption``
## ref-objects into the value-record shapes below.

import std/[json, options, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const
  NO_HOVERED_TRACE* = ""
    ## Sentinel for ``hoveredTrace`` — mirrors the legacy "no trace
    ## hovered" state where the Karax view rendered no
    ## ``recent-trace-tooltip`` with the ``visible`` modifier.
    ## M-REC-2: switched from ``-1`` (int) to ``""`` (UUIDv7 string)
    ## per the recording-id type flip.
  NO_LOADING_TRACE* = ""
    ## Sentinel for ``loadingTraceId``.  M-REC-2: see NO_HOVERED_TRACE.

type
  NewRecordFormState* = object
    ## Reactive state for the new-record form surface.
    ##
    ## Mirrors the legacy ``NewTraceRecord`` ref-object minus the
    ## ``RecordScreenFormValidator`` ref (validation is recomputed
    ## as a derived memo, not held on the form state).  All fields
    ## are plain ``string`` / ``seq[string]`` to stay platform-neutral.
    executable*: string
    args*: seq[string]
    workDir*: string
    outputFolder*: string
    defaultOutputFolder*: bool

  WelcomeScreenVM* = ref object of ViewModel
    ## Reactive state for the Welcome Screen surface.
    store*: ReplayDataStore

    # -- Mutable state --
    recentTraces*: Signal[seq[RecentTraceRecord]]
    recentFolders*: Signal[seq[RecentFolderRecord]]
    startOptions*: Signal[seq[WelcomeStartOptionRecord]]
    # M-REC-2: trace ids are UUIDv7 strings now.
    hoveredTrace*: Signal[string]
    hoveredOption*: Signal[string]
    editMode*: Signal[bool]
    mode*: Signal[WelcomeScreenMode]
    loading*: Signal[bool]
    loadingTraceId*: Signal[string]
    onlineTraceInput*: Signal[string]
    launchConfig*: Signal[LaunchConfigState]
    newRecord*: Signal[NewRecordFormState]

    # -- Derived state --
    hasRecentTraces*: Memo[bool]
    hasRecentFolders*: Memo[bool]
    activeStartOptions*: Memo[seq[WelcomeStartOptionRecord]]
    selectedLaunchConfig*: Memo[Option[LaunchConfigEntry]]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc emptyNewRecord*(): NewRecordFormState =
  ## Fresh ``NewRecordFormState`` with the defaults the Karax
  ## ``loadInitialOptions`` proc seeds when the user clicks
  ## ``"Record new trace"``.  ``defaultOutputFolder`` starts ``true``
  ## so the output-folder input is rendered as a placeholder until
  ## the user explicitly disables it.
  NewRecordFormState(
    executable: "",
    args: @[],
    workDir: "",
    outputFolder: "",
    defaultOutputFolder: true,
  )

proc emptyLaunchConfig*(): LaunchConfigState =
  ## Fresh ``LaunchConfigState`` with no configs and no selection.
  LaunchConfigState(
    configs: @[],
    selectedSlug: "",
    editFolderPath: "",
  )

proc optionKey*(name: string): string =
  ## Mirror of the Karax view's option-class derivation:
  ## ``toLowerAscii($(option.name)).split().join("-")``.  Headless
  ## tests can use this to look up by stable key without hard-coding
  ## the Nim ``cstring`` / ``string`` divide.
  result = name.toLowerAscii
  result = result.replace(' ', '-')

# ---------------------------------------------------------------------------
# Actions — recent traces / recent folders
# ---------------------------------------------------------------------------

proc setRecentTraces*(vm: WelcomeScreenVM; traces: seq[RecentTraceRecord]) =
  ## Bulk-replace the recent-traces list.  Used by the legacy bridge
  ## to mirror ``self.data.recentTraces`` into the VM whenever the
  ## main process emits the latest list.  Resets ``hoveredTrace`` so
  ## a stale tooltip from the previous list cannot bleed through.
  vm.recentTraces.val = traces
  vm.hoveredTrace.val = NO_HOVERED_TRACE

proc addRecentTrace*(vm: WelcomeScreenVM; trace: RecentTraceRecord) =
  ## Append a single trace to the recent-traces list.  Used when the
  ## main process emits ``CODETRACER::recent-trace-added`` after a
  ## fresh recording.
  var entries = vm.recentTraces.val
  entries.add(trace)
  vm.recentTraces.val = entries

proc setRecentFolders*(vm: WelcomeScreenVM; folders: seq[RecentFolderRecord]) =
  ## Bulk-replace the recent-folders list.
  vm.recentFolders.val = folders

proc setStartOptions*(vm: WelcomeScreenVM;
                     options: seq[WelcomeStartOptionRecord]) =
  ## Bulk-replace the start-options list.  Resets ``hoveredOption``
  ## so a stale ``hovered`` modifier from a previously-rendered
  ## option does not survive into the new list.
  vm.startOptions.val = options
  vm.hoveredOption.val = ""

# ---------------------------------------------------------------------------
# Actions — hover state
# ---------------------------------------------------------------------------

proc hoverTrace*(vm: WelcomeScreenVM; traceId: string) =
  ## Set the currently-hovered trace.  ``NO_HOVERED_TRACE`` clears
  ## the hover.
  vm.hoveredTrace.val = traceId

proc clearHoveredTrace*(vm: WelcomeScreenVM) =
  ## Clear the trace-hover state — mirrors a Karax ``onmouseleave``
  ## firing on the trace row.
  vm.hoveredTrace.val = NO_HOVERED_TRACE

proc hoverOption*(vm: WelcomeScreenVM; key: string) =
  ## Set the currently-hovered start-option.  Empty string clears
  ## the hover.
  vm.hoveredOption.val = key

proc clearHoveredOption*(vm: WelcomeScreenVM) =
  ## Clear the start-option hover state.
  vm.hoveredOption.val = ""

# ---------------------------------------------------------------------------
# Actions — mode / edit-mode toggling
# ---------------------------------------------------------------------------

proc setMode*(vm: WelcomeScreenVM; mode: WelcomeScreenMode) =
  ## Switch the welcome-screen surface.  ``wsmEdit`` also flips
  ## ``editMode`` to ``true`` so the legacy bridge can mirror both
  ## flags from one action.  Conversely, switching to any other
  ## mode flips ``editMode`` back to ``false`` to keep the two
  ## signals consistent.
  vm.mode.val = mode
  vm.editMode.val = mode == wsmEdit

proc enterEditMode*(vm: WelcomeScreenVM; folderPath: string = "") =
  ## Convenience wrapper: switch to edit mode and persist the
  ## ``folderPath`` on the launch-config so the GUI spec's
  ## ``editFolderPath`` fixture parameter has a single observable
  ## location in the VM.
  vm.setMode(wsmEdit)
  var lc = vm.launchConfig.val
  lc.editFolderPath = folderPath
  vm.launchConfig.val = lc

proc exitEditMode*(vm: WelcomeScreenVM) =
  ## Leave edit mode and return to the welcome surface.  The
  ## launch-config ``editFolderPath`` is cleared so subsequent
  ## edit-mode entries cannot inherit a stale path.
  vm.setMode(wsmWelcome)
  var lc = vm.launchConfig.val
  lc.editFolderPath = ""
  vm.launchConfig.val = lc

proc showWelcome*(vm: WelcomeScreenVM) =
  ## Swap to the welcome surface (used by the new-record / online-
  ## trace surfaces' "Back" buttons).
  vm.setMode(wsmWelcome)
  vm.onlineTraceInput.val = ""

proc showNewRecord*(vm: WelcomeScreenVM) =
  ## Swap to the new-record-form surface and reset the form to its
  ## empty defaults — mirrors the legacy ``Record new trace`` button.
  vm.setMode(wsmNewRecord)
  vm.newRecord.val = emptyNewRecord()

proc showOnlineTrace*(vm: WelcomeScreenVM) =
  ## Swap to the online-trace download surface — mirrors the legacy
  ## ``Open online trace`` button.
  vm.setMode(wsmOnlineTrace)
  vm.onlineTraceInput.val = ""

proc setOnlineTraceInput*(vm: WelcomeScreenVM; value: string) =
  ## Update the current online-trace download input value.  The
  ## legacy Karax view stored this on ``newDownload.args``; the VM
  ## keeps the typed text as one plain string so the IsoNim view can
  ## bind the input field directly without depending on the legacy ref.
  vm.onlineTraceInput.val = value

# ---------------------------------------------------------------------------
# Actions — loading overlay
# ---------------------------------------------------------------------------

proc beginLoadingTrace*(vm: WelcomeScreenVM; traceId: string) =
  ## Flip the loading overlay on and remember which trace is being
  ## loaded.  Mirrors the Karax ``handleClick`` proc that flips
  ## ``self.loading = true`` and ``self.loadingTrace = trace``.
  vm.loading.val = true
  vm.loadingTraceId.val = traceId

proc endLoading*(vm: WelcomeScreenVM) =
  ## Tear the loading overlay down — mirrors ``resetView`` on the
  ## legacy component.  Used after the trace has finished loading
  ## (or after the load failed) so the welcome surface becomes
  ## interactive again.
  vm.loading.val = false
  vm.loadingTraceId.val = NO_LOADING_TRACE

proc syncLoadingState*(vm: WelcomeScreenVM; loading: bool; traceId: string) =
  ## Bridge helper for the legacy renderer path: mirror the current
  ## loading overlay state without implying a new user action.  This
  ## lets the startup wiring replay ``self.loading`` /
  ## ``self.loadingTrace`` into the VM after IPC handlers mutate the
  ## legacy component directly.
  vm.loading.val = loading
  vm.loadingTraceId.val = if loading: traceId else: NO_LOADING_TRACE

# ---------------------------------------------------------------------------
# Actions — launch config
# ---------------------------------------------------------------------------

proc setLaunchConfigs*(vm: WelcomeScreenVM;
                      configs: seq[LaunchConfigEntry]) =
  ## Bulk-replace the launch-config list.  Resets the selection if
  ## the previously-selected slug is no longer present so a stale
  ## reference cannot survive a refresh.
  var lc = vm.launchConfig.val
  lc.configs = configs
  let stillPresent = block:
    var found = false
    for entry in configs:
      if entry.slug == lc.selectedSlug:
        found = true
        break
    found
  if not stillPresent:
    lc.selectedSlug = ""
  vm.launchConfig.val = lc

proc selectLaunchConfig*(vm: WelcomeScreenVM; slug: string) =
  ## Set the selected launch-config slug.  Empty string clears the
  ## selection.  Out-of-range slugs are accepted verbatim so the VM
  ## stays compatible with optimistic updates from the legacy
  ## bridge.
  var lc = vm.launchConfig.val
  lc.selectedSlug = slug
  vm.launchConfig.val = lc

proc setEditFolderPath*(vm: WelcomeScreenVM; folderPath: string) =
  ## Update the edit-mode folder path without changing ``mode`` /
  ## ``editMode``.
  var lc = vm.launchConfig.val
  lc.editFolderPath = folderPath
  vm.launchConfig.val = lc

# ---------------------------------------------------------------------------
# Actions — new-record form
# ---------------------------------------------------------------------------

proc updateNewRecord*(vm: WelcomeScreenVM;
                     mutate: proc(form: var NewRecordFormState)) =
  ## Apply ``mutate`` to a copy of the current ``NewRecordFormState``
  ## and write it back.  Lets headless tests update one field at a
  ## time without the VM exposing a setter per legacy field.
  var form = vm.newRecord.val
  mutate(form)
  vm.newRecord.val = form

proc setRecordExecutable*(vm: WelcomeScreenVM; path: string) =
  ## Update the executable path on the new-record form.
  vm.updateNewRecord(proc(form: var NewRecordFormState) =
    form.executable = path)

proc setRecordArgs*(vm: WelcomeScreenVM; args: seq[string]) =
  ## Update the command-line arguments on the new-record form.
  vm.updateNewRecord(proc(form: var NewRecordFormState) =
    form.args = args)

proc setRecordWorkDir*(vm: WelcomeScreenVM; path: string) =
  ## Update the working directory on the new-record form.
  vm.updateNewRecord(proc(form: var NewRecordFormState) =
    form.workDir = path)

proc setRecordOutputFolder*(vm: WelcomeScreenVM; path: string) =
  ## Update the output folder on the new-record form.  Implicitly
  ## flips ``defaultOutputFolder`` off so the value is actually
  ## persisted (the Karax checkbox / input are mutually exclusive
  ## via the ``disabled`` attribute).
  vm.updateNewRecord(proc(form: var NewRecordFormState) =
    form.outputFolder = path
    form.defaultOutputFolder = path.len == 0)

proc toggleDefaultOutputFolder*(vm: WelcomeScreenVM) =
  ## Flip the ``defaultOutputFolder`` flag.  Mirrors the Karax
  ## ``onchange`` handler on the form's checkbox.
  vm.updateNewRecord(proc(form: var NewRecordFormState) =
    form.defaultOutputFolder = not form.defaultOutputFolder)

proc isNewRecordValid*(vm: WelcomeScreenVM): bool =
  ## Lightweight client-side validity check.  Required: a non-empty
  ## ``executable``.  ``workDir`` and ``outputFolder`` are optional
  ## (the legacy ``RecordScreenFormValidator.requiredFields`` table
  ## marks only ``executable`` as required).
  vm.newRecord.val.executable.len > 0

# ---------------------------------------------------------------------------
# Actions — backend dispatches
# ---------------------------------------------------------------------------

proc loadRecentTrace*(vm: WelcomeScreenVM; traceId: string) =
  ## Dispatch the legacy ``CODETRACER::load-recent-trace`` flow.
  ## The Karax view sent the same payload via ``self.data.ipc.send``
  ## so the main-process side picks the right handler regardless of
  ## which view triggered it.  Out-of-range trace IDs are accepted
  ## (the bridge logs a warning); we pre-flip the loading overlay
  ## so the spec sees the spinner immediately.
  vm.beginLoadingTrace(traceId)
  let args = %*{"traceId": traceId}
  discard vm.store.backend.send("ct/load-recent-trace", args)

proc loadRecentFolder*(vm: WelcomeScreenVM; folderPath: string) =
  ## Dispatch the legacy ``CODETRACER::load-recent-folder`` flow.
  ## Folder loads transition the welcome surface into edit mode on
  ## the main-process side, so we mirror that locally so the GUI
  ## test does not race the IPC roundtrip.
  vm.enterEditMode(folderPath)
  let args = %*{"folderPath": folderPath}
  discard vm.store.backend.send("ct/load-recent-folder", args)

proc launchSelectedConfig*(vm: WelcomeScreenVM): bool =
  ## Dispatch ``ct/launch-config`` for the currently-selected
  ## launch-config entry.  Returns ``true`` when a dispatch was
  ## issued, ``false`` when no entry is selected or the selected
  ## slug is no longer in the configs list.
  let lc = vm.launchConfig.val
  if lc.selectedSlug.len == 0:
    return false
  for entry in lc.configs:
    if entry.slug == lc.selectedSlug:
      if not entry.enabled:
        return false
      let args = %*{
        "slug": entry.slug,
        "language": entry.language,
        "program": entry.program,
      }
      discard vm.store.backend.send("ct/launch-config", args)
      return true
  return false

proc submitNewRecord*(vm: WelcomeScreenVM): bool =
  ## Dispatch the legacy ``CODETRACER::new-record`` flow if the
  ## current ``NewRecordFormState`` is valid.  Returns ``true`` on
  ## dispatch, ``false`` when validation fails.
  if not vm.isNewRecordValid:
    return false
  let form = vm.newRecord.val
  let args = %*{
    "executable": form.executable,
    "args": form.args,
    "workDir": form.workDir,
    "outputFolder": form.outputFolder,
    "defaultOutputFolder": form.defaultOutputFolder,
  }
  discard vm.store.backend.send("ct/new-record", args)
  return true

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createWelcomeScreenVM*(store: ReplayDataStore): WelcomeScreenVM =
  ## Create a WelcomeScreenVM inside a reactive root owned by
  ## ``withViewModel``.  Sets every signal to its empty/inert default
  ## so headless tests start from a clean state and the IsoNim view
  ## (future iteration) renders the empty-state placeholders on
  ## first paint.  The reactive root is disposed via ``vm.dispose()``.
  withViewModel proc(dispose: proc()): WelcomeScreenVM =
    let recentTraces = createSignal(newSeq[RecentTraceRecord]())
    let recentFolders = createSignal(newSeq[RecentFolderRecord]())
    let startOptions = createSignal(newSeq[WelcomeStartOptionRecord]())
    let hoveredTrace = createSignal(NO_HOVERED_TRACE)
    let hoveredOption = createSignal("")
    let editMode = createSignal(false)
    let mode = createSignal(wsmWelcome)
    let loading = createSignal(false)
    let loadingTraceId = createSignal(NO_LOADING_TRACE)
    let onlineTraceInput = createSignal("")
    let launchConfig = createSignal(emptyLaunchConfig())
    let newRecord = createSignal(emptyNewRecord())

    let hasRecentTraces = createMemo[bool] proc(): bool =
      recentTraces.val.len > 0

    let hasRecentFolders = createMemo[bool] proc(): bool =
      recentFolders.val.len > 0

    let activeStartOptions = createMemo[seq[WelcomeStartOptionRecord]] proc(): seq[WelcomeStartOptionRecord] =
      let all = startOptions.val
      result = newSeqOfCap[WelcomeStartOptionRecord](all.len)
      for opt in all:
        if not opt.inactive:
          result.add(opt)

    let selectedLaunchConfig = createMemo[Option[LaunchConfigEntry]] proc(): Option[LaunchConfigEntry] =
      let lc = launchConfig.val
      if lc.selectedSlug.len == 0:
        return none(LaunchConfigEntry)
      for entry in lc.configs:
        if entry.slug == lc.selectedSlug:
          return some(entry)
      none(LaunchConfigEntry)

    WelcomeScreenVM(
      store: store,
      recentTraces: recentTraces,
      recentFolders: recentFolders,
      startOptions: startOptions,
      hoveredTrace: hoveredTrace,
      hoveredOption: hoveredOption,
      editMode: editMode,
      mode: mode,
      loading: loading,
      loadingTraceId: loadingTraceId,
      onlineTraceInput: onlineTraceInput,
      launchConfig: launchConfig,
      newRecord: newRecord,
      hasRecentTraces: hasRecentTraces,
      hasRecentFolders: hasRecentFolders,
      activeStartOptions: activeStartOptions,
      selectedLaunchConfig: selectedLaunchConfig,
      disposeProc: dispose,
    )
