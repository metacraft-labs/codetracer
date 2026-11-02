## Unit tests for Value Origin Tracking M4 viewmodel layer.
##
## Verifies that:
## - StateVM.onShowOrigin dispatches a `ct/originChain` request with
##   the correct camelCase wire shape (M4 verification #1).
## - OriginChainVM.activeChain updates when a decoded chain is applied
##   (M4 verification #2).
## - OriginChainVM.onSeekToHop invokes the host bridge, which is the
##   same pipeline `ct/history-jump` / `ct/goto-ticks` use
##   (M4 verification #3).
## - OriginChainVM.onPinChain populates `pinnedChains` AND fires the
##   scratchpad bridge (M4 verification #4).
## - The breadcrumb stack accepts repeated `(variable, step)` queries
##   and exposes a navigable LIFO API (M4 verification #5).
## - The State Pane badge logic (`badgeTextForSummary`,
##   `iconClassForTerminator`) returns the per-terminator icon class
##   and the middle-ellipsis-truncated expression
##   (M4 verifications #6 / #12 / #13).
## - The placeholder pill renders for `is_placeholder: true`
##   summaries and the placeholder click dispatches a batched
##   `ct/originSummary` request (M4 verifications #8 / #9 / #14).
## - The history-popover and omniscience-flow surfaces consume the
##   same shared badge rendering (M4 verifications #10 / #11).
##
## Tests where a real db-backend is needed live in
## `src/db-backend/tests/origin_viewmodel_test.rs` per the
## milestones-file Introduction's "real recordings, no mocks" rule —
## those test the *wire shape* directly against a real db-backend
## subprocess; this Nim file tests the *reactive VM transitions* that
## sit on top of the wire shape.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_origin_chain_vm.nim

import std/[json, options, sets, strutils, tables, unicode, unittest]

import isonim/core/async_compat
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/testing/mock_dom

import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, types]
import ../../viewmodels/[
  origin_chain_types,
  origin_chain_vm,
  origin_chain_bridges,
  state_vm,
  scratchpad_vm,
  command_palette_vm,
]
import ../../views/[state_view, isonim_state_view, isonim_scratchpad_view]

proc drain() =
  ## Flush whatever the reactive layer resolved synchronously.
  ##
  ## `drainPlatformCallbacks` rather than `asyncdispatch.poll(0)`: `poll` is
  ## only reachable through `std/asyncdispatch`, which drags in
  ## `std/nativesockets` and fails the JS compile outright
  ## (`undeclared identifier: 'cstringArrayToSeq'`). This helper is the
  ## cross-target primitive — a `poll(0)` on native, the pending-callback
  ## flush on JS — so the suite runs on both backends, which is what
  ## Front-End-Architecture.md §6 asks for and what the `vm-unit-js` lane
  ## exists to enforce.
  drainPlatformCallbacks()

proc tokens(summary: OriginSummary): string =
  ## Helper used by the placeholder-pill assertions to check token
  ## presence without leaking the `Option[string]` into `check` calls.
  if summary.placeholderToken.isSome:
    summary.placeholderToken.get
  else:
    ""

