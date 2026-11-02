## viewmodels/step_list_vm.nim
##
## StepListVM — ViewModel for the Step List panel.
##
## The Step List panel renders a linear list of recently-executed
## source lines around the current debugger position.  Each row carries
## a ``delta`` offset relative to the current step, a small
## ``StepLineLocation`` (path / line / function / rrTicks) and the
## source-line text the step landed on.  ``Call`` and ``Return`` rows
## also carry a list of ``expression = repr`` pairs that the view
## renders inline.  The shape mirrors the legacy ``LineStep`` record;
## see ``store/types.StepLine`` for the field-level docs.
##
## Reactive surface:
## - ``lineSteps``           — the rendered rows in display order.
## - ``currentLocation``     — the live debugger location used to flag
##                              the ``active-step-line`` row.
## - ``panelHeight``         — number of rows the panel can show
##                              (used by ``loadStepLinesFor`` to size
##                              the backend request — the legacy code
##                              measured ``offsetHeight`` of the GL
##                              container directly).
##
## Derived:
## - ``isEmpty``              — convenience for the empty-state.
##
## Actions:
## - ``setLineSteps``         — replace the row list wholesale.
## - ``appendLineSteps``      — append a streamed batch and re-sort by
##                              ``delta`` (mirrors the legacy
##                              ``onUpdatedLoadStepLines`` handler).
## - ``clearLineSteps``       — drop every row (used during a session
##                              switch / fresh ``loadStepLinesFor``).
## - ``setCurrentLocation``   — refresh the active-row reference.
## - ``setViewport``          — the rows the pane shows (its viewport).
## - ``loadStepLinesFor``     — emit a ``ct/load-step-lines`` request
##                              for the given location.  In production
##                              the legacy ``FlowService.loadStepLines``
##                              issues an ``IPC`` message; routing the
##                              request through the backend lets
##                              headless tests verify the end-to-end
##                              flow without depending on Karax.
## - ``jumpToStepLine``       — emit a ``ct/goto-ticks`` request
##                              carrying the row's ``rrTicks`` so the
##                              live debugger jumps to that step.
##
## REACHABILITY, so the next reader does not assume more than is true:
## this pane cannot currently be opened by a user.  Its menu entry is
## commented out (``ui_js.nim``, ``# element "Step List", aStepList``),
## ``aStepList`` has no binding in ``config/default_config.yaml``, the
## pane is absent from ``config/default_layout.json`` (which is also
## what the web bundle loads), and ``Content.StepList`` is listed in
## ``editModeHiddenContentIds()``.
##
## The engine answers ``ct/load-step-lines`` (``dap_handler.rs::
## load_step_lines`` over ``StepLinesLoader``, materialized traces only),
## and ``loadStepLinesFor`` applies the answer itself, so a front-end that
## drives this VM gets rows. The desktop component (``ui/step_list.nim``)
## still sends the legacy ``CODETRACER::load-step-lines`` IPC message,
## which nothing in the index process handles; making the pane reachable
## on the desktop is a separate decision (no spec lists the pane among the
## Core Panes) and would route that component through this VM first.
##
## The VM consumes the same ``LoadStepLinesUpdate`` semantics as the
## legacy component: ``onUpdatedLoadStepLines`` would call
## ``self.lineSteps.concat(update.results)`` and re-sort by ``delta``;
## ``onCompleteMove`` would re-fetch the rows for the new location.
## ``appendLineSteps`` and ``loadStepLinesFor`` reproduce that contract
## platform-neutrally.

import std/[algorithm, json]

