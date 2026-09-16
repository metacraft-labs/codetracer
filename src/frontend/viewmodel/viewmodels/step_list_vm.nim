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
## - ``setPanelHeight``       — cache the latest measured row capacity.
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
## ``editModeHiddenContentIds()``.  Even when opened programmatically it
## renders no rows: ``lineSteps`` is only ever filled by
## ``ui/step_list.nim``'s ``onUpdatedLoadStepLines``, whose producer —
## ``dap_handler.rs::load_step_lines`` — is a stub that builds
## ``vec![]`` and has its ``send_event`` commented out, while the
## ``ct/load-step-lines`` DAP command has no arm at all.
##
## The ``jumpToStepLine`` fix below is therefore a latent-defect fix,
## not a live one.  It is still worth having — the command it used to
## send could never have worked — but do not un-comment the menu entry
## to "make it reachable" until ``load_step_lines`` actually returns
## rows, or the pane will open empty and the gesture will still be
## untestable.
##
## The VM consumes the same ``LoadStepLinesUpdate`` semantics as the
## legacy component: ``onUpdatedLoadStepLines`` would call
## ``self.lineSteps.concat(update.results)`` and re-sort by ``delta``;
## ``onCompleteMove`` would re-fetch the rows for the new location.
## ``appendLineSteps`` and ``loadStepLinesFor`` reproduce that contract
## platform-neutrally.

import std/[algorithm, json]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const DEFAULT_STEP_LIST_PANEL_HEIGHT* = 16
  ## Conservative default for the row capacity used by
  ## ``loadStepLinesFor`` when the host has not yet measured the GL
  ## container.  The legacy code defaulted to ``offsetHeight / 26``;
  ## ~16 rows roughly matches a half-screen panel and avoids issuing a
  ## zero-row request.
  ##
  ## Exported because the HOST needs the same number: `ui/step_list.nim`
  ## measures the GL container's `offsetHeight`, and when the panel is not in
  ## the layout at all there is nothing to measure and this is the answer. Two
  ## copies of "the default row capacity" would be free to disagree.

type
  StepListVM* = ref object of ViewModel
    ## Reactive state for the Step List panel.
    store*: ReplayDataStore

    # -- Mutable state --
    lineSteps*: Signal[seq[StepLine]]
    currentLocation*: Signal[StepLineLocation]
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

proc setPanelHeight*(vm: StepListVM; rows: int) =
  ## Cache the latest measured row capacity.  ``rows`` is the number of
  ## rows the panel can show — the legacy code computed it as
  ## ``offsetHeight div STEP_LINE_HEIGHT_PX``.  Values <=0 are clamped
  ## to ``DEFAULT_STEP_LIST_PANEL_HEIGHT`` so a missing measurement
  ## does not produce a degenerate request.
  if rows <= 0:
    vm.panelHeight.val = DEFAULT_STEP_LIST_PANEL_HEIGHT
  else:
    vm.panelHeight.val = rows

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
  ## Correcting the shape does NOT make this request work, and is not
  ## meant to: ``ct/load-step-lines`` is absent from
  ## ``VALID_DAP_COMMANDS`` and has no arm in either ``dap_server.rs``
  ## dispatch table, so the two cases covering it stay red and stay
  ## registered in ``ci/lib/known-test-failures.tsv``.  What changes is
  ## that they now pin what both peers declare instead of a shape that
  ## would still have been wrong the day an engine arm landed.
  vm.clearLineSteps()
  vm.setCurrentLocation(loc)
  let count =
    if vm.panelHeight.val <= 0: DEFAULT_STEP_LIST_PANEL_HEIGHT
    else: vm.panelHeight.val
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
  discard vm.store.backend.send("ct/load-step-lines", args)

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
  ## (``activeSessionThreadId != 0``), and overwrites ours when it does —
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
    let panelHeight = createSignal(DEFAULT_STEP_LIST_PANEL_HEIGHT)

    let isEmpty = createMemo[bool] proc(): bool =
      lineSteps.val.len == 0

    StepListVM(
      store: store,
      lineSteps: lineSteps,
      currentLocation: currentLocation,
      panelHeight: panelHeight,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )
