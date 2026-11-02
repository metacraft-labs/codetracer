## LAYER RULE — `src/frontend/tui/testing/` is TEST-ONLY infrastructure (see
## `dual_snap.nim`); nothing here is reachable from `main.nim`.
##
## testing/terminal_output_load.nim — PLAT-52. The WHOLE terminal output of a
## recording, for the suites that compare a pane with every write.
##
## A pane asks for the lines it shows (`terminal_output_source.showTerminalLines`,
## Viewport-Driven-Loading Decided Q3); `loadTerminalOutput` hands the
## ViewModel EVERY write (`ct/load-terminal`) instead, which no front-end does.
## The reference suites (`test_plat52_desktop_reference`,
## `real_terminal/test_plat52_screen_reference`) use it to load the output the
## desktop's own pane is compared against.

import std/json

import ../../viewmodel/headless_session
from ../../viewmodel/backend/stdio_backend import sendDapRequest, drainEvents
import ../../viewmodel/viewmodels/[terminal_output_model, terminal_output_vm]
import ../../viewmodel/host/terminal_output_source

proc loadTerminalOutput*(s: HeadlessDebugSession): int =
  ## Ask the engine for the recorded program's terminal output and hand it to
  ## the session's `TerminalOutputVM`. Answers how many writes arrived; raises
  ## when the engine refuses the request.
  let vm = s.session.terminalOutputVM
  if not vm.isNil and vm.recordingKey.len == 0:
    vm.rememberViews(s.tracePath)
  let resp = s.backend.sendDapRequest("ct/load-terminal", newJObject())
  # The engine also pushes the same writes as a `ct/loaded-terminal` event;
  # the answer's body is the same array, so the event is drained.
  discard s.backend.drainEvents()
  if not resp.getOrDefault("success").getBool(false):
    raise newException(ValueError, "ct/load-terminal failed: " &
      resp.getOrDefault("message").getStr("no message"))
  let events = terminalEventsFromJson(resp.getOrDefault("body"))
  if not vm.isNil:
    vm.setEvents(events)
  events.len
