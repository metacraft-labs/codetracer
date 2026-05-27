## Executable ViewModel signal registry for collaborative-session planning.
##
## The registry classifies every exported mutable ``Signal`` in the current
## ReplayDataStore and panel ViewModels. Tests compare this handwritten table
## against the source inventory so new mutable signals fail closed until their
## sync class is explicit.

import std/[algorithm, os, strutils, tables]

type
  ViewModelFieldKind* = enum
    vfkSignal,
    vfkMemo

  ViewModelSyncClass* = enum
    vscBackendAuthoritative,
    vscSharedSessionViewState,
    vscPresenceAwareness,
    vscRendererLocal,
    vscDerivedNonSignal

  ViewModelField* = object
    owner*: string
    field*: string
    kind*: ViewModelFieldKind
    typeExpr*: string
    sourceFile*: string
    line*: int

  SignalRegistryEntry* = object
    owner*: string
    field*: string
    syncClass*: ViewModelSyncClass
    rationale*: string
    requiresStableId*: bool
    stableIdNote*: string

  RegistryValidation* = object
    missing*: seq[ViewModelField]
    stale*: seq[SignalRegistryEntry]
    duplicates*: seq[string]
    invalidDerivedSignals*: seq[SignalRegistryEntry]
    invalidMemoClasses*: seq[SignalRegistryEntry]

proc fieldPath*(owner, field: string): string =
  owner & "." & field

proc fieldPath*(field: ViewModelField): string =
  fieldPath(field.owner, field.field)

proc fieldPath*(entry: SignalRegistryEntry): string =
  fieldPath(entry.owner, entry.field)

proc isValid*(validation: RegistryValidation): bool =
  validation.missing.len == 0 and
    validation.stale.len == 0 and
    validation.duplicates.len == 0 and
    validation.invalidDerivedSignals.len == 0 and
    validation.invalidMemoClasses.len == 0

proc syncClassName*(syncClass: ViewModelSyncClass): string =
  case syncClass
  of vscBackendAuthoritative: "backend-authoritative"
  of vscSharedSessionViewState: "shared-session-view-state"
  of vscPresenceAwareness: "presence-awareness"
  of vscRendererLocal: "renderer-local"
  of vscDerivedNonSignal: "derived/non-signal"

proc canPublishAsViewStateOperation*(entry: SignalRegistryEntry): bool =
  ## M0's publisher boundary: only shared ViewState fields may become
  ## replayable ViewOps. Backend facts, awareness, renderer leaves, and memos
  ## need different channels or local recomputation.
  entry.syncClass == vscSharedSessionViewState

proc addEntry(entries: var seq[SignalRegistryEntry];
              owner, field: string;
              syncClass: ViewModelSyncClass;
              rationale: string;
              requiresStableId = false;
              stableIdNote = "") =
  entries.add SignalRegistryEntry(
    owner: owner,
    field: field,
    syncClass: syncClass,
    rationale: rationale,
    requiresStableId: requiresStableId,
    stableIdNote: stableIdNote,
  )

proc addMany(entries: var seq[SignalRegistryEntry];
             owner: string;
             fields: openArray[string];
             syncClass: ViewModelSyncClass;
             rationale: string) =
  for field in fields:
    entries.addEntry(owner, field, syncClass, rationale)

proc addDerived(entries: var seq[SignalRegistryEntry];
                owner: string;
                fields: openArray[string]) =
  entries.addMany(owner, fields, vscDerivedNonSignal,
    "Memo/computed field; recomputed locally from signals and backend facts.")

