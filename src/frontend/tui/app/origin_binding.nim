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
## Four ViewModel fields in this layer had turned out to be filled by nothing
## — `PointListVM.points` (CTUI-5), `store.locals.globals` (CTUI-7),
## `TimelineVM.bounds` and `EventLogVM.eventRows` (CTUI-8) — so the first
## question this milestone had to answer was whether `OriginChainVM` is a fifth.
## (Two of the four have producers now: `eventRows` is
## `ReplayDataStore.eventLog.rows` and `PointListVM.points` is
## `ReplayDataStore.pointList.rows`, written by `applyEventLogResponse` and
## `applyTracepointResults`. Corrected 2026-09-17; the question below is
## unaffected, since it was always about `OriginChainVM`.)
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
##     at `shield.nr:12`, **tick 219** — a previous iteration of the loop. The
##     hop's `sourceExpr` is `regeneration` and its `sourceText` is
##     `remaining_shield += regeneration;`, which IS line 12.
##   * `mass` answered a FOUR-hop chain; `did_survive_positive`, queried at the
##     end of `main` (tick 1313), answered an `okFunctionCall` hop at
##     `main.nr:15`, **tick 670** — 643 ticks back — whose `sourceText` is
##     line 15 itself, `let did_survive_positive = shield::iterate_asteroids(…)`.
##     Its `stepId` is 671: see the defect note below for why the two differ.
##   * Seeking to the hop's `location.rrTicks` lands the engine at exactly
##     `location.path` and `location.line`, and `stackTrace` at the destination
##     reports the same line. Three surfaces agree.
##
## THIS MODULE NAVIGATES BY `location`, and the reason is that `sourceText`
## names no tick: `location.rrTicks`, `location.path`, `location.line` and
## `stackTrace` at the destination are mutually consistent and are the only
## coordinate a seek can use.
##
## ## AN ENGINE DEFECT THIS MODULE'S SUITE FOUND, AND ITS FIX (2026-09-06)
##
## The numbers above read `shield.nr:14`, tick 220 when CTUI-10 first measured
## them, and `sourceText` read line 12's statement — one hop, two accounts of
## itself, disagreeing. The cause was in `src/db-backend/src/db.rs`, in
## `origin_chain_inferred`'s step "(2) Resolve the source line": it resolves the
## producing line in TWO PASSES — the line of `last_change_step`, and, when that
## line does not parse as an assignment naming the target, the immediately
## preceding step in the same frame, which is the case of a recorder that
## snapshots variables at LINE ENTRY rather than after the line executes. Noir's
## is one, so the second pass fires here. It assigned only `line_text`; the step
## it found was bound as `_prev_step` and DISCARDED, so `location` kept naming
## the SNAPSHOT step and `o` landed ONE RECORDED STEP AFTER the write —
## `shield.nr:14` where §4.2's "the exact step where the variable was written"
## is `shield.nr:12`.
##
## That was an ENGINE DEFECT, not a tie between two equally good answers, and it
## was filed rather than absorbed: `tests/test_value_origin_jump.nim` asserted
## the two fields DIFFERED, as a tripwire. `db.rs` now keeps that step and
## builds the hop's `location` from it — which is what Value-Origin-Tracking.md
## §6.1.0 specified all along ("The hop's `location` correctly points at the
## source line that produced the value because the source line is read from the
## *previous* `Step` event"). The suite's assertion is INVERTED, not deleted, so
## it now guards the fix. The hop's `step_id` deliberately still names
## `last_change_step`: it is the engine-facing cursor, and
## `cross_process_origin.rs` correlates marker firings against it with a ±1-step
## tolerance sized for exactly this snapshot variance.
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

# The navigator, its steps and its notification lines are the shared
# `viewmodels/origin_walk` (PLAT-70 Part E: GPUI walks a chain by the same
# rule), reached through `codetracer_embed` and re-exported for this module's
# importers.
export OriginPendingText, OriginIdleText, OriginEmptyChainText,
  OriginExhaustedText, OriginAtQueryText, MaxOriginHops, OriginQueryState,
  OriginStep, OriginNavigator, initOriginNavigator, stepsOf, adopt,
  answersFor, advance, retreat, currentStep, describeKind,
  describeTerminator, originNotification, exhaustedNotification

# `OriginEventName`, the DAP event this module decodes, reaches this module
# through `codetracer_embed` (it is defined in `viewmodels/origin_chain_types`).
# It is defined there so the native hosts' `host/session_driver` can name it
# without importing this terminal module.

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
