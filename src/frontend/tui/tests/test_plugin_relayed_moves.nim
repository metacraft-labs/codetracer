## test_plugin_relayed_moves.nim — a plugin's relayed actions take the
## terminal's own routes (Extensibility-Model.md §11.12, "a relayed debugger
## move takes a front-end's own route"), and its key bindings are compared in
## the terminal's canonical key names (§11.7.2).
##
## The terminal pumps every move to its stop in its loop and rebuilds its
## panes from the session there. A relayed action applied to the session's
## ViewModel behind that loop moved the replay and left the screen at the old
## stop until the next one. `plugin_service.pluginMoveOf` classifies every
## relayed action onto the terminal's own route (a command line, a menu item,
## a pane click, the call trace pane's jump), refuses the ones the terminal
## cannot show, and `carryOut` runs it — here against a REAL session on the
## `calc` recording, through the same `tui_session.applyOutcome` the loop
## calls.
##
## ## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK
##
## The key suite's `PluginsService` is a set of capturing closures: it records
## the key name the runtime routes to the plugin pass and answers whether a
## plugin claims it, which is the whole of the runtime's side of that door
## (`plugin_service.service` wires the same closures to a real supervisor,
## whose resolution `test_plugin_process_host.nim` drives against real plugin
## processes). Nothing else is a stand-in: the session, the replay and the
## recording are real.

import std/[json, options, strutils, unittest]

import codetracer_embed
import backend/stdio_backend   # `DapReadBound`, the product's read clock
import viewmodels/[calltrace_vm, state_vm]
import ../../../common/key_names
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../host/tui_session
import ../host/plugin_service
import ./fixtures/fixture_provider

const
  Cols = 160
  Rows = 48
  PumpClockMs = 60_000

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc relayed(vm, action: string; args: JsonNode = newJObject()): JsonNode =
  %*{"type": "action", "plugin": "acme-tools.metrics", "vm": vm,
     "action": action, "args": args}

proc run(s: TuiSession; rt: TuiRuntime; msg: JsonNode;
         move: var PluginMove): string =
  ## Classify `msg` and carry it out as the loop does; "" when it ran, else
  ## the refusal.
  var refusal = ""
  if not pluginMoveOf(msg, s.session.session, rt, move, refusal):
    return refusal
  var outcome: RuntimeOutcome
  let why = move.carryOut(rt, s.session.session, outcome)
  if why.len > 0: return why
  s.applyOutcome(rt, outcome)
  ""

proc ticks(s: TuiSession): uint64 = s.session.getCurrentRRTicks()

suite "a plugin's relayed actions, on the terminal's own routes":

  let resolution = resolveFixture("calc")

  test "steps, the call trace jump, the watch and the seek move the stop the screen shows":
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      skip()
    else:
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6,
                             bound = DapReadBound(timeoutMs: PumpClockMs,
                                                  interruptFd: -1))
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.learnExtent()
      s.refresh(rt)
      var move: PluginMove
      # A step: the terminal's own `:next`, pumped to its stop.
      let t0 = s.ticks
      check s.run(rt, relayed("debugControls", "stepIn"), move) == ""
      check move.kind == pmkLine
      check move.line == CommandLineTargetPrefix & ":step"
      check s.ticks != t0
      # The call trace pane's own jump to the `mul` call.
      let calltrace = s.session.session.store.calltrace
      var mul = -1'i64
      for i, l in calltrace.lines.val:
        if l.name == "mul" or l.displayName == "mul":
          mul = calltrace.startLineIndex.val + i.int64
          break
      checkpoint "mul at call-trace line " & $mul
      check mul >= 0
      let beforeJump = s.ticks
      check s.run(rt, relayed("calltrace", "doubleClickEntry",
                              %*{"lineIndex": mul}), move) == ""
      check move.kind == pmkOutcome and move.outcome.jumpsToCall
      check s.ticks != beforeJump
      check rt.app.source.executionLine in 39 .. 41
      # The watch: `:watch`'s own edit, evaluated at once.
      check s.run(rt, relayed("state", "addWatch",
                              %*{"expression": "left*9"}), move) == ""
      check move.outcome.paneClick.kind == pcWatch
      check "left*9" in s.session.session.stateVM.watchExpressions.val
      check "left*9" in rt.app.variables.watches
      # Step out: the Debug menu's item, a later stop.
      let inMul = s.ticks
      check s.run(rt, relayed("debugControls", "stepOut"), move) == ""
      check move.line == "forwardStepOut"
      check s.ticks > inMul
      # A seek: the timeline's own, landing on the tick asked for.
      check s.run(rt, relayed("timeline", "seek", %*{"tick": int(inMul)}),
                  move) == ""
      check move.outcome.paneClick.kind == pcSeek
      check s.ticks == inMul

  test "what the terminal cannot show is refused by name, and no stop is waited for":
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      skip()
    else:
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6,
                             bound = DapReadBound(timeoutMs: PumpClockMs,
                                                  interruptFd: -1))
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.refresh(rt)
      var move: PluginMove
      let t0 = s.ticks
      # A live restore on a finished recording would send a request no stop
      # answers.
      check "live recording" in s.run(rt, relayed("debugControls", "restoreAt",
                                      %*{"rrTicks": 5}), move)
      check "no call-trace search result 3" in s.run(rt,
        relayed("calltrace", "jumpToSearchResult", %*{"index": 3}), move)
      check "cannot show" in s.run(rt,
        relayed("state", "continueOriginChain", %*{"expression": "x"}), move)
      check "no event row 100000" in s.run(rt,
        relayed("eventLog", "doubleClickRow", %*{"row": 100000}), move)
      check "needs an expression" in s.run(rt, relayed("state", "addWatch"),
                                           move)
      check "no toolbar step 'fly'" in s.run(rt,
        relayed("debugControls", "invokeToolbarStep", %*{"actionId": "fly"}),
        move)
      check s.ticks == t0
      # Not a move: applied, then the panes rebuilt.
      check s.run(rt, relayed("calltrace", "selectEntry",
                              %*{"lineIndex": 0}), move) == ""
      check move.kind == pmkRelayRefresh
      # An action the session's ViewModel rejects is not waited on.
      check "was not applied" in s.run(rt, relayed("debugControls", "fly"),
                                       move)
      check s.ticks == t0

  test "while another tab is shown only a plain step runs; the rest is refused":
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      skip()
    else:
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6,
                             bound = DapReadBound(timeoutMs: PumpClockMs,
                                                  interruptFd: -1))
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.learnExtent()
      s.refresh(rt)
      var move: PluginMove
      var refusal = ""
      check pluginMoveOf(relayed("timeline", "seek", %*{"tick": 1}),
                         s.session.session, rt, move, refusal)
      var outcome: RuntimeOutcome
      # `shown` is another session's: the seek was classified against this
      # one's extent, and is not run on the tab in front.
      check "another tab" in move.carryOut(rt, nil, outcome)
      check outcome.paneClick.kind == pcNone
      check pluginMoveOf(relayed("debugControls", "stepForward"),
                         s.session.session, rt, move, refusal)
      let t0 = s.ticks
      check move.carryOut(rt, nil, outcome) == ""
      check outcome.awaitsMove
      s.applyOutcome(rt, outcome)
      check s.ticks != t0

