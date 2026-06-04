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
]

let VALID_DAP_COMMANDS*: HashSet[string] = VALID_DAP_COMMANDS_SEQ.toHashSet

proc isValidDapCommand*(command: string): bool =
  ## Return true if the command string is a valid DAP command that
  ## ``dapCommandToEventKind`` in dap.nim can resolve.
  command in VALID_DAP_COMMANDS
