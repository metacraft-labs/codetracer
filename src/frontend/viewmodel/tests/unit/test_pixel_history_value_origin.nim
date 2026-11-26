## test_pixel_history_value_origin.nim — "Show value origin" on a Pixel
## History entry (codetracer-pm issue 2026-11-26, "Pixel History entries offer
## no value origin").
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## A Pixel History entry is a draw call that touched the picked pixel. Its
## "Show value origin" asks where the colour that draw wrote came from in the
## recorded program's values. That answer needs a bridge from the pixel back
## to those values, which does not exist yet, so the operation opens the
## Origin Chain side panel on the pixel and REFUSES BY NAME: the panel says the
## recording has no CPU-side origin for that pixel, naming the pixel, its frame
## and the draw. It never shows a made-up chain.
##
## Asserted, on the ViewModels every front-end shares:
##
##   * the operation (`PixelHistoryVM.showValueOriginForEntry`) opens the side
##     panel, pushes a breadcrumb naming the pixel, and shows the named refusal
##     (`OriginChainVM.refusal`) — with no chain and no `ct/originChain` sent;
##   * an index outside the history, a history with no picked pixel and a host
##     with no Origin Chain model do nothing;
##   * a following ordinary "Show value origin" on a variable
##     (`OriginChainVM.onShowOrigin`) clears the refusal;
##   * a chain asked for before the pixel cannot land on the refusal late;
##   * going back to the pixel's breadcrumb shows its refusal again, without
##     asking the engine about a "variable" that is a pixel.
##   * a front-end that draws no side panel (the terminal, GPUI) asks the same
##     question and gets the panel's words for its status line
##     (`valueOriginWordsForEntry`), the same with no Origin Chain model, and
##     an entry that is gone named as gone.
##
## THE STAND-INS, AND WHY: the Origin Chain model's store runs over the
## `MockBackendService` that `test_origin_chain_vm.nim` already uses — it
## records each command sent, which is how "no `ct/originChain` is sent for a
## pixel" is observed. The Pixel History model is the production one over a
## client with no transport at all (`VisualReplayClient()`): the operation
## under test asks the player nothing, and any call into that client would
## fail its `assert`. Its entries are set as the player's `/pixel-history`
## answer would set them, so the suite needs no player and runs the same on
## the C and JS backends.

import std/[options, strutils, unittest]

import isonim/core/async_compat
import isonim/core/[signals, computation, owner]

import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, types]
import ../../viewmodels/[origin_chain_types, origin_chain_vm, pixel_history_vm,
                         visual_replay_client]

proc drain() = drainPlatformCallbacks()

proc entry(draw: int; geid: uint64): VisualReplayPixelHistoryEntry =
  VisualReplayPixelHistoryEntry(drawCallIndex: draw, geid: geid, passed: true)

proc makeVMs(): tuple[history: PixelHistoryVM, origin: OriginChainVM,
                      mock: MockBackendService] =
  ## Pixel (12, 34) of frame 2, touched by draws 5 (GEID 501) and 9 (GEID 902).
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let origin = createOriginChainVM(store)
  let history = createPixelHistoryVM(VisualReplayClient(), store)
  history.selectedPixel.val = some(PixelHistoryPixel(x: 12, y: 34, frame: 2))
  history.entries.val = @[entry(5, 501'u64), entry(9, 902'u64)]
  drain()
  mock.clearReceivedCommands()
  (history, origin, mock)

proc chainOf(variable: string): OriginChain =
  OriginChain(queryVariable: variable,
              hops: @[OriginHop(kind: okTrivialCopy, stepId: 7,
                                targetExpr: variable)],
              terminator: Terminator(kind: tkwLiteral, expression: "1"))

