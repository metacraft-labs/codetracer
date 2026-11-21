## host/plugin_service.nim — the terminal runtime's door to its plugins
## (`runtime.PluginsService`), and the plugins' palette entries. The plugins
## themselves, front-end-agnostic, are `plugin_processes`; GPUI uses that
## module without this one.

import std/[json, options]

import codetracer_embed

import ../../viewmodel/viewmodels/omnibar_vm
import ../../viewmodel/session_vm
import ../../viewmodel/store/types as store_types
import viewmodels/[calltrace_vm, debug_controls_vm, event_log_vm, flow_vm,
                   origin_chain_types,
                   origin_chain_vm, request_panel_vm, terminal_output_vm,
                   timeline_vm, trace_log_vm]
from ../../viewmodel/sync/action_relay import applyAction
import ../../viewmodel/plugin_host/supervisor
import ../app/[runtime, tui_app]
import ./plugin_processes
import ./plugin_panes

# ---------------------------------------------------------------------------
# The runtime's door
# ---------------------------------------------------------------------------

proc paletteEntries*(p: SessionPlugins): seq[OmnibarEntry] =
  ## The plugins' palette entries (`plugin_processes.pluginPaletteEntries`),
  ## each a command line the terminal runs as typed.
  p.pluginPaletteEntries(CommandLineTargetPrefix)

proc service*(p: SessionPlugins): PluginsService =
  let panes = newPluginPanes(p)
  PluginsService(
    panes: proc(): seq[tuple[id, title: string; running: bool]] =
      panes.contributedPanes(),
    paneView: proc(id: string): tuple[lines: seq[string]; cursor: int;
                                      stale: bool] =
      panes.paneView(id),
    paneKey: proc(id, key: string): bool = panes.paneKey(id, key),
    paneClick: proc(id: string; row: int): bool = panes.paneClick(id, row),
    decorations: proc(document: string):
        seq[tuple[line: int; glyph, text, plugin: string]] =
      panes.decorationsFor(document),
    markers: proc(document: string):
        seq[tuple[line: int; glyph, text, plugin: string]] =
      panes.markersFor(document),
    closedPanes: proc(): seq[string] = p.closedPanes(),
    setPaneClosed: proc(id: string; closed: bool) = p.setPaneClosed(id, closed),
    control: proc(words: seq[string]): tuple[title, body: string] =
      p.control(words),
    statusText: proc(): string = p.statusText(),
    takeNote: proc(): string = p.takeNote(),
    observeEscape: proc(): bool = p.sup.observeEscape(),
    busy: proc(): bool = p.sup.busy,
    layerLabel: proc(): string = p.sup.topLayerLabel,
    routeLayerKey: proc(key: string): PluginRoute =
      let r = p.sup.resolveLayerKey(key, "")
      if not r.found: return (false, "")
      discard p.sup.routeKey(r, key)
      (true, ""),
    routeStaticKey: proc(key: string): PluginRoute =
      let r = p.sup.resolveStaticKey(key, "")
      if not r.found: return (false, "")
      discard p.sup.routeKey(r, key)
      (true, ""))

const PluginMoveCommands* = [
  ("stepForward", ":next"), ("stepIn", ":step"),
  ("stepBackward", ":reverse-next"), ("reverseStepIn", ":reverse-step"),
  ("continueExecution", ":continue"), ("reverseContinue", ":reverse-continue")]
  ## A plugin's relayed `debugControls` step or continue, as the terminal's
  ## own command line. The terminal pumps every move to its stop in its loop,
  ## so a move applied to the ViewModel behind the loop's back would be sent
  ## and never shown (`pluginMoveOf` lists the other relayed actions and
  ## where each goes).

const PluginStepOutTargets* = [
  ("stepOut", "forwardStepOut"), ("reverseStepOut", "reverseStepOut")]
  ## A relayed step out, as the Debug menu's item: the terminal's command line
  ## has no step-out verb, and the menu's target is the same `kaStepOut` /
  ## `kaReverseStepOut` its keys perform (`runtime.menuKeyAction`).

const PluginToolbarTargets* = [
  ("next", "forwardNext"), ("reverse-next", "reverseNext"),
  ("step-in", "forwardStep"), ("reverse-step-in", "reverseStep"),
  ("step-out", "forwardStepOut"), ("reverse-step-out", "reverseStepOut"),
  ("continue", "forwardContinue"), ("reverse-continue", "reverseContinue")]
  ## `debugControls.invokeToolbarStep`'s action ids (the toolbar's
  ## `TransportControls` ids), as the Debug menu's items.