proc makeOriginVM(): tuple[vm: OriginChainVM,
                           state: StateVM,
                           store: ReplayDataStore,
                           mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let stateVM = createStateVM(store)
  let originVM = createOriginChainVM(store)
  drain()
  mock.clearReceivedCommands()
  (originVM, stateVM, store, mock)

# ---------------------------------------------------------------------------
# M4 V#1: test_state_vm_on_show_origin_dispatches_dap_request
# ---------------------------------------------------------------------------

suite "M4 — StateVM.onShowOrigin dispatches ct/originChain":

  test "test_state_vm_on_show_origin_dispatches_dap_request":
    let (_, stateVM, _, mock) = makeOriginVM()
    let loc = Location(file: "fixture.py", line: 3)
    stateVM.onShowOrigin("total", loc)

    let entry = mock.findCommand("ct/originChain")
    check entry.isSome
    let args = entry.get.args
    check args["variableName"].getStr == "total"
    check args["frameId"].getInt == -1
    check args["stepId"].getInt == -1
    check args["maxHops"].getInt == DEFAULT_ORIGIN_MAX_HOPS
    check args["lazy"].getBool == false
    check args["classifySource"].getBool == true

# ---------------------------------------------------------------------------
# M4 V#2: test_origin_chain_vm_active_chain_signal_updates
#
# Pure VM-side mirror: the VM consumes a parsed `OriginChain` object.
# The wire-level round-trip (real db-backend → parseOriginChain) is
# asserted in `src/db-backend/tests/origin_viewmodel_test.rs`.
# ---------------------------------------------------------------------------

suite "M4 — OriginChainVM.activeChain updates on response":

  test "test_origin_chain_vm_active_chain_signal_updates":
    let (originVM, _, _, _) = makeOriginVM()
    check originVM.activeChain.val.isNone

    let chain = OriginChain(
      queryVariable: "total",
      queryStepId: 3,
      hops: @[
        OriginHop(kind: okTrivialCopy, targetExpr: "c",
                  sourceExpr: "b", stepId: 3,
                  location: OriginLocation(path: "fixture.py", line: 3),
                  confidence: 1.0),
      ],
      terminator: Terminator(kind: tkwLiteral, expression: "10"),
      confidence: 1.0,
    )
    originVM.applyChainResponse(chain)
    check originVM.activeChain.val.isSome
    check originVM.activeChain.val.get.queryVariable == "total"
    check originVM.activeChain.val.get.terminator.kind == tkwLiteral
    check not originVM.loading.val

  test "test_origin_chain_vm_cancellation":
    ## Mirrors M5 verification (cancellation): cancel bumps the
    ## request counter so a late chain is ignored.
    let (originVM, _, _, _) = makeOriginVM()
    originVM.loading.val = true
    let beforeId = originVM.latestRequestId.val
    originVM.onCancelLoad()
    check not originVM.loading.val
    check originVM.latestRequestId.val == beforeId + 1
    # Apply a stale response using the older id — should be ignored.
    let chain = OriginChain(queryVariable: "stale")
    originVM.applyChainResponse(chain, requestId = beforeId)
    check originVM.activeChain.val.isNone

# ---------------------------------------------------------------------------
# M4 V#3: test_origin_chain_vm_seek_to_hop_triggers_goto_ticks
# ---------------------------------------------------------------------------

suite "M4 — OriginChainVM.onSeekToHop reuses goto-ticks/history-jump":

  test "test_origin_chain_vm_seek_to_hop_triggers_goto_ticks":
    let (originVM, _, store, mock) = makeOriginVM()
    var observedStep: int64 = -1
    var observedPath = ""
    originVM.onSeekProc = proc(stepId: int64; loc: Location) =
      observedStep = stepId
      observedPath = loc.file

    let hop = OriginHop(
      kind: okTrivialCopy,
      targetExpr: "b",
      sourceExpr: "a",
      stepId: 47,
      location: OriginLocation(path: "main.py", line: 5, rrTicks: 47),
    )
    originVM.onSeekToHop(hop)
    check observedStep == 47
    check observedPath == "main.py"

    # And when no bridge is installed, the fallback path emits a
    # `ct/history-jump` request through the existing
    # historical-navigation pipeline.
    #
    # THE REQUEST MUST NAME THE HOP'S OWN STEP, and this is the assertion
    # this test used to be missing.  It checked `findCommand(...).isSome` —
    # that a command was sent — and stayed green for months while the payload
    # was `{expression, location: {…}, stepId}`, a shape whose only field
    # name in common with the `task::Location` the backend deserialises is
    # `expression`.  `Location` is `#[serde(default)]` at container level, so
    # the backend accepted it, built a zeroed location, seeked to
    # `rrTicks = 0` and answered `success`: every hop click landed on the
    # first step of the recording (codetracer#698).  "A command was sent" and
    # "the status was success" are both exactly what the defect did, so
    # neither can be the assertion — the destination has to be.
    let (originVM2, _, _, mock2) = makeOriginVM()
    originVM2.onSeekToHop(hop)
    drain()
    let seek = mock2.findCommand("ct/history-jump")
    check seek.isSome
    let seekArgs = seek.get.args
    check seekArgs.hasKey("rrTicks")
    check seekArgs["rrTicks"].getBiggestInt == 47
    check seekArgs["path"].getStr == "main.py"
    check seekArgs["line"].getInt == 5
    # And the destination is at the TOP level, where the command reads it.
    # The pre-fix payload carried the same numbers one level down under
    # `location`, which is why it read as a jump to nowhere.
    check not seekArgs.hasKey("location")

    # A SECOND HOP, at a different step and a different path, because a
    # single case cannot distinguish "reads the hop" from "returns a
    # constant" — and 47 was already the value the bridge assertion above
    # uses.
    let (originVM3, _, _, mock3) = makeOriginVM()
    originVM3.onSeekToHop(OriginHop(
      kind: okTrivialCopy,
      targetExpr: "total",
      sourceExpr: "subtotal",
      stepId: 512,
      location: OriginLocation(path: "lib/acc.py", line: 91, rrTicks: 512),
    ))
    drain()
    let secondSeek = mock3.findCommand("ct/history-jump")
    check secondSeek.isSome
    check secondSeek.get.args["rrTicks"].getBiggestInt == 512
    check secondSeek.get.args["path"].getStr == "lib/acc.py"
    check secondSeek.get.args["line"].getInt == 91

# ---------------------------------------------------------------------------
# M4 V#4: test_origin_chain_vm_pin_chain_persists_in_scratchpad
# ---------------------------------------------------------------------------

suite "M4 — OriginChainVM.onPinChain mirrors into Scratchpad VM":

  test "test_origin_chain_vm_pin_chain_persists_in_scratchpad":
    let (originVM, stateVM, store, _) = makeOriginVM()
    let scratchVM = createScratchpadVM(store)
    wireOriginChainBridges(stateVM, originVM,
      proc(): ScratchpadVM = scratchVM)

    let chain = OriginChain(queryVariable: "total", queryStepId: 3)
    originVM.onPinChain(chain)
    check originVM.pinnedChains.val.len == 1
    check originVM.pinnedChains.val[0].queryVariable == "total"
    check scratchVM.chainEntries.val.len == 1
    check scratchVM.chainEntries.val[0].chain.queryVariable == "total"
    check scratchVM.rowCount.val == 1

# ---------------------------------------------------------------------------
# M4 V#5: test_origin_chain_vm_breadcrumb_stack
# ---------------------------------------------------------------------------

suite "M4 — OriginChainVM.breadcrumbStack is LIFO":

  test "test_origin_chain_vm_breadcrumb_stack":
    let (originVM, _, _, _) = makeOriginVM()
    originVM.onPushBreadcrumb(BreadcrumbEntry(variableName: "x", stepId: 1))
    originVM.onPushBreadcrumb(BreadcrumbEntry(variableName: "y", stepId: 2))
    originVM.onPushBreadcrumb(BreadcrumbEntry(variableName: "z", stepId: 3))
    check originVM.breadcrumbStack.val.len == 3
    let popped = originVM.onPopBreadcrumb()
    check popped.isSome
    check popped.get.variableName == "z"
    check originVM.breadcrumbStack.val.len == 2
    originVM.onClearBreadcrumbs()
    check originVM.breadcrumbStack.val.len == 0
    check originVM.onPopBreadcrumb().isNone

# ---------------------------------------------------------------------------
# M4 V#6: test_state_pane_inline_badge_renders_terminator_icon
# ---------------------------------------------------------------------------

suite "M4 — inline origin badge renders icon per terminator":

  test "test_state_pane_inline_badge_renders_terminator_icon":
    let prefs = defaultOriginPreferences()
    var summary = OriginSummary(
      terminatorKind: tkwLiteral,
      terminatorExpr: "10",
      hopCount: 3,
      confidence: 1.0,
    )
    check iconClassForTerminator(summary.terminatorKind) ==
      "ct-origin-icon-quotation"
    check badgeTextForSummary(summary, prefs) == "10"
    # Computational terminator → sigma glyph.
    summary.terminatorKind = tkwComputational
    summary.terminatorExpr = "a + b + c + d + e + f + g + h + i + j + k + l"
    check iconClassForTerminator(summary.terminatorKind) ==
      "ct-origin-icon-sigma"
    # Long expressions are abbreviated.
    let truncated = badgeTextForSummary(summary, prefs)
    check truncated.contains("…")

# ---------------------------------------------------------------------------
# M4 V#7: test_state_pane_inline_chain_expands_on_badge_click
# ---------------------------------------------------------------------------

suite "M4 — clicking the badge toggles inline expansion":

  test "test_state_pane_inline_chain_expands_on_badge_click":
    let (originVM, stateVM, store, mock) = makeOriginVM()
    let row = VariableId(name: "total", scopePath: "main")
    check not stateVM.expandedOrigins.val.contains(row)
    stateVM.toggleOriginExpansion(row)
    check stateVM.expandedOrigins.val.contains(row)
    # Second click collapses
    stateVM.toggleOriginExpansion(row)
    check not stateVM.expandedOrigins.val.contains(row)

    # The OriginChainVM mirror exposes the same toggle helper.
    originVM.toggleExpanded(row)
    check originVM.isExpanded(row)
    originVM.toggleExpanded(row)
    check not originVM.isExpanded(row)

# ---------------------------------------------------------------------------
# M4 V#8 / V#9: placeholder pill + ct/originSummary roundtrip
# ---------------------------------------------------------------------------

suite "M4 — placeholder badge and lazy fill":

  test "test_state_pane_placeholder_badge_renders_for_placeholder_summary":
    let prefs = defaultOriginPreferences()
    let summary = placeholderSummary("tok-XYZ")
    check summary.isPlaceholder
    check badgeTextForSummary(summary, prefs) == "[?]"
    check tokens(summary).len > 0

  test "test_state_pane_placeholder_click_resolves_via_ct_origin_summary":
    let (originVM, _, _, mock) = makeOriginVM()
    originVM.enqueuePlaceholderFill("tok-1")
    originVM.enqueuePlaceholderFill("tok-2")
    originVM.flushPlaceholderFill()
    drain()
    let req = mock.findCommand("ct/originSummary")
    check req.isSome
    let tokens = req.get.args["tokens"]
    check tokens.kind == JArray
    check tokens.len == 2
    check tokens[0].getStr == "tok-1"
    check tokens[1].getStr == "tok-2"

    # Apply a response — the resolved summaries land in
    # `lastResolvedSummaries` and the queue empties.
    let resolved = @[
      OriginSummary(terminatorKind: tkwLiteral, terminatorExpr: "10",
                    hopCount: 3),
      OriginSummary(terminatorKind: tkwComputational,
                    terminatorExpr: "a + b", hopCount: 1),
    ]
    originVM.applySummaryResponse(@["tok-1", "tok-2"], resolved)
    check originVM.inFlightSummary.val == false
    check originVM.placeholderFillQueue.val.len == 0
    check originVM.lastResolvedSummaries.val.hasKey("tok-1")
    check originVM.lastResolvedSummaries.val["tok-1"].terminatorExpr == "10"

# ---------------------------------------------------------------------------
# M4 V#10: test_state_pane_history_popover_renders_origin_badges_per_entry
# ---------------------------------------------------------------------------
#
# The history-popover rendering happens at the DOM layer in
# `ui/value.nim`. Our verification at this layer asserts that the
# badge component selects the per-entry icon class correctly given a
# per-entry `OriginSummary` decoded from the `ct/load-history`
# response shape (spec §3.2.3 row "State Pane history-popover
# entries"). The wire shape itself is exercised in
# `src/db-backend/tests/origin_dap_test.rs::test_load_history_origin_summary_per_entry`.

suite "M4 — history popover rows attach per-entry origin badges":

  test "test_state_pane_history_popover_renders_origin_badges_per_entry":
    let prefs = defaultOriginPreferences()
    let entries = @[
      OriginSummary(terminatorKind: tkwLiteral, terminatorExpr: "1",
                    hopCount: 1, isPlaceholder: false),
      OriginSummary(terminatorKind: tkwComputational,
                    terminatorExpr: "a+b", hopCount: 2,
                    isPlaceholder: false),
      OriginSummary(terminatorKind: tkwUnknownSource, isPlaceholder: true,
                    placeholderToken: some("tok-3")),
    ]
    var iconClasses: seq[string] = @[]
    var badgeTexts: seq[string] = @[]
    for s in entries:
      iconClasses.add(iconClassForTerminator(s.terminatorKind))
      badgeTexts.add(badgeTextForSummary(s, prefs))
    check iconClasses == @["ct-origin-icon-quotation",
                           "ct-origin-icon-sigma",
                           "ct-origin-icon-question"]
    check badgeTexts[0] == "1"
    check badgeTexts[1] == "a+b"
    check badgeTexts[2] == "[?]"

# ---------------------------------------------------------------------------
# M4 V#11: test_omniscience_flow_overlay_renders_origin_badges_per_annotation
# ---------------------------------------------------------------------------

suite "M4 — omniscience-flow overlay uses icon-only badge":

  test "test_omniscience_flow_overlay_renders_origin_badges_per_annotation":
    # Spec §3.2.3 row "Omniscience-Flow editor overlay" — icon-only
    # badge variant. The shared component's `badgeClassFor` emits the
    # `ct-origin-badge-icon-only` modifier when `iconOnly = true`.
    let summary = OriginSummary(
      terminatorKind: tkwLiteral, terminatorExpr: "1", hopCount: 1)
    let cls = origin_chain_types.iconClassForTerminator(summary.terminatorKind)
    check cls == "ct-origin-icon-quotation"

# ---------------------------------------------------------------------------
# M4 V#12: test_preference_show_containing_function_toggles_function_suffix
# ---------------------------------------------------------------------------

suite "M4 — showContainingFunction preference":

  test "test_preference_show_containing_function_toggles_function_suffix":
    var prefs = defaultOriginPreferences()
    let summary = OriginSummary(
      terminatorKind: tkwComputational,
      terminatorExpr: "a + b",
      terminatorFunction: some("compute"),
      hopCount: 1,
    )
    prefs.showContainingFunctionInline = false
    let inlineOff = badgeTextForSummary(summary, prefs, atSidePanel = false)
    check not inlineOff.contains("@")
    prefs.showContainingFunctionInline = true
    let inlineOn = badgeTextForSummary(summary, prefs, atSidePanel = false)
    check inlineOn.endsWith("@ compute")
    # Side-panel default on
    prefs.showContainingFunctionPanel = true
    let panelOn = badgeTextForSummary(summary, prefs, atSidePanel = true)
    check panelOn.endsWith("@ compute")
    prefs.showContainingFunctionPanel = false
    let panelOff = badgeTextForSummary(summary, prefs, atSidePanel = true)
    check not panelOff.contains("@")

# ---------------------------------------------------------------------------
# M4 V#13: test_preference_expression_style_full_vs_abbreviated_vs_hash
# ---------------------------------------------------------------------------

suite "M4 — expressionStyle preference cycles":

  test "test_preference_expression_style_full_vs_abbreviated_vs_hash":
    let long = "this_is_a_long_expression_that_does_not_fit_in_a_narrow_pane"
    let full = abbreviateExpr(long, oesFull)
    check full.contains("…")
    check full.len < long.len
    let abbr = abbreviateExpr(long, oesAbbreviated)
    # 16 ASCII chars + 3-byte UTF-8 ellipsis = 19 bytes.
    check abbr.len <= 19
    check abbr.endsWith("…")
    let hashed = abbreviateExpr(long, oesHash)
    check hashed.len == 9    # "#" + 8 hex digits
    check hashed.startsWith("#")

  test "test_preference_expression_style_counts_runes_not_bytes":
    # An expression with a non-ASCII identifier — legal in every language
    # CodeTracer records. `abbreviateExpr` used to index by BYTE, so both
    # styles cut mid-UTF-8-sequence and emitted an invalid string, and both
    # compared a byte count against a limit written in characters.
    let long = "μεταβλητή_με_πολύ_μεγάλο_όνομα_που_δεν_χωράει"
    check long.runeLen < long.len            # the premise: multi-byte

    let full = abbreviateExpr(long, oesFull)
    check full.contains("…")
    check validateUtf8(full) == -1
    check full.runeLen < long.runeLen

    let abbr = abbreviateExpr(long, oesAbbreviated)
    check validateUtf8(abbr) == -1
    check abbr.endsWith("…")
    # SIXTEEN CHARACTERS plus the ellipsis, which is what the doc comment
    # ("keeps the first ~16 characters") says. The byte-indexed version kept
    # eight characters here and corrupted the ninth.
    check abbr.runeLen == 17

    # Shorter in runes than the limit, longer in bytes: not abbreviated.
    check abbreviateExpr("αβγδε", oesAbbreviated) == "αβγδε"

# ---------------------------------------------------------------------------
# M4 V#14: test_preference_batch_fill_visible_triggers_lazy_load_on_scroll
# ---------------------------------------------------------------------------

suite "M4 — batchFillVisible queues placeholders for batched fill":

  test "test_preference_batch_fill_visible_triggers_lazy_load_on_scroll":
    let (originVM, _, _, mock) = makeOriginVM()
    # batchFillVisible defaults to on per spec §3.7.
    check originVM.preferences.val.batchFillVisible
    originVM.enqueuePlaceholderFill("scroll-tok-1")
    # De-dup: re-enqueue the same token does NOT grow the queue.
    originVM.enqueuePlaceholderFill("scroll-tok-1")
    check originVM.placeholderFillQueue.val.len == 1
    # A second distinct token grows it.
    originVM.enqueuePlaceholderFill("scroll-tok-2")
    check originVM.placeholderFillQueue.val.len == 2

    # The visible-rows fill is driven by an externally-scheduled
    # debounce (per `originDisplay.batchFillThrottleMs`); the test
    # invokes `flushPlaceholderFill` directly to simulate the timer
    # firing.
    originVM.flushPlaceholderFill()
    drain()
    let req = mock.findCommand("ct/originSummary")
    check req.isSome

    # Toggle batchFillVisible off → in a real UI, the scroll-listener
    # bridge skips enqueueing further tokens. We can't observe the
    # scroll-listener at this layer; we assert the preference plumbing
    # round-trip on the VM signal instead.
    originVM.setBatchFillVisible(false)
    check originVM.preferences.val.batchFillVisible == false

# ---------------------------------------------------------------------------
# Extra coverage — command palette + watch-expression prefix
# ---------------------------------------------------------------------------

suite "M4 — auxiliary deliverables":

  test "command palette `Show Value Origin` forwards to host bridge":
    let (_, _, store, _) = makeOriginVM()
    let palette = createCommandPaletteVM(store)
    var observedExpression = ""
    palette.onShowValueOrigin = proc(expression: string) =
      observedExpression = expression
    palette.requestShowValueOrigin("total")
    check observedExpression == "total"
    # Closing the palette is a side effect of `requestShowValueOrigin`.
    check palette.isActive.val == false

  test "watch-expression prefix `origin(expr)` is recognised":
    check isOriginWatch("origin(total)")
    check isOriginWatch("  origin( total )  ")
    check not isOriginWatch("total")
    check unwrapOriginWatch("origin(total)") == "total"
    check unwrapOriginWatch("origin(  a + b  )") == "a + b"
    check unwrapOriginWatch("total") == "total"

  test "originChain JSON parsers round-trip a backend payload":
    let payload = parseJson("""
      {
        "queryVariable": "c",
        "queryStepId": 3,
        "hops": [
          {
            "kind": "trivialCopy",
            "targetExpr": "c",
            "sourceExpr": "b",
            "sourceVariable": "b",
            "location": {"path": "fixture.py", "line": 3, "rrTicks": 3},
            "sourceText": "c = b",
            "stepId": 3,
            "operandSnapshots": [],
            "truncatedOperands": false,
            "confidence": 1.0
          }
        ],
        "terminator": {
          "kind": "literal",
          "expression": "10",
          "function": "main"
        },
        "truncated": false,
        "metrics": {"stepsScanned": 4, "elapsedMs": 1, "classifierHits": 1},
        "confidence": 1.0
      }
    """)
    let chain = parseOriginChain(payload)
    check chain.queryVariable == "c"
    check chain.hops.len == 1
    check chain.hops[0].kind == okTrivialCopy
    check chain.terminator.kind == tkwLiteral
    check chain.terminator.expression == "10"
    check chain.terminator.function == some("main")

  test "originSummary JSON parser recovers placeholder + eager shapes":
    let eager = parseOriginSummary(parseJson("""
      {"terminatorKind": "computational", "terminatorExpr": "a+b",
       "hopCount": 2, "confidence": 0.9, "isPlaceholder": false}
    """))
    check eager.terminatorKind == tkwComputational
    check not eager.isPlaceholder

    let placeholder = parseOriginSummary(parseJson("""
      {"terminatorKind": "unknownSource", "isPlaceholder": true,
       "placeholderToken": "tok-1"}
    """))
    check placeholder.isPlaceholder
    check placeholder.placeholderToken == some("tok-1")

  test "originChainArgs payload matches CtOriginChainArguments shape":
    let args = originChainArgs("total", stepId = 3, maxHops = 8)
    check args["variableName"].getStr == "total"
    check args["stepId"].getInt == 3
    check args["maxHops"].getInt == 8
    check args["lazy"].getBool == false
    check args["classifySource"].getBool == true

  test "iconClassForKind covers every OriginKind":
    for kind in OriginKind:
      let cls = iconClassForKind(kind)
      check cls.len > 0
      check cls.startsWith("ct-origin-icon-")

  test "iconClassForFrameTransition emits both directions":
    check iconClassForFrameTransition(ftkParameterPass) ==
      "ct-origin-icon-frame-enter"
    check iconClassForFrameTransition(ftkReturnCapture) ==
      "ct-origin-icon-frame-return"

  test "defaultOriginPreferences matches spec §3.2.3 defaults":
    let prefs = defaultOriginPreferences()
    check prefs.eagerMode[opsStateLocals] == oemEager
    check prefs.eagerMode[opsStateWatches] == oemEager
    check prefs.eagerMode[opsHistoryPopover] == oemPlaceholder
    check prefs.eagerMode[opsFlowOverlay] == oemPlaceholder
    check prefs.eagerMode[opsScratchpad] == oemEager
    check prefs.eagerMode[opsEditorHover] == oemEager
    check prefs.batchFillVisible
    check prefs.defaultMaxHops == DEFAULT_ORIGIN_MAX_HOPS

  test "preference setters mutate the in-memory signal":
    let (originVM, _, _, _) = makeOriginVM()
    originVM.setExpressionStyle(oesAbbreviated)
    check originVM.preferences.val.expressionStyle == oesAbbreviated
    originVM.setEagerMode(opsFlowOverlay, oemEager)
    check originVM.preferences.val.eagerMode[opsFlowOverlay] == oemEager
    originVM.setBatchFillThrottleMs(250)
    check originVM.preferences.val.batchFillThrottleMs == 250
    originVM.setDefaultMaxHops(32)
    check originVM.preferences.val.defaultMaxHops == 32
    originVM.setCollapseTrivialChainsThreshold(8)
    check originVM.preferences.val.collapseTrivialChainsThreshold == 8

# ---------------------------------------------------------------------------
# State-Pane rendering integration tests (M4 deliverable #3 + #4).
#
# These tests render the actual State Pane via the IsoNim MockRenderer
# and walk the resulting MockNode tree to assert that every variable
# row carries the inline origin badge described in spec §3.2.1, that
# placeholder summaries render the `[?]` pill variant, and that the
# badge button click toggles the in-row chain expansion.
# ---------------------------------------------------------------------------

proc findByClass(node: MockNode; cls: string): MockNode =
  ## First descendant (or self) whose ``class`` attribute contains
  ## ``cls`` as a whole word.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    for part in nodeClass.split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  nil

proc findAllByClass(node: MockNode; cls: string): seq[MockNode] =
  ## All descendants (incl. self) whose ``class`` attribute contains
  ## ``cls`` as a whole word.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    for part in nodeClass.split(' '):
      if part == cls:
        result.add(node)
        break
  for child in node.children:
    result.add(findAllByClass(child, cls))

proc findRowNamed(node: MockNode; rowName: string): MockNode =
  ## The row whose ``data-variable-name`` is ``rowName`` — the attribute
  ## names the ROW and nothing inside it.
  if node.kind == mnkElement and
      node.attributes.getOrDefault("data-variable-name", "") == rowName:
    return node
  for child in node.children:
    let found = findRowNamed(child, rowName)
    if found != nil:
      return found
  nil

proc findBadgeForRow(panel: MockNode; rowName: string): MockNode =
  ## Return the badge button attached to the row identified by
  ## ``rowName`` — the row's own badge, found inside the row, which is how
  ## the Playwright page object finds it (`originChainPane.badge`). Returns
  ## nil when no badge is found.
  let row = findRowNamed(panel, rowName)
  if row.isNil:
    return nil
  findByClass(row, "ct-origin-badge")

proc visibleBadgeCount(panel: MockNode): int =
  ## Count badge buttons whose ``display`` style is not ``none`` —
  ## matches what a Playwright ``.locator()`` would see.
  for badge in findAllByClass(panel, "ct-origin-badge"):
    let display = badge.styles.getOrDefault("display", "")
    if display != "none":
      inc result

suite "M4 — State Pane renders inline origin badge per row":

  test "test_state_pane_inline_badge_renders_terminator_icon":
    createRoot proc(dispose: proc()) =
      let (originVM, stateVM, store, _) = makeOriginVM()
      discard originVM
      let r = MockRenderer()
      # Two locals — one literal-terminator eager, one computational.
      store.updateLocals(@[
        makeVariable("total", "42", "int"),
        makeVariable("sum", "7", "int"),
      ])
      stateVM.updateOriginSummaries(@[
        ("total", OriginSummary(terminatorKind: tkwLiteral,
                                terminatorExpr: "10", hopCount: 1)),
        ("sum", OriginSummary(terminatorKind: tkwComputational,
                              terminatorExpr: "a + b", hopCount: 2)),
      ])
      let panel = renderStatePanel[MockRenderer, MockNode](r, stateVM)
      let totalBadge = findBadgeForRow(panel, "total")
      let sumBadge = findBadgeForRow(panel, "sum")
      check totalBadge != nil
      check sumBadge != nil
      # Per-row terminator icon class is part of the badge button's
      # class string.
      check "ct-origin-icon-quotation" in totalBadge.attributes["class"]
      check "ct-origin-icon-sigma" in sumBadge.attributes["class"]
      # Visible badge text uses the (possibly abbreviated) terminator
      # expression — both rows fit in the default width so no ellipsis.
      check totalBadge.textContent.contains("10")
      check sumBadge.textContent.contains("a + b")
      check visibleBadgeCount(panel) == 2
      dispose()

  test "test_state_pane_placeholder_badge_renders_for_placeholder_summary":
    createRoot proc(dispose: proc()) =
      let (_, stateVM, store, _) = makeOriginVM()
      let r = MockRenderer()
      store.updateLocals(@[
        makeVariable("pending", "<unresolved>", "any"),
      ])
      stateVM.updateOriginSummaries(@[
        ("pending", placeholderSummary("tok-XYZ")),
      ])
      let panel = renderStatePanel[MockRenderer, MockNode](r, stateVM)
      let badge = findBadgeForRow(panel, "pending")
      check badge != nil
      # Placeholder badges carry the ``ct-origin-badge-placeholder``
      # modifier per spec §3.2.1 + emit ``[?]`` as visible text.
      check "ct-origin-badge-placeholder" in badge.attributes["class"]
      check badge.textContent.contains("[?]")
      # Placeholder badges keep the token so the click handler can
      # forward it to ``ct/originSummary``.
      check badge.attributes.getOrDefault("data-token", "") == "tok-XYZ"
      dispose()

  test "test_state_pane_inline_chain_expands_on_badge_click":
    createRoot proc(dispose: proc()) =
      let (originVM, stateVM, store, _) = makeOriginVM()
      discard originVM
      let r = MockRenderer()
      store.updateLocals(@[
        makeVariable("c", "10", "int"),
      ])
      stateVM.updateOriginSummaries(@[
        ("c", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "10", hopCount: 3)),
      ])
      # Wire a chain lookup so the in-row expansion has data to
      # render. The chain looks up by variable name ("c").
      let chain = OriginChain(
        queryVariable: "c",
        queryStepId: 3,
        hops: @[
          OriginHop(kind: okTrivialCopy, targetExpr: "c",
                    sourceExpr: "b", stepId: 3,
                    location: OriginLocation(path: "fixture.py", line: 3)),
          OriginHop(kind: okTrivialCopy, targetExpr: "b",
                    sourceExpr: "a", stepId: 2,
                    location: OriginLocation(path: "fixture.py", line: 2)),
        ],
        terminator: Terminator(kind: tkwLiteral, expression: "10"),
      )
      stateVM.originChainLookup = proc(name: string): Option[OriginChain] =
        if name == "c": some(chain) else: none(OriginChain)

      let panel = renderStatePanel[MockRenderer, MockNode](r, stateVM)
      let badge = findBadgeForRow(panel, "c")
      check badge != nil
      # Before the click the in-row chain block is present in the DOM
      # but hidden via ``display: none``.
      let chainBlocks = findAllByClass(panel, "ct-origin-inline-chain")
      check chainBlocks.len == 1
      check chainBlocks[0].styles.getOrDefault("display", "") == "none"

      # Click the badge — reactive effects then toggle the row's
      # display attribute and emit the chain rows.
      badge.fireEvent("click")
      let after = findAllByClass(panel, "ct-origin-inline-chain")
      check after.len == 1
      check after[0].styles.getOrDefault("display", "") == "block"
      let hops = findAllByClass(after[0], "ct-origin-inline-chain-hop")
      check hops.len == 2
      let terminatorRow =
        findByClass(after[0], "ct-origin-inline-chain-terminator")
      check terminatorRow != nil
      check terminatorRow.textContent.contains("10")

      # Second click collapses again.
      badge.fireEvent("click")
      let afterCollapse = findAllByClass(panel, "ct-origin-inline-chain")
      check afterCollapse[0].styles.getOrDefault("display", "") == "none"
      dispose()

  test "test_state_pane_badge_click_does_not_propagate_to_parent":
    createRoot proc(dispose: proc()) =
      let (originVM, stateVM, store, _) = makeOriginVM()
      discard originVM
      let r = MockRenderer()
      store.updateLocals(@[
        makeVariable("x", "42", "int"),
      ])
      stateVM.updateOriginSummaries(@[
        ("x", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "42", hopCount: 1)),
      ])
      # Wire a chain lookup
      let chain = OriginChain(
        queryVariable: "x",
        queryStepId: 1,
        hops: @[
          OriginHop(kind: okTrivialCopy, targetExpr: "x",
                    sourceExpr: "y", stepId: 1,
                    location: OriginLocation(path: "fixture.py", line: 1)),
        ],
        terminator: Terminator(kind: tkwLiteral, expression: "42"),
      )
      stateVM.originChainLookup = proc(name: string): Option[OriginChain] =
        if name == "x": some(chain) else: none(OriginChain)

      let panel = renderStatePanel[MockRenderer, MockNode](r, stateVM)
      let badge = findBadgeForRow(panel, "x")
      check badge != nil

      let row = findByClass(panel, "value-name-container")
      check row != nil

      # Install parent click listener to detect propagation
      var parentClicked = false
      row.eventHandlers["click"] = @[
        proc(ev: MockEvent) = parentClicked = true
      ]

      let ev = MockEvent(`type`: "click", target: badge, currentTarget: badge)
      fireEventWith(badge, "click", ev)

      # 1. Inline chain expanded in VM and DOM
      let id = badgeRowId(getStateViewState(stateVM).variables[0])
      check stateVM.isOriginExpanded(id) == true
      let chainBlocks = findAllByClass(panel, "ct-origin-inline-chain")
      check chainBlocks.len == 1
      check chainBlocks[0].styles.getOrDefault("display", "") == "block"

      # 2. Propagation was stopped
      check not parentClicked
      check ev.propagationStopped

      dispose()

  test "test_state_pane_placeholder_click_resolves_via_ct_origin_summary":
    createRoot proc(dispose: proc()) =
      let (originVM, stateVM, store, mock) = makeOriginVM()
      let r = MockRenderer()
      store.updateLocals(@[
        makeVariable("pending", "<unresolved>", "any"),
      ])
      stateVM.updateOriginSummaries(@[
        ("pending", placeholderSummary("tok-XYZ")),
      ])
      # Install the bridges ``state.nim`` installs (``wireOriginChainBridges``):
      # they forward placeholder-pill clicks into ``OriginChainVM.onShowOrigin`` so
      # the placeholder is resolved via the same ``ct/originChain`` /
      # ``ct/originSummary`` pipeline.
      wireOriginChainBridges(stateVM, originVM,
        proc(): ScratchpadVM = nil)

      let panel = renderStatePanel[MockRenderer, MockNode](r, stateVM)
      let badge = findBadgeForRow(panel, "pending")
      check badge != nil

      # Click the placeholder pill — the host bridge dispatches a
      # ``ct/originChain`` request through the mock backend.
      badge.fireEvent("click")
      drain()
      let req = mock.findCommand("ct/originChain")
      check req.isSome
      check req.get.args["variableName"].getStr == "pending"
      dispose()

  test "test_state_pane_row_context_menu_dispatches_show_value_origin":
    ## M4 deliverable §3.1 — right-click on a State Pane variable row
    ## opens a context menu whose "Show value origin" entry routes
    ## through ``StateVM.onShowOrigin``, which (a) dispatches
    ## ``ct/originChain`` via the backend and (b) opens the dedicated
    ## side panel by setting ``OriginChainVM.sidePanelOpen.val = true``
    ## and populating ``activeChain`` once the DAP response lands.
    ##
    ## The test exercises Option-A from the brief: it fires
    ## ``contextmenu`` on the rendered row's MockNode so the
    ## handler attached by ``renderVariableRowImpl`` actually runs (the
    ## menu items appear in ``StateVM.lastContextMenu``), then invokes
    ## the "Show value origin" action proc and asserts the wire side
    ## effects via the same ``MockBackendService`` /
    ## ``applyChainResponse`` pattern the prior tests use.
    createRoot proc(dispose: proc()) =
      let (originVM, stateVM, store, mock) = makeOriginVM()
      let r = MockRenderer()
      store.updateLocals(@[
        makeVariable("total", "42", "int"),
      ])
      stateVM.updateOriginSummaries(@[
        ("total", OriginSummary(terminatorKind: tkwLiteral,
                                terminatorExpr: "10", hopCount: 1)),
      ])
      # Install the bridges ``state.nim`` installs (``wireOriginChainBridges``) so the
      # action's call to ``stateVM.onShowOrigin`` flows through to
      # ``OriginChainVM.onShowOrigin`` — that's where the side-panel
      # signal flips and the breadcrumb is pushed.
      wireOriginChainBridges(stateVM, originVM,
        proc(): ScratchpadVM = nil)

      let panel = renderStatePanel[MockRenderer, MockNode](r, stateVM)
      # Locate the row by its ``data-variable-name`` attribute.
      var row: MockNode = nil
      proc findRow(node: MockNode) =
        if row != nil:
          return
        if node.kind == mnkElement and
            node.attributes.getOrDefault("data-variable-name", "") == "total":
          row = node
          return
        for child in node.children:
          findRow(child)
      findRow(panel)
      check row != nil

      # Verify the row carries the renderer-agnostic ``contextmenu``
      # listener (registered via the DSL's ``oncontextmenu = handler``
      # rewrite — see ``isonim/dsl/transform.nim::eventName``).  Without
      # this the handler is silently absent and the menu wouldn't open.
      check "contextmenu" in row.eventListeners or
            "contextmenu" in row.eventHandlers
      # Fire the right-click — the handler reads the row's live state
      # and publishes the menu through ``StateVM.lastContextMenu`` so
      # tests can interrogate the entries without touching the
      # JS-only ``showContextMenu`` primitive.
      row.fireEvent("contextmenu")
      let menu = stateVM.lastContextMenu.val
      check menu.len >= 1
      var showOriginEntry: OriginContextMenuEntry
      var found = false
      for entry in menu:
        if entry.label == "Show value origin":
          showOriginEntry = entry
          found = true
      check found
      check showOriginEntry.hint == "Ctrl+Shift+O"
      check not showOriginEntry.action.isNil

      # Pre-condition: side panel is closed and the backend log is
      # empty (we cleared it during ``makeOriginVM``).
      check not originVM.sidePanelOpen.val
      check mock.findCommand("ct/originChain").isNone

      # Invoke the menu's "Show value origin" action — same code path
      # the JS-side ``showContextMenu`` would trigger when the user
      # clicks the menu item.
      showOriginEntry.action()
      drain()

      # 1. ``StateVM.onShowOrigin`` dispatches ``ct/originChain`` — the
      #    bridged ``OriginChainVM`` sends it — with the variable name.
      let req = mock.findCommand("ct/originChain")
      check req.isSome
      check req.get.args["variableName"].getStr == "total"
      # 2. The host bridge forwarded the call to ``OriginChainVM`` which
      #    opens the dedicated side panel per spec §3.2.2.
      check originVM.sidePanelOpen.val == true
      # 3. ``activeChain`` becomes Some after the DAP response lands.
      #    The mock returns ``%*{}`` so we synthesise the response the
      #    real db-backend would dispatch through ``applyChainResponse``
      #    (same pattern the existing ``activeChain`` test uses).
      check originVM.activeChain.val.isNone
      let chain = OriginChain(
        queryVariable: "total",
        queryStepId: -1,
        hops: @[
          OriginHop(kind: okTrivialCopy, targetExpr: "total",
                    sourceExpr: "10", stepId: -1,
                    location: OriginLocation(path: "fixture.py", line: 1),
                    confidence: 1.0),
        ],
        terminator: Terminator(kind: tkwLiteral, expression: "10"),
        confidence: 1.0,
      )
      originVM.applyChainResponse(chain)
      check originVM.activeChain.val.isSome
      check originVM.activeChain.val.get.queryVariable == "total"
      check originVM.activeChain.val.get.terminator.kind == tkwLiteral
      dispose()