suite "Pixel History: Show value origin":

  test "the menu's words are the shared ones":
    check ShowValueOriginLabel == "Show value origin"

  test "an entry's value origin opens the side panel on a named refusal":
    let (history, origin, mock) = makeVMs()
    check not origin.sidePanelOpen.val
    check history.showValueOriginForEntry(1, origin)
    drain()
    check origin.sidePanelOpen.val
    # The breadcrumb names the pixel.
    check origin.breadcrumbStack.val.len == 1
    let crumb = origin.breadcrumbStack.val[0].variableName
    check "12, 34" in crumb
    check "frame 2" in crumb
    # The refusal names the recording's missing origin, the pixel, its frame
    # and the draw — and nothing pretends to be a chain.
    let refusal = origin.refusal.val
    check "no CPU-side origin" in refusal
    check "pixel 12, 34" in refusal
    check "frame 2" in refusal
    check "draw 9" in refusal
    check "GEID 902" in refusal
    check refusal == pixelOriginRefusalText(PixelOriginQuery(
      x: 12, y: 34, frame: 2, drawCallIndex: 9, geid: 902'u64))
    check origin.activeChain.val.isNone
    check not origin.loading.val
    # No engine can answer a pixel's origin yet: nothing is asked.
    check mock.findCommand("ct/originChain").isNone

  test "an index outside the history, no pixel, or no model does nothing":
    let (history, origin, mock) = makeVMs()
    check not history.showValueOriginForEntry(-1, origin)
    check not history.showValueOriginForEntry(2, origin)
    check not history.showValueOriginForEntry(0, nil)
    history.selectedPixel.val = none(PixelHistoryPixel)
    check not history.showValueOriginForEntry(0, origin)
    drain()
    check not origin.sidePanelOpen.val
    check origin.breadcrumbStack.val.len == 0
    check origin.refusal.val == ""
    check mock.findCommand("ct/originChain").isNone

  test "an ordinary Show value origin afterwards clears the refusal":
    let (history, origin, mock) = makeVMs()
    check history.showValueOriginForEntry(0, origin)
    check origin.refusal.val.len > 0
    origin.onShowOrigin("total", Location(file: "main.py", line: 3))
    drain()
    check origin.refusal.val == ""
    check origin.sidePanelOpen.val
    check origin.breadcrumbStack.val.len == 2
    check origin.breadcrumbStack.val[1].variableName == "total"
    check mock.findCommand("ct/originChain").isSome

  test "a chain asked before the pixel does not land on its refusal":
    let (history, origin, _) = makeVMs()
    origin.onShowOrigin("total", Location(file: "main.py", line: 3))
    let asked = origin.latestRequestId.val
    check history.showValueOriginForEntry(1, origin)
    # The variable's answer arrives late: it is for the earlier question.
    origin.applyChainResponse(chainOf("total"), asked)
    check origin.activeChain.val.isNone
    check "no CPU-side origin" in origin.refusal.val

  test "going back to the pixel's breadcrumb shows its refusal again":
    let (history, origin, mock) = makeVMs()
    check history.showValueOriginForEntry(1, origin)
    let refusal = origin.refusal.val
    origin.onShowOrigin("total", Location(file: "main.py", line: 3))
    origin.applyChainResponse(chainOf("total"), origin.latestRequestId.val)
    check origin.activeChain.val.isSome
    check origin.refusal.val == ""
    mock.clearReceivedCommands()
    origin.onSelectBreadcrumb(0)
    drain()
    check origin.refusal.val == refusal
    check origin.activeChain.val.isNone
    check origin.breadcrumbStack.val.len == 1
    check mock.findCommand("ct/originChain").isNone

  test "a front-end with no side panel gets the panel's words":
    # The terminal and the GPUI window draw no Origin Chain side panel: they
    # ask the same question of the same model and print its answer on their
    # status line (`valueOriginWordsForEntry`).
    let (history, origin, mock) = makeVMs()
    let want = pixelOriginRefusalText(PixelOriginQuery(
      x: 12, y: 34, frame: 2, drawCallIndex: 5, geid: 501'u64))
    check history.valueOriginWordsForEntry(0, origin) == want
    check origin.refusal.val == want
    check origin.breadcrumbStack.val.len == 1
    # A host with no Origin Chain model says the same words.
    check history.valueOriginWordsForEntry(0, nil) == want
    # An entry that is gone is named as gone, and nothing is asked.
    check history.valueOriginWordsForEntry(2, origin) == NoHistoryEntryText
    check origin.breadcrumbStack.val.len == 1
    check mock.findCommand("ct/originChain").isNone
