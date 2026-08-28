## isonim_uncovered_views_test.nim
##
## BlockTracer.milestones.org M2a, item 2 — "headless render tests for the 7
## uncovered IsoNim views".
##
## ## What was uncovered, and how the number was established
##
## `src/frontend/viewmodel/views/` holds 48 modules. `views/isonim_views_test
## .nim` imports 37 of them and *invokes* every one of those 37 render procs
## (checked, not assumed — an import with no call would be coverage on paper).
## Four more are rendered headlessly elsewhere: `state_view` and
## `debug_controls_view` in `views/views_test.nim`,
## `isonim_process_tree_view` in `scenarios/process_tree_view_test.nim`, and
## `isonim_editor_test_controls_view` in
## `viewmodel/tests/unit/test_editor_test_controls_m4.nim`. 37 + 4 = 41, and
## 48 − 41 = 7.
##
## **Six of the seven are render views, and they are the whole of this file.**
## The seventh is `views/context_menu_bridge.nim`, and it is a different
## animal: a ~20-line `when defined(js)` shim exporting only
## `showContextMenu(options, x, yPos)`. It has no `MockRenderer` overload and
## produces no `MockNode`, so there is nothing a headless render test can
## assert about it. That is recorded here rather than closed with a test that
## would only be asserting that a JS FFI declaration exists — the honest count
## of views needing a render test is six, and all six are below.
##
## The four visual-replay panels had ViewModel-level suites already
## (`frame-viewer/*_test.nim`) which never touch `MockRenderer`: state
## machines only, zero DOM assertions. So the *view* half of those four —
## every class, every overlay's display toggle, every button's wiring — was
## genuinely unasserted.
##
## ## Why a separate file
##
## `isonim_views_test.nim` is 11,335 lines and 465 cases in one binary, and
## it has SIGSEGV-ed partway through before, silently cancelling every case
## declared after the crash (see the `MockNodeNotFoundError` note in that
## file, and the two `agent_activity_*_view_test.nim` files split out of it
## for the same reason). Adding six more suites to it would inherit that
## blast radius, so the established mitigation — a separate file — is what
## this is.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/tests/gui/tests/views/isonim_uncovered_views_test.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/tests/gui/tests/views/isonim_uncovered_views_test.nim

import std/[options, strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/core/async_compat
import isonim/testing/mock_dom

import viewmodels/frame_viewer_vm
import viewmodels/pixel_history_vm
import viewmodels/shader_debug_vm
import viewmodels/video_player_vm
import viewmodels/visual_replay_client

import views/isonim_event_log_filter_dropdown_view
import views/isonim_frame_viewer_view
import views/isonim_pixel_history_view
import views/isonim_shader_debug_view
import views/isonim_toggle_view
import views/isonim_video_player_view

# ---------------------------------------------------------------------------
# Lookup helpers
#
# Raising, not nil-returning, for the reason `isonim_views_test.nim` documents
# at length: every lookup here is followed by a dereference, a nil `MockNode`
# dereference is a SIGSEGV, and a SIGSEGV takes the whole binary down —
# cancelling every case declared after it without reporting one. A raised
# CatchableError fails exactly the case that hit it and lets the rest run.
# ---------------------------------------------------------------------------

type
  MockNodeNotFoundError = object of CatchableError

proc findByClassOrNil(node: MockNode; cls: string): MockNode =
  if node.isNil:
    return nil
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClassOrNil(child, cls)
    if found != nil:
      return found
  nil

proc findByClass(node: MockNode; cls: string): MockNode =
  result = findByClassOrNil(node, cls)
  if result.isNil:
    raise newException(MockNodeNotFoundError,
      "the rendered mock DOM has no element with class '" & cls & "'")

proc findByIdOrNil(node: MockNode; id: string): MockNode =
  if node.isNil:
    return nil
  if node.kind == mnkElement and node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findByIdOrNil(child, id)
    if found != nil:
      return found
  nil

proc findById(node: MockNode; id: string): MockNode =
  result = findByIdOrNil(node, id)
  if result.isNil:
    raise newException(MockNodeNotFoundError,
      "the rendered mock DOM has no element with id '" & id & "'")

proc countByClass(node: MockNode; cls: string): int =
  if node.isNil:
    return 0
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        inc result
  for child in node.children:
    result += countByClass(child, cls)

proc allText(node: MockNode): string =
  ## Every text node beneath `node`, concatenated. Used where the assertion
  ## is "this string reached the DOM" and its exact host element is not the
  ## point.
  ##
  ## `mock_dom.textContent` already recurses, so this is a nil-guard and a
  ## name, not a second traversal — writing the recursion again here doubles
  ## every string, which is how this helper was wrong the first time.
  if node.isNil: "" else: node.textContent

proc displayOf(node: MockNode): string =
  ## `display` is a STYLE in the mock DOM, not an attribute
  ## (`mock_dom.setStyle` writes `node.styles`). Reading it from
  ## `node.attributes` raises `KeyError`, so the accessor exists to make the
  ## right table the only reachable one.
  if node.isNil: "" else: node.styles.getOrDefault("display", "")

# ---------------------------------------------------------------------------
# A fake VisualReplayClient
#
# Copied in shape from `frame-viewer/video_player_vm_test.nim`'s
# `makeMinimalClient`, which is the established fake for these four VMs.
# ---------------------------------------------------------------------------

proc makeClient(drawCalls: seq[VisualReplayDrawCall] = @[]):
    VisualReplayClient =
  ## `drawCalls` is a parameter rather than a constant because
  ## `FrameViewerVM.loadFrameForDraw` re-fetches the draw-call list on
  ## completion. A test that only seeds `vm.drawCalls.val` and then clicks a
  ## draw call has its selection immediately overwritten by whatever the
  ## client answers — which, with an empty fake, is nothing.
  let stubFrame = VisualReplayFrame(
    imageSrc: "stub", geid: some(0'u64), frame: some(0),
    width: 64, height: 64)
  VisualReplayClient(
    playerUrl: "http://stub/",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      newCompletedFuture(VisualReplayInfo(frameCount: 10, width: 64,
                                          height: 64)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(stubFrame),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-" & $frame, geid: some(uint64(frame)),
        frame: some(frame), width: 64, height: 64)),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "draw-" & $draw, geid: some(uint64(100 + draw)),
        frame: some(0), width: 64, height: 64)),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      newCompletedFuture(drawCalls),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      newCompletedFuture(newSeq[VisualReplayPixelHistoryEntry]()),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      newCompletedFuture(VisualReplayShaderDebugInfo()))