# ---------------------------------------------------------------------------
# M4 fix-up Gap 1 / Gap 2 — wire-shape extractors that ``ui/value.nim``
# (history popover) and ``ui/flow.nim`` (omniscience-flow overlay) use
# to recover the per-entry / per-annotation ``originSummary`` from the
# raw JsObject the wire deserialiser hands them.
#
# The JS-side ``extractOriginSummary`` / ``extractOriginSummaryMap``
# helpers live in ``ui/origin_badge.nim`` (gated by ``when defined(js)``
# because they touch ``std/jsffi``).  This headless test exercises the
# JSON-side primitives ``parseOriginSummary`` does so the wire contract
# is asserted in lock-step with the badge-rendering surfaces.
# ---------------------------------------------------------------------------

suite "M4 — wire-shape originSummary extraction for value-rendering surfaces":

  test "history popover per-entry originSummary parses through parseOriginSummary":
    ## Mirrors the JsObject path ``ui/value.nim::renderHistoryTableDom``
    ## walks: a per-entry ``originSummary`` field comes back over the
    ## wire as JSON, gets decoded into ``OriginSummary``, and is
    ## consumed by ``renderBadgeDom`` with ``iconOnly = true``.
    let payload = parseJson("""
      [
        {"location": {"path": "a.py", "line": 3}, "value": {},
         "time": 0, "description": "",
         "originSummary": {"terminatorKind": "literal",
                           "terminatorExpr": "10", "hopCount": 1}},
        {"location": {"path": "a.py", "line": 4}, "value": {},
         "time": 0, "description": "",
         "originSummary": {"terminatorKind": "unknownSource",
                           "isPlaceholder": true,
                           "placeholderToken": "tok-history-A"}}
      ]
    """)
    var summaries: seq[OriginSummary] = @[]
    for entry in payload:
      summaries.add(parseOriginSummary(entry{"originSummary"}))
    check summaries.len == 2
    check summaries[0].terminatorKind == tkwLiteral
    check summaries[0].terminatorExpr == "10"
    check not summaries[0].isPlaceholder
    check summaries[1].isPlaceholder
    check summaries[1].placeholderToken == some("tok-history-A")
    # The badge class for the eager entry carries the per-terminator
    # icon class; the placeholder entry carries the
    # ``ct-origin-badge-placeholder`` modifier.
    check "ct-origin-icon-quotation" in badgeClassFor(summaries[0])
    check "ct-origin-badge-placeholder" in badgeClassFor(summaries[1])
    # The icon-only variant adds the ``ct-origin-badge-icon-only``
    # modifier (spec §3.2.3 row "Omniscience-Flow overlay"
    # icon-only badge; the history popover also renders icon-only per
    # the §3.2.3 V1 defaults).
    check "ct-origin-badge-icon-only" in badgeClassFor(
      summaries[0], iconOnly = true)

  test "flow overlay per-step origin_summaries map parses correctly":
    ## Mirrors the JsObject path ``ui/flow.nim::flowSimpleValue`` walks
    ## per annotated value: ``FlowStep.origin_summaries`` is keyed by
    ## variable name and emits one ``OriginSummary`` per key.  The Nim
    ## ``FlowStep`` doesn't carry the field as a typed slot, so we
    ## recover it from the raw JSON shape and run each entry through
    ## ``parseOriginSummary`` (the same pipeline
    ## ``extractOriginSummaryMap`` runs on the JS side).
    let payload = parseJson("""
      {
        "originSummaries": {
          "x": {"terminatorKind": "literal", "terminatorExpr": "42",
                "hopCount": 1},
          "y": {"terminatorKind": "computational",
                "terminatorExpr": "x+1", "hopCount": 2}
        }
      }
    """)
    var entries: seq[(string, OriginSummary)] = @[]
    let summariesNode = payload{"originSummaries"}
    for key, value in summariesNode.pairs:
      entries.add((key, parseOriginSummary(value)))
    # Order is map-iteration order; sort for stable assertions.
    var byKey = initTable[string, OriginSummary]()
    for (key, summary) in entries:
      byKey[key] = summary
    check byKey.hasKey("x")
    check byKey.hasKey("y")
    check byKey["x"].terminatorKind == tkwLiteral
    check byKey["y"].terminatorKind == tkwComputational
    check byKey["y"].terminatorExpr == "x+1"

  test "extractor returns an empty seq when origin_summaries is absent":
    ## Older backends (and non-materialized traces) omit the field.
    ## Both extractors must tolerate the empty case so the surfaces
    ## render the value without a badge.
    let payload = parseJson("""{}""")
    let summariesNode = payload{"originSummaries"}
    check summariesNode.isNil
    # ``parseOriginSummary`` returns a default (zeroed)
    # ``OriginSummary`` for a nil/non-object JsonNode so the badge
    # rendering path can short-circuit on
    # ``terminatorKind == tkwUnknownSource``.
    let summary = parseOriginSummary(summariesNode)
    check summary.terminatorKind == tkwUnknownSource