type
  PluginMoveKind* = enum
    pmkLine
      ## `line` is a menu target or a command line (`CommandLineTargetPrefix`)
      ## run as the terminal's own (`runtime.runMenuAction`), whichever tab is
      ## shown: it is what the user's own key would have done there.
    pmkOutcome
      ## `outcome` is the terminal's own route for the action (a pane click, a
      ## call trace jump), applied by `tui_session.applyOutcome`.
    pmkRelayMove
      ## The terminal has no route of its own: `relay` is applied to the
      ## plugin's session (`action_relay.applyAction`) in the loop and the
      ## move it sends is pumped to its stop. Classified only when a stop
      ## will come (the row, the hop, the result exists), so the loop never
      ## waits on one that is not coming.
    pmkRelayRefresh
      ## Not a move: `relay` changes what a pane shows (a selection, a page, a
      ## filter, an iteration of a loop). Applied in the loop, then the panes
      ## are rebuilt from the session, so the change is shown at once rather
      ## than at the next stop.

  PluginMove* = object
    ## One relayed action a plugin sent, carried out by the terminal's loop
    ## on its own route so the screen shows what it did.
    kind*: PluginMoveKind
    name*: string
      ## `vm.action`, for the notes.
    plugin*: string
      ## The plugin that relayed it.
    line*: string
    relay*: JsonNode
    session*: SessionViewModel
      ## The session the action was classified against (the one the plugins
      ## mirror). Everything but a `pmkLine` is refused while another tab is
      ## shown: the guards that made it safe were read from this session.
    outcome*: RuntimeOutcome

const LiveSessionModes = {liveMcr, liveMaterialized, historicalFromLive}
  ## The session modes in which the live-MCR actions (`restoreAt`,
  ## `jumpToLive`) mean anything.

const UnshownActions* = [
  ("state", "continueOriginChain"), ("originChain", "continueActiveChain"),
  ("eventLog", "jumpToCounterpartOf")]
  ## Relayed actions the terminal cannot show, refused by name: it draws no
  ## origin side panel and no "continue tracing" under a chain, and a
  ## boundary counterpart lives in another recording, found by an answer
  ## that arrives after the loop's turn.

