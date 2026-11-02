## test_terminal_output_window.nim — Tier 1 for the Terminal Output pane's
## line window (Viewport-Driven-Loading V1-V2, Decided Q3).
##
## The line view asks for the lines it shows, not for every write:
##
##   - a viewport of R lines at line F asks `ct/load-terminal-lines` for the
##     20/10 window, once per distinct window, and an unmeasured view asks
##     nothing;
##   - the answer is decoded by the same line builder a whole stream goes
##     through, colours carried from earlier lines by the line's prefix;
##   - the current line follows the position, one count-0 request per tick;
##   - every write (`ct/load-terminal`) is loaded only when the screen view is
##     shown, and only for output that drives a screen.
##
## WHY A SCRIPTED BACKEND: the property under test is what the ViewModel
## SENDS and how it applies an answer of the engine's shape. The engine's
## splitting of writes into lines is tested where it lives
## (`db-backend/src/terminal_lines.rs`); here a small closure answers in its
## shape from a fixed list of lines, so a test can see each request and
## control each answer without a recording.
##
## Runs on the C and JS backends.

import std/[json, options, strutils, tables, unittest]

import isonim/core/[signals, computation, async_compat]

import backend/backend_service
import store/[replay_data_store, types]
import viewport
import viewmodels/terminal_output_vm

proc drain() = drainPlatformCallbacks()

type
  Engine = ref object
    ## The scripted engine: `lineCount` lines "line <i>", each its own write
    ## at tick 10 × (i + 1); line 0 turns the text red for every later line.
    lineCount: int
    offered: bool
    sent: seq[(string, JsonNode)]

proc linesAnswer(e: Engine; args: JsonNode): JsonNode =
  let start = min(args{"start"}.getInt(0), e.lineCount)
  let count = args{"count"}.getInt(0)
  let stop = min(start + count, e.lineCount)
  let at = args{"atRRTicks"}.getBiggestInt(-1)
  var current = -1
  for i in 0 ..< e.lineCount:
    if 10 * (i + 1) <= at: current = i
  var lines = newJArray()
  for i in start ..< stop:
    let content = (if i == 0: "\e[31m" else: "") & "line " & $i
    lines.add %*{
      "index": i,
      "prefix": (if i == 0: "" else: "\e[31m"),
      "segments": [{"write": i, "content": content,
                    "directLocationRRTicks": 10 * (i + 1),
                    "eventIndex": 100 + i, "highLevelPath": "/p.py",
                    "highLevelLine": i + 1, "stdout": true}]}
  %*{"start": start, "total": e.lineCount, "writes": e.lineCount,
     "screenOffered": e.offered, "currentLine": current, "lines": lines}

proc setup(lineCount = 1000; offered = false):
    (Engine, ReplayDataStore, TerminalOutputVM) =
  let e = Engine(lineCount: lineCount, offered: offered)
  let backend = BackendService(
    sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
      e.sent.add((command, args))
      let body =
        case command
        of "ct/load-terminal-lines": e.linesAnswer(args)
        of "ct/load-terminal": %*[{"content": "\e[?1049hx",
                                   "directLocationRRTicks": 10,
                                   "eventIndex": 100}]
        else: newJObject()
      newCompletedFuture[JsonNode](
        %*{"type": "response", "success": true, "body": body}),
    onEventProc: proc(handler: EventHandler) = discard)
  let store = createReplayDataStore(backend)
  (e, store, createTerminalOutputVM(store))

proc sentOf(e: Engine; command: string): seq[JsonNode] =
  for (c, a) in e.sent:
    if c == command: result.add a

proc windowsAsked(e: Engine): seq[JsonNode] =
  ## The `ct/load-terminal-lines` requests that ask for lines (not only the
  ## current line).
  for a in e.sentOf("ct/load-terminal-lines"):
    if a{"count"}.getInt(0) > 0: result.add a

