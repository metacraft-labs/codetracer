## Keyboard focus follows committed pane ownership, not a drag's temporary
## projection. The real runtime receives SGR pointer reports and Escape.
## No mocks: layout-only input is supported without a replay session; these
## cases use the real layout, focus manager, router and gesture binding.

import std/[json, strutils, unittest]

import codetracer_embed

import headless_app/layout_model
import ../runtime
import ../tui_app
import ../edit_binding
import ../views/source_pane
import ../layout/[binding, cells]
import ../theme/capabilities

const ExpectedAssertions = 58
var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc areaOf(rt: TuiRuntime; pane: PaneKind): CellArea =
  for region in rt.layoutGeometry().projection.regions:
    if region.pane == pane:
      return region.area
  raise newException(AssertionDefect, "pane absent: " & $pane)

proc visible(rt: TuiRuntime; pane: PaneKind): bool =
  for region in rt.layoutGeometry().projection.regions:
    if region.pane == pane:
      return true

proc mouse(rt: TuiRuntime; code, row, col: int; release = false) =
  discard rt.handleToken("\e[<" & $code & ";" & $(col + 1) & ";" &
                        $(row + 1) & (if release: "m" else: "M"), 0)

proc click(rt: TuiRuntime; area: CellArea) =
  rt.mouse(0, area.row, area.col + 2)
  rt.mouse(0, area.row, area.col + 2, release = true)

proc focusAreaOf(rt: TuiRuntime; pane: PaneKind): CellArea =
  for region in rt.focus.regions:
    if region.pane == pane:
      return region.area
  raise newException(AssertionDefect, "focus region absent: " & $pane)

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, 200, 50)
  discard result.enableLayoutBinding()
  let editor = result.areaOf(paneEditor)
  result.mouse(0, editor.row + 2, editor.col + 2)
  result.mouse(0, editor.row + 2, editor.col + 2, release = true)

proc withSource(rt: TuiRuntime): EditBuffer =
  # Route through a real readonly replay document, using this file's bytes.
  let path = currentSourcePath()
  let text = readFile(path)
  let lines = text.splitLines()
  rt.app.source = initSourcePaneModel(path = path, heldLines = lines,
    firstHeldLine = 1, totalLineCount = lines.len, viewportTop = 1,
    executionLine = 1)
  rt.app.editSession = newEditSession()
  discard rt.app.editSession.openFile(path, text)
  result = rt.app.editSession.activeBuffer()
  result.doc.setReadOnly(true)

proc typeText(rt: TuiRuntime; text: string) =
  for ch in text:
    discard rt.handleToken($ch, 0)