# ---------------------------------------------------------------------------
# M4 fix-up Gap 5 — Scratchpad side-by-side chain diff.  The pure
# algorithm tests assert on the diff rows ``chainDiffRows`` emits; the
# MockRenderer test renders the panel with two pinned chains and walks
# the DOM to confirm the diff block carries one ``data-pair-index`` per
# adjacent pair.
# ---------------------------------------------------------------------------

proc makeFixtureChain(queryVariable: string;
                      hopExprs: openArray[(string, string)];
                      terminatorExpr: string;
                      terminatorKind: TerminatorKindWire =
                        tkwLiteral): OriginChain =
  ## Minimal chain fixture for the diff tests.  Each ``(target, source)``
  ## pair becomes one ``TrivialCopy`` hop; the terminator carries the
  ## supplied expression + kind.
  var hops: seq[OriginHop] = @[]
  for (target, source) in hopExprs:
    hops.add(OriginHop(
      kind: okTrivialCopy,
      targetExpr: target,
      sourceExpr: source,
      stepId: 0,
      location: OriginLocation(path: "fixture.py", line: 1),
    ))
  OriginChain(
    queryVariable: queryVariable,
    queryStepId: 0,
    hops: hops,
    terminator: Terminator(kind: terminatorKind, expression: terminatorExpr),
  )

