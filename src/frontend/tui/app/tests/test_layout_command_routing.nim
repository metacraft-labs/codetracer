## test_layout_command_routing.nim — PLAT-6, Tier 1.
##
## ## What this file is for
##
## PLAT-6 landed a binding nothing called. `app/tui_app.enableLayoutBinding`
## existed, `views/shell.shellModel` honoured it, and no path in the product
## reached either — so every gesture in `test_layout_binding.nim` was driven by
## a test constructing a `LayoutBinding` directly. This suite asserts the WIRING
## that closes that: `app/runtime.enableLayoutBinding` is the opt-in, and
## `runPromptLine` routes the twelve layout verbs from the REAL `:` prompt into
## `binding.runLayoutCommand`.
##
## `tests/real_terminal/test_real_layout_gestures.nim` drives the same path
## through a real pty. This one owns the parts a terminal cannot answer: the
## resulting `Layout`, and the screen a NON-bound runtime paints.
##
## ## THE MOUSE HALF, ADDED AFTER THE FIRST CLOSING PASS
##
## PLAT-6 stayed `partial` a second time for a row nobody had ticked honestly:
## `binding.onMouse`, `beginDrag`, `hoverAt` and `dropDrag` had no caller
## outside their own module and `test_layout_binding.nim`. `handleToken` routed
## the twelve `:` verbs and NO mouse report, so with `--layout-binding` on a
## typed `:dock bottom` rearranged a real terminal and a mouse drag did nothing.
## `runtime.routeMouseReport` is the wiring; the cases below are its Tier-1
## half, and `tests/real_terminal/test_real_layout_mouse.nim` drives the same
## drag through a real pty.
##
## One of them is a RECHECK rather than a new assertion. The milestone recorded
## that a mouse drop can reach only the top and the bottom dock edges until
## something is docked left or right — a claim written about a gesture no input
## path reached. "which dock edges a real drag can reach" sweeps every cell of
## the screen for the set, commits four aimed drags through `handleToken`, and
## then asserts the claim's second half by docking one pane left and sweeping
## again.
##
## ## THE HALF THAT MATTERS MOST IS THE OFF ARM
##
## The binding is an OPT-IN and PLAT-6's whole "byte-identical screens" claim
## rests on what happens without it. Two separate statements are made here, and
## they are not the same statement:
##
##   * **off**: `:dock bottom` at the prompt is the unknown §4.3 command it has
##     always been, `layoutBinding` is `nil`, and the routing branch is not
##     entered — so the screen is CTUI-3's;
##   * **on but ungestured**: the binding is seeded from the arrangement the
##     session would have painted, so the frame after `enableLayoutBinding` is
##     the frame that would have been painted without it — compared as RENDERED
##     ROWS at twenty geometries, not read off the nil defaults.
##
## The second is the interesting one: "nothing changed because the field is
## nil" is a fact about a field, and "nothing changed because the two screens
## are equal" is a fact about the screens.
##
## ## No mocks
##
## There is no mock here and none is justified. `TuiRuntime` takes a
## `Dispatcher` with no ViewModels — which is not a stand-in for one:
## `app/commands/interpreter.nim` documents nil as "not wired" and answers
## `drUnavailable` BY NAME, and that named answer is what the §4.3 arms below
## assert. The layout verbs need no debugger at all, which is the point of them
## being a separate surface. The keymap, the prompt, the interpreter, the
## binding and the layout model are all the product's own.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc` cannot
## see `testStatusIMPL`, so it sets a module-level global and the case still
## reports `[OK]` with its failed comparison printed above it. Every helper here
## that calls `check` is a `template`; the ones that are `proc`s return values
## and call `check` nowhere.

import std/[algorithm, json, options, strutils, unittest]

import headless_app/layout_model

import ../runtime
import ../theme/capabilities

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 402