proc collabSignalRegistry*(): seq[SignalRegistryEntry] =
  ## Handwritten classification table for M0. Owner names match the Nim object
  ## type that declares the exported ``Signal``/``Memo`` field.
  var entries: seq[SignalRegistryEntry] = @[]

  entries.addMany("ReplayDataStore",
    ["session", "debugger", "currentGeid", "timeline"],
    vscBackendAuthoritative,
    "Top-level replay/debugger facts owned by the backend authority.")
  entries.addMany("CalltraceStore",
    ["lines", "args", "startLineIndex", "totalCallsCount", "finished",
     "loadingState"],
    vscBackendAuthoritative,
    "Calltrace rows and loading status come from backend requests/snapshots.")
  entries.addMany("LocalsStore",
    ["locals", "globals", "loadingState", "loadedForRRTicks", "codeStateLine"],
    vscBackendAuthoritative,
    "Variable data and source excerpt are backend-derived for a debugger tick.")

  entries.addEntry("CalltraceVM", "scrollPosition", vscRendererLocal,
    "Viewport scroll offset is a renderer projection, not shared intent.")
  entries.addEntry("CalltraceVM", "viewportHeight", vscRendererLocal,
    "Measured panel height is renderer-local.")
  entries.addEntry("CalltraceVM", "viewportDepth", vscRendererLocal,
    "Render window depth is local virtualization state.")
  entries.addEntry("CalltraceVM", "selectedEntry", vscSharedSessionViewState,
    "Calltrace selection is collaborative session intent.",
    requiresStableId = true,
    stableIdNote = "Currently stores a calltrace row index; needs a stable call node id/key.")
  entries.addEntry("CalltraceVM", "expandedNodes", vscSharedSessionViewState,
    "Calltrace expansion set is collaborative session intent.",
    requiresStableId = true,
    stableIdNote = "Currently stores row indices; expansion ops need stable call node ids.")
  entries.addMany("CalltraceVM", ["searchQuery", "rawIgnorePatterns"],
    vscSharedSessionViewState,
    "Calltrace filter/search settings are logical shared view state.")
  entries.addEntry("CalltraceVM", "backendSearchResults", vscBackendAuthoritative,
    "Search result payloads come from backend queries.")
  entries.addDerived("CalltraceVM",
    ["visibleLines", "hasMoreAbove", "hasMoreBelow", "highlightedMatches",
     "isLoading"])

  entries.addMany("StateVM", ["activeTab", "watchExpressions"],
    vscSharedSessionViewState,
    "State pane tab and watch list are shared session view state.")
  entries.addEntry("StateVM", "expandedPaths", vscSharedSessionViewState,
    "State variable expansion set is shared session view state.",
    requiresStableId = true,
    stableIdNote = "String paths can drift when variable identity/order changes; stable variable ids are needed.")
  entries.addEntry("StateVM", "selectedPath", vscSharedSessionViewState,
    "Selected variable path is shared session view state.",
    requiresStableId = true,
    stableIdNote = "String paths are not durable variable identities across backend snapshots.")
  entries.addDerived("StateVM", ["currentVariables", "isLoading", "codeStateLine"])

  entries.addEntry("EventLogVM", "selectedRow", vscSharedSessionViewState,
    "Event-log selection is logical session state.",
    requiresStableId = true,
    stableIdNote = "Currently stores a visible row index; should target eventId.")
  entries.addMany("EventLogVM",
    ["currentPage", "pageSize", "searchQuery", "sortColumn", "sortAscending"],
    vscSharedSessionViewState,
    "Event-log query/page/sort settings are logical shared view state.")
  entries.addMany("EventLogVM", ["eventRows", "totalEventCount", "loadingState"],
    vscBackendAuthoritative,
    "Event-log rows/count/loading are backend query results.")
  entries.addDerived("EventLogVM", ["totalPages", "isLoading"])

  entries.addMany("FlowVM", ["flowMode", "showRawValues"],
    vscSharedSessionViewState,
    "Flow display mode options are shared logical view state.")
  entries.addEntry("FlowVM", "selectedIteration", vscSharedSessionViewState,
    "Selected flow iteration is shared session view state.",
    requiresStableId = true,
    stableIdNote = "Iteration index needs a stable loop/iteration identity before network sync.")
  entries.addEntry("FlowVM", "hoveredStep", vscPresenceAwareness,
    "Hover is ephemeral participant awareness.")
  entries.addMany("FlowVM", ["iterationCount", "loadingState", "steps"],
    vscBackendAuthoritative,
    "Flow step payloads and loading status are backend-derived.")
  entries.addDerived("FlowVM", ["isLoading", "totalIterations"])

  entries.addEntry("EditorVM", "activeTabIndex", vscSharedSessionViewState,
    "Active editor tab is shared view state.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; shared state should target stable file/source ids.")
  entries.addMany("EditorVM", ["cursorLine", "cursorColumn"],
    vscPresenceAwareness,
    "Editor cursor is per-participant awareness.")
  entries.addEntry("EditorVM", "scrollTop", vscRendererLocal,
    "Monaco/renderer scroll offset stays local.")
  entries.addMany("EditorVM", ["showFlowOverlay", "showBreakpointGutter"],
    vscSharedSessionViewState,
    "Logical editor overlays are shared session view preferences.")
  entries.addDerived("EditorVM",
    ["activeFileName", "activeSourceGeneration", "activeSourceDigest",
     "executionCursorKind"])

  entries.addMany("TimelineVM", ["zoomLevel", "viewStart", "viewEnd"],
    vscSharedSessionViewState,
    "Timeline range is collaborative view state over stable rrTicks.")
  entries.addEntry("TimelineVM", "hoveredTick", vscPresenceAwareness,
    "Hover is ephemeral participant awareness.")
  entries.addDerived("TimelineVM", ["currentPosition", "markers"])

  entries.addDerived("DebugControlsVM",
    ["canStepForward", "canStepBackward", "canContinue", "canReverseContinue",
     "isRunning", "statusText", "toolbarModeText", "recordingHeadText",
     "showRecordingHead", "showJumpToLive", "canJumpToLive"])

  entries.addMany("SearchVM", ["mode", "query", "resultsVisible"],
    vscSharedSessionViewState,
    "Search panel mode/query/visibility are logical view state.")
  entries.addEntry("SearchVM", "selectedResult", vscSharedSessionViewState,
    "Selected search result is shared view state.",
    requiresStableId = true,
    stableIdNote = "Current field is a result index; needs stable file/location result identity.")
  entries.addEntry("SearchVM", "results", vscBackendAuthoritative,
    "Search results are produced by a backend/search service query.")

  entries.addEntry("PointListVM", "selectedPoint", vscSharedSessionViewState,
    "Point selection should be shared when points become session objects.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; breakpoints/points need stable ids.")
  entries.addEntry("PointListVM", "editingPoint", vscRendererLocal,
    "Inline edit focus is local renderer state.",
    requiresStableId = true,
    stableIdNote = "If synchronized later, this index must become a stable point id.")
  entries.addEntry("PointListVM", "points", vscSharedSessionViewState,
    "Point/breakpoint list is shared session view state.",
    requiresStableId = true,
    stableIdNote = "Point rows need stable ids before concurrent list operations.")

  entries.addMany("ScratchpadVM", ["entries", "localsByExpression"],
    vscSharedSessionViewState,
    "Scratchpad/watch-like entries are user-authored shared session state.")
  entries.addDerived("ScratchpadVM", ["isEmpty", "rowCount"])

  entries.addMany("ShellVM", ["inputBuffer", "scrollPosition", "historyIndex"],
    vscRendererLocal,
    "Terminal input, scroll, and history cursor are local interaction state.")
  entries.addEntry("ShellVM", "inputHistory", vscPresenceAwareness,
    "Command history is participant-local awareness, not replayable ViewState.")

  entries.addMany("SearchResultsVM", ["query", "active", "filter"],
    vscSharedSessionViewState,
    "Global search results panel query/filter/visibility are shared view state.")
  entries.addEntry("SearchResultsVM", "results", vscBackendAuthoritative,
    "Search result rows are backend/search service output.")
  entries.addDerived("SearchResultsVM", ["visibleResults", "resultCount"])

  entries.addMany("TraceLogVM", ["entries"], vscBackendAuthoritative,
    "Trace-log entries are backend/session facts.")
  entries.addEntry("TraceLogVM", "selectedIndex", vscSharedSessionViewState,
    "Trace-log selection is shared view state.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; needs stable trace-log entry identity.")
  entries.addDerived("TraceLogVM", ["isEmpty", "rowCount"])

  entries.addMany("TerminalOutputVM", ["lines", "currentRRTicks"],
    vscBackendAuthoritative,
    "Terminal output is backend trace data.")
  entries.addEntry("TerminalOutputVM", "initialLoad", vscRendererLocal,
    "Initial-load flag controls local render behavior.")
  entries.addDerived("TerminalOutputVM", ["isLoading", "isEmpty"])

  entries.addMany("StepListVM", ["lineSteps", "currentLocation"],
    vscBackendAuthoritative,
    "Step-list rows and current location are backend-derived.")
  entries.addEntry("StepListVM", "panelHeight", vscRendererLocal,
    "Measured panel height is renderer-local.")
  entries.addDerived("StepListVM", ["isEmpty"])

  entries.addEntry("LowLevelCodeVM", "activeOffset", vscSharedSessionViewState,
    "Low-level code cursor is logical view state.",
    requiresStableId = true,
    stableIdNote = "Offset should be tied to stable instruction/address identity.")
  entries.addMany("LowLevelCodeVM",
    ["instructions", "address", "errorMessage", "noirProject"],
    vscBackendAuthoritative,
    "Instruction data and status are backend-derived facts.")
  entries.addDerived("LowLevelCodeVM", ["isEmpty"])

  entries.addMany("NoSourceVM",
    ["message", "location", "history", "originatingAddress", "stopSignalText"],
    vscBackendAuthoritative,
    "No-source diagnostic data is derived from backend/debugger state.")

  entries.addEntry("CalltraceEditorVM", "mounted", vscRendererLocal,
    "Mount lifecycle is renderer-local.")

  entries.addMany("BuildVM",
    ["output", "errors", "problems", "command", "running", "code",
     "buildStartTime"],
    vscBackendAuthoritative,
    "Build output/status is owned by the local build/process service.")
  entries.addEntry("BuildVM", "autoScroll", vscRendererLocal,
    "Auto-scroll is a local panel behavior.")
  entries.addDerived("BuildVM", ["status", "isRunning", "hasOutput"])

  entries.addEntry("ErrorsVM", "problems", vscBackendAuthoritative,
    "Problem rows are produced by build/diagnostic services.")
  entries.addMany("ErrorsVM", ["filter", "groupByFile"],
    vscSharedSessionViewState,
    "Problem filter/grouping are logical view state.")
  entries.addDerived("ErrorsVM",
    ["visibleProblems", "errorCount", "warningCount", "totalCount"])

  entries.addMany("CommandPaletteVM",
    ["isActive", "inputValue", "inputPlaceholder", "mode", "query",
     "results", "selectedIndex", "activeCommandName"],
    vscRendererLocal,
    "Command palette state is local transient UI interaction.")
  entries.addDerived("CommandPaletteVM", ["hasResults", "resultCount"])

  entries.addMany("WelcomeScreenVM",
    ["recentTraces", "recentFolders", "startOptions", "hoveredRecording",
     "hoveredOption", "editMode", "mode", "loading", "loadingRecordingId",
     "onlineTraceInput", "launchConfig", "newRecord",
     "recordBackendAvailability"],
    vscRendererLocal,
    "Welcome/startup form state is outside an active collaborative replay session.")
  entries.addDerived("WelcomeScreenVM",
    ["hasRecentTraces", "hasRecentFolders", "activeStartOptions",
     "selectedLaunchConfig", "recordBackendOptions", "showRecordBackendChoice",
     "newRecordStartsLive", "newRecordSessionMode"])

  entries.addMany("ReplayLifecycleVM",
    ["deploymentMode", "traceKind", "stage", "sourcePath", "entryFunction",
     "expectedStreamingPhases", "completedStreamingPhases", "errorMessage"],
    vscBackendAuthoritative,
    "Replay lifecycle fields describe backend/session launch facts.")
  entries.addDerived("ReplayLifecycleVM",
    ["isBrowserReplay", "isMaterializedBrowserReplay", "isMcrBrowserReplay",
     "isStreaming", "isReady", "hasAllStreamingPhases"])

  entries.addMany("RequestPanelVM",
    ["filterMethod", "filterStatus", "searchText"],
    vscSharedSessionViewState,
    "Request-panel filters are logical view state.")
  entries.addEntry("RequestPanelVM", "requests", vscBackendAuthoritative,
    "Request records are captured/backend facts.")
  entries.addEntry("RequestPanelVM", "selectedIndex", vscSharedSessionViewState,
    "Selected request is shared view state.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; needs stable request id.")
  entries.addDerived("RequestPanelVM", ["filteredRequests"])

  entries.addMany("ReplVM", ["history", "replEnabled", "materialized", "langName"],
    vscBackendAuthoritative,
    "REPL history/status reflects backend/materialization capability and output.")
  entries.addDerived("ReplVM", ["displayMode"])

  entries.addMany("VCSVM",
    ["deepReviewMode", "headerTitle", "headerIcon", "isGitRepo",
     "errorMessage", "currentBranch", "branches", "commits", "changedFiles",
     "diffFiles"],
    vscBackendAuthoritative,
    "VCS rows/status are local repository facts.")
  entries.addMany("VCSVM", ["branchDropdownOpen", "unifiedDiffActive",
                            "hunkToolbarVisible", "hunkCopyFeedback"],
    vscRendererLocal,
    "Dropdowns and copy feedback are local UI state.")
  entries.addEntry("VCSVM", "selectedCommitIndex", vscRendererLocal,
    "Current VCS selection uses an index and is not part of replay session sync.",
    requiresStableId = true,
    stableIdNote = "Would need commit hash/id if synchronized.")
  entries.addEntry("VCSVM", "selectedHunks", vscRendererLocal,
    "Hunk selection uses local diff coordinates.",
    requiresStableId = true,
    stableIdNote = "Would need stable diff hunk ids if synchronized.")
  entries.addDerived("VCSVM", ["fileCount", "selectedHunkCount"])

  entries.addMany("DeepReviewVM",
    ["hasData", "sessionTitle", "commitDisplay", "statsText",
     "traceContexts", "files", "flowCount", "currentFunctionKey",
     "maxIterations", "unifiedFiles", "callNodes"],
    vscBackendAuthoritative,
    "DeepReview content is analysis/service output.")
  entries.addMany("DeepReviewVM",
    ["glEmbedded", "viewMode", "hunkToolbarVisible", "hunkCopyFeedback"],
    vscRendererLocal,
    "Embedding mode and transient toolbar feedback are local UI details.")
  entries.addEntry("DeepReviewVM", "selectedTraceContextId", vscRendererLocal,
    "DeepReview selection is outside replay session sync.",
    requiresStableId = true,
    stableIdNote = "Would need stable trace-context id if synchronized.")
  entries.addEntry("DeepReviewVM", "selectedFileIndex", vscRendererLocal,
    "DeepReview file selection uses an index.",
    requiresStableId = true,
    stableIdNote = "Would need stable file identity if synchronized.")
  entries.addEntry("DeepReviewVM", "selectedExecutionIndex", vscRendererLocal,
    "DeepReview execution selection uses an index.",
    requiresStableId = true,
    stableIdNote = "Would need stable execution identity if synchronized.")
  entries.addEntry("DeepReviewVM", "selectedIteration", vscRendererLocal,
    "DeepReview iteration selection uses an index.",
    requiresStableId = true,
    stableIdNote = "Would need stable iteration identity if synchronized.")
  entries.addEntry("DeepReviewVM", "selectedHunks", vscRendererLocal,
    "DeepReview hunk selection uses local diff coordinates.",
    requiresStableId = true,
    stableIdNote = "Would need stable hunk ids if synchronized.")
  entries.addDerived("DeepReviewVM", ["selectedFile", "fileCount"])

  entries.addMany("FilesystemVM",
    ["rootEntry", "diffEntries", "deepReviewActive", "deepReviewFiles"],
    vscBackendAuthoritative,
    "Filesystem tree/diff contents are local repository facts.")
  entries.addEntry("FilesystemVM", "expandedPaths", vscSharedSessionViewState,
    "Filesystem expansion can be shared as logical path state.",
    requiresStableId = true,
    stableIdNote = "Paths may be enough for files, but virtual/deep-review nodes need stable ids.")
  entries.addDerived("FilesystemVM", ["isEmpty", "hasDiff", "totalEntryCount"])

  entries.addMany("AgentActivityVM",
    ["messages", "terminals", "isLoading", "reRecordInProgress",
     "wantsPassword", "wantsPermission", "sessionKey"],
    vscBackendAuthoritative,
    "Agent activity stream/session status is service-owned.")
  entries.addEntry("AgentActivityVM", "inputValue", vscRendererLocal,
    "Prompt draft is local typing state.")
  entries.addDerived("AgentActivityVM",
    ["messageCount", "terminalCount", "hasMessages"])

  entries.addMany("AgentActivityDeepReviewVM",
    ["coverageSummary", "testResults", "fileCoverage", "notifications"],
    vscBackendAuthoritative,
    "Agent DeepReview data is service output.")
  entries.addEntry("AgentActivityDeepReviewVM", "isExpanded", vscRendererLocal,
    "Expansion of the embedded summary is local UI state.")
  entries.addDerived("AgentActivityDeepReviewVM",
    ["coveragePercent", "hasFailures", "notificationCount"])

  entries.addMany("AgentWorkspaceVM",
    ["viewKind", "workspacePath", "sessionId", "summary", "files",
     "notificationCount"],
    vscBackendAuthoritative,
    "Agent workspace content/session metadata is service-owned.")
  entries.addEntry("AgentWorkspaceVM", "selectedFileIndex", vscRendererLocal,
    "Workspace file selection uses an index and is local.",
    requiresStableId = true,
    stableIdNote = "Would need stable workspace file id if synchronized.")
  entries.addEntry("AgentWorkspaceVM", "coverageOverlayEnabled", vscRendererLocal,
    "Coverage overlay toggle is local UI state.")
  entries.addDerived("AgentWorkspaceVM",
    ["fileCount", "hasWorkspace", "selectedFile", "selectedCoverageText"])

  entries.addMany("FrameViewerVM",
    ["visualReplayAvailable", "playerUrl", "currentGeid", "currentFrame",
     "frameCount", "frameImageSrc", "frameWidth", "frameHeight", "loading",
     "error", "drawCalls"],
    vscBackendAuthoritative,
    "Frame-viewer frame data is visual replay backend output.")
  entries.addEntry("FrameViewerVM", "selectedPixel", vscSharedSessionViewState,
    "Pixel selection can be shared once tied to a stable frame.",
    requiresStableId = true,
    stableIdNote = "Needs stable frame/geid plus pixel coordinate identity.")
  entries.addEntry("FrameViewerVM", "selectedDrawCall", vscSharedSessionViewState,
    "Draw-call selection can be shared once draw calls have stable ids.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; needs stable draw-call id.")

  entries.addEntry("PixelHistoryVM", "selectedPixel", vscSharedSessionViewState,
    "Pixel-history target can be shared once tied to stable frame identity.",
    requiresStableId = true,
    stableIdNote = "Needs stable frame/geid plus pixel coordinate identity.")
  entries.addMany("PixelHistoryVM", ["entries", "loading", "error"],
    vscBackendAuthoritative,
    "Pixel-history rows/status are visual replay backend output.")
  entries.addEntry("PixelHistoryVM", "selectedEntry", vscSharedSessionViewState,
    "Pixel-history row selection can be shared with stable row ids.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; needs stable pixel-history entry id.")

  entries.addEntry("ShaderDebugVM", "selectedContext", vscSharedSessionViewState,
    "Shader debug context selection is logical visual replay state.",
    requiresStableId = true,
    stableIdNote = "Needs stable draw/shader invocation identity.")
  entries.addMany("ShaderDebugVM", ["debugInfo", "loading", "error"],
    vscBackendAuthoritative,
    "Shader debug payload/status are backend output.")
  entries.addEntry("ShaderDebugVM", "currentStepIndex", vscSharedSessionViewState,
    "Shader step selection can be shared with stable step ids.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; needs stable shader-step id.")

  entries