suite "the terminal output's line window":

  test "an unmeasured view asks for nothing":
    let (e, _, vm) = setup()
    drain()
    check e.sentOf("ct/load-terminal-lines").len == 0
    check e.sentOf("ct/load-terminal").len == 0
    check not vm.windowed

  test "R lines at line F ask for the 20/10 window, and hold it":
    let (e, _, vm) = setup()
    vm.setViewport(Viewport(rows: 25, firstRow: 400))
    drain()
    let asked = e.windowsAsked
    check asked.len == 1
    # The window's answer names the current line: no second request for it.
    check e.sentOf("ct/load-terminal-lines").len == 1
    check asked[0]["start"].getInt == 400 - TrailRows
    check asked[0]["count"].getInt == 25 + LeadRows + TrailRows
    check vm.windowed
    check vm.lineCount == 1000
    check vm.linesStart.val == 390
    check vm.lines.val.len == 55
    check vm.heldLine(400).isSome
    check vm.heldLine(400).get.lineIndex == 400
    check vm.heldLine(10).isNone

  test "the same window is not asked twice":
    let (e, _, vm) = setup()
    vm.setViewport(Viewport(rows: 25, firstRow: 400))
    vm.setViewport(Viewport(rows: 25, firstRow: 400))
    drain()
    check e.windowsAsked.len == 1
    vm.setViewport(Viewport(rows: 25, firstRow: 401))
    drain()
    check e.windowsAsked.len == 2

  test "a line keeps the colour an earlier line set":
    let (_, _, vm) = setup()
    vm.setViewport(Viewport(rows: 5, firstRow: 50))
    drain()
    let line = vm.heldLine(50).get
    check line.fragments.len == 1
    check line.fragments[0].text == "line 50"
    check line.fragments[0].style.fg.kind != tckDefault
    check line.fragments[0].eventIndex == 50
    check line.fragments[0].rrTicks == 510'u64

  test "a fragment's write is known for a jump without loading the writes":
    let (e, _, vm) = setup()
    vm.setViewport(Viewport(rows: 5, firstRow: 50))
    drain()
    let ev = vm.eventOf(52)
    check ev.eventIndex == 52
    check ev.logIndex == 152
    check ev.rrTicks == 530'u64
    check e.sentOf("ct/load-terminal").len == 0

  test "the current line follows the position, one request per tick":
    let (e, store, vm) = setup()
    vm.setViewport(Viewport(rows: 25, firstRow: 0))
    drain()
    store.updateDebuggerPosition(255'u64, "/p.py", 1)
    drain()
    check vm.currentLine() == 24
    let before = e.sentOf("ct/load-terminal-lines").len
    store.updateDebuggerPosition(255'u64, "/p.py", 1)
    drain()
    check e.sentOf("ct/load-terminal-lines").len == before
    store.updateDebuggerPosition(1000'u64, "/p.py", 1)
    drain()
    check vm.currentLine() == 99
    let last = e.sentOf("ct/load-terminal-lines")[^1]
    check last["count"].getInt == 0

  test "the empty overlay reads the total, not the window":
    let (_, _, vm) = setup(lineCount = 0)
    vm.setViewport(Viewport(rows: 25, firstRow: 0))
    drain()
    check vm.isEmpty.val
    let (_, _, full) = setup()
    full.setViewport(Viewport(rows: 25, firstRow: 0))
    drain()
    check not full.isEmpty.val

  test "the writes are loaded only once the screen view is shown":
    let (e, _, vm) = setup(offered = true)
    vm.setViewport(Viewport(rows: 25, firstRow: 0))
    drain()
    # Output that drives a screen opens in the screen view (the default).
    check vm.view.val == tvScreen
    check e.sentOf("ct/load-terminal").len == 1
    check vm.events.val.len == 1
    # The line window stays what the engine answered.
    check vm.lineCount == 1000

  test "output that drives no screen never loads every write":
    let (e, _, vm) = setup(offered = false)
    vm.setViewport(Viewport(rows: 25, firstRow: 0))
    drain()
    vm.setView(tvScreen)
    drain()
    check vm.view.val == tvLines
    check e.sentOf("ct/load-terminal").len == 0

  test "a chosen line view loads no writes even when a screen is offered":
    let (e, _, vm) = setup(offered = true)
    vm.setRecordingKey("/rec", {"/rec": tvLines}.toTable)
    vm.setViewport(Viewport(rows: 25, firstRow: 0))
    drain()
    check vm.view.val == tvLines
    check e.sentOf("ct/load-terminal").len == 0

  test "a host that hands over the whole output still gets every line":
    let (e, _, vm) = setup()
    vm.setEvents(@[TerminalOutputEvent(content: "a\nb\n", rrTicks: 5)])
    drain()
    check not vm.windowed
    check vm.lineCount == 2
    check vm.heldLine(1).get.fragments[0].text == "b"
    check e.sentOf("ct/load-terminal-lines").len == 0