proc colour(r, g, b, a: float): VisualReplayPixelColor =
  VisualReplayPixelColor(r: r, g: g, b: b, a: a)

# ===========================================================================
# 1. isonim_toggle_view — renderToggle
# ===========================================================================

suite "IsoNim Toggle — structure":

  test "an unchecked medium toggle renders the documented attribute set":
    let r = MockRenderer()
    let node = renderToggle(r, ToggleRecord(
      label: "Auto-scroll", isChecked: false, isDisabled: false, size: "md"))

    check node.attributes["class"] == "ct-toggle-field"
    check node.attributes["data-disabled"] == ""
    let sw = node.findByClass("ct-toggle")
    check sw.attributes["data-checked"] == "false"
    check sw.attributes["data-size"] == "md"
    # `aria-hidden` on the switch is deliberate: the accessible control is
    # the `role="switch"` input inside it, not the styled span.
    check sw.attributes["aria-hidden"] == "true"
    check node.findByClass("ct-toggle-input").attributes["role"] == "switch"
    check node.findByClass("ct-toggle-label").textContent == "Auto-scroll"

  test "checked and small are carried as data attributes, not classes":
    # The component is documented as "purely CSS-driven: the track color and
    # thumb position are controlled by data-checked / data-size". A refactor
    # that moved state into class names would break every stylesheet rule
    # and pass any test that only looked for the root class.
    let r = MockRenderer()
    let sw = renderToggle(r, ToggleRecord(
      label: "Wrap", isChecked: true, size: "sm")).findByClass("ct-toggle")
    check sw.attributes["data-checked"] == "true"
    check sw.attributes["data-size"] == "sm"

  test "an unknown size falls back to md rather than emitting it verbatim":
    let r = MockRenderer()
    let sw = renderToggle(r, ToggleRecord(label: "X", size: "enormous"))
      .findByClass("ct-toggle")
    check sw.attributes["data-size"] == "md"

  test "an empty size is md too":
    let r = MockRenderer()
    let sw = renderToggle(r, ToggleRecord(label: "X")).findByClass("ct-toggle")
    check sw.attributes["data-size"] == "md"

  test "disabled sets data-disabled on the field wrapper":
    let r = MockRenderer()
    let node = renderToggle(r, ToggleRecord(label: "X", isDisabled: true))
    check node.attributes["data-disabled"] == "true"

suite "IsoNim Toggle — events":

  test "clicking the switch fires onChange":
    let r = MockRenderer()
    var fired = 0
    let node = renderToggle(r, ToggleRecord(label: "X"),
      ToggleCallbacks(onChange: proc() = inc fired))
    node.findByClass("ct-toggle").fireEvent("click")
    check fired == 1

  test "clicking with no callback does not fault":
    # Every handler in this view is nil-guarded, and the guard is only
    # observable by exercising it.
    let r = MockRenderer()
    let node = renderToggle(r, ToggleRecord(label: "X"))
    node.findByClass("ct-toggle").fireEvent("click")
    check node.findByClass("ct-toggle-label").textContent == "X"

# ===========================================================================
# 2. isonim_event_log_filter_dropdown_view — renderFilterDropdownPanel
# ===========================================================================

proc tagRow(label, state: string;
            kinds: openArray[(string, string)]): FilterTagRow =
  result = FilterTagRow(label: label, checkState: state, kinds: @[])
  for (kl, ks) in kinds:
    result.kinds.add(FilterKindRecord(label: kl, checkState: ks))