suite "a plugin's key bindings, in the terminal's key names":

  test "the modifiers' spelling is folded, the key's own case is not":
    check bindingKeyName("ctrl+alt+m") == "Ctrl+Alt+m"
    check bindingKeyName("Control+Option+M") == "Ctrl+Alt+m"
    check bindingKeyName("escape") == "Esc"
    check bindingKeyName("escape escape escape") == "Esc Esc Esc"
    check bindingKeyName("J") == "J"
    check bindingKeyName("j") == "j"
    check bindingKeyName("shift+j") == "J"
    check bindingKeyName("J") != bindingKeyName("j")
    check bindingKeyName("shift+f7") == "Shift+F7"
    # What the terminal decodes for the bytes a legacy terminal sends.
    check keyName("\x1b\x0b") == bindingKeyName("ctrl+alt+k")
    check keyName("J") == bindingKeyName("J")

  test "an Alt chord a plugin binds reaches the plugin pass whole; `J` and `j` are two keys":
    let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
    var routed: seq[string]
    rt.plugins = PluginsService(
      panes: proc(): seq[tuple[id, title: string; running: bool]] = @[],
      paneView: proc(id: string): tuple[lines: seq[string]; cursor: int;
                                        stale: bool] = (@[], 0, false),
      paneKey: proc(id, key: string): bool = false,
      paneClick: proc(id: string; row: int): bool = false,
      decorations: proc(document: string):
          seq[tuple[line: int; glyph, text, plugin: string]] = @[],
      markers: proc(document: string):
          seq[tuple[line: int; glyph, text, plugin: string]] = @[],
      closedPanes: proc(): seq[string] = @[],
      setPaneClosed: proc(id: string; closed: bool) = discard,
      control: proc(words: seq[string]): tuple[title, body: string] = ("", ""),
      statusText: proc(): string = "",
      takeNote: proc(): string = "",
      busy: proc(): bool = false,
      layerLabel: proc(): string = "",
      observeEscape: proc(): bool = false,
      routeLayerKey: proc(key: string): PluginRoute = (false, ""),
      routeStaticKey: proc(key: string): PluginRoute =
        routed.add key
        (key in ["Ctrl+Alt+k", "J"], ""),
      claimsKey: proc(key: string): bool = key in ["Ctrl+Alt+k", "J"])
    discard rt.handleToken("\x1b\x0b", 0'i64)
    check "Ctrl+Alt+k" in routed
    check "Ctrl+k" notin routed
    routed = @[]
    discard rt.handleToken("j", 0'i64)
    discard rt.handleToken("J", 0'i64)
    check routed == @["j", "J"]