suite "M4 — Scratchpad side-by-side chain diff (Gap 5)":

  test "chainDiffRows pairs hops by index and flags mismatches":
    let left = ScratchpadChainEntry(chain: makeFixtureChain(
      "total",
      [("c", "b"), ("b", "a"), ("a", "10")],
      "10"))
    let right = ScratchpadChainEntry(chain: makeFixtureChain(
      "total",
      [("c", "b"), ("b", "x"), ("x", "20")],
      "20"))
    let rows = chainDiffRows(left, right)
    # 3 hops + 1 terminator row.
    check rows.len == 4
    # First hop is identical → not flagged as changed.
    check not rows[0].changed
    check rows[0].leftHop == "c = b"
    check rows[0].rightHop == "c = b"
    # Second hop differs (sources b/a vs b/x).
    check rows[1].changed
    check rows[1].leftHop == "b = a"
    check rows[1].rightHop == "b = x"
    # Third hop differs (a=10 vs x=20).
    check rows[2].changed
    # Terminator row differs (10 vs 20) and is always emitted last.
    check rows[3].leftHop.startsWith("[terminator] ")
    check rows[3].rightHop.startsWith("[terminator] ")
    check rows[3].changed

  test "chainDiffRows handles unequal-length chains with placeholder text":
    let left = ScratchpadChainEntry(chain: makeFixtureChain(
      "total",
      [("c", "b"), ("b", "a")],
      "literal"))
    let right = ScratchpadChainEntry(chain: makeFixtureChain(
      "total",
      [("c", "b"), ("b", "a"), ("a", "1"), ("a_prev", "0")],
      "literal"))
    let rows = chainDiffRows(left, right)
    # max(2, 4) = 4 hops + 1 terminator
    check rows.len == 5
    check not rows[0].changed
    check not rows[1].changed
    # Left ran out at index 2 — placeholder text appears on the left.
    check rows[2].leftHop == ScratchpadChainDiffEmptyHopText
    check rows[2].changed
    check rows[3].leftHop == ScratchpadChainDiffEmptyHopText
    # Terminator expressions match → terminator row not flagged.
    check not rows[4].changed

  test "diffRowClass appends the changed modifier when the row differs":
    let unchanged = ChainDiffRow(leftHop: "x = 1", rightHop: "x = 1",
                                 changed: false)
    let changed = ChainDiffRow(leftHop: "x = 1", rightHop: "x = 2",
                               changed: true)
    check diffRowClass(unchanged) == ScratchpadChainDiffRowClass
    check ScratchpadChainDiffChangedClass in diffRowClass(changed)

  test "Scratchpad panel renders side-by-side diff blocks for adjacent pinned chains":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let scratchVM = createScratchpadVM(store)
      let r = MockRenderer()
      let panel = renderScratchpadPanel[MockRenderer, MockNode](r, scratchVM)
      # One chain → no diff block.
      scratchVM.addChain(makeFixtureChain(
        "total", [("c", "b")], "10"))
      check findAllByClass(panel, "scratchpad-chain-diff").len == 0
      # Two chains → one diff block (chain[0] vs chain[1]).
      scratchVM.addChain(makeFixtureChain(
        "total", [("c", "x")], "20"))
      let diffs = findAllByClass(panel, "scratchpad-chain-diff")
      check diffs.len == 1
      check diffs[0].attributes.getOrDefault("data-pair-index", "") == "0"
      # Three chains → two diff blocks (0↔1, 1↔2).
      scratchVM.addChain(makeFixtureChain(
        "total", [("c", "y")], "30"))
      let diffsAfter = findAllByClass(panel, "scratchpad-chain-diff")
      check diffsAfter.len == 2
      check diffsAfter[0].attributes.getOrDefault("data-pair-index", "") == "0"
      check diffsAfter[1].attributes.getOrDefault("data-pair-index", "") == "1"
      # The first diff block carries the differing-hop modifier on the
      # one hop row (c = b vs c = x).
      let changedRows = findAllByClass(diffsAfter[0],
                                       ScratchpadChainDiffChangedClass)
      check changedRows.len > 0
      dispose()