proc pluginMoveOf*(msg: JsonNode; session: SessionViewModel; rt: TuiRuntime;
                   move: var PluginMove; refusal: var string): bool =
  ## Where the relayed action `msg` runs in the terminal. `true`: `move` says
  ## which route the loop takes. `false` with `refusal` set: the action must
  ## not run at all (it would send a request no stop answers, or show
  ## nothing), and `refusal` says why, for the status line.
  ##
  ## The routes, each the terminal's own path where it has one:
  ##
  ## * `debugControls` steps and continues: their command line
  ##   (`PluginMoveCommands`); step out and reverse step out, and
  ##   `invokeToolbarStep`'s ids: the Debug menu's items.
  ## * `debugControls.restoreAt` / `jumpToLive`: refused on a recording that
  ##   is not live; on a live one applied and pumped.
  ## * `calltrace.doubleClickEntry`: the call trace pane's own jump
  ##   (`jumpsToCall`); `jumpToSearchResult`: applied and pumped, refused for
  ##   a result the session does not hold.
  ## * `state.addWatch` / `removeWatch` / `editWatch`: `:watch`'s `pcWatch`.
  ## * `timeline.seek`, `seekAtFraction`, `state.jumpToHistoryEntry`,
  ##   `originChain.seekToHop`: the timeline's seek (`pcSeek`).
  ## * `eventLog.doubleClickRow`, `traceLog.jumpToEntry`,
  ##   `terminalOutput.jumpToEvent` / `jumpToWrite`: the event log's row jump
  ##   (`pcEventJump`).
  ## * `state.onShowOrigin`: the Variables pane's "Show value origin"
  ##   (`pcValueOrigin`), opened, never toggled shut.
  ## * `breakpoints.set`: applied, then the panes refreshed, as the
  ##   terminal's own breakpoint toggle refreshes them.
  ## * `requestPanel.jumpToHandler`, `flow.clickStep`: applied and pumped,
  ##   only for a row or step that exists and can be sought.
  ## * `UnshownActions`: refused.
  ## * Everything else changes what a pane shows: applied, then the panes
  ##   rebuilt (`pmkRelayRefresh`).
  refusal = ""
  if msg.isNil or msg.kind != JObject: return false
  let vm = msg{"vm"}.getStr("")
  let action = msg{"action"}.getStr("")
  let args = if msg{"args"}.isNil: newJObject() else: msg{"args"}
  move = PluginMove(name: vm & "." & action, plugin: msg{"plugin"}.getStr(""),
                    session: session)
  # Templates, not closures: `move` and `refusal` are `var` parameters.
  template unknown(what: string): bool =
    refusal = "'" & vm & "." & action & "': " & what
    false
  template lineMove(target: string): bool =
    move.kind = pmkLine
    move.line = target
    true
  template click(c: PaneClickRequest): bool =
    move.kind = pmkOutcome
    move.outcome.paneClick = c
    move.outcome.repaint = true
    true
  template relayMove(): bool =
    move.kind = pmkRelayMove
    move.relay = msg
    move.outcome.awaitsMove = true
    move.outcome.repaint = true
    true
  for (v, a) in UnshownActions:
    if v == vm and a == action:
      return unknown("the terminal cannot show this")
  if session.isNil:
    return unknown("no session is open")
  case vm
  of "debugControls":
    for (name, line) in PluginMoveCommands:
      if name == action: return lineMove(CommandLineTargetPrefix & line)
    for (name, target) in PluginStepOutTargets:
      if name == action: return lineMove(target)
    case action
    of "invokeToolbarStep":
      let id = args{"actionId"}.getStr("")
      for (name, target) in PluginToolbarTargets:
        if name == id: return lineMove(target)
      if id == "run-to-entry":
        return click(PaneClickRequest(kind: pcSeek, tick: 0'u64))
      return unknown("no toolbar step '" & id & "'")
    of "restoreAt", "jumpToLive":
      let mode = if session.store.isNil: completedReplay
                 else: session.store.session.val.debugSessionMode
      if mode notin LiveSessionModes:
        return unknown("needs a live recording; this session replays a " &
                       "finished one")
      if action == "jumpToLive" and (session.debugControlsVM.isNil or
                                     not session.debugControlsVM.canJumpToLive.val):
        return unknown("the session is already at the live head")
      return relayMove()
    else: discard
  of "calltrace":
    case action
    of "doubleClickEntry":
      move.kind = pmkOutcome
      move.outcome.jumpsToCall = true
      move.outcome.callIndex = args{"lineIndex"}.getBiggestInt(0).int64
      move.outcome.repaint = true
      return true
    of "jumpToSearchResult":
      let index = args{"index"}.getInt(-1)
      let held = if session.calltraceVM.isNil: 0
                 else: session.calltraceVM.backendSearchResults.val.len
      if index < 0 or index >= held:
        return unknown("no call-trace search result " & $index & " (" &
                       $held & " held)")
      return relayMove()
    else: discard
  of "state":
    let expression = args{"expression"}.getStr("")
    case action
    of "addWatch", "removeWatch", "editWatch":
      if expression.len == 0 or
         action == "editWatch" and args{"old"}.getStr("").len == 0:
        return unknown("needs " &
          (if action == "editWatch": "the old and the new expression"
           else: "an expression"))
      return click(case action
        of "addWatch": PaneClickRequest(kind: pcWatch, text: expression)
        of "removeWatch": PaneClickRequest(kind: pcWatch, path: expression,
                                           behaviour: "remove")
        else: PaneClickRequest(kind: pcWatch, path: args{"old"}.getStr(""),
                               text: expression, behaviour: "edit"))
    of "jumpToHistoryEntry":
      let ticks = args{"ticks"}.getBiggestInt(-1)
      if ticks < 0: return unknown("needs a tick")
      return click(PaneClickRequest(kind: pcSeek, tick: uint64(ticks)))
    of "onShowOrigin":
      if expression.len == 0: return unknown("needs an expression")
      if not rt.isNil and expression in rt.app.openOrigins:
        # Already open under its row: "show" must not close it.
        move.kind = pmkOutcome
        move.outcome.refreshesSession = true
        move.outcome.repaint = true
        return true
      return click(PaneClickRequest(kind: pcValueOrigin, path: expression))
    else: discard
  of "timeline":
    case action
    of "seek":
      return click(PaneClickRequest(kind: pcSeek,
                                    tick: uint64(max(0, args{"tick"}.getBiggestInt(0)))))
    of "seekAtFraction":
      let tick = if session.timelineVM.isNil: none(uint64)
                 else: session.timelineVM.tickAtFraction(args{"fraction"}.getFloat(0.0))
      if tick.isNone: return unknown("the timeline's extent is not known yet")
      return click(PaneClickRequest(kind: pcSeek, tick: tick.get))
    else: discard
  of "originChain":
    if action == "seekToHop":
      let chain = if session.originChainVM.isNil: none(OriginChain)
                  else: session.originChainVM.activeChain.val
      let stepId = args{"stepId"}.getBiggestInt(-1)
      let ticks = uint64(max(0, args{"rrTicks"}.getBiggestInt(0)))
      if chain.isSome:
        for hop in chain.get.hops:
          if hop.stepId == stepId and hop.location.rrTicks == ticks:
            return click(PaneClickRequest(kind: pcSeek, tick: ticks))
      return unknown("no hop " & $stepId & " in the chain shown")
  of "eventLog":
    if action == "doubleClickRow":
      let row = args{"row"}.getInt(-1)
      let rows = if session.eventLogVM.isNil: @[]
                 else: session.eventLogVM.eventRows.val
      if row < 0 or row >= rows.len: return unknown("no event row " & $row)
      let e = rows[row]
      if e.noPosition: return unknown("the event has no position to go to")
      return click(PaneClickRequest(kind: pcEventJump,
        index: int64(e.eventId),
        tick: (if e.rrTicks != 0'u64: e.rrTicks else: e.eventId),
        path: e.file, line: e.line, text: e.value))
  of "traceLog":
    if action == "jumpToEntry":
      let index = args{"index"}.getInt(-1)
      let rows = if session.traceLogVM.isNil: @[]
                 else: session.traceLogVM.entries.val
      if index < 0 or index >= rows.len:
        return unknown("no trace log entry " & $index)
      let e = rows[index]
      return click(PaneClickRequest(kind: pcEventJump, index: int64(e.eventId),
        tick: uint64(max(0, e.rrTicks)), path: e.path, line: e.line))
  of "terminalOutput":
    if action in ["jumpToEvent", "jumpToWrite"]:
      let t = session.terminalOutputVM
      if t.isNil: return unknown("the recording has no terminal output")
      var ev = TerminalOutputEvent(eventIndex: -1)
      if action == "jumpToWrite":
        let write = args{"write"}.getInt(-1)
        let evs = t.events.val
        if write >= 0 and write < evs.len: ev = evs[write]
      else:
        ev = t.eventOf(args{"eventIndex"}.getInt(-1))
      if ev.eventIndex < 0: return unknown("no such write")
      return click(PaneClickRequest(kind: pcEventJump, index: int64(ev.logIndex),
        tick: ev.rrTicks, path: ev.path, line: ev.line))
  of "requestPanel":
    if action == "jumpToHandler":
      let index = args{"index"}.getInt(-1)
      let rows = if session.requestPanelVM.isNil: @[]
                 else: session.requestPanelVM.filteredRequests.val
      if index < 0 or index >= rows.len: return unknown("no request " & $index)
      let req = rows[index]
      if req.seekUnavailableReason.len > 0:
        return unknown(req.seekUnavailableReason)
      if req.externalTracePath.len > 0:
        # Opens another recording (a new tab); no stop comes in this one.
        move.kind = pmkRelayRefresh
        move.relay = msg
        return true
      return relayMove()
  of "flow":
    if action == "clickStep":
      let step = args{"step"}.getInt(-1)
      var found = false
      if not session.flowVM.isNil:
        for st in session.flowVM.steps.val:
          if st.step == step: found = true
      if not found: return unknown("no flow step " & $step)
      return relayMove()
  of "breakpoints":
    if action == "set":
      move.kind = pmkRelayRefresh
      move.relay = msg
      return true
  else: discard
  # Not a move: what it changes is shown once the loop rebuilds the panes.
  move.kind = pmkRelayRefresh
  move.relay = msg
  true

proc routeMoves*(p: SessionPlugins; queue: ref seq[PluginMove];
                 rt: TuiRuntime = nil) =
  ## Take EVERY relayed action of the plugins into `queue`, for the loop to
  ## carry out on the terminal's own routes (`pluginMoveOf`), and refuse,
  ## through the supervisor (the status line and a note), the ones the
  ## terminal cannot show. None runs behind the loop.
  if p.isNil: return
  let sup = p.sup
  sup.actionHook = proc(msg: JsonNode; refusal: var string): bool =
    var move: PluginMove
    if pluginMoveOf(msg, sup.session, rt, move, refusal):
      queue[].add move
      return true
    false

proc carryOut*(move: PluginMove; rt: TuiRuntime; shown: SessionViewModel;
               outcome: var RuntimeOutcome): string =
  ## Run `move` in the loop: its line, or its relayed action on its session,
  ## into `outcome` for `tui_session.applyOutcome`. Answers why it was not
  ## run ("" when it was): a move classified against the plugins' session
  ## while another tab is shown, or an action the session's ViewModel
  ## rejected — no stop is then waited for.
  outcome = move.outcome
  case move.kind
  of pmkLine:
    rt.runMenuAction(move.line, outcome)
    return ""
  of pmkOutcome, pmkRelayMove:
    if move.session != shown:
      outcome = RuntimeOutcome()
      return "'" & move.name & "' was for another tab; not applied"
  of pmkRelayRefresh:
    if move.session != shown:
      # The plugins' session changes behind its tab, which shows it when
      # the tab is shown again.
      discard move.session.applyAction(move.relay)
      outcome = RuntimeOutcome()
      return ""
  if move.kind in {pmkRelayMove, pmkRelayRefresh}:
    if not move.session.applyAction(move.relay):
      outcome = RuntimeOutcome()
      return "'" & move.name & "' was not applied: the session has no such " &
             "action"
    if move.kind == pmkRelayRefresh:
      outcome.refreshesSession = true
      outcome.repaint = true
  ""
