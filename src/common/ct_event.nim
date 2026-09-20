type
  CtEventKind* = enum
    CtUpdateTable,
    CtUpdatedTable,
    CtUpdateTableResponse
    CtSubscribe,
    CtLoadLocals,
    CtLoadLocalsResponse,
    CtUpdatedCalltrace,
    CtLoadCalltraceSection,
    CtCompleteMove,
    DapStopped,
    DapInitialized,
    DapInitialize,
    DapInitializeResponse,
    DapConfigurationDone,
    DapConfigurationDoneResponse,
    DapLaunch,
    DapLaunchResponse,
    DapOutput,
    DapStepIn,
    DapStepInResponse,
    DapStepOut,
    DapStepOutResponse,
    DapNext,
    DapNextResponse,
    DapContinue,
    DapContinueResponse,
    DapStepBack,
    DapStepBackResponse,
    DapReverseContinue,
    DapReverseContinueResponse,
    DapSetBreakpoints,
    CtReverseStepIn,
    CtReverseStepInResponse,
    CtReverseStepOut,
    CtReverseStepOutResponse,
    CtEventLoad,
    CtUpdatedEvents,
    CtUpdatedEventsContent,
    CtLoadTerminal,
    CtLoadedTerminal,
    CtCollapseCalls,
    CtExpandCalls,
    CtCalltraceJump,
    CtEventJump,
    CtLoadHistory,
    CtUpdatedHistory,
    CtHistoryJump,
    CtSearchCalltrace,
    CtCalltraceSearchResponse,
    CtSourceLineJump,
    CtSourceCallJump,
    CtLocalStepJump,
    CtTracepointToggle,
    CtTracepointDelete,
    CtTraceJump,
    CtUpdatedTrace,
    CtLoadFlow,
    CtUpdatedFlow,
    CtRunToEntry,
    CtRunTracepoints,
    CtRunTraceSession,
    CtSetupTraceSession,
    CtLoadAsmFunction,
    CtLoadAsmFunctionResponse,
    CtUpdateExpansion,
    CtUpdateExpansionResponse,
    InternalLastCompleteMove,
    InternalAddToScratchpad,
    InternalAddToScratchpadFromExpression,
    InternalStatusUpdate,
    InternalNewOperation,
    InternalTraceMapUpdate,
    CtNotification,
    TracepointLocals,
    CtTracepointResults,
    CtFlowJump,
    CtTimelineSeek,
    CtShellEval,
    CtMcrGetRecordingHead,
    CtMcrRestoreAt,
    CtLiveRestoreAt,
    CtMcrLiveStep,
    CtSeekToGeid,
    # Value Origin Tracking (M2). See
    # codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md §5.2.
    CtUpdatedOriginChain,
    # Value Origin Tracking (M4) — frontend-initiated requests
    # (spec §5.3 / §5.3.2). Listed here so the Karax / IsoNim event
    # router can dispatch them through the same DapApi pipeline as
    # every other ct/* command.
    CtOriginChain,
    CtOriginChainResponse,
    CtOriginSummary,
    CtOriginSummaryResponse,
    # Column-Aware Replay Navigation (M3) — frontend-initiated requests
    # that toggle the formatted-view step-over runner.  See
    # codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
    CtSetActiveSourceView,
    CtSetActiveSourceViewResponse,
    CtInstallSourceView,
    CtInstallSourceViewResponse,
    # Request Panel live sessions (RS-M3). ``CtLoadRequestSpansSince`` is the
    # frontend-initiated poll that carries the opaque cursor; the backend
    # answers with a delta body AND emits ``CtUpdatedHttpRequests`` carrying an
    # identically-shaped body so a panel that never polls still grows.  See
    # codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org
    # §RS-M3 and codetracer-specs/GUI/Core-Panes/Request-Panel.md.
    CtLoadRequestSpansSince,
    CtUpdatedHttpRequests,
    # Multi-process sessions (M29 §5.2 / M42 §14.8). `ct/listProcesses`
    # is unusual in that the backend speaks it in BOTH directions: as a
    # request the frontend may issue, and as an unsolicited event
    # dispatched once per session load
    # (`db-backend/src/dap_server.rs::dispatch_session_load_event`).
    # Both carry the same body shape, so both route to this kind and
    # `SessionViewModel.applyListProcessesResponse` decodes either.
    CtListProcesses,
    CtListProcessesResponse,
    # M25b §5.3 / M49 — Event Log correlation-marker counterpart lookup.
    # The boundary chip's jump resolves a marker's counterpart through
    # this request; without a kind here `dapCommandToEventKind` raises
    # and the request is never written to the wire, so the click
    # resolved nothing and rotated nothing.
    CtPairIndexLookup,
    CtPairIndexLookupResponse,
    # M25b §5.3 / M49 — seek the active recording's timeline to a
    # marker firing's step. `EventLogVM.jumpToCounterpart` has always
    # named this command; it had no kind, so the send raised and the
    # jump landed wherever the process switch happened to leave the
    # cursor instead of on the correlated step.
    CtGotoTicks,

func commandToCtResponseEventKind*(command: string): CtEventKind =
  ## The `CtEventKind` a DAP **response** bearing `command` fans out as.
  ##
  ## This is the fourth of the four command tables, and until #690 it was the
  ## only one nothing checked. The other three are
  ## `EVENT_KIND_TO_DAP_MAPPING` (`src/frontend/dap.nim`), `VALID_DAP_COMMANDS`
  ## (`src/frontend/viewmodel/backend/dap_commands.nim`) and the engine's own
  ## dispatch (`src/db-backend/src/dap_server.rs`);
  ## `ci/test/dap-command-sync.py` now reconciles all four.
  ##
  ## It lives here, next to the enum it returns, rather than in `dap.nim`, for
  ## two reasons. It needs nothing from the JS FFI — it is a pure string-to-enum
  ## map — and `dap.nim` imports `std/jsffi` unconditionally, so a headless
  ## ViewModel test that has to run on the NATIVE (C) lane as well as the JS one
  ## cannot reach anything behind it. The one table with no guard therefore also
  ## had no test that could name it. `dap.nim::receiveResponse` is still the
  ## only production caller.
  ##
  ## Note what the guard does and does not check: it reconciles which commands
  ## have an arm, not which `CtEventKind` each arm returns. An arm pointing at
  ## the wrong kind is a Nim-level assertion's job — see *the poll's response
  ## round-trips through the DAP response table* in
  ## `src/tests/gui/tests/request-panel/request_panel_live_vm_test.nim`, which
  ## asserts the kind and not merely the absence of a raise.
  ##
  ## Raises `ValueError` for a command with no arm. The caller
  ## (`src/frontend/ui_js.nim::onDapReceiveResponse`) catches it and logs
  ## `dap: ignoring response for unmapped command: …`, which is the console
  ## line issue #690 reported.
  case command:
  of "ct/load-locals": CtLoadLocalsResponse
  of "initialize": DapInitializeResponse
  of "launch": DapLaunchResponse
  of "configurationDone": DapConfigurationDoneResponse
  of "stepIn": DapStepInResponse
  of "stepOut": DapStepOutResponse
  of "next": DapNextResponse
  of "continue": DapContinueResponse
  of "stepBack": DapStepBackResponse
  of "reverseContinue": DapReverseContinueResponse
  of "ct/reverseStepIn": CtReverseStepInResponse
  of "ct/reverseStepOut": CtReverseStepOutResponse
  of "ct/load-asm-function": CtLoadAsmFunctionResponse
  of "ct/update-expansion": CtUpdateExpansionResponse
  of "ct/mcr-get-recording-head": CtMcrGetRecordingHead
  of "ct/mcr-restore-at": CtMcrRestoreAt
  of "ct/live-restore-at": CtLiveRestoreAt
  of "ct/mcr-live-step": CtMcrLiveStep
  of "ct/seek-to-geid": CtSeekToGeid
  # Value Origin Tracking (M4)
  of "ct/originChain": CtOriginChainResponse
  of "ct/originSummary": CtOriginSummaryResponse
  # Column-Aware Replay Navigation (M3)
  of "ct/set-active-source-view": CtSetActiveSourceViewResponse
  of "ct/install-source-view": CtInstallSourceViewResponse
  # Request Panel live sessions (RS-M3) — issue #690.
  #
  # The response fans out as the REQUEST's own kind, not as a dedicated
  # `…Response` kind, because the two bodies are the same body: the backend
  # answers the poll with a span delta and emits `ct/updated-http-requests`
  # carrying an identically-shaped one
  # (`db-backend/src/dap_handler.rs::load_request_spans_since`). That is the
  # same shape as the five `ct/mcr-*` / `ct/seek-to-geid` arms above, and it
  # is what `ReplayDataStore.installBackendEventHandlers` was already written
  # against — its branch names `CtLoadRequestSpansSince` next to
  # `CtUpdatedHttpRequests`
  # (`src/frontend/viewmodel/store/replay_data_store.nim`), a branch that
  # could never fire while this arm was missing.
  #
  # Applying the delta twice is safe and is asserted headlessly
  # ("applying the same delta twice is idempotent",
  # `src/tests/gui/tests/request-panel/request_panel_live_vm_test.nim`):
  # `reset` replaces and a non-reset delta merges on `id`, last wins.
  of "ct/load-request-spans-since": CtLoadRequestSpansSince
  # Multi-process sessions (M42 §14.8)
  of "ct/listProcesses": CtListProcessesResponse
  of "ct/pairIndexLookup": CtPairIndexLookupResponse
  else: raise newException(
    ValueError,
    "no ct event kind response for command: \"" & command & "\" defined")

when defined(js):
  import std / jsffi

  type
    CtRawEvent* = ref object
      kind*: CtEventKind
      value*: JsObject

type
  CtEvent*[T] = ref object
    kind*: CtEventKind
    value: T
