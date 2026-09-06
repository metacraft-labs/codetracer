## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade
## — and never `viewmodel/*` directly.
##
## app/origin_binding.nim — CTUI-10. §4.2's `o` / `O` ("Value Origin
## Tracking") over `OriginChainVM`. THE HEADLINE FEATURE of this front-end.
##
## ## WHY THIS FILE IS NOT `app/controllers/origin.nim`
##
## CTUI-10's deliverable list names `app/controllers/origin.nim`. There is no
## `app/controllers/` in this tree and never has been: CTUI-5, CTUI-6, CTUI-7
## and CTUI-8 each faced the same shape — something has to READ the ViewModels
## so the views can stay pure functions of a value — and each put it in a
## top-level `<subject>_binding.nim` (`source_binding`, `call_stack_binding`,
## `variables_binding`, `timeline_binding`) beside a pure `views/<subject>.nim`.
## This module does exactly what those four do, so it is spelled the way those
## four are spelled. A fifth directory holding one file would make the tree's
## one convention two.
##
## ## THE ORIGIN DATA IS REAL, AND THAT WAS ESTABLISHED BY RUNNING IT
##
## Four ViewModel fields in this layer have turned out to be filled by nothing
## — `PointListVM.points` (CTUI-5), `store.locals.globals` (CTUI-7),
## `TimelineVM.markers` and `EventLogVM.eventRows` (CTUI-8) — so the first
## question this milestone had to answer was whether `OriginChainVM` is a fifth.
## IT IS NOT. Measured on `noir_space_ship` through a real `replay-server`,
## 2026-09-06:
##
##   * `ct/originChain` is a real dispatch arm (`dap_server.rs`'s
##     `"ct/originChain" => handler.origin_chain`), reaching
##     `Handler::compute_origin_chain` and, for a materialized trace,
##     `origin_chain_inferred_with_metadata`.
##   * `remaining_shield`, queried at tick 283 (`shield.nr:6`), answered ONE
##     hop of kind `okComputational`, confidence 0.9, terminator
##     `tkwComputational`,
##     at `shield.nr:14`, **tick 220** — a previous iteration of the loop. The
##     hop's `sourceExpr` is `regeneration` and its `sourceText` is
##     `remaining_shield += regeneration;`.
##   * `mass` answered a FOUR-hop chain; `did_survive_positive`, queried at the
##     end of `main`, answered a hop at tick 671 — 643 ticks back.
##   * Seeking to the hop's `location.rrTicks` lands the engine at exactly
##     `location.path` and `location.line`, and `stackTrace` at the destination
##     reports the same line. Three surfaces agree.
##
## ONE MEASURED DISAGREEMENT, recorded rather than smoothed over, AND ITS CAUSE
## IS IN `db.rs`: a hop's `sourceText` is the statement the CLASSIFIER matched,
## and `location.line` is the line the recorded STEP is on. For
## `remaining_shield` above they are twelve and fourteen —
## `remaining_shield += regeneration;` is line 12 of `shield.nr` and the step at
## tick 220 is on line 14.
##
## `src/db-backend/src/db.rs`, in `origin_chain_inferred_with_metadata`'s step
## "(2) Resolve the source line", resolves the producing line in TWO PASSES:
## the line of `last_change_step`, and — when that line does not parse as an
## assignment naming the target — the immediately preceding step in the same
## frame, which is the case of a recorder that snapshots variables at line entry
## rather than after the line executes. Noir's is one, so the second pass fires
## here. It assigns only `line_text`; the step it found is bound as `_prev_step`
## and DISCARDED, so `location` keeps naming the later step.
##
## THIS MODULE NAVIGATES BY `location` ANYWAY, and the reason is that
## `sourceText` names no tick: `location.rrTicks`, `location.path`,
## `location.line` and `stackTrace` at the destination are mutually consistent
## and are the only coordinate a seek can use. The price is that for such a
## recorder `o` lands ONE RECORDED STEP AFTER the write — `shield.nr:14` where
## §4.2's "the exact step where the variable was written" is `shield.nr:12`.
## That is an ENGINE DEFECT, not a tie between two equally good answers, and it
## is filed rather than absorbed. `tests/test_value_origin_jump.nim` asserts
## both fields, including that they differ, so the day `db.rs` keeps
## `_prev_step` the suite says so instead of quietly moving the destination.
##
## ## THE QUERY IS ASYNCHRONOUS AND ITS PENDING STATE IS VISIBLE
##
## CTUI-10's named risk: "origin queries are slow on large traces and the pane
## appears hung", and its mitigation: "the query is asynchronous with a visible
## pending state, and the test asserts the pending state appears — an
## optimization that hides a hang behind a frozen screen is worse than the
## wait."
##
## `OriginChainVM` already has that shape and this module uses it rather than
## inventing a second one:
##
##   * `onShowOrigin` sets `loading = true`, bumps `latestRequestId`, pushes a
##     breadcrumb and sends `ct/originChain`. `originQueryState` reads
##     `oqPending` off that signal.
##   * The chain comes back as the `ct/updated-origin-chain` EVENT that
##     `Handler::respond_origin_chain` emits beside the response — measured:
##     exactly one event is queued per `onShowOrigin`. `applyOriginEvents`
##     decodes it and calls `applyChainResponse`, which clears `loading`.
##   * `onCancelLoad` bumps the request id so a late answer is ignored, and
##     `applyChainResponse` refuses a stale `requestId` on its own.
##
## The response is taken from the EVENT rather than from `send`'s future because
## `onShowOrigin` discards that future by design (it is the desktop's
## fire-and-forget action proc). Reading the event is not a workaround: it is
## the documented event-driven path — "so the event-driven UI can react to lazy
## continuations without re-issuing a fresh request" — and it means this
## front-end issues exactly ONE `ct/originChain` per `o`.
##
## ## WHAT `o` AND `O` MEAN, WHICH IS A READING OF §4.2 AND IS MARKED AS ONE
##
## §4.2: `o` is "Jump to Value Origin — jumps to the exact step where the
## variable/expression under cursor was written"; `O` is "Reverse Origin — jumps
## to the next point in time where this value is modified".
##
## An origin CHAIN is a walk BACKWARDS through causes. So:
##
##   * `o` walks one hop DEEPER (further back in time) and pushes the tick it
##     left onto a return stack. The first `o` on a fresh selection has no chain
##     yet, so it issues the query and the walk happens when the chain lands.
##   * `O` pops that stack, which moves FORWARD in time to the next point at
##     which the value was written — the previous hop, or, at the top of the
##     stack, the tick the question was asked from.
##
## That is the only reading under which the two keys are inverses and under
## which `O`'s "next point in time" is a point the recording actually contains.
## It is written down here because it is a reading rather than a transcription,
## the same way `keymap.nim` records `Ctrl+p`'s.
##
## ## No mocks
##
## Nothing here constructs a ViewModel, a store or a backend. It takes the ones
## a real session built, and it decodes the engine's own event.