suite "keyboard focus during layout input":
  test "a tab drag and Escape keep the committed keyboard owner":
    let rt = newRuntime()
    let b = rt.app.layoutBinding
    let state = rt.areaOf(paneState)
    let editor = rt.areaOf(paneEditor)
    rt.click(state)
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState
    let committed = saveLayout(b.layout)
    rt.mouse(0, state.row, state.col + 2)
    rt.mouse(32, state.row, state.col + 6)
    ck b.interaction.kind == ikDraggingTab
    ck b.interaction.source == paneState
    ck not b.presentedLayout.tree.contains(paneState)
    ck b.layout.tree.contains(paneState)
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState
    rt.mouse(32, editor.row + editor.height div 2,
             editor.col + editor.width div 2)
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState
    discard rt.handleToken("\e", 0)
    ck b.interaction.kind == ikNone
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState
    ck saveLayout(b.layout) == committed
    ck paneState in rt.focus.focusOrder()

  test "resize during a tab drag reprojects committed ownership":
    let rt = newRuntime()
    let b = rt.app.layoutBinding
    let state = rt.areaOf(paneState)
    let editor = rt.areaOf(paneEditor)
    rt.click(state)
    rt.mouse(0, state.row, state.col + 2)
    rt.mouse(32, state.row, state.col + 6)
    ck b.interaction.kind == ikDraggingTab
    rt.resize(240, 60)
    ck b.interaction.kind == ikDraggingTab
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState
    ck rt.focusAreaOf(paneEditor).height > editor.height
    # Resizing legitimately re-shares the committed layout. Cancellation
    # must preserve that resized value, rather than undoing the resize.
    let resizedCommitted = saveLayout(b.layout)
    let resizedEditor = rt.areaOf(paneEditor)
    rt.mouse(32, resizedEditor.row + resizedEditor.height div 2,
             resizedEditor.col + resizedEditor.width div 2)
    discard rt.handleToken("\e", 0)
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.interaction.kind == ikNone
    ck saveLayout(b.layout) == resizedCommitted

  test "programmatic tab activation keeps the input owner":
    let rt = newRuntime()
    let b = rt.app.layoutBinding
    ck rt.focus.focusedPane() == (true, paneEditor)
    ck b.focus == paneEditor
    let activated = b.dispatch(cmdActivateTab(paneScratchpad))
    ck activated.status == lasApplied
    ck b.focus == paneEditor
    ck rt.focus.focusedPane() == (true, paneEditor)

  test "the wheel changes tabs without taking keyboard focus":
    let rt = newRuntime()
    let b = rt.app.layoutBinding
    let state = rt.areaOf(paneState)
    ck rt.focus.focusedPane() == (true, paneEditor)
    rt.mouse(65, state.row, state.col + 2)
    ck rt.visible(paneScratchpad)
    ck rt.focus.focusedPane() == (true, paneEditor)
    ck b.focus == paneEditor

  test "pointer clicks focus inactive and already active tabs":
    let rt = newRuntime()
    let b = rt.app.layoutBinding
    let state = rt.areaOf(paneState)
    discard b.dispatch(cmdActivateTab(paneScratchpad))
    rt.click(state)
    ck rt.visible(paneState)
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState
    discard rt.handleToken("\ev", 0)
    ck rt.focus.focusedPane() == (true, paneEditor)
    rt.click(state)
    ck rt.focus.focusedPane() == (true, paneState)
    ck b.focus == paneState

  test "a typed focus command hands ownership back from the binding":
    let rt = newRuntime()
    let buf = rt.withSource()
    let original = buf.text()
    ck rt.debugBuffer() == buf
    ck rt.focus.focusedPane() == (true, paneEditor)
    discard rt.handleToken(":", 0)
    ck rt.prompt.open
    rt.typeText("focus left")
    discard rt.handleToken("\r", 0)
    ck not rt.prompt.open
    ck rt.focus.focusedPane() == (true, paneFileTree)
    ck rt.app.layoutBinding.focus == paneFileTree
    discard rt.handleToken(":", 0)
    rt.typeText("dock left")
    discard rt.handleToken("\r", 0)
    let docked = rt.app.layoutBinding.layout.dockedAt(leLeft)
    ck docked.len == 1 and docked[0].pane == paneFileTree
    ck rt.app.layoutBinding.layout.tree.contains(paneEditor)
    ck rt.focus.focusedPane()[0]
    ck buf.text() == original

  test "a palette focus command survives palette closure":
    let rt = newRuntime()
    let buf = rt.withSource()
    let original = buf.text()
    ck rt.debugBuffer() == buf
    ck rt.focus.focusedPane() == (true, paneEditor)
    discard rt.handleToken("\eOP", 0)
    ck rt.app.omnibar.isOpen
    rt.typeText(":focus left")
    discard rt.handleToken("\r", 0)
    ck not rt.app.omnibar.isOpen
    ck rt.focus.focusedPane() == (true, paneFileTree)
    ck rt.app.layoutBinding.focus == paneFileTree
    discard rt.handleToken(":", 0)
    rt.typeText("dock left")
    discard rt.handleToken("\r", 0)
    let docked = rt.app.layoutBinding.layout.dockedAt(leLeft)
    ck docked.len == 1 and docked[0].pane == paneFileTree
    ck rt.app.layoutBinding.layout.tree.contains(paneEditor)
    ck rt.focus.focusedPane()[0]
    ck buf.text() == original

  test "assertion count":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