const
  Geometries = [(cols: 80, rows: 24), (cols: 120, rows: 40),
                (cols: 200, rows: 60)]

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# Fixtures. Values only; nothing here calls `check`.
# ---------------------------------------------------------------------------

proc caps(): TerminalCapabilities =
  ## A resolved capability set, from a constructed environment rather than the
  ## process's own — `test_capability_resolution.nim`'s rule, for the same
  ## reason: a suite that read `getEnv` would assert something different on
  ## every host.
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newRuntime(cols, rows: int): TuiRuntime =
  newTuiRuntime(newTuiApp(), caps(), cols, rows)

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  ## `:`, then every character, then `Enter` — through `handleToken`, ONE TOKEN
  ## AT A TIME, which is the path a terminal's bytes take. Returns the outcome
  ## of the submit, because that is the one that ran anything.
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc focusedPaneOf(rt: TuiRuntime): PaneKind =
  let (had, pane) = rt.focus.focusedPane()
  if had: pane else: PaneKind.low

proc bodyRows(rt: TuiRuntime): seq[string] =
  rt.shellScreenOf().rows

proc sgrReport(button, row, col: int; pressed: bool): string =
  ## One SGR-1006 report, in the EXACT bytes a terminal puts on the wire.
  ##
  ## Written out here rather than taken from a helper, and both halves of that
  ## matter. `TermAssert.sendMouseClick` can only write a press and a release at
  ## the SAME cell — which is a click, not a drag — so a drag has to be spelled
  ## by hand whatever this file does; and Verification-Harness-Traps §9 is about
  ## exactly the cost of trusting an input helper that quietly narrows what it
  ## was asked for. The coordinates are ONE-BASED on the wire (`app/input/
  ## mouse.nim`'s header), which is why every argument here is zero-based and
  ## every field below is `+ 1`: a decoder that stopped subtracting would agree
  ## with a test that had also stopped adding, so the offset is written on the
  ## far side of the decoder from the assertion.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc dockedEdgeOf(rt: TuiRuntime; pane: PaneKind): (bool, LayoutEdge) =
  ## Which edge `pane` is auto-hidden on, read from the layout itself.
  for edge in [leLeft, leRight, leTop, leBottom]:
    for d in rt.app.layoutBinding.layout.dockedAt(edge):
      if d.pane == pane:
        return (true, edge)
  (false, leLeft)

proc dockEdgesADropCanReach(rt: TuiRuntime; dragged: PaneKind;
                            cols, rows: int): seq[string] =
  ## Every dock edge a DROP can land on, swept over every cell of the screen.
  ##
  ## The gesture is begun and cancelled per cell, so nothing is committed and
  ## the geometry the sweep measures against cannot move underneath it.
  ## `cancel` takes no layout and therefore cannot have changed one — the
  ## binding's own suite asserts that separately.
  result = @[]
  let b = rt.app.layoutBinding
  let geom = rt.layoutGeometry()
  for row in 0 ..< rows:
    for col in 0 ..< cols:
      discard b.beginDrag(dragged)
      discard b.hoverAt(geom, row, col)
      if b.interaction.hover.isSome and
         b.interaction.hover.get.kind == dtDockEdge:
        let side = $b.interaction.hover.get.region.side
        if side notin result:
          result.add side
      discard b.cancelGesture()
  result.sort()

proc dockStripRowOf(rt: TuiRuntime): int =
  ## The row a BOTTOM dock strip occupies, read from the binding's own geometry
  ## rather than computed here a second time.
  let geom = rt.layoutGeometry()
  for s in geom.strips:
    if s.edge == leBottom:
      return s.area.row
  -1

# ---------------------------------------------------------------------------