import std/[json, options, strutils]

import codetracer_embed

import ./views/styled_row

export styled_row

const
  OriginEventName* = "ct/updated-origin-chain"
    ## The DAP event `Handler::respond_origin_chain` emits beside every
    ## `ct/originChain` response (`dap.rs`'s `updated_origin_chain_event`).

  OriginPendingText* = "origin: querying…"
    ## What the notification area reads while a query is in flight. THE VISIBLE
    ## PENDING STATE — see this module's header.

  OriginIdleText* = "origin: nothing selected"
  OriginEmptyChainText* = "origin: no recorded write for this value"
  OriginExhaustedText* = "origin: at the start of the chain"
  OriginAtQueryText* = "origin: back at the question"

  MaxOriginHops* = 16
    ## What `o` asks for. `origin_chain_types.DEFAULT_ORIGIN_MAX_HOPS` is the
    ## published default (spec §6.1 numerics) and this front-end does not
    ## second-guess it; the constant is named here so a test can assert the
    ## request carried it rather than whatever the VM's preferences happened to
    ## hold.

type
  OriginQueryState* = enum
    ## Where an origin query is, as ONE value a status bar can render.
    ##
    ## Derived from `OriginChainVM.loading` and `activeChain` rather than held,
    ## because a second copy of "is a query in flight" is a second thing that
    ## can be stale — and a stale "ready" is exactly the frozen screen the risk
    ## mitigation is about.
    oqIdle = "idle"
    oqPending = "pending"
    oqReady = "ready"

  OriginStep* = object
    ## One hop, as the navigator needs it: WHERE to go and WHY.
    tick*: uint64
    path*: string
    line*: int
    targetExpr*: string
    sourceExpr*: string
    sourceText*: string
    kind*: OriginKind
    confidence*: float

  OriginNavigator* = object
    ## `o` / `O` as a value. Holds the chain in hand, how deep `o` has walked,
    ## and the ticks `O` returns through.
    variable*: string
      ## The variable the chain in hand answers for. "" means no chain.
    queryTick*: uint64
      ## The tick the question was asked from — the bottom of the return stack.
    steps*: seq[OriginStep]
    depth*: int
      ## How many hops `o` has walked. 0 means "standing at the question".
    returnStack*: seq[uint64]
    terminator*: TerminatorKindWire
    truncated*: bool