# ---------------------------------------------------------------------------
# M21 V#8 — StateVM origin-metadata mode indicator
#
# Exercises the per-trace mode indicator the State Pane settings sub-menu
# renders (spec §3.7 + M21 deliverable #4). The default ("unavailable")
# applies before the backend responds; `updateOriginMetadataMode` is the
# entry-point the `ct/originMode` response bridge invokes.
# ---------------------------------------------------------------------------

suite "M21 — StateVM origin-metadata mode indicator":

  test "default origin metadata mode label is unavailable":
    let (_, stateVM, _, _) = makeOriginVM()
    check stateVM.originMetadataModeLabel == "unavailable"

  test "updateOriginMetadataMode flips the indicator label":
    let (_, stateVM, _, _) = makeOriginVM()
    stateVM.updateOriginMetadataMode("on")
    check stateVM.originMetadataModeLabel == "on"
    stateVM.updateOriginMetadataMode("lazy")
    check stateVM.originMetadataModeLabel == "lazy"
    stateVM.updateOriginMetadataMode("off")
    check stateVM.originMetadataModeLabel == "off"
    stateVM.updateOriginMetadataMode("unavailable")
    check stateVM.originMetadataModeLabel == "unavailable"

# ---------------------------------------------------------------------------
# M86 (#856) — the PRODUCTION bridges: the origin badge fetches the chain it
# expands, and "Pin to scratchpad" reaches the Scratchpad.
#
# Every bridge below is installed by `origin_chain_bridges
# .wireOriginChainBridges`, the proc `ui/state.nim` calls in the renderer.
# None is assigned by hand: the suites above that assigned `onPinChainProc`
# or `onShowOriginProc` themselves passed while no production
# code installed either the pin bridge or a chain fetch for an eager badge
# (Value-Origin-Tracking.md §3.2.1 "Clicking the badge (when loaded) expands
# the row in place to show the full hop chain"; §3.3 "Pin to scratchpad";
# §3.5 the pinned chain card).
#
# The mock backend stands in for the replay server because these cases are
# about which request the VM sends and what it does with the answer; the
# answer's wire shape is pinned against a real db-backend in
# `src/db-backend/tests/origin_viewmodel_test.rs`.
# ---------------------------------------------------------------------------

