## viewmodel/host/terminal_output_source.nim — PLAT-52. The Terminal Output
## pane's PRODUCER for the native hosts (the terminal and the GPUI window).
##
## `ct/load-terminal` answers every write the recorded program made to its
## terminal (the engine's `Write` events, `dap_handler.load_terminal`); this
## hands them to the session's `TerminalOutputVM`, which builds the line view
## and the screen model from them (`viewmodels/terminal_output_model`) — the
## SAME model the desktop's view draws, fed there by `ui/terminal_output.nim`
## from the `ct/loaded-terminal` event.
##
## Native-only (it holds a `HeadlessDebugSession`, which spawns the engine),
## and asked ONCE per recording, at open: the output of a recording does not
## change.
##
## The view the user chose for a recording (lines / screen) is remembered in
## the native state root (`native_state.terminalViewsPath`) — the
## specification's "remembers the user's choice per recording" — and both
## native front-ends read and write the one file.

when defined(js):
  {.error: "terminal_output_source.nim is native-only".}

import std/[json, os, tables]

import ../headless_session
from ../backend/stdio_backend import sendDapRequest, drainEvents
import ../viewmodels/terminal_output_vm
import ./native_state

proc rememberViews*(vm: TerminalOutputVM; recording: string) =
  ## Key `vm`'s view choice by `recording` (its absolute path), seeded from
  ## what was remembered, and write every later choice back.
  if vm.isNil:
    return
  vm.setRecordingKey(absolutePath(recording),
                     viewMemoryFromJson(readTerminalViews()))
  vm.onViewChosen = proc(memory: Table[string, TerminalView]) =
    discard writeStaged(terminalViewsPath(), viewMemoryToJson(memory))

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