import isonim/core/[signals, computation, owner, batch, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
import ../viewport
export viewport

const DEFAULT_STEP_LIST_PANEL_HEIGHT* = 16
  ## The row capacity the DOM view binding reports when it cannot measure the
  ## GL container (the panel is not in the layout). The fallback is the
  ## binding's to apply, not this ViewModel's: an unmeasured viewport issues
  ## no request (Viewport-Driven-Loading V2). ~16 rows roughly matches a
  ## half-screen panel.

type
  StepListVM* = ref object of ViewModel
    ## Reactive state for the Step List panel.
    store*: ReplayDataStore

    # -- Mutable state --
    lineSteps*: Signal[seq[StepLine]]
    currentLocation*: Signal[StepLineLocation]
    viewport*: Signal[Viewport]
      ## What the view was given (`setViewport`). `panelHeight` is its rows,
      ## kept for the collaboration registry and the view.
    panelHeight*: Signal[int]

    # -- Derived state --
    isEmpty*: Memo[bool]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc cmpByDelta(a, b: StepLine): int =
  ## Comparator used to keep the list sorted by ``delta`` after
  ## streaming appends.  Mirrors the legacy ``sort(lineSteps, ...)``
  ## call in ``onUpdatedLoadStepLines``.
  cmp(a.delta, b.delta)

proc isCurrentRow*(line: StepLine; loc: StepLineLocation): bool =
  ## True when the given ``line`` describes the current debugger
  ## position.  Same triple-equality the legacy ``lineStepLineView``
  ## proc used (``rrTicks`` + ``path`` + ``line``).
  line.location.rrTicks == loc.rrTicks and
    line.location.path == loc.path and
    line.location.line == loc.line

proc stepLinesOf(body: JsonNode): seq[StepLine] =
  ## The rows of a ``ct/load-step-lines`` answer — the engine's
  ## ``LoadStepLinesUpdate`` (``db-backend/src/task.rs``): ``results`` is a
  ## list of ``LineStep``, whose ``kind`` is ``LineStepKind``'s ordinal
  ## (Line 0 / Call 1 / Return 2, ``serde_repr``) and whose ``values`` are
  ## ``{expression, value}`` pairs, rendered here with the call-trace
  ## argument budget (``callArgTextOf``) so the view gets text.
  if body.isNil or body.kind != JObject:
    return
  let results = body.getOrDefault("results")
  if results.isNil or results.kind != JArray:
    return
  for r in results:
    if r.kind != JObject:
      continue
    let kindOrd = r.getOrDefault("kind").getInt(0)
    let loc = r.getOrDefault("location")
    var line = StepLine(
      kind: (if kindOrd in ord(low(StepLineKind))..ord(high(StepLineKind)):
               StepLineKind(kindOrd)
             else: slkLine),
      delta: r.getOrDefault("delta").getInt(0),
      sourceLine: r.getOrDefault("sourceLine").getStr(""))
    if not loc.isNil and loc.kind == JObject:
      line.location = StepLineLocation(
        path: loc.getOrDefault("path").getStr(""),
        line: loc.getOrDefault("line").getInt(0),
        functionName: loc.getOrDefault("functionName").getStr(""),
        rrTicks: loc.getOrDefault("rrTicks").getInt(0))
    let values = r.getOrDefault("values")
    if not values.isNil and values.kind == JArray:
      for v in values:
        line.values.add StepLineFlowValue(
          expression: v.getOrDefault("expression").getStr(""),
          value: callArgTextOf(v))
    result.add line

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setLineSteps*(vm: StepListVM; lines: seq[StepLine]) =
  ## Replace the row list wholesale.  Used by the legacy
  ## ``loadStepLinesFor`` flow when a fresh request is issued — the
  ## previous rows are discarded before the streamed batches arrive.
  ## The list is sorted by ``delta`` here so callers can pass an
  ## unordered batch and still get a stable visual order.
  var sorted = lines
  sort(sorted, cmpByDelta)
  vm.lineSteps.val = sorted

proc appendLineSteps*(vm: StepListVM; lines: seq[StepLine]) =
  ## Append a streamed batch and re-sort by ``delta``.  Mirrors the
  ## legacy ``onUpdatedLoadStepLines`` handler:
  ## ``self.lineSteps = self.lineSteps.concat(update.results)`` followed
  ## by ``sort(... cmp delta)``.
  if lines.len == 0:
    return
  var entries = vm.lineSteps.val
  for line in lines:
    entries.add(line)
  sort(entries, cmpByDelta)
  vm.lineSteps.val = entries

proc clearLineSteps*(vm: StepListVM) =
  ## Reset the row list.  Called when starting a fresh request so the
  ## previous run's rows do not bleed into the next.
  vm.lineSteps.val = @[]

proc setCurrentLocation*(vm: StepListVM; loc: StepLineLocation) =
  ## Refresh the live debugger location used to flag the
  ## ``active-step-line`` row.  The legacy view re-read this every
  ## render via ``data.services.debugger.location``; the VM caches it
  ## as a signal so view re-renders do not require touching the legacy
  ## record.
  vm.currentLocation.val = loc

proc setViewport*(vm: StepListVM; v: Viewport) =
  ## The size the view was given — the ONE way a view tells this ViewModel
  ## how many rows it shows (Viewport-Driven-Loading V1). The view binding
  ## measures it (`offsetHeight div STEP_LINE_HEIGHT_PX`) and applies the
  ## GUI's fallback when it cannot measure; an unmeasured list asks for
  ## nothing (`loadStepLinesFor`).
  batch(proc() =
    vm.viewport.val = v
    vm.panelHeight.val = max(0, v.rows))

proc loadStepLinesFor*(vm: StepListVM; loc: StepLineLocation) =
  ## Issue a ``ct/load-step-lines`` request for ``loc``.  Resets the
  ## row list before the streamed responses arrive, mirroring the
  ## legacy ``loadStepLinesFor`` proc.  The backend reply lands as
  ## individual ``appendLineSteps`` calls dispatched by the UI bridge.
  ##
  ## THE PAYLOAD IS A ``LoadStepLinesArg``, because that is the only
  ## shape anything on this wire declares.  Both peers already agree on
  ## it and always did — ``task.rs``'s ``LoadStepLinesArg`` and
  ## ``common_types/debugger_features/stepping.nim``'s are the same
  ## record: a nested ``location``, a ``forwardCount`` and a
  ## ``backwardCount``.
  ##
  ## This used to send ``{path, line, rrTicks, count}`` — flat, and with
  ## ONE count.  Not one field of that object appears in either
  ## declaration: the destination sat at the top level, where a
  ## ``LoadStepLinesArg`` never looks, and ``count`` names neither
  ## direction.  It is the same invention as ``no_source_vm.jumpBack``'s
  ## ``{previousPath, action}`` (codetracer#698), with one difference
  ## worth stating: ``LoadStepLinesArg`` is NOT ``#[serde(default)]`` at
  ## container level, so this payload could never have silently
  ## succeeded the way a zeroed ``Location`` did — it would have failed
  ## ``load_args`` on the missing ``location`` field.  A hard error, but
  ## only once something dispatches the command at all.
  ##
  ## The single measured capacity is sent as BOTH counts, which is the
  ## legacy contract rather than a choice made here:
  ## ``ui/step_list.nim`` measures one ``panelHeight()`` and
  ## ``flow_service.loadStepLines`` fills ``forwardCount`` and
  ## ``backwardCount`` from it.
  ##
  ## The engine answers with the whole window in one ``LoadStepLinesUpdate``
  ## (``finish: true``); the rows replace the list, unless the current
  ## location has moved on to a newer request in the meantime.
  vm.clearLineSteps()
  vm.setCurrentLocation(loc)
  # The rows the pane shows, either side of the current line; an unmeasured
  # pane asks for nothing (Viewport-Driven-Loading V2).
  let count = vm.panelHeight.val
  if count <= 0:
    return
  let args = %*{
    "location": {
      "path": loc.path,
      "line": loc.line,
      "rrTicks": loc.rrTicks,
      "functionName": loc.functionName,
      "highLevelPath": loc.path,
      "highLevelLine": loc.line,
    },
    "forwardCount": count,
    "backwardCount": count,
  }
  # The answer is the whole window at once (`finish: true`); it replaces the
  # rows unless a newer request has moved the list on since.
  let asked = loc.rrTicks
  async_compat.onComplete(vm.store.backend.send("ct/load-step-lines", args),
    onSuccess = proc(response: JsonNode) =
      if responseSucceeded(response) and
          vm.currentLocation.val.rrTicks == asked:
        vm.setLineSteps(stepLinesOf(responseBody(response))),
    onError = proc(msg: string) = discard)

proc jumpToStepLine*(vm: StepListVM; line: StepLine) =
  ## Move the debugger to the step the clicked row names.
  ##
  ## Emits ``ct/goto-ticks`` — the same command the Event Log row click
  ## already uses (``event_log_vm.jumpToCounterpart``) for this exact
  ## gesture-class: "put the session on the tick this row names".
  ##
  ## WHY NOT ``ct/local-step-jump``, which is what the legacy view used
  ## (``DebuggerService.lineStepJump`` → ``jumpToLocalStep(..., rrTicks =
  ## lineStep.location.rrTicks)``): the two handlers do the *same work*
  ## on a materialized trace —
  ##
  ##     local_step_jump: replay.jump_to(StepId(arg.rr_ticks));
  ##                      complete_move(...)
  ##     goto_ticks:      replay.jump_to(StepId(arg.ticks));
  ##                      complete_move(...); respond_dap(...)
  ##
  ## — but only ``goto_ticks`` answers the request.  ``local_step_jump``
  ## takes its request as ``_req`` and never calls ``respond_dap``, so
  ## the caller's future never settles.  That is not academic: the native
  ## ``BackendService`` built by ``stdio_backend.toBackendService``
  ## implements ``send`` as a *blocking* ``sendDapRequest``, so routing
  ## this click at ``ct/local-step-jump`` hangs any native/headless
  ## caller outright (measured — it deadlocked the test in this commit's
  ## first draft), and leaves an unsettled promise on the JS path.
  ## ``ct/goto-ticks`` is dispatched, moves the session, AND responds.
  ##
  ## ``threadId`` is sent explicitly and is NOT optional: Rust's
  ## ``GoToTicksArguments`` has no ``#[serde(default)]``, so omitting it
  ## fails the whole request with ``missing field `threadId``` (that is a
  ## live bug in ``event_log_vm``'s copy of this payload, which sends
  ## ``rrTicks``/``ticks`` and no ``threadId``).  ``dap.nim`` only stamps
  ## a ``threadId`` when a *multi-process* session is active
  ## (the session's ``DapApi.routingThreadId != 0``), and overwrites ours when it does —
  ## which is the desired precedence, since that value is the routing id.
  ##
  ## KNOWN GAP, deliberately not papered over: legacy's *non*-materialized
  ## arm did ``step(StepIn, repeat = delta, reverse = delta < 0)``, and
  ## DAP has no repeat count — ``dap_command_to_step_action`` maps
  ## ``"stepIn"`` to ``(Action::StepIn, false)`` with no way to express
  ## ``repeat``.  A tick jump is the right answer for materialized
  ## traces (the only kind the web product replays); reproducing legacy's
  ## rr/gdb semantics needs an engine-side arm that branches on
  ## ``trace_kind``.  Recorded rather than guessed at, because this pane
  ## is not reachable today (see the module header).
  ##
  ## This used to emit ``ct/line-step-jump`` — a string absent from
  ## ``EVENT_KIND_TO_DAP_MAPPING``, from ``VALID_DAP_COMMANDS`` and from
  ## both dispatch tables in ``dap_server.rs``.  ``ui_js.nim``'s
  ## production ``sendProc`` resolves the command through
  ## ``dapCommandToEventKind`` before any transport is touched, and that
  ## raises ``ValueError`` on an unmapped string, so the call threw
  ## synchronously out of the click handler rather than failing on the
  ## wire.
  let threadId =
    if vm.store.debugger.val.threadId != 0'u32:
      int(vm.store.debugger.val.threadId)
    else:
      1
  let args = %*{
    "threadId": threadId,
    "ticks": line.location.rrTicks,
  }
  discard vm.store.backend.send("ct/goto-ticks", args)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createStepListVM*(store: ReplayDataStore): StepListVM =
  ## Create a StepListVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty placeholder on first paint.
  withViewModel proc(dispose: proc()): StepListVM =
    let lineSteps = createSignal(newSeq[StepLine]())
    let currentLocation = createSignal(StepLineLocation())
    let viewport = createSignal(Viewport())
    let panelHeight = createSignal(0)

    let isEmpty = createMemo[bool] proc(): bool =
      lineSteps.val.len == 0

    StepListVM(
      store: store,
      lineSteps: lineSteps,
      currentLocation: currentLocation,
      viewport: viewport,
      panelHeight: panelHeight,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )
