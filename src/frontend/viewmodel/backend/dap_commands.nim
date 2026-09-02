## dap_commands.nim
##
## Authoritative set of valid DAP command strings that BackendService
## accepts.  This module is pure Nim (no JS FFI) so it can be imported
## by both the JS renderer and native headless tests.
##
## The strings here MUST match the non-empty values in
## ``EVENT_KIND_TO_DAP_MAPPING`` (defined in ``src/frontend/dap.nim``).
## When a new CtEventKind with a DAP command is added, the
## corresponding string must be added here as well.
##
## That promise is no longer kept by hand. ``ci/test/dap-command-sync.py``
## derives the engine's dispatch table from ``src/db-backend/src/dap_server.rs``
## and the event mapping from ``src/frontend/dap.nim``, and fails if either
## names a command this list does not. It had drifted in exactly the direction
## nobody checks — ten commands the engine implements were missing, two of them
## already present in ``EVENT_KIND_TO_DAP_MAPPING`` — because a hand-maintained
## mirror of a machine-readable fact always does.
##
## Note what this list is NOT: a subset of the engine's requests. It is the
## union of three things — requests the engine dispatches, events the engine
## EMITS (``stopped``, ``ct/updated-*``, ``ct/notification`` …, which are
## `sender.send` sites rather than any table), and ``internal/last-complete-move``
## which no engine implements at all. That is why the guard checks the two
## derivable directions instead of generating the list outright; generating it
## from the dispatch table alone would delete every event string here.
##
## The headless test ``test_dap_command_validation`` uses this set to
## verify that every command sent by ViewModel auto-load effects and
## actions is a valid DAP command, catching the class of bug where an
## unmapped command string causes ``dapCommandToEventKind`` to raise
## ``ValueError`` and kill all subsequent reactive effects.

import std/sets

const VALID_DAP_COMMANDS_SEQ*: seq[string] = @[
  # Standard DAP commands
  "stopped",
  "initialized",
  "initialize",
  "configurationDone",
  "launch",
  "output",
  "stepIn",
  "stepOut",
  "next",
  "continue",
  "stepBack",
  "reverseContinue",
  "setBreakpoints",

  # CodeTracer extension commands
  "ct/update-table",
  "ct/updated-table",
  "ct/load-locals",
  "ct/updated-calltrace",
  "ct/load-calltrace-section",
  "ct/complete-move",
  "ct/reverseStepIn",
  "ct/reverseStepOut",
  "ct/event-load",
  "ct/updated-events",
  "ct/updated-events-content",
  "ct/load-terminal",
  "ct/loaded-terminal",
  "ct/collapse-calls",
  "ct/expand-calls",
  "ct/calltrace-jump",
  "ct/event-jump",
  "ct/load-history",
  "ct/updated-history",
  "ct/history-jump",
  "ct/search-calltrace",
  "ct/calltrace-search-res",
  "ct/source-line-jump",
  "ct/source-call-jump",
  "ct/local-step-jump",
  "ct/tracepoint-toggle",
  "ct/tracepoint-delete",
  "ct/trace-jump",
  "ct/updated-trace",
  "ct/load-flow",
  "ct/updated-flow",
  "ct/run-to-entry",
  "ct/run-tracepoints",
  "ct/run-trace-session",
  "ct/setup-trace-session",
  "ct/load-asm-function",
  "ct/update-expansion",
  "internal/last-complete-move",
  "ct/notification",
  "tracepoint-locals",
  "ct/tracepoint-results",
  "ct/flow-jump",
  "ct/timeline-seek",
  "ct/shell-eval",
  "ct/mcr-get-recording-head",
  "ct/mcr-restore-at",
  "ct/live-restore-at",
  "ct/mcr-live-step",
  "ct/seek-to-geid",
  # Value Origin Tracking (M2). The backend emits this event next to
  # `ct/updated-history` so the frontend can react to lazy
  # continuations of an origin chain.
  "ct/updated-origin-chain",
  # Value Origin Tracking (M4) — frontend-initiated requests. The
  # backend dispatch lives in `src/db-backend/src/dap_server.rs` (see
  # the `ct/originChain` / `ct/originSummary` arms).
  "ct/originChain",
  "ct/originSummary",
  # Request Panel live sessions (RS-M3). `ct/load-request-spans-since` is
  # sent from `ReplayDataStore.requestRequestSpansSince`, which is exactly
  # the class of caller this set exists to validate; the backend answers it
  # with a delta and emits `ct/updated-http-requests` carrying the same
  # body.
  "ct/load-request-spans-since",
  "ct/updated-http-requests",
  # Multi-process sessions (M42 §14.8) and the M25b §5.3 Event Log
  # boundary-chip jump. `ct/listProcesses` had a `CtEventKind` but was
  # missing here, so the two lists this module's header promises to
  # keep in sync had already drifted.
  "ct/listProcesses",
  "ct/pairIndexLookup",
  "ct/goto-ticks",

  # ---------------------------------------------------------------------
  # Commands the ENGINE dispatches that this list had never named.
  #
  # `dap_dialect.md` §7b recorded this drift as nine commands. It is ten:
  # `disconnect` is answered in `dap_server.rs`'s message loop rather than
  # in `handle_request`'s `match`, so it is invisible to a reader scanning
  # the one obvious table. `ci/test/dap-command-sync.py` now derives all
  # four dispatch constructs mechanically, which is how the tenth surfaced.
  #
  # None of these has a `CtEventKind`, with the two noted exceptions below,
  # so `dapCommandToEventKind` still raises on them and `RealBackendService`
  # cannot translate one. That is intentional and pinned as EXPECTED_RESIDUE
  # in the guard: nothing sends them through `BackendService` today
  # (`worker_backend.nim` reaches the engine directly), and inventing event
  # kinds for traffic no ViewModel produces would be a bigger lie than the
  # gap. What is fixed here is `isValidDapCommand` rejecting commands the
  # engine really implements.

  # Standard DAP requests. `dap_server.rs:2050-2066` for the first five;
  # `disconnect` at `dap_server.rs:2643` and `:2893`, in the message loop.
  "scopes",
  "threads",
  "stackTrace",
  "variables",
  "restart",
  "disconnect",

  # CodeTracer extension requests the engine answers.
  # `ct/originMode` — `dap_server.rs:2098` (M21 eager-origin indicator).
  "ct/originMode",
  # `ct/load-request-spans` — `dap_server.rs:2166`. The non-delta sibling of
  # `ct/load-request-spans-since`, which was listed above while the base
  # command was not.
  "ct/load-request-spans",
  # These two were ALREADY in `EVENT_KIND_TO_DAP_MAPPING` (`dap.nim:166`,
  # `:168`) and dispatched by the engine (`dap_server.rs:2219`, `:2236`),
  # and absent only here — the exact both-directions drift this module's
  # header promises cannot happen. They do have `CtEventKind`s, so they are
  # not part of the residue.
  "ct/set-active-source-view",
  "ct/install-source-view",
]

let VALID_DAP_COMMANDS*: HashSet[string] = VALID_DAP_COMMANDS_SEQ.toHashSet

proc isValidDapCommand*(command: string): bool =
  ## Return true if the command string is a valid DAP command that
  ## ``dapCommandToEventKind`` in dap.nim can resolve.
  command in VALID_DAP_COMMANDS