proc registryByPath*(entries: openArray[SignalRegistryEntry]):
    Table[string, SignalRegistryEntry] =
  for entry in entries:
    result[entry.fieldPath] = entry

proc stableIdBlockedFields*(
    entries: openArray[SignalRegistryEntry] = collabSignalRegistry()):
    seq[SignalRegistryEntry] =
  for entry in entries:
    if entry.requiresStableId:
      result.add(entry)

proc viewModelSourceFiles*(sourceRoot = "src/frontend/viewmodel"): seq[string] =
  result.add(sourceRoot / "session_vm.nim")
  result.add(sourceRoot / "store" / "replay_data_store.nim")
  for file in walkFiles(sourceRoot / "viewmodels" / "*.nim"):
    result.add(file)
  result.sort(proc(a, b: string): int = cmp(a, b))

proc parseObjectOwner(line: string): string =
  let stripped = line.strip
  if not stripped.contains("* ="):
    return ""
  if not (stripped.contains("= object") or
      stripped.contains("= ref object")):
    return ""
  let star = stripped.find('*')
  if star <= 0:
    return ""
  stripped[0 ..< star].strip

proc parseField(line: string; owner, sourceFile: string; lineNo: int):
    ViewModelField =
  let code = line.split("##", maxsplit = 1)[0].strip
  let marker = code.find("*:")
  if marker < 0:
    return

  let name = code[0 ..< marker].strip
  let typePart = code[marker + 2 .. ^1].strip
  if typePart.startsWith("Signal["):
    return ViewModelField(owner: owner, field: name, kind: vfkSignal,
      typeExpr: typePart, sourceFile: sourceFile, line: lineNo)
  if typePart.startsWith("Memo["):
    return ViewModelField(owner: owner, field: name, kind: vfkMemo,
      typeExpr: typePart, sourceFile: sourceFile, line: lineNo)