proc initOriginNavigator*(): OriginNavigator =
  OriginNavigator(variable: "", queryTick: 0, steps: @[], depth: 0,
                  returnStack: @[], terminator: tkwUnknownSource,
                  truncated: false)

# ---------------------------------------------------------------------------
# The query
# ---------------------------------------------------------------------------

proc originQueryState*(vm: OriginChainVM): OriginQueryState =
  ## THE ONE READER of "is a query in flight". See the module header.
  if vm.isNil:
    return oqIdle
  if vm.loading.val:
    return oqPending
  if vm.activeChain.val.isSome:
    return oqReady
  oqIdle

proc beginOriginQuery*(vm: OriginChainVM; expression: string;
                       location: Location; stepId: int64 = -1) =
  ## Issue `ct/originChain` through `OriginChainVM`'s OWN action proc.
  ##
  ## `setDefaultMaxHops` first, so the request carries `MaxOriginHops` rather
  ## than whatever a previous surface left in the preferences — `onShowOrigin`
  ## reads `preferences.defaultMaxHops` to build the arguments, and a front-end
  ## that did not state its budget would inherit one.
  if vm.isNil:
    return
  vm.setDefaultMaxHops(MaxOriginHops)
  vm.onShowOrigin(expression, location, stepId)

proc cancelOriginQuery*(vm: OriginChainVM) =
  ## `Esc` at a pending query. `onCancelLoad` clears the spinner AND bumps the
  ## request id, so the answer that is already on the wire is ignored when it
  ## lands rather than repainting a pane the user has left.
  if vm.isNil:
    return
  vm.onCancelLoad()

proc chainFromEvent*(event: JsonNode): (bool, OriginChain) =
  ## Decode one `ct/updated-origin-chain` event body.
  ##
  ## Returns `(false, …)` for anything else, so a caller can hand this module
  ## its whole drained event queue without pre-filtering — and so a run in
  ## which the event NEVER arrives is distinguishable from one in which it
  ## arrived empty.
  if event.isNil or event.kind != JObject:
    return (false, OriginChain())
  if event.getOrDefault("event").getStr("") != OriginEventName:
    return (false, OriginChain())
  let body = event.getOrDefault("body")
  if body.isNil or body.kind != JObject:
    return (false, OriginChain())
  (true, parseOriginChain(body))

proc applyOriginEvents*(vm: OriginChainVM;
                        events: openArray[JsonNode]): int =
  ## Apply every `ct/updated-origin-chain` in `events` to the ViewModel.
  ##
  ## Returns HOW MANY were applied, not whether any were: "exactly one event
  ## per query" is a property a test can count, and a path that answered twice
  ## would otherwise be invisible.
  result = 0
  if vm.isNil:
    return
  for event in events:
    let (ok, chain) = chainFromEvent(event)
    if ok:
      vm.applyChainResponse(chain, vm.latestRequestId.val)
      inc result

# ---------------------------------------------------------------------------
# The chain, as steps
# ---------------------------------------------------------------------------

proc stepsOf*(chain: OriginChain): seq[OriginStep] =
  ## The chain's hops as navigable steps, in chain order — nearest cause first.
  ##
  ## A hop whose `location.rrTicks` is 0 AND whose path is empty is DROPPED:
  ## it names no recorded step, so `o` has nowhere to go and a navigator that
  ## kept it would seek to tick 0 and call that the origin. That is codetracer
  ## #698's failure mode exactly, one layer up.
  result = @[]
  for hop in chain.hops:
    if hop.location.path.len == 0 and hop.location.rrTicks == 0'u64:
      continue
    result.add OriginStep(
      tick: hop.location.rrTicks,
      path: hop.location.path,
      line: hop.location.line,
      targetExpr: hop.targetExpr,
      sourceExpr: hop.sourceExpr,
      sourceText: hop.sourceText,
      kind: hop.kind,
      confidence: hop.confidence)

proc adopt*(nav: var OriginNavigator; chain: OriginChain;
            variable: string; queryTick: uint64) =
  ## Take a freshly arrived chain as the one `o` walks.
  ##
  ## The depth and the return stack are RESET, because a new question is a new
  ## walk: carrying a stack across two chains would let `O` return to a tick
  ## that belongs to a variable nobody is looking at.
  nav.variable = variable
  nav.queryTick = queryTick
  nav.steps = stepsOf(chain)
  nav.depth = 0
  nav.returnStack = @[]
  nav.terminator = chain.terminator.kind
  nav.truncated = chain.truncated

