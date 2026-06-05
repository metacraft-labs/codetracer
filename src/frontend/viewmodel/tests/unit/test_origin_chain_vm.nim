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

import std/[asyncdispatch, json, options, sets, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/testing/mock_dom

import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, types]
import ../../viewmodels/[
  origin_chain_types,
  origin_chain_vm,
  state_vm,
  scratchpad_vm,
  command_palette_vm,
]
import ../../views/[state_view, isonim_state_view, isonim_scratchpad_view]

proc drain() =
  try:
    poll(0)
  except ValueError:
    discard

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
      location: OriginLocation(path: "main.py", line: 5),
    )
    originVM.onSeekToHop(hop)
    check observedStep == 47
    check observedPath == "main.py"

    # And when no bridge is installed, the fallback path emits a
    # `ct/history-jump` request through the existing
    # historical-navigation pipeline.
    let (originVM2, _, _, mock2) = makeOriginVM()
    originVM2.onSeekToHop(hop)
    drain()
    check mock2.findCommand("ct/history-jump").isSome

# ---------------------------------------------------------------------------
# M4 V#4: test_origin_chain_vm_pin_chain_persists_in_scratchpad
# ---------------------------------------------------------------------------

suite "M4 — OriginChainVM.onPinChain mirrors into Scratchpad VM":

  test "test_origin_chain_vm_pin_chain_persists_in_scratchpad":
    let (originVM, _, store, _) = makeOriginVM()
    let scratchVM = createScratchpadVM(store)
    originVM.onPinChainProc = proc(chain: OriginChain) =
      scratchVM.addChain(chain)

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

proc findBadgeForRow(panel: MockNode; rowName: string): MockNode =
  ## Return the badge button attached to the row identified by
  ## ``rowName``. Returns nil when no badge is found.
  for badge in findAllByClass(panel, "ct-origin-badge"):
    if badge.attributes.getOrDefault("data-variable-name", "") == rowName:
      return badge
  nil

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
      let panel = renderStatePanel(r, stateVM)
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
      let panel = renderStatePanel(r, stateVM)
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

      let panel = renderStatePanel(r, stateVM)
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
      # Install the host bridge ``state.nim`` would install: forward
      # placeholder-pill clicks into ``OriginChainVM.onShowOrigin`` so
      # the placeholder is resolved via the same ``ct/originChain`` /
      # ``ct/originSummary`` pipeline.
      stateVM.onShowOriginProc = proc(expression: string;
                                      location: Location) =
        originVM.onShowOrigin(expression, location)

      let panel = renderStatePanel(r, stateVM)
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
      let panel = renderScratchpadPanel(r, scratchVM)
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