proc discoverViewModelFields*(sourceRoot = "src/frontend/viewmodel"):
    seq[ViewModelField] =
  for file in viewModelSourceFiles(sourceRoot):
    if not fileExists(file):
      continue
    var owner = ""
    var lineNo = 0
    for line in lines(file):
      inc lineNo
      let parsedOwner = parseObjectOwner(line)
      if parsedOwner.len > 0:
        owner = parsedOwner
        continue
      if owner.len == 0:
        continue
      let field = parseField(line, owner, file, lineNo)
      if field.owner.len > 0:
        result.add(field)
  result.sort(proc(a, b: ViewModelField): int =
    let byPath = cmp(a.fieldPath, b.fieldPath)
    if byPath != 0: byPath else: cmp(a.sourceFile, b.sourceFile))

proc validateRegistry*(inventory: openArray[ViewModelField];
                       entries: openArray[SignalRegistryEntry]):
    RegistryValidation =
  var seenEntries = initTable[string, int]()
  var registryKinds = initTable[string, ViewModelFieldKind]()
  for field in inventory:
    registryKinds[field.fieldPath] = field.kind

  for entry in entries:
    let path = entry.fieldPath
    if seenEntries.hasKey(path):
      result.duplicates.add(path)
    else:
      seenEntries[path] = 1

    if not registryKinds.hasKey(path):
      result.stale.add(entry)
      continue

    case registryKinds[path]
    of vfkSignal:
      if entry.syncClass == vscDerivedNonSignal:
        result.invalidDerivedSignals.add(entry)
    of vfkMemo:
      if entry.syncClass != vscDerivedNonSignal:
        result.invalidMemoClasses.add(entry)

  let byPath = entries.registryByPath
  for field in inventory:
    if not byPath.hasKey(field.fieldPath):
      result.missing.add(field)

proc formatValidation*(validation: RegistryValidation): string =
  var chunks: seq[string] = @[]
  if validation.missing.len > 0:
    var values: seq[string] = @[]
    for field in validation.missing:
      values.add(field.fieldPath & " at " & field.sourceFile & ":" & $field.line)
    chunks.add("missing classifications: " & values.join(", "))
  if validation.stale.len > 0:
    var values: seq[string] = @[]
    for entry in validation.stale:
      values.add(entry.fieldPath)
    chunks.add("stale classifications: " & values.join(", "))
  if validation.duplicates.len > 0:
    chunks.add("duplicate classifications: " & validation.duplicates.join(", "))
  if validation.invalidDerivedSignals.len > 0:
    var values: seq[string] = @[]
    for entry in validation.invalidDerivedSignals:
      values.add(entry.fieldPath)
    chunks.add("mutable signals marked derived/non-signal: " & values.join(", "))
  if validation.invalidMemoClasses.len > 0:
    var values: seq[string] = @[]
    for entry in validation.invalidMemoClasses:
      values.add(entry.fieldPath)
    chunks.add("memos not marked derived/non-signal: " & values.join(", "))
  chunks.join("\n")