proc answersFor*(nav: OriginNavigator; variable: string;
                 tick: uint64): bool =
  ## Whether the chain in hand answers `o` for this (variable, tick).
  ##
  ## The tick comparison is against `queryTick` and NOT against the current
  ## position, because walking the chain moves the position: after one `o` the
  ## debugger is at the origin and the chain still answers for the question it
  ## was asked.
  nav.variable.len > 0 and nav.variable == variable and
    (nav.depth > 0 or nav.queryTick == tick)

proc needsQuery*(nav: OriginNavigator; variable: string;
                 tick: uint64): bool =
  ## Whether `o` must issue a NEW query. The inverse of `answersFor`, named so
  ## a caller reads the intent rather than a negation.
  not nav.answersFor(variable, tick)

proc advance*(nav: var OriginNavigator): (bool, OriginStep) =
  ## `o`: one hop deeper into the chain. Returns the step to seek to.
  ##
  ## `false` at the end of the chain — the caller REPORTS that (see
  ## `OriginExhaustedText`) rather than doing nothing, which is CTUI-10's
  ## second contract applied to a key instead of to a command.
  if nav.depth >= nav.steps.len:
    return (false, OriginStep())
  let from0 =
    if nav.depth == 0: nav.queryTick else: nav.steps[nav.depth - 1].tick
  nav.returnStack.add from0
  let step = nav.steps[nav.depth]
  inc nav.depth
  (true, step)

proc retreat*(nav: var OriginNavigator): (bool, uint64) =
  ## `O`: back the way `o` came. Returns the tick to seek to.
  if nav.returnStack.len == 0 or nav.depth == 0:
    return (false, 0'u64)
  let tick = nav.returnStack[^1]
  nav.returnStack.setLen(nav.returnStack.len - 1)
  dec nav.depth
  (true, tick)

proc currentStep*(nav: OriginNavigator): (bool, OriginStep) =
  ## The hop `o` last landed on, or `(false, …)` at the question.
  if nav.depth <= 0 or nav.depth > nav.steps.len:
    return (false, OriginStep())
  (true, nav.steps[nav.depth - 1])

# ---------------------------------------------------------------------------
# What the user sees
# ---------------------------------------------------------------------------

proc describeKind*(kind: OriginKind): string =
  ## The one-word account of a hop, for the notification area. §3.3.6's
  ## "transient status messages" is the whole of §4.2's origin UI in this
  ## front-end — there is no origin PANE in §3.3.
  case kind
  of okTrivialCopy: "copied from"
  of okFieldAccess: "field of"
  of okIndexAccess: "index of"
  of okComputational: "computed from"
  of okFunctionCall: "returned by"
  of okLiteral: "literal"
  of okReturnCapture: "captured from"
  of okFunctionReturn: "returned from"
  of okParameterPass: "passed as"
  of okCrossThreadCopy: "copied across threads"
  of okUnknown: "written at"

proc describeTerminator*(kind: TerminatorKindWire): string =
  ## Why the chain stopped. Rendered when `o` reaches the end, so "there is
  ## nothing before this" and "the budget ran out" are different reports.
  case kind
  of tkwUnknownSource: "the classifier could not name a source"
  of tkwLiteral: "a literal"
  of tkwComputational: "a computation"
  of tkwParameterAtRecordStart: "a parameter at the start of the recording"
  of tkwReadFromExternal: "a read from outside the recording"
  of tkwRecordingStart: "the start of the recording"
  of tkwUnknownVariable: "an unknown variable"
  of tkwDepthLimit: "the hop budget"
  of tkwOutOfBudget: "the scan budget"

proc originNotification*(nav: OriginNavigator;
                         state: OriginQueryState): string =
  ## The §3.3.6 notification line for the current origin state. NEVER EMPTY
  ## when something has been asked, because an empty notification and a
  ## finished query look the same on a terminal.
  case state
  of oqPending:
    OriginPendingText
  of oqIdle:
    if nav.variable.len == 0: OriginIdleText else: OriginEmptyChainText
  of oqReady:
    if nav.steps.len == 0:
      OriginEmptyChainText
    else:
      let (has, step) = nav.currentStep()
      if not has:
        OriginAtQueryText
      else:
        nav.variable & " " & describeKind(step.kind) & " " &
          step.sourceExpr.strip() & " @ " & pathBaseName(step.path) & ":" &
          $step.line & " (tick " & $step.tick & ", hop " & $nav.depth &
          "/" & $nav.steps.len & ")"

proc exhaustedNotification*(nav: OriginNavigator): string =
  ## What `o` reports when there is no hop left: the reason the ENGINE gave.
  OriginExhaustedText & " — " & describeTerminator(nav.terminator) &
    (if nav.truncated: " (truncated)" else: "")
