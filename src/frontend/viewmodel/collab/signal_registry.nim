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
    ["session", "debugger", "currentGeid", "timeline", "agentSessions"],
    vscBackendAuthoritative,
    "Top-level replay/debugger and agent-service facts owned by the backend authority.")
  entries.addMany("CalltraceStore",
    ["lines", "args", "startLineIndex", "totalCallsCount", "finished",
     "loadingState"],
    vscBackendAuthoritative,
    "Calltrace rows and loading status come from backend requests/snapshots.")
  entries.addMany("LocalsStore",
    ["locals", "globals", "loadingState", "loadedForRRTicks", "codeStateLine"],
    vscBackendAuthoritative,
    "Variable data and source excerpt are backend-derived for a debugger tick.")
  # `watches` is the ANSWERS, not the questions. The expressions a user typed
  # are `StateVM.watchExpressions`, classified below as shared session view
  # state; what comes back for them rides the same `ct/load-locals` response as
  # `locals` and `globals` (told apart by `value.isWatch`, which the backend
  # sets) and is a fact about the loaded step. A refused watch is still a row
  # here, carrying the backend's reason — which is the clearest sign these are
  # the owning peer's answers rather than anything a participant authored.
  entries.addEntry("LocalsStore", "watches", vscBackendAuthoritative,
    "Answers to the shared watch expressions at the loaded step; they arrive on the same backend response as `locals`.")
  # §14's four degraded-state axes. They are on the STORE precisely so that
  # five panes cannot disagree about whether this replay is windowed, and each
  # one is a property of the recording and the backend replaying it — never of
  # a participant. A collaborator must receive all four from the backend owner;
  # merging two peers' views of trace integrity would be inventing a third.
  entries.addMany("DegradedStateStore",
    ["availability", "integrity", "capability", "sourceAvailability"],
    vscBackendAuthoritative,
    "The degraded-state catalogue's four axes are facts about the recording and the replay backend, not about a viewer.")
  # The event log's rows moved onto the store so that one decoder
  # (`applyEventLogResponse`) serves every front-end, and the classification
  # follows the data rather than the move: every field here is a property of
  # the RECORDING as the backend-owning peer read it. `loadedStart` is included
  # deliberately — it is not a viewport, it is which window of the log the
  # owning peer's last request fetched, and a participant who received rows
  # without it would not know what the rows' indices mean.
  entries.addMany("EventLogStore",
    ["rows", "recordsTotal", "recordsFiltered", "maxRRTicks", "loadedStart",
     "loadingState", "windowSource"],
    vscBackendAuthoritative,
    "Event rows, the counts, the recording's extent, the fetched window's offset, the load status and which route produced the window are all backend answers about the recording.")
  # The point list has TWO producers and both are the owning peer's:
  # `applyCollections` reads the CHECKOUT's `points.toml` (which a remote
  # participant does not have) and `applyTracepointResults` reads a sweep the
  # backend ran. A participant's own toggle of a collection would be shared
  # session view state, but that field does not exist yet — when it does it
  # belongs beside `StateVM.watchExpressions`, not here.
  entries.addMany("PointListStore",
    ["rows", "tracepointHits", "loadingState"],
    vscBackendAuthoritative,
    "Declared point rows are resolved against the owning peer's checkout and annotated by a backend sweep; the hits are the sweep's own answer.")

  # RS-M3 HTTP request tail. The store owns the poll, not the panel: rows,
  # the opaque poll cursor, the producer label and the load status are all
  # values the backend-owning peer hands over. The cursor in particular is
  # protocol state — echoed back verbatim to the same producer — so merging
  # two peers' cursors would corrupt the stream rather than reconcile it.
  entries.addMany("RequestSpansStore",
    ["requests", "cursor", "source", "loadingState"],
    vscBackendAuthoritative,
    "Span rows, the opaque poll cursor, the producer label and the load status are backend stream facts.")

  # M29 multi-process session surface.
  entries.addEntry("ProcessTreeVM", "entries", vscBackendAuthoritative,
    "Process/recording rows mirror the ct/listProcesses backend reply.")
  entries.addEntry("SessionViewModel", "activeProcessRecordingId",
    vscSharedSessionViewState,
    "The active recording selection is shared session view state over a stable recordingId.")
  entries.addDerived("SessionViewModel", ["crossProcessSpans"])

  entries.addEntry("CalltraceVM", "scrollPosition", vscRendererLocal,
    "Viewport scroll offset is a renderer projection, not shared intent.")
  entries.addEntry("CalltraceVM", "viewportHeight", vscRendererLocal,
    "Measured panel height is renderer-local.")
  entries.addEntry("CalltraceVM", "viewportDepth", vscRendererLocal,
    "Render window depth is local virtualization state.")
  entries.addEntry("CalltraceVM", "rowHeightPx", vscRendererLocal,
    "Row height measured from the rendered DOM after layout; a per-front-end " &
    "measurement (font size, em scaling, zoom) that must never travel.")
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
  entries.addEntry("CalltraceVM", "backendSearchResults",
    vscBackendAuthoritative,
    "Search result payloads come from backend queries.")
  entries.addDerived("CalltraceVM",
    ["visibleLines", "hasMoreAbove", "hasMoreBelow", "highlightedMatches",
     "isLoading", "degradedState"])

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
  entries.addEntry("StateVM", "expandedHistories", vscSharedSessionViewState,
    "Which variables have their value history unfolded is the same kind of " &
    "expansion intent as `expandedPaths`, and shares its key.",
    requiresStableId = true,
    stableIdNote = "Keyed by the dot-separated variable path, which can drift when variable identity/order changes; needs stable variable ids.")
  entries.addEntry("StateVM", "valueHistory", vscBackendAuthoritative,
    "Value-history rows are the `ct/load-history` reply, cached under the path they were requested for.")
  # M4 Value Origin Tracking surface mirrored onto the State Pane.
  entries.addEntry("StateVM", "expandedOrigins", vscSharedSessionViewState,
    "Per-row origin-chain expansion set is shared session view state.",
    requiresStableId = true,
    stableIdNote = "VariableId is a (name + scopePath) string key that can drift; needs stable variable ids.")
  entries.addMany("StateVM", ["breadcrumbStack", "originPreferences"],
    vscSharedSessionViewState,
    "Origin breadcrumb navigation and user-mutable badge/chain preferences are shared view state.")
  entries.addEntry("StateVM", "originSummaries", vscBackendAuthoritative,
    "Origin summaries are populated from the ct/load-locals backend response.")
  entries.addEntry("StateVM", "originMetadataMode", vscBackendAuthoritative,
    "Origin-metadata mode label is bridged from the db-backend ct/originMode reply.")
  entries.addEntry("StateVM", "lastContextMenu", vscRendererLocal,
    "Most-recent right-click context menu is a transient local render artefact.")
  entries.addDerived("StateVM", ["currentVariables", "isLoading",
      "codeStateLine", "degradedState", "hasCodeState"])

  # M4 Value Origin Tracking — dedicated VM behind the State Pane badge,
  # the side panel, the scratchpad pins, and the editor hover card.
  entries.addEntry("OriginChainVM", "expandedOrigins",
    vscSharedSessionViewState,
    "Per-row origin-chain expansion set is shared session view state.",
    requiresStableId = true,
    stableIdNote = "VariableId is a (name + scopePath) string key that can drift; needs stable variable ids.")
  entries.addMany("OriginChainVM",
    ["pinnedChains", "breadcrumbStack", "preferences", "sidePanelOpen"],
    vscSharedSessionViewState,
    "User-pinned chains, breadcrumb navigation, badge/chain preferences, and side-panel visibility are shared logical view state.")
  entries.addMany("OriginChainVM",
    ["activeChain", "loading", "inFlightSummary", "lastResolvedSummaries"],
    vscBackendAuthoritative,
    "Resolved chains/summaries and their request-lifecycle loading flags come from ct/originChain + ct/originSummary backend responses.")
  entries.addMany("OriginChainVM",
    ["placeholderFillQueue", "latestRequestId"],
    vscRendererLocal,
    "Pending-fill queue and the stale-response request counter are local request-batching bookkeeping.")

  entries.addEntry("EventLogVM", "selectedRow", vscSharedSessionViewState,
    "Event-log selection is logical session state.",
    requiresStableId = true,
    stableIdNote = "Currently stores a visible row index; should target eventId.")
  entries.addMany("EventLogVM",
    ["currentPage", "pageSize", "searchQuery", "sortColumn", "sortAscending"],
    vscSharedSessionViewState,
    "Event-log query/page/sort settings are logical shared view state.")
  entries.addMany("EventLogVM", ["eventRows", "totalEventCount",
      "loadingState"],
    vscBackendAuthoritative,
    "Event-log rows/count/loading are backend query results.")
  # M25b correlation-marker surface. The marker rows, the per-key
  # counterpart cache, and the load banner are all populated from
  # backend responses (`ct/event-load`, `ct/pairIndexLookup`,
  # `ct/markerLoad*` DAP events), so they are backend facts that must
  # stream from the owning peer rather than CRDT-merge between users.
  entries.addMany("EventLogVM",
    ["markerRows", "counterpartCache", "loadingBanner", "emptyState"],
    vscBackendAuthoritative,
    "Marker rows/cache/load-banner/empty-state are derived from backend marker responses.")
  # The toast is a one-time, per-workspace discovery hint with no
  # collaborative meaning; the dismissal log persists locally through
  # the preferences bridge (spec §7). Both stay renderer-local.
  entries.addMany("EventLogVM", ["toastState", "dismissedWorkspaces"],
    vscRendererLocal,
    "Discovery toast and its per-workspace dismissal log are local UI hints.")
  # `filterBar` is the parsed projection of `searchQuery` (already
  # shared). It is a mutable signal rather than a memo, but it carries
  # the same shared filter intent.
  entries.addEntry("EventLogVM", "filterBar", vscSharedSessionViewState,
    "Parsed marker filter bar mirrors the shared search/filter intent.")
  entries.addDerived("EventLogVM",
    ["totalPages", "isLoading", "visibleMarkerRows", "degradedState"])

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
  # The loaded flow window. All three are written together by
  # `applyFlowUpdate` out of one `ct/load-flow` reply — `loops` is
  # index-aligned with the backend's own array, `focusedLoop` is
  # `pickFocusedLoop(loops)` over it, and `windowRRTicks` is the tick the
  # reply was computed for. They are signals rather than memos only because
  # the VM owns the window instead of a flow sub-store; nothing here is user
  # intent, so a peer must receive them from the backend owner as a set and
  # never merge them.
  entries.addMany("FlowVM", ["loops", "focusedLoop", "windowRRTicks", "styledLines"],
    vscBackendAuthoritative,
    "The loaded flow window: backend loop array, the loop picked from it, the tick it was loaded for, and its per-line facts.")
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
     "executionCursorKind", "degradedState", "sourceAvailability",
     "instructionLevelStepping"])

  entries.addMany("TimelineVM", ["zoomLevel", "viewStart", "viewEnd"],
    vscSharedSessionViewState,
    "Timeline range is collaborative view state over stable rrTicks.")
  entries.addEntry("TimelineVM", "hoveredTick", vscPresenceAwareness,
    "Hover is ephemeral participant awareness.")
  entries.addDerived("TimelineVM", ["currentPosition", "markers"])

  entries.addDerived("DebugControlsVM",
    ["canStepForward", "canStepBackward", "canContinue", "canReverseContinue",
     "isRunning", "statusText", "toolbarModeText", "recordingHeadText",
     "showRecordingHead", "showJumpToLive", "canJumpToLive",
     "degradedState", "replayUsable", "capabilityRung", "divergenceDetected",
     "traceTruncated"])
  # THE ONE MUTABLE SIGNAL THIS VM OWNS, and its own header says so. It is a
  # revision counter the host bumps whenever `shortcutFor` starts answering
  # differently — i.e. when a new `Config` is installed — so that tooltips
  # naming a chord re-render.
  #
  # Renderer-local because of what it invalidates: a key binding is a
  # participant's own preference, read out of THEIR `default_config.yaml` and
  # their overrides, and two people in one session are expected to have
  # different ones. Publishing the counter would re-render everyone's toolbar
  # to say nothing new, and publishing what it stands for would put one
  # participant's keyboard on another participant's screen. Same call as
  # `OriginChainVM.latestRequestId`: a local invalidation token, not a value.
  entries.addEntry("DebugControlsVM", "shortcutsRevision", vscRendererLocal,
    "Invalidation counter for this participant's own key bindings; the chords it stands for are a local preference.")

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

  entries.addMany("ScratchpadVM",
    ["entries", "localsByExpression", "chainEntries"],
    vscSharedSessionViewState,
    "Scratchpad/watch-like entries (including pinned origin-chain entries) are user-authored shared session state.")
  entries.addEntry("ScratchpadVM", "expandedPaths", vscSharedSessionViewState,
    "Which scratchpad rows are unfolded is user-authored intent over the same shared entry list.",
    requiresStableId = true,
    stableIdNote = "String value paths are not durable identities across backend snapshots; needs stable variable ids.")
  entries.addDerived("ScratchpadVM", ["isEmpty", "rowCount"])

  entries.addMany("ShellVM", ["inputBuffer", "scrollPosition", "historyIndex"],
    vscRendererLocal,
    "Terminal input, scroll, and history cursor are local interaction state.")
  entries.addEntry("ShellVM", "inputHistory", vscPresenceAwareness,
    "Command history is participant-local awareness, not replayable ViewState.")

  entries.addMany("SearchResultsVM", ["query", "active"],
    vscSharedSessionViewState,
    "Global search results panel query and visibility are shared view state. " &
    "There is no `filter` alongside them any more: the client-side " &
    "result-narrowing signal was retired with the Find in Files redesign, " &
    "which had already dropped the (never-wired) input that was meant to " &
    "drive it.")
  entries.addEntry("SearchResultsVM", "results", vscBackendAuthoritative,
    "Search result rows are backend/search service output.")
  entries.addEntry("SearchResultsVM", "loading", vscBackendAuthoritative,
    "In-flight flag for one search request; set on submit and cleared by the first batch of backend results.")
  entries.addEntry("SearchResultsVM", "recentSearches", vscPresenceAwareness,
    "A participant's own last ten queries, shown in this panel's empty " &
    "state. Same call as ShellVM.inputHistory: what one person typed is " &
    "theirs, not replayable session state, and publishing it would put " &
    "another participant's search history in front of everyone.")
  entries.addDerived("SearchResultsVM", ["resultCount", "fileCount"])

  entries.addMany("TestResultsVM", ["catalog", "summary", "projectName"],
    vscBackendAuthoritative,
    "What tests a project has and what a run of them said are facts about " &
    "the workspace and the runner, not about a participant. Everyone in a " &
    "session is looking at the same project and the same run.")
  entries.addEntry("TestResultsVM", "runAbsence", vscRendererLocal,
    "Why THIS renderer cannot start a run — a browser has no `nargo` and no " &
    "subprocess, a desktop host does. It is a statement about the local " &
    "platform, so publishing it would tell a desktop participant that their " &
    "own machine cannot run tests because someone else's tab cannot.")
  entries.addEntry("TestResultsVM", "runTests", vscRendererLocal,
    "WHICH runner this renderer was given, which is a fact about the host " &
    "and not about the project: the web arm installs " &
    "`web_noir_build.startNoirTests` and a desktop host installs its own. " &
    "Publishing it would hand one participant a closure that only means " &
    "anything inside another participant's process. Classified for the same " &
    "reason `runAbsence` is — the pair answers 'can a run start HERE'.")
  # The three row actions are `runTests` again, one per row affordance, and
  # they take their classification from it for the identical reason: each is a
  # `TestRowActionProc` the HOST installed, closing over that host's recorder,
  # its filesystem and its subprocess machinery. Handing one to another
  # participant would hand them a closure that only means anything inside the
  # process it was built in.
  entries.addMany("TestResultsVM",
    ["refreshRecording", "openExistingRecording", "recordAndOpenRecording"],
    vscRendererLocal,
    "Host-installed per-row action closures; like `runTests`, they only mean anything inside the process that installed them.")
  entries.addEntry("TestResultsVM", "recordings", vscBackendAuthoritative,
    "Which tests have a recording that can be entered is an artefact of the " &
    "workspace, not of a viewer — and it deliberately OUTLIVES the run that " &
    "made it, unlike `summary`. Everyone in a session is looking at the same " &
    "recordings on the same disk.")
  entries.addEntry("TestResultsVM", "inFlight", vscBackendAuthoritative,
    "A run this pane started is still going — the request-lifecycle half of " &
    "`summary`, covering the window before the worker emits `run-started` " &
    "and `summary.inProgress` can be true. Classified with the fact it " &
    "guards, the same call as `VCSVM.loadingMore` and `SearchResultsVM.loading`.")
  entries.addEntry("TestResultsVM", "shiftHeld", vscRendererLocal,
    "Whether Shift is down RIGHT NOW, driven by document-level keydown/keyup " &
    "so the tooltip and the button can change under a resting pointer. It is " &
    "a participant's own hand on their own keyboard; publishing it would " &
    "rewrite everyone's buttons when one person leaned on a modifier.")
  entries.addDerived("TestResultsVM",
    ["rows", "isEmpty", "headline", "runFailure"])

  entries.addMany("ConstraintsVM", ["report", "projectName"],
    vscBackendAuthoritative,
    "A circuit's opcode counts are a property of the sources everyone in " &
    "the session is looking at, produced by `nargo info` or shipped with " &
    "the bundled template.")
  entries.addDerived("ConstraintsVM",
    ["hasReport", "acirOpcodes", "unconstrainedOpcodes", "headline"])

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
  # NS4 anchoring. `anchors` is the mapping a PRODUCER emitted and `validate`
  # accepted; `anchorDefects` is why the last `setAnchors` was refused. Both
  # are answers about the artefact, identical for every participant looking at
  # the same build, so they follow `instructions` rather than merging.
  #
  # `anchorDefects` is kept as state rather than logged because §4 requires a
  # suspension to be VISIBLE — a pane silently showing no mapping cannot be
  # told from one whose producer is broken. That requirement is about every
  # viewer, which is the same reason it is backend-authoritative and not local.
  entries.addMany("LowLevelCodeVM", ["anchors", "anchorDefects"],
    vscBackendAuthoritative,
    "The installed producer mapping and the reason the last one was refused are facts about the artefact.")
  entries.addEntry("LowLevelCodeVM", "syncSettings", vscSharedSessionViewState,
    "Whether this pane follows the source caret is a logical view preference, the same class as EditorVM's overlay toggles.")
  entries.addDerived("LowLevelCodeVM",
    ["isEmpty", "hasAnchors", "anchorsRejected"])

  # Generated-Code-Listing.md. The sibling of LowLevelCodeVM one abstraction
  # up: a producer's listing for a target, plus the source caret it follows.
  # The split below is exactly that sentence — the listing is a fact, the
  # caret is a person.
  entries.addMany("GeneratedCodeVM",
    ["state", "targetId", "targetName", "producer", "listingPath", "rows",
     "revision", "anchors", "listingAbsence", "failure", "stale"],
    vscBackendAuthoritative,
    "The opened listing and everything describing it — producer, target, rows, anchors, revision, the two distinct empty answers (§8) and whether it has since gone stale — are a producer's output for a build every participant shares.")
  # `revision` is in that list rather than treated as bookkeeping on purpose:
  # its whole contract is that it increments ONLY when the rows are replaced
  # and a cursor move leaves it alone, which is to say it is a property of the
  # listing and not of the reading. That is also why it must not merge — two
  # peers counting their own re-anchorings would produce a number that means
  # nothing on either side.
  entries.addEntry("GeneratedCodeVM", "activeTabPath",
    vscSharedSessionViewState,
    "Which source file the pane is describing — the same shared pane intent " &
    "as `EditorVM.activeTabIndex`, and already a path rather than an index, " &
    "so unlike that field it is not stable-id blocked.")
  entries.addEntry("GeneratedCodeVM", "cursorLine", vscPresenceAwareness,
    "The mirrored source caret this pane follows (`syncFromSource`). It is " &
    "`EditorVM.cursorLine` observed from one pane over, so it carries the " &
    "same classification: a caret is per-participant awareness, and syncing " &
    "it as view state would drag every collaborator's listing to wherever " &
    "the last person clicked.")
  entries.addEntry("GeneratedCodeVM", "syncEnabled", vscSharedSessionViewState,
    "Whether the listing follows the caret at all is a logical view preference, the same class as `LowLevelCodeVM.syncSettings`.")
  entries.addDerived("GeneratedCodeVM",
    ["isOpen", "describesActiveTab", "focus", "focusRows",
     "instantiationCount", "focusText", "tabTitle", "producerLine"])

  # -------------------------------------------------------------------------
  # `SourceVM` — CLASSIFIED BY PLAT-33, 2026-09-20. THE WHOLE TYPE WAS ABSENT.
  # -------------------------------------------------------------------------
  # Eighteen of the thirty-two unclassified fields were this one ViewModel,
  # which had never had a row. It is worth classifying carefully rather than
  # by bulk because it is the pane a shared editing session is ABOUT, and
  # PLAT-34 will bind it to `editor/`.
  #
  # **THE VIEWPORT IS RENDERER-LOCAL AND THE HELD WINDOW IS NOT**, and that
  # split is the interesting one. `EditorVM.scrollTop` is already classified
  # renderer-local — two participants with different window heights must be
  # able to look at different parts of one file, which is the whole reason
  # follow-the-driver is a separate, opt-in feature rather than the default.
  # What the pane has FETCHED, on the other hand, is a set of backend answers
  # about the recording's source, and it is cached in signals rather than
  # memos only because a projection cannot perform a request.
  entries.addMany("SourceVM", ["viewportHeight", "overscan", "viewportTop"],
    vscRendererLocal,
    "Where this participant is looking and how much they render around it; the same call as `EditorVM.scrollTop`, and the reason follow-the-driver is opt-in.")
  entries.addMany("SourceVM",
    ["heldFirstLine", "heldLines", "heldRevision", "totalLineCount",
     "pendingRequests"],
    vscBackendAuthoritative,
    "The fetched source window, the revision it was fetched at, the file's extent and the requests still in flight: backend answers, cached in signals because a projection cannot issue a request.")
  entries.addDerived("SourceVM",
    ["revision", "executionLine", "path", "sourceGeneration", "sourceDigest",
     "visibleFirstLine", "visibleLastLine", "windowFirstLine", "windowLastLine",
     "degradedState"])

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

  # VN-M3/M4. BuildVM's shape, one verifier over: a long-running tool is
  # launched against the project and everything this VM holds is that tool's
  # report on it. Nothing here is authored by a participant — there is no
  # filter, no selection, no toggle — so the whole mutable surface is a single
  # backend-authoritative block rather than a split.
  #
  # `commandLine` and `projectRoot` are in it for the same reason `BuildVM`'s
  # `command` is: they describe the invocation that produced the report, and a
  # peer that substituted its own would be labelling someone else's results
  # with its own paths. `elapsedMs`/`outputLineCount`/`lastOutputLine` are the
  # progress the run itself reported; the header note on `lastOutputLine` —
  # that Verno is not chatty, so it is often stale and `elapsedMs` is shown
  # BESIDE it rather than instead of it — is exactly why the two must travel
  # together from the owning peer and never be recomputed locally.
  #
  # The four payload fields are VN-M4's structured tier. `payloadStatus` is a
  # verdict about an artifact (found / refused / believed), `payloadProblems`
  # is why a refusal happened and `payloadNotes` is where an accepted payload
  # disagreed with the text tier. All three are answers about the artifact, so
  # every participant is entitled to the same one.
  entries.addMany("VerificationVM",
    ["phase", "actionId", "actionLabel", "commandLine", "projectRoot",
     "elapsedMs", "outputLineCount", "lastOutputLine", "startFailure",
     "report", "payloadStatus", "payload", "payloadProblems", "payloadNotes"],
    vscBackendAuthoritative,
    "A verification run's invocation, progress, outcome and structured payload are the verifier's report on the shared project.")
  entries.addDerived("VerificationVM",
    ["isRunning", "isCancellable", "hasReport", "statusText", "outcomeText",
     "markers", "findingCount", "failedObligationCount", "limitationCount"])

  # VN-M5. One OPEN counterexample, and its identity is the finding it came
  # from — so unlike the VM above, this one does carry participant intent, and
  # the block splits along that line.
  entries.addMany("CounterexampleSessionVM", ["isOpen", "findingId"],
    vscSharedSessionViewState,
    "Whether a counterexample is open and which obligation's it is: the " &
    "affordance is 'open THIS finding's counterexample', which is shared " &
    "session intent over an id the solver already made stable.")
  entries.addMany("CounterexampleSessionVM", ["trace", "refusalReason"],
    vscBackendAuthoritative,
    "The solver's model, and why the last open declined to show one. Both " &
    "are functions of the payload rather than of the click: two participants " &
    "opening the same finding get the same answer, which is what makes the " &
    "refusal worth storing (`CounterexampleIsOfferedOnlyWhenSteppable`) " &
    "instead of leaving a button that does nothing and says nothing.")
  entries.addEntry("CounterexampleSessionVM", "currentStep",
    vscSharedSessionViewState,
    "Where in the counterexample the session is standing — stepping through " &
    "it together is the point of opening it.",
    requiresStableId = true,
    stableIdNote = "An index into `steps`, which is a projection of `trace`. It means nothing against a different solver run, so sharing it needs a step identity that names the trace it belongs to.")
  entries.addDerived("CounterexampleSessionVM",
    ["steps", "loops", "stepCount", "canStepForward", "canStepBackward",
     "violationStep", "currentLoop", "currentIteration"])

  entries.addEntry("ErrorsVM", "problems", vscBackendAuthoritative,
    "Problem rows are produced by build/diagnostic services.")
  entries.addMany("ErrorsVM", ["filter", "groupByFile"],
    vscSharedSessionViewState,
    "Problem filter/grouping are logical view state.")
  entries.addEntry("ErrorsVM", "selectedIndex", vscSharedSessionViewState,
    "Which diagnostic the pane is sitting on is shared session intent, the same class as `TraceLogVM.selectedIndex`.",
    requiresStableId = true,
    stableIdNote = "An index into `problems`, and this pane already knows that is not an identity: `visibleRefs` exists because two diagnostics on the same line of the same file are equal by value and must still be distinguishable. Needs a stable diagnostic id.")
  # EMT-D22.2's "the wrap is announced", made observable. `gotoError` writes
  # the sentence its own key press produced ("wrapped to the first error") and
  # the pane header paints it, because this repo has no status bar to put it
  # in. It is one participant's navigation feedback about one participant's
  # key press — publishing it would announce someone else's wrap to everybody,
  # and the selection it accompanies is already shared above.
  entries.addEntry("ErrorsVM", "statusMessage", vscRendererLocal,
    "The last thing THIS participant's error navigation announced; ephemeral local feedback, not session state.")
  entries.addDerived("ErrorsVM",
    ["visibleProblems", "errorCount", "warningCount", "totalCount",
     "visibleRefs"])

  entries.addMany("CommandPaletteVM",
    ["isActive", "inputValue", "inputPlaceholder", "mode", "query",
     "results", "selectedIndex", "activeCommandName"],
    vscRendererLocal,
    "Command palette state is local transient UI interaction.")
  entries.addDerived("CommandPaletteVM", ["hasResults", "resultCount"])

  entries.addMany("WelcomeScreenVM",
    ["recentTraces", "recentFolders", "startOptions", "startOptionsNote",
     "hoveredRecording",
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
  entries.addEntry("RequestPanelVM", "detailTab", vscSharedSessionViewState,
    "Which detail tab the selected request is being read through — the same " &
    "kind of shared pane intent as StateVM.activeTab, and already a stable " &
    "tab name rather than an index.")
  entries.addDerived("RequestPanelVM", ["filteredRequests"])

  entries.addMany("ReplVM", ["history", "replEnabled", "materialized",
      "langName"],
    vscBackendAuthoritative,
    "REPL history/status reflects backend/materialization capability and output.")
  entries.addDerived("ReplVM", ["displayMode"])

  entries.addMany("VCSVM",
    ["deepReviewMode", "headerTitle", "headerIcon", "statsText",
     "traceContexts", "isGitRepo",
     "errorMessage", "currentBranch", "branches", "commits", "changedFiles",
     "diffFiles"],
    vscBackendAuthoritative,
    "VCS rows/status are local repository facts.")
  entries.addEntry("VCSVM", "selectedTraceContextId", vscRendererLocal,
    "Review trace-context selection is outside replay session sync.",
    requiresStableId = true,
    stableIdNote = "Would need stable trace-context id if synchronized.")
  entries.addMany("VCSVM", ["branchDropdownOpen", "unifiedDiffActive",
                            "hunkToolbarVisible", "hunkCopyFeedback"],
    vscRendererLocal,
    "Dropdowns and copy feedback are local UI state.")
  # `selectedCommitIndex` became `selectedCommitIndices` when the commit
  # accordion gained ctrl/shift multi-select; the classification is unchanged,
  # for the reason the whole VCS panel is renderer-local — it describes the
  # *local* repository checkout, which is not the object a replay session is
  # shared over and need not even be the same tree on another participant's
  # machine.
  entries.addEntry("VCSVM", "selectedCommitIndices", vscRendererLocal,
    "Expanded/selected commit rows are a view of the local repository, outside replay session sync.",
    requiresStableId = true,
    stableIdNote = "Currently commit row indices; would need commit hashes if synchronized.")
  entries.addEntry("VCSVM", "lastClickedIndex", vscRendererLocal,
    "Shift-click anchor for commit range selection; a local pointer gesture.",
    requiresStableId = true,
    stableIdNote = "Currently a commit row index; would need a commit hash if synchronized.")
  entries.addEntry("VCSVM", "commitFilesMap", vscBackendAuthoritative,
    "Per-commit file rows read from the local repository, alongside `commits` and `changedFiles`.")
  entries.addEntry("VCSVM", "loadingMore", vscBackendAuthoritative,
    "In-flight flag for the next commit page; a request-lifecycle fact of the fetch it guards.")
  entries.addEntry("VCSVM", "viewMode", vscRendererLocal,
    "What a file click opens in *this* panel instance (`vcs.defaultView`). " &
    "It never changes what the panel renders, and the docked panel and a " &
    "diff tab of the same session deliberately hold different values, so it " &
    "is per-panel local behaviour rather than session intent.")
  entries.addEntry("VCSVM", "selectedHunks", vscRendererLocal,
    "Hunk selection uses local diff coordinates.",
    requiresStableId = true,
    stableIdNote = "Would need stable diff hunk ids if synchronized.")
  entries.addEntry("VCSVM", "reviewCommit", vscBackendAuthoritative,
    "The commit a review's changeset belongs to is a fact of the dataset.")
  entries.addEntry("VCSVM", "reviewEntered", vscRendererLocal,
    "Whether this panel already ran review entry; a local one-shot that " &
    "keeps re-entry from re-opening tabs or re-focusing panels.")
  entries.addEntry("VCSVM", "lastHunkClickOrdinal", vscRendererLocal,
    "Shift-click anchor for hunk range selection; a local pointer gesture.",
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
    ["rootEntry", "diffEntries"],
    vscBackendAuthoritative,
    "Filesystem tree/diff contents are local repository facts.")
  entries.addEntry("FilesystemVM", "loadingState", vscBackendAuthoritative,
    "Tree/diff load status belongs to the index-process request that fills `rootEntry`.")
  entries.addEntry("FilesystemVM", "expandedPaths", vscSharedSessionViewState,
    "Filesystem expansion can be shared as logical path state.",
    requiresStableId = true,
    stableIdNote = "Paths may be enough for files, but virtual nodes need stable ids.")
  entries.addDerived("FilesystemVM", ["isEmpty", "hasDiff", "totalEntryCount"])

  entries.addMany("AgentActivityVM",
    ["messages", "terminals", "isLoading", "reRecordInProgress",
     "wantsPassword", "wantsPermission", "sessionKey"],
    vscBackendAuthoritative,
    "Agent activity stream/session status is service-owned.")
  # AA-2/AA-3. `testRuns` and `evidenceCalls` are re-derived from `messages`
  # on every `setMessages`, and `evidenceDatasets` is what the host found out
  # by reading each dataset path. All three are signals rather than memos
  # because a projection cannot read a file and the dataset answers have to
  # survive a re-sync — but none of them is user intent, so they follow
  # `messages` and stream from the peer that owns the session.
  entries.addMany("AgentActivityVM",
    ["testRuns", "evidenceCalls", "evidenceDatasets"],
    vscBackendAuthoritative,
    "Test-run and evidence projections of the session feed, plus the host's answers about each dataset path.")
  entries.addEntry("AgentActivityVM", "sessionNotice", vscBackendAuthoritative,
    "RV-6 — why this panel is showing the conversation it is showing; the " &
    "outcome of the session load, stated by whoever performed it.")
  # §2.1.2 "the summary is drillable": which cards a reviewer has opened is
  # ordinary shared expansion intent, the same class as the calltrace and
  # state-pane expansion sets. Both are already keyed by identities that do
  # not drift — a run by the id of the message it anchors to, a test row by
  # `expansionKey(anchorId, testId)` — so neither is stable-id blocked.
  entries.addMany("AgentActivityVM", ["expandedTestRuns", "expandedTests"],
    vscSharedSessionViewState,
    "Drilled-open test-run and test rows are shared review intent, keyed by agent message anchor ids.")
  entries.addEntry("AgentActivityVM", "inputValue", vscRendererLocal,
    "Prompt draft is local typing state.")
  # The toolbar's three session facts, set by the host rather than typed by a
  # user: which model this agent session is running (`setSelectedModel`), the
  # branch it is working on, and the branches its repository offers for
  # checkout. All three answer "what is this session doing", which is the same
  # question `sessionKey` and `messages` answer, so they stream from the peer
  # that owns the session. `permissionInfo` joins them because it is the
  # DETAIL of the prompt `wantsPermission` announces, and that flag is already
  # classified backend-authoritative directly above.
  entries.addMany("AgentActivityVM",
    ["selectedModel", "currentBranch", "branches", "permissionInfo"],
    vscBackendAuthoritative,
    "Active model, working branch, available branches and the pending permission prompt's detail are agent-session facts the host reports.")
  entries.addEntry("AgentActivityVM", "branchDropdownOpen", vscRendererLocal,
    "Whether the branch selector is open; the same call as `VCSVM.branchDropdownOpen` — a dropdown is local UI state.")
  # -------------------------------------------------------------------------
  # CLASSIFIED BY PLAT-33, 2026-09-20, WITH THE COUNT RE-MEASURED
  # -------------------------------------------------------------------------
  # `vm-collab-units` was red on this table for having drifted behind the
  # ViewModels, and the justfile recorded the drift as "30 unclassified, 1
  # stale". Re-measured by running the suite: **32 unclassified and 0 stale**.
  # The stale row had already been dealt with by whoever last touched the
  # ViewModel; the two the figure was short of are `AgentActivityVM.
  # settingsActiveDropdown` and `EventLogStore.windowSource`. A number in a
  # comment that nothing re-takes is a number that drifts alongside the thing
  # it describes, which is the defect this registry exists to prevent, one
  # level up.
  #
  # The three dropdown flags follow `branchDropdownOpen` directly above: a
  # dropdown is local UI state, and there is no reading of a shared session in
  # which one participant's open menu belongs on another's screen.
  entries.addMany("AgentActivityVM",
    ["modelDropdownOpen", "addContextDropdownOpen", "settingsActiveDropdown"],
    vscRendererLocal,
    "Which selector menu is open; the same call as `branchDropdownOpen` — a dropdown is local UI state.")
  # The composition draft follows `inputValue`, which is already classified
  # renderer-local as "prompt draft is local typing state". These are the rest
  # of the same draft: both are CLEARED on submit, and what survives the
  # submit is a session fact the host reports back through `messages`.
  entries.addMany("AgentActivityVM", ["pastedImages", "contextPaths"],
    vscRendererLocal,
    "Images pasted and context paths added for the next prompt; the rest of `inputValue`'s draft, cleared on submit.")
  # The settings form is the same argument once more, and it is worth stating
  # because the instinct is to call a runtime budget "shared": these nine
  # fields are an UNSUBMITTED form. The moment they are submitted the session
  # they configure reports its own runtime through the backend-authoritative
  # fields above, so sharing the draft as well would give two sources for one
  # fact — and the draft is the one that is wrong between the edit and the
  # submit.
  entries.addEntry("AgentActivityVM", "settingsOpen", vscRendererLocal,
    "Whether the settings panel is expanded; local UI disclosure, like the dropdowns above.")
  entries.addMany("AgentActivityVM",
    ["settingsRuntime", "settingsCpu", "settingsMemory", "settingsNetworkAccess",
     "settingsDeliveryMode", "settingsDeliveryBranch", "settingsPermissions"],
    vscRendererLocal,
    "The agent-session settings form before it is submitted; a draft, like `inputValue`. What the session actually runs with is reported back as a backend fact.")
  entries.addDerived("AgentActivityVM",
    ["messageCount", "terminalCount", "hasMessages", "hasSessionNotice",
     "testRunCount", "evidenceCallCount"])

  entries.addMany("AgentWorkspaceVM",
    ["viewKind", "workspacePath", "sessionId", "summary", "files",
     "notificationCount"],
    vscBackendAuthoritative,
    "Agent workspace content/session metadata is service-owned.")
  entries.addEntry("AgentWorkspaceVM", "selectedFileIndex", vscRendererLocal,
    "Workspace file selection uses an index and is local.",
    requiresStableId = true,
    stableIdNote = "Would need stable workspace file id if synchronized.")
  entries.addEntry("AgentWorkspaceVM", "coverageOverlayEnabled",
    vscRendererLocal,
    "Coverage overlay toggle is local UI state.")
  entries.addDerived("AgentWorkspaceVM",
    ["fileCount", "hasWorkspace", "selectedFile", "selectedCoverageText"])

  entries.addMany("AgenticSessionVM",
    ["workspaceMode", "activeEditorPath", "activeEditorContent",
     "userEditorSnapshot", "agentEditorSnapshot"],
    vscRendererLocal,
    "Agent workspace projection and editor snapshots are local UI coordination state.")
  entries.addMany("AgenticSessionVM", ["activeTabId", "activeCaption"],
    vscDerivedNonSignal,
    "Memo/computed field; recomputed locally from agent session store state.")

  entries.addMany("FrameViewerVM",
    ["visualReplayAvailable", "playerUrl", "currentGeid", "currentFrame",
     "frameCount", "frameImageSrc", "frameWidth", "frameHeight", "loading",
     "error", "drawCalls", "clearFrames", "medianFetchMs"],
    vscBackendAuthoritative,
    "Frame-viewer frame data is visual replay backend output.")
  entries.addEntry("FrameViewerVM", "selectedPixel", vscSharedSessionViewState,
    "Pixel selection can be shared once tied to a stable frame.",
    requiresStableId = true,
    stableIdNote = "Needs stable frame/geid plus pixel coordinate identity.")
  entries.addEntry("FrameViewerVM", "selectedDrawCall",
    vscSharedSessionViewState,
    "Draw-call selection can be shared once draw calls have stable ids.",
    requiresStableId = true,
    stableIdNote = "Current field is an index; needs stable draw-call id.")

  entries.addMany("VideoPlayerVM",
    ["playState", "direction", "rate", "pickerState", "magnifier",
     "magnifierCenterColor", "bufferingDegraded"],
    vscRendererLocal,
    "Video playback controls, picker state, loupe sampling, and buffering hints are local visual-replay UI state.")

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

  entries.addEntry("ShaderDebugVM", "selectedContext",
    vscSharedSessionViewState,
    "Shader debug context selection is logical visual replay state.",
    requiresStableId = true,
    stableIdNote = "Needs stable draw/shader invocation identity.")
  entries.addMany("ShaderDebugVM", ["debugInfo", "loading", "error"],
    vscBackendAuthoritative,
    "Shader debug payload/status are backend output.")
  entries.addEntry("ShaderDebugVM", "currentStepIndex",
    vscSharedSessionViewState,
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

# ---------------------------------------------------------------------------
# Source scanning
#
# The inventory below is read out of the ViewModel sources with a small token
# scanner rather than by matching formatting literals.  THAT DISTINCTION IS THE
# WHOLE POINT OF THE GATE: an exported mutable `Signal` that this scanner does
# not see is a field with no declared replication behaviour that `validateRegistry`
# never gets the chance to refuse.  A scanner keyed on a literal is only
# fail-closed against the formatting that happens to be dominant today.
#
# Concretely, the previous implementation searched for the literal `"*:"` and
# for `"* ="`, so all of these legal Nim spellings were INVISIBLE to it, each
# one silently admitting an unclassified field:
#
#   probeSpaced* : Signal[int]          # space before the colon
#   fromMode*, toMode*: Signal[int]     # only the LAST name was recovered, and
#                                       # then as the bogus name "fromMode*, toMode"
#   tagged* {.used.}: Signal[int]       # a pragma between the `*` and the `:`
#   SomeVM*= ref object                 # no space around `=`; the whole type,
#                                       # and therefore EVERY field in it, vanished
#   SomeVM*[T] = ref object             # a generic owner, same consequence
#
# Two more were found by probing the replacement rather than the predecessor,
# and they are recorded here because a tolerant scanner earns its keep only if
# its OWN blind spots have been looked for:
#
#   type SomeVM* = object               # the object on the section keyword's
#                                       # line — `viewmodels/edit_mode_toolbar
#                                       # .nim` and `viewmodels/
#                                       # verification_report.nim` both do this
#   `type`*: Signal[int]                # a stropped field name
#
# The scanner walks each line once, tracking bracket depth and string/char
# literals, and answers three questions: where the code ends (i.e. where a `#`
# comment begins), where the top-level `:` is, and where the top-level `=` is.
# Both the owner parser and the field parser are expressed in terms of it, so
# there is one place that knows how to read a Nim declaration.
# ---------------------------------------------------------------------------

const
  identChars = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}

type
  DeclScan = object
    ## Structural landmarks of a single source line.
    indent: int    ## number of leading whitespace characters
    codeEnd: int   ## index one past the last code character (comment stripped)
    colon: int     ## index of the `:` at bracket depth 0, or -1
    assign: int    ## index of the `=` at bracket depth 0, or -1

proc scanDecl(line: string): DeclScan =
  ## Locate the top-level `:` and `=` of `line`, ignoring anything inside
  ## brackets, string literals, char literals or a trailing comment.
  ##
  ## Bracket depth matters because a type is full of colons that are not the
  ## field separator (`Table[string, int]`, `proc (x: int)`), and because a
  ## pragma is spelled `{.foo: bar.}`.  Comments matter because a commented-out
  ## declaration must not be inventoried as a live one.
  result = DeclScan(indent: 0, codeEnd: line.len, colon: -1, assign: -1)
  while result.indent < line.len and line[result.indent] in {' ', '\t'}:
    inc result.indent

  var depth = 0
  var i = result.indent
  while i < line.len:
    let c = line[i]
    case c
    of '#':
      # Both `#` and `##` end the code portion of the line.
      result.codeEnd = i
      break
    of '"':
      # Skip a string literal, honouring backslash escapes.  A triple-quoted
      # string is not special-cased: it would have to open and close on the
      # same line to matter here, and then this loop handles it as three
      # empty/one-character strings, which leaves `depth` and the landmarks
      # untouched.
      inc i
      while i < line.len and line[i] != '"':
        if line[i] == '\\':
          inc i
        inc i
    of '\'':
      # A char literal — but ONLY when the apostrophe does not directly follow
      # an identifier character, which is Nim's own rule for distinguishing
      # `'a'` from the custom-numeric-literal suffix in `1'i64`.
      if i > result.indent and line[i - 1] in identChars:
        discard
      else:
        inc i
        while i < line.len and line[i] != '\'':
          if line[i] == '\\':
            inc i
          inc i
    of '(', '[', '{':
      inc depth
    of ')', ']', '}':
      if depth > 0:
        dec depth
    of ':':
      if depth == 0 and result.colon < 0:
        result.colon = i
    of '=':
      # `==`, `<=`, `>=`, `!=` and `=>` are comparisons/lambdas, not the
      # definition operator that introduces an object body.
      if depth == 0 and result.assign < 0 and
          (i + 1 >= line.len or line[i + 1] != '=') and
          (i == 0 or line[i - 1] notin {'=', '<', '>', '!'}):
        result.assign = i
    else:
      discard
    inc i

  if result.codeEnd > line.len:
    result.codeEnd = line.len

proc splitTopLevel(s: string; sep: char): seq[string] =
  ## Split `s` on `sep` at bracket depth 0, so a pragma such as `{.a, b.}` is
  ## not mistaken for two names in a comma-separated declaration.
  var depth = 0
  var start = 0
  for i, c in s:
    case c
    of '(', '[', '{': inc depth
    of ')', ']', '}': (if depth > 0: dec depth)
    else:
      if c == sep and depth == 0:
        result.add(s[start ..< i])
        start = i + 1
  result.add(s[start .. ^1])

proc parseExportedName(spec: string): string =
  ## The exported identifier declared by `spec`, or `""` when `spec` does not
  ## declare exactly one exported name.
  ##
  ## Accepts `name*`, `name *`, `name*[T]`, `name* {.pragma.}` and the stropped
  ## spelling `` `name`* ``; rejects anything that is not an identifier followed
  ## by the export marker, which is what keeps a `proc` signature or a `case`
  ## discriminator out of the field inventory.
  var i = 0
  while i < spec.len and spec[i] in {' ', '\t'}:
    inc i

  var name: string
  if i < spec.len and spec[i] == '`':
    # A STROPPED identifier: `` `type`*: Signal[int] ``.  Nim spells a field
    # whose name collides with a keyword this way, and the declared name is the
    # text BETWEEN the backticks.  Reading it matters because a field this
    # scanner cannot name is a field `validateRegistry` is never asked about —
    # the fail-OPEN direction, which is the one that costs something.
    let quoteStart = i + 1
    inc i
    while i < spec.len and spec[i] != '`':
      inc i
    if i >= spec.len:
      return ""  # unterminated on this line; not a declaration we can read
    name = spec[quoteStart ..< i]
    if name.len == 0:
      return ""
    inc i  # step past the closing backtick
  else:
    let nameStart = i
    while i < spec.len and spec[i] in identChars:
      inc i
    if i == nameStart:
      return ""
    name = spec[nameStart ..< i]

  while i < spec.len and spec[i] in {' ', '\t'}:
    inc i
  if i >= spec.len or spec[i] != '*':
    return ""
  name

proc dropLeadingTypeKeyword(lhs: string): string =
  ## `lhs` without a leading `type` SECTION KEYWORD.
  ##
  ## `type Foo* = ref object` puts the object on the same line as the keyword,
  ## and that is ordinary Nim rather than an exotic spelling: the ViewModel tree
  ## itself writes `type RunPlan* = object` (`viewmodels/edit_mode_toolbar.nim`)
  ## and `type ParsedDiagnostic* = object` (`viewmodels/verification_report.nim`)
  ## for one-off records.  Left unconsumed, the keyword is read as the type's
  ## name, no owner is recognised, and EVERY field in such a type drops out of
  ## the inventory unseen — so the day somebody adds a `Signal` to one of them,
  ## the gate passes it.  A field the scanner cannot see is the one failure this
  ## module has no second chance at.
  ##
  ## Only the keyword is consumed, never an identifier that merely starts with
  ## it: `typeName* = object` declares a type called `typeName`.
  let stripped = lhs.strip(leading = true, trailing = false)
  if not stripped.startsWith("type"):
    return lhs
  if stripped.len == "type".len or stripped["type".len] notin {' ', '\t'}:
    return lhs
  stripped["type".len .. ^1]

proc parseObjectOwner(line: string): string =
  ## The name of the object type declared on `line`, or `""`.
  let scan = scanDecl(line)
  if scan.assign < 0 or scan.colon >= 0:
    return ""
  var rhs = line[scan.assign + 1 ..< scan.codeEnd].strip
  if rhs.startsWith("ref "):
    rhs = rhs[4 .. ^1].strip
  # `object`, `object of Base`, `object {.pragma.}` — but not `objectish`.
  if not rhs.startsWith("object"):
    return ""
  if rhs.len > "object".len and rhs["object".len] in identChars:
    return ""
  parseExportedName(dropLeadingTypeKeyword(line[0 ..< scan.assign]))

proc parseFields(line: string; owner, sourceFile: string; lineNo: int):
    seq[ViewModelField] =
  ## Every exported `Signal`/`Memo` field declared on `line`.
  ##
  ## A sequence rather than a single field because `a*, b*: Signal[int]` is one
  ## line and two fields; the literal-matching predecessor recovered neither of
  ## them correctly.
  let scan = scanDecl(line)
  if scan.colon < 0 or scan.colon >= scan.codeEnd:
    return

  let typeExpr = line[scan.colon + 1 ..< scan.codeEnd].strip
  let kind =
    if typeExpr.startsWith("Signal["): vfkSignal
    elif typeExpr.startsWith("Memo["): vfkMemo
    else: return

  for spec in splitTopLevel(line[scan.indent ..< scan.colon], ','):
    let name = parseExportedName(spec)
    if name.len > 0:
      result.add(ViewModelField(owner: owner, field: name, kind: kind,
        typeExpr: typeExpr, sourceFile: sourceFile, line: lineNo))

proc discoverViewModelFields*(sourceRoot = "src/frontend/viewmodel"):
    seq[ViewModelField] =
  for file in viewModelSourceFiles(sourceRoot):
    if not fileExists(file):
      continue
    var owner = ""
    var ownerIndent = 0
    var lineNo = 0
    for line in lines(file):
      inc lineNo
      let parsedOwner = parseObjectOwner(line)
      if parsedOwner.len > 0:
        owner = parsedOwner
        ownerIndent = scanDecl(line).indent
        continue
      if owner.len == 0:
        continue
      # A field belongs to the object only while the source is still INDENTED
      # under its declaration.  Without this the scanner would go on attributing
      # everything below the `type` section — `proc` signatures, `let` bindings —
      # to the last object it saw, which is exactly the false-positive risk that
      # a tolerant parser takes on and a literal-matching one avoided by
      # accident.
      let scan = scanDecl(line)
      if scan.indent >= scan.codeEnd:
        continue  # blank or comment-only: says nothing about the body's extent
      if scan.indent <= ownerIndent:
        owner = ""
        continue
      result.add(parseFields(line, owner, file, lineNo))
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