suite "PLAT-6: the `:` prompt reaches the layout binding, and only on request":

  test "OFF BY DEFAULT: a layout verb is the unknown §4.3 command it always was":
    # THE ARM THE WHOLE OPT-IN RESTS ON. Nothing here may behave differently
    # from the way it behaved before the routing existed.
    var runsChecked = 0
    for g in Geometries:
      let rt = newRuntime(g.cols, g.rows)
      ck not rt.layoutBindingEnabled()
      ck rt.app.layoutBinding.isNil
      let before = rt.bodyRows()
      for verb in LayoutVerbNames:
        inc runsChecked
        let outcome = rt.typeLine(verb & " bottom")
        # It reached §4.3's interpreter and was REPORTED, which is CTUI-10's
        # rule; it did not reach the binding, because there is not one.
        ck rt.app.layoutBinding.isNil
        ck rt.app.notification.len > 0
        ck rt.app.notification.contains(verb)
        ck not outcome.quit
      # …and the screen is the one it started with, compared as rendered rows.
      let after = rt.bodyRows()
      ck after.len == before.len
      var changed = 0
      for i in 0 ..< min(before.len, after.len):
        # The status row carries the notification, so it is expected to differ;
        # every other row must be identical.
        if before[i] != after[i]:
          inc changed
          if i != before.len - 1:
            checkpoint("row " & $i & " moved with no binding:\n  '" &
                       before[i] & "'\n  '" & after[i] & "'")
      ck changed <= 1
    checkpoint("layout verbs typed with no binding: " & $runsChecked)
    ck runsChecked == 3 * LayoutVerbNames.len

  test "enabling it changes NOTHING on screen, compared as rendered rows":
    # THE MEASURED FORM OF "byte identical". Twenty geometries, spanning all
    # three profiles and both sides of every band boundary, each rendered twice
    # — once from a runtime with no binding and once from a runtime whose
    # binding has just been enabled and not gestured with. Reading the nil
    # defaults would be a statement about a field.
    var comparisons = 0
    var mismatches: seq[string] = @[]
    for size in [(80, 24), (81, 24), (100, 30), (119, 34), (120, 34),
                 (120, 35), (121, 40), (140, 40), (160, 50), (179, 40),
                 (180, 40), (181, 45), (200, 60), (240, 60), (80, 34),
                 (80, 35), (200, 34), (100, 60), (300, 80), (60, 20)]:
      let plain = newRuntime(size[0], size[1])
      let bound = newRuntime(size[0], size[1])
      discard bound.enableLayoutBinding()
      ck bound.layoutBindingEnabled()
      let a = plain.bodyRows()
      let b = bound.bodyRows()
      inc comparisons
      if a != b:
        for i in 0 ..< min(a.len, b.len):
          if a[i] != b[i]:
            mismatches.add $size[0] & "x" & $size[1] & " row " & $i &
              ":\n  unbound '" & a[i] & "'\n  bound   '" & b[i] & "'"
            break
      ck a == b
      # And the DECORATIONS are empty, which is what says the equality above is
      # not two screens that both happen to be wrong.
      ck bound.shellScreenOf().decorations.len == 0
    if mismatches.len > 0:
      for m in mismatches[0 ..< min(4, mismatches.len)]:
        checkpoint(m)
    checkpoint("geometries compared bound against unbound: " & $comparisons)
    ck comparisons == 20
    ck mismatches.len == 0

  test "`:dock bottom` typed at the prompt docks the FOCUSED pane, and shows it":
    # THE GESTURE, THROUGH THE PRODUCT'S OWN INPUT PATH: `handleToken` for
    # every byte, `command_line.applyKey` for the buffer, `runPromptLine` for
    # the submit, `binding.runLayoutCommand` for the verb. Asserted on the
    # resulting `Layout` AND on the painted screen.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    let focused = rt.focusedPaneOf()
    ck focused == paneCalltrace          ## the Compact profile's first region
    ck rt.app.layoutBinding.layout.tree.contains(focused)
    ck rt.app.layoutBinding.layout.dockedIndex(focused) < 0
    ck rt.dockStripRowOf() < 0

    let outcome = rt.typeLine("dock bottom")
    checkpoint(":dock bottom -> " & rt.app.notification)
    ck outcome.repaint
    ck not outcome.quit
    # THE MODEL. The pane left the tree for the docked list, which is a fact
    # only the layout can be asked about.
    ck rt.app.layoutBinding.layout.dockedIndex(focused) >= 0
    ck not rt.app.layoutBinding.layout.tree.contains(focused)
    ck rt.app.layoutBinding.userModified
    # THE SCREEN. A bottom strip exists, it is one row, and it is painted with
    # the dock-strip glyph carrying the pane's own title.
    let stripRow = rt.dockStripRowOf()
    ck stripRow >= 0
    let screen = rt.shellScreenOf()
    var stripDecorations = 0
    for d in screen.decorations:
      if d.kind == ldDockStrip:
        inc stripDecorations
        ck d.area.height == DockStripThickness
        ck d.area.row == stripRow
    ck stripDecorations == 1
    let painted = screen.rows[stripRow]
    checkpoint("dock strip row: '" & painted & "'")
    ck painted.contains(DockStripGlyph)
    ck painted.contains("Call Stack")
    # …and the pane's own title row is gone from the body, which is the half a
    # strip-only assertion would miss.
    var titlesLeft = 0
    for row in screen.rows:
      if row.startsWith("CALL STACK"):
        inc titlesLeft
    ck titlesLeft == 0

    # `:undo-layout`, through the same prompt, puts it back.
    discard rt.typeLine("undo-layout")
    checkpoint(":undo-layout -> " & rt.app.notification)
    ck rt.app.layoutBinding.layout.dockedIndex(focused) < 0
    ck rt.app.layoutBinding.layout.tree.contains(focused)
    ck rt.dockStripRowOf() < 0
    var titlesBack = 0
    for row in rt.shellScreenOf().rows:
      if row.startsWith("CALL STACK"):
        inc titlesBack
    ck titlesBack == 1

  test "the pane a verb acts on is the one Tab moved to":
    # ONE FOCUS, NOT TWO. `LayoutBinding.focus` is what `:dock` acts on and
    # `PaneFocus` is what `Tab` moves; `runPromptLine` synchronises them before
    # every layout command, so a user who tabbed to a pane and typed `:dock
    # bottom` docks THAT pane. Without the synchronisation this docks whatever
    # the binding was constructed with, which is a defect a screen assertion
    # alone would not name.
    let rt = newRuntime(120, 40)
    discard rt.enableLayoutBinding()
    let first = rt.focusedPaneOf()
    discard rt.handleToken("\t", 0'i64)
    let second = rt.focusedPaneOf()
    checkpoint("Tab moved focus from " & $first & " to " & $second)
    ck second != first
    discard rt.typeLine("dock right")
    ck rt.app.layoutBinding.layout.dockedIndex(second) >= 0
    ck rt.app.layoutBinding.layout.dockedIndex(first) < 0
    # …and the focus ring was REBUILT, so `Tab` no longer offers a pane that is
    # not on the screen any more.
    ck rt.focusedPaneOf() != second
    var offered = 0
    for pane in rt.focus.focusOrder():
      if pane == second:
        inc offered
    ck offered == 0

  test "§4.3 is untouched: its own commands still reach the interpreter":
    # THE ROUTING IS A PREFIX, NOT A REPLACEMENT. A layout verb is intercepted;
    # everything else goes where it always went, including the one §4.3 command
    # that is a LOCAL action and therefore proves the whole tail of
    # `handleToken` still runs.
    let rt = newRuntime(120, 40)
    discard rt.enableLayoutBinding()

    # `:goto 4500` reaches CTUI-10's dispatcher and is answered by name.
    let goto = rt.typeLine("goto 4500")
    checkpoint(":goto 4500 -> " & rt.app.notification & " | detail '" &
               goto.detail & "'")
    ck goto.action == kaSeekToTick
    ck rt.app.notification.len > 0
    # The layout did not move: `goto` is not a layout verb.
    ck rt.app.layoutBinding.layout.tree.contains(paneCalltrace)
    ck not rt.app.layoutBinding.userModified

    # An unknown word is still reported as one, and is not mistaken for a verb.
    let unknown = rt.typeLine("teleport")
    checkpoint(":teleport -> " & rt.app.notification)
    ck rt.app.notification.contains("teleport")
    ck unknown.action == kaNone
    ck not rt.app.layoutBinding.userModified

    # `:quit` is a §4.3 command that resolves to a LOCAL action, and it still
    # ends the session — CTUI-14's defect, which lived exactly here.
    let quitting = rt.typeLine("quit")
    ck quitting.quit
    ck quitting.detail == QuitDetail

  test "every verb is reachable from the prompt, and none of them is silent":
    # THE WHOLE SURFACE THROUGH THE REAL PATH, not through `runLayoutCommand`
    # directly. Each verb is typed with an argument that is legal for it; what
    # is asserted is that the prompt REACHED the binding — the notification is
    # the binding's message and not the interpreter's "unknown command".
    var reached = 0
    for verb in LayoutVerbNames:
      let rt = newRuntime(80, 24)
      discard rt.enableLayoutBinding()
      let arg = case verb
        of "move-tab": " left"
        of "move-pane": " right"
        of "merge-pane": " state"
        of "dock": " bottom"
        of "undock": ""
        of "reveal": ""
        of "hide": ""
        of "resize": " 60"
        of "focus": " right"
        else: ""
      discard rt.typeLine(verb & arg)
      let said = rt.app.notification
      checkpoint(":" & verb & arg & " -> " & said)
      ck said.len > 0
      # THE DISCRIMINATOR. §4.3's interpreter reports an unknown command with
      # the word "unknown" in it; the binding never does, whatever it decided.
      # So this distinguishes "the binding answered" from "the interpreter
      # answered", which "the message is non-empty" cannot.
      ck not said.toLowerAscii().contains("unknown command")
      inc reached
    checkpoint("verbs that reached the binding from the prompt: " & $reached)
    ck reached == LayoutVerbNames.len

    # THE NEGATIVE TWIN, through the same predicate and the same path: a word
    # that is NOT a verb does produce the interpreter's own report, so the
    # assertion above is a measurement rather than a `not contains` over a
    # haystack that never contains anything.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    discard rt.typeLine("teleport")
    checkpoint("the negative twin says: " & rt.app.notification)
    ck rt.app.notification.toLowerAscii().contains("unknown command")

  test "a resize re-flows an untouched arrangement and leaves a gestured one":
    # §8.4's decision, through the RUNTIME rather than through the binding: it
    # is `runtime.resize` that a real SIGWINCH reaches, and a binding whose
    # `resize` nobody called would silently keep the old profile's tree.
    block:
      let rt = newRuntime(80, 24)
      discard rt.enableLayoutBinding()
      ck rt.app.layoutBinding.profile == lpCompact
      rt.resize(200, 60)
      ck rt.app.layoutBinding.profile == lpUltraWide
      ck not rt.app.layoutBinding.userModified
      # The Ultra-wide tree really is what is on screen now.
      ck rt.bodyRows() == newRuntime(200, 60).bodyRows()

    block:
      let rt = newRuntime(80, 24)
      discard rt.enableLayoutBinding()
      discard rt.typeLine("dock bottom")
      ck rt.app.layoutBinding.userModified
      let mine = $rt.app.layoutBinding.saveDocument()
      rt.resize(200, 60)
      ck rt.app.layoutBinding.profile == lpUltraWide
      ck $rt.app.layoutBinding.saveDocument() == mine
      # …and it still PROJECTS at the new size: the strip is still one row and
      # the screen still has the right number of them.
      ck rt.dockStripRowOf() >= 0
      ck rt.bodyRows().len == 60

  test "OFF BY DEFAULT: a mouse report is the inert token it always was":
    # THE MOUSE HALF'S OFF ARM, and it is the same statement the verb arm above
    # makes: without a binding the decoder is not even CALLED, `keyName` answers
    # "" for a mouse report, `keymap.resolve` reports `krNone`, and nothing
    # happens — which is what a mouse has done in this front-end since CTUI-6
    # extracted the decoder.
    var tokensChecked = 0
    for g in Geometries:
      let rt = newRuntime(g.cols, g.rows)
      ck not rt.layoutBindingEnabled()
      let before = rt.bodyRows()
      for token in [sgrReport(0, 2, 2, true), sgrReport(0, 5, 9, false),
                    sgrReport(65, 3, 3, true), sgrReport(64, 3, 3, true)]:
        inc tokensChecked
        let outcome = rt.handleToken(token, 0'i64)
        ck not outcome.repaint
        ck not outcome.quit
        ck outcome.detail.len == 0
        ck outcome.action == kaNone
      ck rt.app.notification.len == 0
      ck rt.app.layoutBinding.isNil
      ck rt.bodyRows() == before
    checkpoint("mouse tokens delivered with no binding: " & $tokensChecked)
    ck tokensChecked == 4 * Geometries.len

  test "a mouse DRAG docks the pane it picked up, through handleToken":
    # **THE ROW PLAT-6 STAYED `partial` FOR.** `binding.onMouse`, `beginDrag`,
    # `hoverAt` and `dropDrag` had no caller outside their own module and its
    # own suite: `handleToken` routed the twelve `:` verbs and no mouse report,
    # so with `--layout-binding` on a typed command rearranged a terminal and a
    # drag did nothing. This is the gesture, driven the way the product drives
    # it — the exact bytes a terminal delivers, through `handleToken`.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    let source = rt.layoutGeometry().regionOfPane(paneCalltrace)
    checkpoint("the call-stack pane is at " & $source)
    ck not source.isEmptyArea
    ck rt.focusedPaneOf() == paneCalltrace
    ck rt.app.layoutBinding.layout.dockedIndex(paneCalltrace) < 0

    # PRESS on a bare pane's own title row picks it up.
    let pressed = rt.handleToken(
      sgrReport(0, source.row, source.col, true), 0'i64)
    checkpoint("press -> " & pressed.detail)
    ck pressed.repaint
    ck not pressed.quit
    ck rt.app.layoutBinding.interaction.kind == ikDraggingTab
    ck rt.app.layoutBinding.interaction.source == paneCalltrace
    # …and the drag GHOST is on the frame the next paint would produce, which
    # is the half an assertion about the model alone would miss.
    var ghosts = 0
    for d in rt.shellScreenOf().decorations:
      if d.kind == ldDragGhost:
        inc ghosts
    ck ghosts == 1

    # RELEASE outside the tree area — the header row — docks it.
    let dropped = rt.handleToken(sgrReport(0, 0, 40, false), 0'i64)
    checkpoint("release on the header row -> " & dropped.detail)
    ck dropped.repaint
    ck rt.app.layoutBinding.layout.dockedIndex(paneCalltrace) >= 0
    ck not rt.app.layoutBinding.layout.tree.contains(paneCalltrace)
    ck rt.app.layoutBinding.userModified
    ck rt.app.layoutBinding.interaction.kind == ikNone
    let (docked, edge) = rt.dockedEdgeOf(paneCalltrace)
    ck docked
    ck edge == leTop
    # THE SCREEN. A top strip exists, one row deep, carrying the pane's title.
    var strips = 0
    for d in rt.shellScreenOf().decorations:
      if d.kind == ldDockStrip:
        inc strips
        ck d.area.height == DockStripThickness
    ck strips == 1

    # …AND `:undo-layout`, through the prompt, puts it back — which says the
    # gesture went onto the SAME undo log a typed verb uses rather than beside
    # it.
    discard rt.typeLine("undo-layout")
    ck rt.app.layoutBinding.layout.dockedIndex(paneCalltrace) < 0
    ck rt.app.layoutBinding.layout.tree.contains(paneCalltrace)

  test "a mouse press moves the focus RING, not only the binding's focus":
    # THE RETURN LEG OF THE FOCUS SYNCHRONISATION. `runPromptLine` only has to
    # push `PaneFocus` into the binding, because a typed verb cannot move the
    # binding's focus; a mouse press CAN — pressing in a pane's body is how a
    # user focuses it with a pointer — so `routeMouseReport` carries the answer
    # back. Without the return leg `Tab` continues the ring from wherever the
    # keyboard left it and the status bar names a pane the user is not on.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    ck rt.focusedPaneOf() == paneCalltrace
    let editor = rt.layoutGeometry().regionOfPane(paneEditor)
    checkpoint("the editor pane is at " & $editor)
    ck not editor.isEmptyArea
    ck editor.height > 1

    # INSIDE THE BODY, not on the title row: a press on the title row picks the
    # pane UP, and the arm under test here is the other one.
    let o = rt.handleToken(
      sgrReport(0, editor.row + 1, editor.col + 1, true), 0'i64)
    checkpoint("press inside the editor -> " & o.detail)
    ck o.repaint
    ck rt.app.layoutBinding.interaction.kind == ikNone
    ck rt.app.layoutBinding.focus == paneEditor
    ck rt.focusedPaneOf() == paneEditor
    # AND THE TWO NOTIONS ARE ONE: a verb typed straight afterwards acts on the
    # pane the POINTER chose.
    discard rt.typeLine("dock bottom")
    ck rt.app.layoutBinding.layout.dockedIndex(paneEditor) >= 0
    ck rt.app.layoutBinding.layout.dockedIndex(paneCalltrace) < 0

  test "a click activates a tab and a wheel scrolls the strip, through handleToken":
    # PRESS AND RELEASE ON ONE CELL IS A CLICK — which is exactly what
    # `TermAssert.sendMouseClick` writes — and buttons 64/65 are the wheel on
    # the same protocol. Both reach the binding through `handleToken` here.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    var stackRow = -1
    var stackCol = -1
    var tabs: seq[string] = @[]
    var active = -1
    for r in rt.layoutGeometry().projection.regions:
      if r.activeTab >= 0 and r.tabs.len > 0:
        stackRow = r.area.row
        stackCol = r.area.col
        tabs = r.tabs
        active = r.activeTab
        break
    checkpoint("the Compact profile's stack is " & $tabs & ", active " & $active)
    ck tabs.len >= 3
    ck active == 0
    ck stackRow >= 0

    # A CLICK on the second tab.
    let spans = tabSpans(tabs, active)
    ck spans.len == tabs.len
    let secondCol = stackCol + spans[1].startCol + 1
    discard rt.handleToken(sgrReport(0, stackRow, secondCol, true), 0'i64)
    let clicked = rt.handleToken(sgrReport(0, stackRow, secondCol, false), 0'i64)
    checkpoint("click on tab 1 -> " & clicked.detail)
    ck clicked.repaint
    ck clicked.detail.contains("activateTab")
    ck rt.app.layoutBinding.interaction.kind == ikNone
    var activeNow = -1
    for r in rt.layoutGeometry().projection.regions:
      if r.activeTab >= 0 and r.tabs.len > 0:
        activeNow = r.activeTab
        break
    ck activeNow == 1

    # A WHEEL on the same strip moves it on again.
    let scrolled = rt.handleToken(sgrReport(65, stackRow, stackCol, true), 0'i64)
    checkpoint("wheel down on the strip -> " & scrolled.detail)
    ck scrolled.repaint
    var activeAfter = -1
    for r in rt.layoutGeometry().projection.regions:
      if r.activeTab >= 0 and r.tabs.len > 0:
        activeAfter = r.activeTab
        break
    ck activeAfter == 2

  test "a mouse report does not disturb an open prompt":
    # THE PRECEDENCE, ASSERTED RATHER THAN DOCUMENTED. A report is routed AHEAD
    # of the prompt because it is not a prompt key — `command_line.applyKey`
    # answers `claUnhandled` for one, its printable arm requiring
    # `token.len == 1` — so the prompt keeps its buffer and stays open while the
    # gesture happens underneath it.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    discard rt.handleToken(":", 0'i64)
    for ch in "dock bo":
      discard rt.handleToken($ch, 0'i64)
    ck rt.prompt.open
    ck rt.prompt.buffer == "dock bo"
    let source = rt.layoutGeometry().regionOfPane(paneCalltrace)
    discard rt.handleToken(sgrReport(0, source.row, source.col, true), 0'i64)
    ck rt.prompt.open
    ck rt.prompt.buffer == "dock bo"
    ck rt.app.layoutBinding.interaction.kind == ikDraggingTab
    discard rt.handleToken(sgrReport(0, 0, 40, false), 0'i64)
    ck rt.prompt.buffer == "dock bo"
    ck rt.app.layoutBinding.layout.dockedIndex(paneCalltrace) >= 0

  test "which dock edges a real drag can reach, measured rather than argued":
    # **PLAT-6's MEDIUM CLAIM, RECHECKED NOW THAT THE GESTURE IS REACHABLE.**
    # The milestone recorded, as a property of the medium rather than a gap in
    # the model, that a mouse drop can reach only the TOP and the BOTTOM dock
    # edges until something is docked left or right — a drop docks when it
    # lands outside the tree area, and a terminal has no column left of column
    # 0. That was written about a gesture no input path reached. It is swept
    # here over every cell of the screen and then COMMITTED for real.
    let rt = newRuntime(80, 24)
    discard rt.enableLayoutBinding()
    let reached = rt.dockEdgesADropCanReach(paneCalltrace, 80, 24)
    checkpoint("with nothing docked, a drop reaches: " & $reached)
    # EXACT, not "does not contain left" — trap 4's rule: a sweep that resolved
    # nothing would satisfy every negative assertion over it, and the set's
    # membership is knowable.
    ck reached == @["bottom", "top"]

    # COMMITTED THROUGH `handleToken`, so the sweep above is not the only
    # witness. Four aimed drags: the two rows outside the body dock, and the
    # two columns a user would aim at for `left` and `right` do not.
    var dragsMade = 0
    for probe in [(0, 40, true, "the header row"),
                  (23, 40, true, "the status row"),
                  (12, 0, false, "column 0, mid-height"),
                  (12, 79, false, "the last column, mid-height")]:
      inc dragsMade
      let r = newRuntime(80, 24)
      discard r.enableLayoutBinding()
      let src = r.layoutGeometry().regionOfPane(paneCalltrace)
      discard r.handleToken(sgrReport(0, src.row, src.col, true), 0'i64)
      let o = r.handleToken(sgrReport(0, probe[0], probe[1], false), 0'i64)
      checkpoint("a drag onto " & probe[3] & " -> " & o.detail)
      ck (r.app.layoutBinding.layout.dockedIndex(paneCalltrace) >= 0) == probe[2]
    ck dragsMade == 4

    # THE CLAIM'S SECOND HALF, and it is the positive twin that stops the first
    # from being a statement about a sweep that reaches nothing: `:dock left` is
    # how that edge is first reached, and once a strip is there a drop onto it
    # works like any other.
    let after = newRuntime(80, 24)
    discard after.enableLayoutBinding()
    discard after.typeLine("dock left")
    checkpoint(":dock left -> " & after.app.notification)
    ck after.app.layoutBinding.layout.dockedAt(leLeft).len == 1
    let now = after.dockEdgesADropCanReach(paneEditor, 80, 24)
    checkpoint("with one pane docked left, a drop reaches: " & $now)
    ck now == @["bottom", "left", "top"]

  test "assertion count":
    checkpoint("CHECKS: " & $countedAssertions)
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
