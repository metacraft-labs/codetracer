## viewmodel/host/terminal_output_source.nim — PLAT-52. The Terminal Output
## pane's producer for the native hosts (the terminal and the GPUI window).
##
## THE LINE VIEW ASKS FOR THE LINES IT SHOWS (Viewport-Driven-Loading,
## Decided Q3): a host reports the pane's rows and first line
## (`showTerminalLines`), the session's `TerminalOutputVM` asks the engine
## for that window (`ct/load-terminal-lines`), and the native backend's
## synchronous answer is applied before the call returns. The screen view's
## writes are loaded by the ViewModel itself, once that view is shown.
## `openTerminalOutput` prepares the pane at open without loading anything.
##
## `loadTerminalOutput` hands the ViewModel EVERY write (`ct/load-terminal`):
## for a consumer that shows no line view and wants the whole output (a
## script, a test fixture), not for a pane.
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

proc openTerminalOutput*(s: HeadlessDebugSession) =
  ## Prepare the session's Terminal Output pane at open: the view choice
  ## remembered for this recording. Its lines are asked for when a host
  ## first reports what the pane shows.
  let vm = s.session.terminalOutputVM
  if not vm.isNil and vm.recordingKey.len == 0:
    vm.rememberViews(s.tracePath)

proc showTerminalLines*(vm: TerminalOutputVM; v: Viewport) =
  ## The pane shows `v` (rows, first line): hold that window, asking the
  ## engine for it when it is not held, and apply the answer now.
  if vm.isNil:
    return
  vm.setViewport(v)
  pumpCallbacks()

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