suite "IsoNim Event Log Filter Dropdown — structure":

  test "an empty dropdown still renders its container and its list id":
    let r = MockRenderer()
    let panel = renderFilterDropdownPanel(r, @[], @[])
    check panel.attributes["class"] == "dropdown-container"
    # The list id is a const the production caller positions against; a
    # renamed id is a silent break in `ui/event_log.nim`.
    check panel.findById(FilterDropdownListId).attributes["class"] ==
      "dropdown-list"
    check panel.countByClass("dropdown-list-row") == 0

  test "tabs render in order with the selected one marked":
    let r = MockRenderer()
    let panel = renderFilterDropdownPanel(r, @[
      FilterTabRecord(label: "Trace events", isSelected: false),
      FilterTabRecord(label: "Recorded events", isSelected: true)], @[])
    let tabs = panel.findByClass("toggle-buttons")
    check tabs.children[0].textContent == "Trace events"
    check tabs.children[0].attributes["data-selected"] == ""
    check tabs.children[1].textContent == "Recorded events"
    check tabs.children[1].attributes["data-selected"] == "true"

  test "a tag row renders its own checkmark and one per kind":
    let r = MockRenderer()
    let panel = renderFilterDropdownPanel(r, @[], @[
      tagRow("Write", "indeterminate",
             [("storage", "checked"), ("memory", "unchecked")])])
    check panel.countByClass("dropdown-list-row") == 1
    let row = panel.findByClass("dropdown-list-row")
    check row.findByClass("ct-checkmark").attributes["data-state"] ==
      "indeterminate"
    check row.findByClass("ct-checkmark-label").textContent == "Write"
    let kinds = row.findByClass("dropdown-kind-items")
    check kinds.children.len == 2
    check allText(kinds.children[0]).contains("storage")
    check allText(kinds.children[1]).contains("memory")

  test "the three check states reach the DOM verbatim":
    # "checked" / "unchecked" / "indeterminate" are the CSS selector values.
    for state in ["checked", "unchecked", "indeterminate"]:
      let r = MockRenderer()
      let panel = renderFilterDropdownPanel(r, @[], @[tagRow("T", state, [])])
      checkpoint("state " & state)
      check panel.findByClass("ct-checkmark").attributes["data-state"] == state

  test "the enable toggle reflects filtersEnabled in label and data-checked":
    let r = MockRenderer()
    let on = renderFilterDropdownPanel(r, @[], @[], filtersEnabled = true)
    check on.findByClass("ct-toggle-label").textContent == "ENABLED"
    check on.findByClass("ct-toggle").attributes["data-checked"] == "true"

    let r2 = MockRenderer()
    let off = renderFilterDropdownPanel(r2, @[], @[], filtersEnabled = false)
    check off.findByClass("ct-toggle-label").textContent == "DISABLED"
    check off.findByClass("ct-toggle").attributes["data-checked"] == "false"

suite "IsoNim Event Log Filter Dropdown — events":

  test "clicking a tab reports its index":
    let r = MockRenderer()
    var clicked = -1
    let panel = renderFilterDropdownPanel(r, @[
      FilterTabRecord(label: "Trace events"),
      FilterTabRecord(label: "Recorded events")], @[],
      cb = FilterDropdownCallbacks(
        onTabClick: proc(i: int) = clicked = i))
    panel.findByClass("toggle-buttons").children[1].fireEvent("click")
    check clicked == 1

  test "toggling a tag reports the row index":
    let r = MockRenderer()
    var toggled = -1
    let panel = renderFilterDropdownPanel(r, @[], @[
      tagRow("A", "checked", []), tagRow("B", "unchecked", [])],
      cb = FilterDropdownCallbacks(
        onTagToggle: proc(i: int) = toggled = i))
    let rows = panel.findById(FilterDropdownListId)
    rows.children[1].findByClass("ct-checkmark-input").fireEvent("change")
    check toggled == 1

  test "toggling a kind reports BOTH indices, not just the kind's":
    # The row index is captured per row and the kind index per kind. A
    # single-loop implementation that captured only the innermost index
    # would pass any one-row test, so this uses two rows deliberately.
    let r = MockRenderer()
    var seenTag = -1
    var seenKind = -1
    let panel = renderFilterDropdownPanel(r, @[], @[
      tagRow("A", "checked", [("a0", "checked")]),
      tagRow("B", "checked", [("b0", "checked"), ("b1", "unchecked")])],
      cb = FilterDropdownCallbacks(
        onKindToggle: proc(t, k: int) =
          seenTag = t
          seenKind = k))
    let rows = panel.findById(FilterDropdownListId)
    let kinds = rows.children[1].findByClass("dropdown-kind-items")
    kinds.children[1].findByClass("ct-checkmark-input").fireEvent("change")
    check seenTag == 1
    check seenKind == 1

  test "clicking the enable toggle fires onToggleEnabled":
    let r = MockRenderer()
    var fired = 0
    let panel = renderFilterDropdownPanel(r, @[], @[],
      cb = FilterDropdownCallbacks(
        onToggleEnabled: proc() = inc fired))
    panel.findByClass("ct-toggle").fireEvent("click")
    check fired == 1

  test "every handler is nil-safe":
    let r = MockRenderer()
    let panel = renderFilterDropdownPanel(r, @[
      FilterTabRecord(label: "Trace events")], @[
      tagRow("A", "checked", [("a0", "checked")])])
    panel.findByClass("toggle-buttons").children[0].fireEvent("click")
    panel.findByClass("ct-toggle").fireEvent("click")
    let row = panel.findByClass("dropdown-list-row")
    row.findByClass("ct-checkmark-input").fireEvent("change")
    row.findByClass("dropdown-kind-items").children[0]
      .findByClass("ct-checkmark-input").fireEvent("change")
    check panel.attributes["class"] == "dropdown-container"