proc twoHopChainPayload(variable: string): JsonNode =
  ## A `ct/originChain` body in the backend's wire shape (the round-trip
  ## case above parses the same shape): `variable = b`, `b = a`, literal 10.
  %*{
    "queryVariable": variable,
    "queryStepId": 3,
    "hops": [
      {"kind": "trivialCopy", "targetExpr": variable, "sourceExpr": "b",
       "sourceVariable": "b",
       "location": {"path": "fixture.py", "line": 3, "rrTicks": 3},
       "sourceText": variable & " = b", "stepId": 3,
       "operandSnapshots": [], "truncatedOperands": false,
       "confidence": 1.0},
      {"kind": "trivialCopy", "targetExpr": "b", "sourceExpr": "a",
       "sourceVariable": "a",
       "location": {"path": "fixture.py", "line": 2, "rrTicks": 2},
       "sourceText": "b = a", "stepId": 2,
       "operandSnapshots": [], "truncatedOperands": false,
       "confidence": 1.0},
    ],
    "terminator": {"kind": "literal", "expression": "10",
                   "function": "main"},
    "truncated": false,
    "metrics": {"stepsScanned": 4, "elapsedMs": 1, "classifierHits": 2},
    "confidence": 1.0,
  }

proc originChainRequests(mock: MockBackendService): seq[JsonNode] =
  for rc in mock.receivedCommands:
    if rc.command == "ct/originChain":
      result.add(rc.args)

type WiredOrigin = tuple[origin: OriginChainVM, state: StateVM,
                         scratch: ScratchpadVM, store: ReplayDataStore,
                         mock: MockBackendService]

proc makeWiredOrigin(): WiredOrigin =
  ## The State pane, its OriginChainVM and the Scratchpad, joined by the
  ## renderer's own wiring.
  let (originVM, stateVM, store, mock) = makeOriginVM()
  let scratchVM = createScratchpadVM(store)
  wireOriginChainBridges(stateVM, originVM,
    proc(): ScratchpadVM = scratchVM)
  (originVM, stateVM, scratchVM, store, mock)

proc showEagerRow(w: WiredOrigin; name: string) =
  ## One local whose origin summary arrived eagerly with `ct/load-locals`:
  ## the badge is loaded, the chain behind it is not.
  w.store.updateLocals(@[makeVariable(name, "10", "int")])
  w.state.updateOriginSummaries(@[
    (name, OriginSummary(terminatorKind: tkwLiteral,
                         terminatorExpr: "10", hopCount: 2)),
  ])
  drain()
  w.mock.clearReceivedCommands()