# ===========================================================================
# 3. isonim_frame_viewer_view — renderFrameViewerPanel
# ===========================================================================

suite "IsoNim Frame Viewer — structure":

  test "the panel renders its root and its three regions":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())
      let panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.attributes["class"] == "frame-viewer-component"
      check not panel.findByClassOrNil("frame-viewer-toolbar").isNil
      check not panel.findByClassOrNil("frame-viewer-scrubber").isNil
      check not panel.findByClassOrNil("frame-viewer-body").isNil
      dispose()

  test "the connection status has three distinguishable states":
    # Absent, connected and disconnected are three different CSS classes and
    # three different strings. A view that collapsed two of them would still
    # render something for each.
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())

      vm.visualReplayAvailable.val = false
      var panel = renderFrameViewerPanel(MockRenderer(), vm)
      check not panel.findByClassOrNil("absent").isNil
      check allText(panel).contains("Visual replay absent")

      vm.visualReplayAvailable.val = true
      vm.playerUrl.val = ""
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check not panel.findByClassOrNil("disconnected").isNil
      check allText(panel).contains("Visual replay not connected")

      vm.playerUrl.val = "http://player/"
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check not panel.findByClassOrNil("connected").isNil
      check allText(panel).contains("Visual replay connected")
      dispose()

  test "the frame label prefers a GEID over a frame index":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())
      vm.currentFrame.val = 3
      vm.frameCount.val = 10
      var panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-frame-label").allText ==
        "Frame 3 / 9"

      vm.currentGeid.val = some(77'u64)
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-frame-label").allText ==
        "GEID 77 / 9"
      dispose()

  test "the four stage overlays are mutually exclusive by display":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())

      # Nothing loaded: only the empty placeholder shows.
      var panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-empty").displayOf ==
        "block"
      check panel.findByClass("frame-viewer-loading").displayOf ==
        "none"
      check panel.findByClass("frame-viewer-image").displayOf ==
        "none"

      vm.loading.val = true
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-loading").displayOf ==
        "block"
      check panel.findByClass("frame-viewer-empty").displayOf ==
        "none"

      vm.loading.val = false
      vm.error.val = "player exited"
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-error").displayOf ==
        "block"
      check panel.findByClass("frame-viewer-error").allText == "player exited"
      check panel.findByClass("frame-viewer-empty").displayOf ==
        "none"

      vm.error.val = ""
      vm.frameImageSrc.val = "data:image/png;base64,AAA"
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-image").displayOf ==
        "block"
      check panel.findByClass("frame-viewer-image").attributes["src"] ==
        "data:image/png;base64,AAA"
      check panel.findByClass("frame-viewer-empty").displayOf ==
        "none"
      dispose()

  test "the scrub range is bounded by frameCount, and by 0 when empty":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())
      var panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-frame-range").attributes["max"] ==
        "0"
      vm.frameCount.val = 12
      vm.currentFrame.val = 5
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      let range = panel.findByClass("frame-viewer-frame-range")
      check range.attributes["max"] == "11"
      check range.attributes["value"] == "5"
      dispose()

  test "draw calls render, and the selected one carries the class":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())
      var panel = renderFrameViewerPanel(MockRenderer(), vm)
      check not panel.findByClassOrNil("frame-viewer-draw-calls-empty").isNil

      vm.drawCalls.val = @[
        VisualReplayDrawCall(index: 0, geid: 10'u64, name: "clear",
                             pipeline: "gfx"),
        VisualReplayDrawCall(index: 1, geid: 11'u64, name: "ship",
                             pipeline: "pbr")]
      vm.selectedDrawCall.val = some(1)
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClassOrNil("frame-viewer-draw-calls-empty").isNil
      check panel.countByClass("frame-viewer-draw-call") == 2
      check panel.countByClass("selected") == 1
      let list = panel.findByClass("frame-viewer-draw-calls")
      check allText(list).contains("#1 ship GEID 11")
      check allText(list).contains("pbr")
      dispose()

  test "the selected pixel readout distinguishes none from some":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())
      var panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-selected-pixel").allText ==
        "No pixel selected"
      vm.selectedPixel.val = some(FrameViewerPixel(x: 12, y: 34))
      panel = renderFrameViewerPanel(MockRenderer(), vm)
      check panel.findByClass("frame-viewer-selected-pixel").allText ==
        "Pixel 12, 34"
      dispose()