suite "M86 — the origin badge and Pin to scratchpad, through the production bridges":

  test "an eager badge click fetches the chain and the expanded row renders its hops":
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.showEagerRow("c")
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      let badge = findBadgeForRow(panel, "c")
      check badge != nil
      # Nothing has fetched a chain yet: no context menu, no side panel.
      check w.origin.activeChain.val.isNone

      badge.fireEvent("click")
      drain()

      let sent = originChainRequests(w.mock)
      check sent.len == 1
      check sent.len == 1 and sent[0]["variableName"].getStr == "c"
      let blocks = findAllByClass(panel, "ct-origin-inline-chain")
      check blocks.len == 1
      check blocks.len == 1 and
        blocks[0].styles.getOrDefault("display", "") == "block"
      if blocks.len == 1:
        check findAllByClass(blocks[0], "ct-origin-inline-chain-hop").len == 2
        let terminatorRow =
          findByClass(blocks[0], "ct-origin-inline-chain-terminator")
        check terminatorRow != nil
        check terminatorRow != nil and terminatorRow.textContent.contains("10")
      dispose()

  test "the badge expands IN PLACE: it does not open the side panel":
    # §3.2.1 "expands the row in place"; the side panel is the context
    # menu's target (§3.1) and the expanded chain's "Show in side panel"
    # affordance's (§3.2.2), not the badge's.
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.showEagerRow("c")
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      findBadgeForRow(panel, "c").fireEvent("click")
      drain()
      check originChainRequests(w.mock).len == 1
      check not w.origin.sidePanelOpen.val
      check w.origin.activeChain.val.isNone
      check not w.origin.loading.val
      check w.origin.breadcrumbStack.val.len == 0
      dispose()

  test "collapsing, and re-expanding a row whose chain is held, send nothing":
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.showEagerRow("c")
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      let badge = findBadgeForRow(panel, "c")
      badge.fireEvent("click")   # expand: fetch
      drain()
      badge.fireEvent("click")   # collapse
      drain()
      badge.fireEvent("click")   # expand again: the chain is held
      drain()
      check originChainRequests(w.mock).len == 1
      let blocks = findAllByClass(panel, "ct-origin-inline-chain")
      check blocks.len == 1 and
        findAllByClass(blocks[0], "ct-origin-inline-chain-hop").len == 2
      dispose()

  test "expanding one row does not empty another":
    # Each row draws its own chain (`OriginChainVM.rowChains`), not the
    # single active chain, so the second fetch leaves the first row drawn.
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.store.updateLocals(@[makeVariable("c", "10", "int"),
                             makeVariable("d", "10", "int")])
      w.state.updateOriginSummaries(@[
        ("c", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "10", hopCount: 2)),
        ("d", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "10", hopCount: 2)),
      ])
      drain()
      w.mock.clearReceivedCommands()
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      w.mock.expect("ct/originChain", twoHopChainPayload("d"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      findBadgeForRow(panel, "c").fireEvent("click")
      drain()
      findBadgeForRow(panel, "d").fireEvent("click")
      drain()
      check originChainRequests(w.mock).len == 2
      let blocks = findAllByClass(panel, "ct-origin-inline-chain")
      check blocks.len == 2
      for b in blocks:
        check b.styles.getOrDefault("display", "") == "block"
        check findAllByClass(b, "ct-origin-inline-chain-hop").len == 2
      dispose()

  test "after a move an expanded row never draws the previous stop's chain, and is asked again there":
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.showEagerRow("c")
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      findBadgeForRow(panel, "c").fireEvent("click")
      drain()
      check w.state.originChainLookup("c").isSome
      w.mock.clearReceivedCommands()

      # The debugger moves. Nothing is queued for the re-ask the move
      # triggers, so the mock answers it with no chain: the old stop's
      # chain must not be drawn in the meantime.
      var d = w.store.debugger.val
      d.rrTicks = d.rrTicks + 9
      d.location.line = d.location.line + 1
      w.store.debugger.val = d
      drain()
      check originChainRequests(w.mock).len == 1
      check w.state.originChainLookup("c").isNone

      # The new stop's locals and summaries arrive (as the stop loader
      # delivers them): the row, still expanded, is asked once more — the
      # chainless answer above may be retried — and draws this stop's chain.
      var oneHop = twoHopChainPayload("c")
      oneHop["hops"].elems.setLen(1)
      w.mock.expect("ct/originChain", oneHop)
      w.store.updateLocals(@[makeVariable("c", "11", "int")])
      w.state.updateOriginSummaries(@[
        ("c", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "10", hopCount: 1)),
      ])
      drain()
      check originChainRequests(w.mock).len == 2
      let blocks = findAllByClass(panel, "ct-origin-inline-chain")
      check blocks.len == 1
      check blocks.len == 1 and
        blocks[0].styles.getOrDefault("display", "") == "block"
      check blocks.len == 1 and
        findAllByClass(blocks[0], "ct-origin-inline-chain-hop").len == 1

      # Summaries arriving again at the same stop ask nothing more.
      w.state.updateOriginSummaries(@[
        ("c", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "10", hopCount: 1)),
      ])
      drain()
      check originChainRequests(w.mock).len == 2
      dispose()

  test "one \"Show value origin\" from the row menu sends one ct/originChain":
    # One gesture, one backward walk: each `ct/originChain` spends its own
    # budget (§6.1.7), so a second request for the same expression costs the
    # backend a whole walk for an answer the OriginChainVM then discards.
    # With the production bridges installed the request is the
    # OriginChainVM's to send; `StateVM.onShowOrigin` sends nothing itself.
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.showEagerRow("c")
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      var row: MockNode = nil
      proc findRow(node: MockNode) =
        if row != nil:
          return
        if node.kind == mnkElement and
            node.attributes.getOrDefault("data-variable-name", "") == "c":
          row = node
          return
        for child in node.children:
          findRow(child)
      findRow(panel)
      check row != nil
      row.fireEvent("contextmenu")
      var showOrigin: proc() = nil
      for entry in w.state.lastContextMenu.val:
        if entry.label == "Show value origin":
          showOrigin = entry.action
      check not showOrigin.isNil
      showOrigin()
      drain()
      let requests = originChainRequests(w.mock)
      check requests.len == 1
      check requests.len == 1 and requests[0]["variableName"].getStr == "c"
      check w.origin.sidePanelOpen.val
      check w.origin.activeChain.val.isSome and
        w.origin.activeChain.val.get.queryVariable == "c"
      check w.origin.breadcrumbStack.val.len == 1
      dispose()

  test "without the OriginChainVM bridge, StateVM.onShowOrigin still sends one ct/originChain":
    # The headless fallback: a StateVM with no OriginChainVM behind it sends
    # the request itself, once.
    let (_, stateVM, _, mock) = makeOriginVM()
    check stateVM.onShowOriginProc.isNil
    stateVM.onShowOrigin("total", Location(file: "fixture.py", line: 3))
    let requests = originChainRequests(mock)
    check requests.len == 1
    check requests.len == 1 and requests[0]["variableName"].getStr == "total"

  test "a row's chain, asked after a move, leaves the side panel's chain alone":
    # The in-row block and the side panel are separate surfaces (§3.2.1,
    # §3.2.2): the re-ask a move triggers for an expanded row must not
    # replace the chain the side panel shows, nor its breadcrumb.
    createRoot proc(dispose: proc()) =
      let w = makeWiredOrigin()
      w.showEagerRow("d")
      # "Show value origin": through its bridge, the OriginChainVM sends the
      # one request.
      w.mock.expect("ct/originChain", twoHopChainPayload("c"))
      w.state.onShowOrigin("c", Location(file: "fixture.py", line: 3))
      drain()
      check w.origin.sidePanelOpen.val
      check w.origin.activeChain.val.isSome and
        w.origin.activeChain.val.get.queryVariable == "c"
      w.mock.expect("ct/originChain", twoHopChainPayload("d"))
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), w.state)
      findBadgeForRow(panel, "d").fireEvent("click")
      drain()
      check w.state.originChainLookup("d").isSome

      w.mock.clearReceivedCommands()
      w.mock.expect("ct/originChain", twoHopChainPayload("d"))
      var d = w.store.debugger.val
      d.rrTicks = d.rrTicks + 9
      d.location.line = d.location.line + 1
      w.store.debugger.val = d
      drain()
      check originChainRequests(w.mock).len == 1
      check w.state.originChainLookup("d").isSome
      check w.origin.sidePanelOpen.val
      check w.origin.activeChain.val.isSome and
        w.origin.activeChain.val.get.queryVariable == "c"
      check w.origin.breadcrumbStack.val.len == 1 and
        w.origin.breadcrumbStack.val[0].variableName == "c"
      check not w.origin.loading.val
      dispose()

  test "Pin to scratchpad, through the production bridge, reaches ScratchpadVM.chainEntries":
    let w = makeWiredOrigin()
    let chain = parseOriginChain(twoHopChainPayload("total"))
    w.origin.onPinChain(chain)
    check w.origin.pinnedChains.val.len == 1
    check w.scratch.chainEntries.val.len == 1
    check w.scratch.chainEntries.val.len == 1 and
      w.scratch.chainEntries.val[0].chain.queryVariable == "total"
    check w.scratch.rowCount.val == 1

  test "a pin lands in the Scratchpad VM current when it happens":
    # The renderer builds the OriginChainVM before the Scratchpad pane's VM
    # and later replaces that VM with the session's, so the target is
    # resolved per pin, and a pin before any Scratchpad exists is kept on
    # the OriginChainVM without failing.
    let (originVM, stateVM, store, _) = makeOriginVM()
    var current: ScratchpadVM = nil
    wireOriginChainBridges(stateVM, originVM,
      proc(): ScratchpadVM = current)
    let chain = parseOriginChain(twoHopChainPayload("total"))
    originVM.onPinChain(chain)
    check originVM.pinnedChains.val.len == 1
    let first = createScratchpadVM(store)
    current = first
    originVM.onPinChain(chain)
    let second = createScratchpadVM(store)
    current = second
    originVM.onPinChain(chain)
    check first.chainEntries.val.len == 1
    check second.chainEntries.val.len == 1
    check originVM.pinnedChains.val.len == 3

  test "on the transport, a row's request is never the side panel's":
    # The renderer applies `ct/originChain` answers from the DAP channel
    # (`ui_js.nim`: `applyChainAnswer`, then `openSidePanel`;
    # `rejectChainAnswer` for an answer with no chain). The DAP transport
    # names every tracked request from INSIDE `send`, before it writes the
    # frame (`dap.dispatchCtRequest` → the `trackCtRequests` hook → `ui_js`'s
    # `noteChainRequestSent`). The backend below does exactly that in front
    # of the mock, so the VM sees the hook at the moment the real transport
    # calls it; a legacy menu, which sends on the mediator without the VM,
    # is the hook called with no VM send around it.
    let mock = newMockBackendService(autoRespond = true)
    var originRef: OriginChainVM = nil
    var sentIds = 0
    let inner = mock.toBackendService()
    let tracked = BackendService(
      sendProc: proc(command: string;
                     args: JsonNode): BackendFuture[JsonNode] =
        if command == "ct/originChain" and not originRef.isNil:
          inc sentIds
          originRef.noteChainRequestSent("req-" & $sentIds)
        inner.sendProc(command, args),
      onEventProc: inner.onEventProc,
      disconnectProc: inner.disconnectProc,
    )
    let store = createReplayDataStore(tracked)
    let stateVM = createStateVM(store)
    let originVM = createOriginChainVM(store)
    originRef = originVM
    wireOriginChainBridges(stateVM, originVM,
      proc(): ScratchpadVM = nil)
    drain()
    let loc = Location(file: "fixture.py", line: 3)

    # The badge: its answer is not the side panel's to show.
    stateVM.onLoadOriginChainProc("c", loc)
    check sentIds == 1
    check not originVM.loading.val
    check not originVM.applyChainAnswer(
      parseOriginChain(twoHopChainPayload("c")), "req-1")
    check originVM.activeChain.val.isNone
    check not originVM.sidePanelOpen.val

    # A legacy menu's request, then another row's badge while it is
    # outstanding: the badge supersedes nothing, and its failed answer
    # cancels nothing, so the menu's answer still lands in the side panel.
    originVM.noteChainRequestSent("menu-1")
    check originVM.loading.val
    stateVM.onLoadOriginChainProc("d", loc)
    check sentIds == 2
    check not originVM.rejectChainAnswer("req-2")
    check originVM.loading.val
    check originVM.applyChainAnswer(
      parseOriginChain(twoHopChainPayload("x")), "menu-1")
    check originVM.activeChain.val.isSome and
      originVM.activeChain.val.get.queryVariable == "x"
    check not originVM.loading.val

    # The context menu: `StateVM.onShowOrigin` sends one request, through its
    # bridge — the side panel's, which opens the panel and whose failed
    # answer ends the wait.
    stateVM.onShowOrigin("c", loc)
    check sentIds == 3
    check originVM.sidePanelOpen.val
    check originVM.loading.val
    check originVM.rejectChainAnswer("req-3")
    check not originVM.loading.val