suite "IsoNim Frame Viewer — events":

  test "the previous and next buttons move the frame":
    createRoot proc(dispose: proc()) =
      let vm = createFrameViewerVM(makeClient())
      vm.frameCount.val = 10
      vm.currentFrame.val = 4
      let panel = renderFrameViewerPanel(MockRenderer(), vm)
      panel.findByClass("frame-viewer-next-frame").fireEvent("click")
      check vm.currentFrame.val == 5
      panel.findByClass("frame-viewer-prev-frame").fireEvent("click")
      check vm.currentFrame.val == 4
      dispose()

  test "clicking a draw call selects that draw call, not the first":
    createRoot proc(dispose: proc()) =
      let calls = @[
        VisualReplayDrawCall(index: 0, geid: 10'u64, name: "a", pipeline: ""),
        VisualReplayDrawCall(index: 1, geid: 11'u64, name: "b", pipeline: ""),
        VisualReplayDrawCall(index: 2, geid: 12'u64, name: "c", pipeline: "")]
      let vm = createFrameViewerVM(makeClient(calls))
      vm.drawCalls.val = calls
      let panel = renderFrameViewerPanel(MockRenderer(), vm)
      let list = panel.findByClass("frame-viewer-draw-calls")
      # children[0] is the header div; the buttons follow it.
      list.children[^1].fireEvent("click")
      check vm.selectedDrawCall.val == some(2)
      dispose()

# ===========================================================================
# 4. isonim_pixel_history_view — renderPixelHistoryPanel
# ===========================================================================

proc historyEntry(draw: int; geid: uint64; passed: bool;
                  reason = ""): VisualReplayPixelHistoryEntry =
  VisualReplayPixelHistoryEntry(
    geid: geid, drawCallIndex: draw, fragmentIndex: 0, primitiveId: 0,
    preColor: colour(0.0, 0.0, 0.0, 1.0),
    shaderOutput: colour(1.0, 0.5, 0.25, 1.0),
    postColor: colour(1.0, 1.0, 1.0, 1.0),
    passed: passed, failureReason: reason,
    testStatus: VisualReplayPixelTestStatus(
      depth: "pass", stencil: "off", blend: "src", cull: "back"))

suite "IsoNim Pixel History — structure":

  test "with no pixel selected the header says so and the list is empty":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      check panel.attributes["class"] == "pixel-history-component"
      check panel.findByClass("pixel-history-title").allText == "Pixel History"
      check panel.findByClass("pixel-history-pixel").allText ==
        "No pixel selected"
      check not panel.findByClassOrNil("pixel-history-empty").isNil
      check panel.countByClass("pixel-history-entry") == 0
      dispose()

  test "a selected pixel is reported with its coordinates and frame":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.selectedPixel.val = some(PixelHistoryPixel(x: 7, y: 9, frame: 3))
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      check panel.findByClass("pixel-history-pixel").allText ==
        "Pixel 7, 9 frame 3"
      dispose()

  test "loading and error suppress the empty placeholder":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.loading.val = true
      var panel = renderPixelHistoryPanel(MockRenderer(), vm)
      check panel.findByClass("pixel-history-loading").displayOf ==
        "block"
      check panel.findByClassOrNil("pixel-history-empty").isNil

      vm.loading.val = false
      vm.error.val = "player gone"
      panel = renderPixelHistoryPanel(MockRenderer(), vm)
      check panel.findByClass("pixel-history-error").displayOf ==
        "block"
      check panel.findByClass("pixel-history-error").allText == "player gone"
      check panel.findByClassOrNil("pixel-history-empty").isNil
      dispose()

  test "each entry carries its geid, its draw index and its pass verdict":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.entries.val = @[
        historyEntry(0, 100'u64, true),
        historyEntry(1, 101'u64, false, "depth")]
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      check panel.countByClass("pixel-history-entry") == 2
      let list = panel.findByClass("pixel-history-list")
      check list.children[0].attributes["data-geid"] == "100"
      check allText(list.children[0]).contains("Draw 0")
      check allText(list.children[0]).contains("GEID 100")
      check allText(list.children[0]).contains("Passed")
      check allText(list.children[1]).contains("Failed: depth")
      dispose()

  test "a failure with no reason still reads as a failure":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.entries.val = @[historyEntry(0, 1'u64, false)]
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      let text = allText(panel.findByClass("pixel-history-pass"))
      check text == "Failed"
      dispose()

  test "the three colour swatches carry converted rgba backgrounds":
    # The 0..1 floats are converted to 0..255 for CSS. An off-by-one or a
    # missing clamp here is invisible to a ViewModel test.
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.entries.val = @[historyEntry(0, 1'u64, true)]
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      let colours = panel.findByClass("pixel-history-colors")
      check colours.children.len == 3
      check panel.countByClass("pixel-history-swatch") == 3
      let firstSwatch = colours.children[0].findByClass("pixel-history-swatch")
      check firstSwatch.attributes["style"] == "background: rgba(0, 0, 0, 1.000)"
      let shaderSwatch = colours.children[1].findByClass("pixel-history-swatch")
      check shaderSwatch.attributes["style"] ==
        "background: rgba(255, 128, 64, 1.000)"
      dispose()

  test "the test-status line names all four tests":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.entries.val = @[historyEntry(0, 1'u64, true)]
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      let tests = panel.findByClass("pixel-history-tests").allText
      check tests.contains("Depth pass")
      check tests.contains("Stencil off")
      check tests.contains("Blend src")
      check tests.contains("Cull back")
      dispose()

  test "the selected entry is the only one carrying the selected class":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.entries.val = @[
        historyEntry(0, 1'u64, true), historyEntry(1, 2'u64, true)]
      vm.selectedEntry.val = some(1)
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      check panel.countByClass("selected") == 1
      let list = panel.findByClass("pixel-history-list")
      check list.children[1].attributes["class"] ==
        "pixel-history-entry selected"
      dispose()

suite "IsoNim Pixel History — events":

  test "clicking an entry selects that entry":
    createRoot proc(dispose: proc()) =
      let vm = createPixelHistoryVM(makeClient())
      vm.entries.val = @[
        historyEntry(0, 1'u64, true), historyEntry(1, 2'u64, true)]
      let panel = renderPixelHistoryPanel(MockRenderer(), vm)
      panel.findByClass("pixel-history-list").children[1].fireEvent("click")
      check vm.selectedEntry.val == some(1)
      dispose()

# ===========================================================================
# 5. isonim_shader_debug_view — renderShaderDebugPanel
# ===========================================================================

proc debugInfo(): VisualReplayShaderDebugInfo =
  VisualReplayShaderDebugInfo(
    shaderStage: "fragment",
    entryPoint: "main",
    source: "a\nb\nc",
    sourceLines: @["let a = 1;", "let b = a * 2;", "return b;"],
    steps: @[
      VisualReplayShaderStep(
        stepIndex: 0, instruction: "OpLoad", sourceLine: 1,
        variables: @[VisualReplayShaderValue(name: "a", value: "1",
                                             valueType: "int")],
        registers: @[]),
      VisualReplayShaderStep(
        stepIndex: 1, instruction: "OpIMul", sourceLine: 2,
        variables: @[],
        registers: @[VisualReplayShaderValue(name: "r0", value: "2",
                                             valueType: "u32")])])

suite "IsoNim Shader Debug — structure":

  test "with no context the panel shows the empty prompt and no toolbar":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      let panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.attributes["class"] == "shader-debug-component"
      check panel.findByClass("shader-debug-title").allText == "Shader Debugger"
      check panel.findByClass("shader-debug-context").allText ==
        "No shader context"
      check not panel.findByClassOrNil("shader-debug-empty").isNil
      check panel.findByClassOrNil("shader-debug-toolbar").isNil
      dispose()

  test "the context line grows one clause per optional field that is set":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.selectedContext.val = some(VisualReplayShaderDebugRequest(x: 4, y: 5))
      var panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.findByClass("shader-debug-context").allText == "Pixel 4, 5"

      vm.selectedContext.val = some(VisualReplayShaderDebugRequest(
        x: 4, y: 5, frame: some(2), drawCallIndex: some(6),
        geid: some(99'u64)))
      panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.findByClass("shader-debug-context").allText ==
        "Pixel 4, 5 frame 2 draw 6 GEID 99"
      dispose()

  test "with debug info the toolbar, source and inspector all render":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())
      let panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.findByClassOrNil("shader-debug-empty").isNil
      check panel.findByClass("shader-debug-stage").allText == "fragment / main"
      check panel.findByClass("shader-debug-step-label").allText == "Step 1 / 2"
      check panel.countByClass("shader-debug-source-line") == 3
      check not panel.findByClassOrNil("shader-debug-inspector").isNil
      dispose()

  test "the step counter is one-based against a zero-based index":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())
      vm.currentStepIndex.val = 1
      let panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.findByClass("shader-debug-step-label").allText == "Step 2 / 2"
      dispose()

  test "exactly one source line carries the current marker, and it moves":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())
      var panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.countByClass("current") == 1
      let source = panel.findByClass("shader-debug-source")
      check source.children[0].attributes["class"] ==
        "shader-debug-source-line current"

      vm.currentStepIndex.val = 1
      panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.countByClass("current") == 1
      check panel.findByClass("shader-debug-source").children[1]
        .attributes["class"] == "shader-debug-source-line current"
      dispose()

  test "line numbers are right-aligned to three columns":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())
      let panel = renderShaderDebugPanel(MockRenderer(), vm)
      let source = panel.findByClass("shader-debug-source")
      check source.children[0].findByClass("shader-debug-line-number")
        .allText == "  1"
      check source.children[0].findByClass("shader-debug-line-code")
        .allText == "let a = 1;"
      dispose()

  test "variables and registers each get their own table or empty note":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())

      # Step 0 has a variable and no registers.
      var panel = renderShaderDebugPanel(MockRenderer(), vm)
      check not panel.findByClassOrNil("shader-debug-variables-table").isNil
      check panel.findByClassOrNil("shader-debug-registers-table").isNil
      check panel.countByClass("shader-debug-values-empty") == 1
      let varRow = panel.findByClass("shader-debug-value-row")
      check varRow.findByClass("shader-debug-value-name").allText == "a"
      check varRow.findByClass("shader-debug-value-type").allText == "int"
      check varRow.findByClass("shader-debug-value-current").allText == "1"

      # Step 1 is the mirror image.
      vm.currentStepIndex.val = 1
      panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.findByClassOrNil("shader-debug-variables-table").isNil
      check not panel.findByClassOrNil("shader-debug-registers-table").isNil
      check panel.findByClass("shader-debug-value-name").allText == "r0"
      dispose()

  test "instruction text reaches the inspector":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())
      let panel = renderShaderDebugPanel(MockRenderer(), vm)
      check panel.findByClass("shader-debug-instruction-value").allText ==
        "OpLoad"
      dispose()

suite "IsoNim Shader Debug — events":

  test "the four step buttons drive the step index and clamp at the ends":
    createRoot proc(dispose: proc()) =
      let vm = createShaderDebugVM(makeClient())
      vm.debugInfo.val = some(debugInfo())
      let panel = renderShaderDebugPanel(MockRenderer(), vm)

      panel.findByClass("shader-debug-step-forward").fireEvent("click")
      check vm.currentStepIndex.val == 1
      panel.findByClass("shader-debug-step-forward").fireEvent("click")
      check vm.currentStepIndex.val == 1  # clamped at the last step
      panel.findByClass("shader-debug-step-first").fireEvent("click")
      check vm.currentStepIndex.val == 0
      panel.findByClass("shader-debug-step-back").fireEvent("click")
      check vm.currentStepIndex.val == 0  # clamped at the first step
      panel.findByClass("shader-debug-step-last").fireEvent("click")
      check vm.currentStepIndex.val == 1
      dispose()

# ===========================================================================
# 6. isonim_video_player_view — renderVideoPlayerPanel
# ===========================================================================

proc makePlayer(): VideoPlayerVM =
  createVideoPlayerVM(createFrameViewerVM(makeClient()))

suite "IsoNim Video Player — structure":

  test "the panel renders its root, stage, transport and scrubber":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.attributes["class"] == "video-player-component"
      check not panel.findByClassOrNil("video-player-stage").isNil
      check not panel.findByClassOrNil("video-player-transport").isNil
      check not panel.findByClassOrNil("video-player-scrubber").isNil
      dispose()

  test "the loupe canvas matches the spec's declared geometry":
    # LoupeCanvasSize is exported and the stylesheet is written against the
    # same number; the canvas attributes are the only place the two meet.
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      let canvas = panel.findByClass("video-player-loupe-canvas")
      # `width`/`height` are CSS style properties, so IsoNim's `ui` DSL routes
      # them through `setStyle` rather than `setAttribute`
      # (`isonim/dsl/transform.nim:isStyleProperty`). Asserted where the view
      # actually puts them; a test reading `attributes` here raises KeyError.
      check canvas.styles.getOrDefault("width", "") == $LoupeCanvasSize
      check canvas.styles.getOrDefault("height", "") == $LoupeCanvasSize
      check LoupeGridSize == LoupeGridRadius * 2 + 1
      check LoupeGridPixels == LoupeGridSize * LoupePixelScale
      dispose()

  test "the play button's glyph follows the play state":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      var panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-play").allText == "▶"
      vm.playState.val = Playing
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-play").allText == "⏸"
      dispose()

  test "the rate badge shows Paused, then a direction arrow and a multiplier":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      var panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-rate-badge").allText == "Paused"

      vm.playState.val = Playing
      vm.direction.val = Forward
      vm.rate.val = Rate4x
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-rate-badge").allText == "▶ 4×"

      vm.direction.val = Reverse
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-rate-badge").allText == "◀ 4×"
      dispose()

  test "picker mode marks the root, the button and the overlay together":
    # Three separate class computations read the same signal. A view that
    # updated one of them and not the others would look right in a
    # screenshot of the button alone.
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      var panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.attributes["class"] == "video-player-component"
      check panel.findByClass("video-player-picker").attributes["class"] ==
        "video-player-button video-player-picker"
      check panel.findByClass("video-player-canvas-overlay")
        .attributes["class"] == "video-player-canvas-overlay"

      vm.pickerState.val = PickerActive
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.attributes["class"] == "video-player-component picker-active"
      check panel.findByClass("video-player-picker").attributes["class"] ==
        "video-player-button video-player-picker pressed"
      check panel.findByClass("video-player-canvas-overlay")
        .attributes["class"] == "video-player-canvas-overlay picker"
      dispose()

  test "an error disables the transport, shows the badge and locks the scrub":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      vm.frameVm.error.val = "player exited (2)"
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-transport").attributes["class"] ==
        "video-player-transport disabled"
      check panel.findByClass("video-player-error").displayOf ==
        "block"
      check panel.findByClass("video-player-error-message").allText ==
        "player exited (2)"
      check panel.findByClass("video-player-scrub-range")
        .attributes["disabled"] == "disabled"
      dispose()

  test "the buffering dot only shows while playing":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      vm.bufferingDegraded.val = true
      var panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-buffering").displayOf ==
        "none"
      vm.playState.val = Playing
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-buffering").displayOf ==
        "block"
      dispose()

  test "the startup spinner gives way to the empty placeholder":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      # The spinner's four conditions (video_player_vm.isStartupSpinnerVisible):
      # visual-capable, a player URL exists, /info has not reported a frame
      # count yet, and no error. `createFrameViewerVM` calls `loadInfo`, and
      # the fake client answers frameCount = 10 synchronously, so the count
      # has to be put back to 0 for "still starting" to be representable.
      vm.frameVm.visualReplayAvailable.val = true
      vm.frameVm.playerUrl.val = "http://player/"
      vm.frameVm.frameCount.val = 0
      var panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-startup").displayOf ==
        "block"
      check panel.findByClass("video-player-empty").displayOf ==
        "none"

      # Not available at all: nothing is starting, so the empty placeholder
      # is the right message.
      vm.frameVm.visualReplayAvailable.val = false
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-startup").displayOf ==
        "none"
      check panel.findByClass("video-player-empty").displayOf ==
        "block"
      dispose()

  test "the frame and draw labels track the frame ViewModel":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      vm.frameVm.frameCount.val = 20
      vm.frameVm.currentFrame.val = 7
      vm.frameVm.drawCalls.val = @[
        VisualReplayDrawCall(index: 0, geid: 1'u64, name: "a", pipeline: ""),
        VisualReplayDrawCall(index: 1, geid: 2'u64, name: "b", pipeline: "")]
      vm.frameVm.selectedDrawCall.val = some(1)
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-frame-label").allText ==
        "Frame 7 / 19"
      check panel.findByClass("video-player-draw-label").allText == "Draw 1 / 1"
      check panel.findByClass("video-player-scrub-range").attributes["max"] ==
        "19"
      dispose()

  test "the magnifier is only visible in picker mode with a position":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      var panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-loupe").attributes["class"] ==
        "video-player-loupe"

      vm.pickerState.val = PickerActive
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-loupe").attributes["class"] ==
        "video-player-loupe"  # active, but nothing to point at yet

      vm.magnifier.val = some(MagnifierPosition(
        displayX: 100.0, displayY: 200.0, sourceX: 5, sourceY: 6))
      panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-loupe").attributes["class"] ==
        "video-player-loupe visible"
      dispose()

  test "the loupe readout reports source coordinates and the frame":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      vm.frameVm.currentFrame.val = 4
      vm.magnifier.val = some(MagnifierPosition(
        displayX: 10.0, displayY: 20.0, sourceX: 33, sourceY: 44))
      vm.magnifierCenterColor.val = some(colour(0.5, 0.25, 0.125, 1.0))
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      check panel.findByClass("video-player-loupe-readout").allText ==
        "x=33 y=44  frame 4"
      check panel.findByClass("video-player-loupe-rgba").allText ==
        "RGBA 0.5000 0.2500 0.1250 1.0000"
      dispose()

suite "IsoNim Video Player — events":

  test "the play button toggles the play state":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      panel.findByClass("video-player-play").fireEvent("click")
      check vm.playState.val == Playing
      panel.findByClass("video-player-play").fireEvent("click")
      check vm.playState.val == Paused
      dispose()

  test "fast forward and rewind drive direction and rate":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      panel.findByClass("video-player-fast-forward").fireEvent("click")
      check vm.playState.val == Playing
      check vm.direction.val == Forward
      check vm.rate.val == Rate1x
      panel.findByClass("video-player-fast-forward").fireEvent("click")
      check vm.rate.val == Rate2x
      panel.findByClass("video-player-rewind").fireEvent("click")
      check vm.direction.val == Reverse
      check vm.rate.val == Rate1x
      dispose()

  test "the picker button toggles picker mode":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      panel.findByClass("video-player-picker").fireEvent("click")
      check vm.pickerState.val == PickerActive
      dispose()

  test "the frame step buttons move by one frame in each direction":
    createRoot proc(dispose: proc()) =
      let vm = makePlayer()
      vm.frameVm.frameCount.val = 10
      vm.frameVm.currentFrame.val = 4
      let panel = renderVideoPlayerPanel(MockRenderer(), vm)
      panel.findByClass("video-player-step-frame-forward").fireEvent("click")
      check vm.frameVm.currentFrame.val == 5
      panel.findByClass("video-player-step-frame-back").fireEvent("click")
      check vm.frameVm.currentFrame.val == 4
      dispose()
