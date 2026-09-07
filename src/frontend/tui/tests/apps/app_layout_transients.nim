## app_layout_transients.nim — PLAT-6 snapshot app: the shell with a LAYOUT
## GESTURE IN FLIGHT.
##
## One component tree per transient state, exported so the Tier-1 half of
## `tests/real_terminal/test_real_layout_transients.nim` composites the SAME
## proc in process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier and the
## input framing.
##
## ## WHY THIS APP EXISTS
##
## PLAT-6's third obligation is that a binding DRAWS transient state — the drag
## ghost, the highlighted drop target, the resize guide, the auto-hide strips
## and a revealed dock — derived per frame from `Interaction` and stored by
## nobody. Everything about those that can be decided in process is decided in
## `app/tests/test_layout_binding.nim`, on the composited screen through
## `TerminalTestHarness.cellAt`. What no Tier-1 test can say is whether a REAL
## TERMINAL agrees: `paintDecorations` writes one-cell glyphs (U+2591..U+2593,
## U+00B7) over a grid that already holds box-drawing runes, and CTUI-2's own
## first run found three defects in exactly that seam — a compositor that never
## wrote a ghost cell, a libvterm binding that raised on the trailing half of a
## wide glyph, and two encoders that disagreed about it.
##
## PLAT-6 left this row unticked. This is it.
##
## ## THE STATE IS A PURE FUNCTION OF `(cols, rows, step)`
##
## `runDualSnap`'s construction — one `buildTree`, two ways — only says
## something about the renderer if both processes build the same tree, so
## nothing here reads a clock, a file or an environment variable. `step` selects
## which `TransientState` is painted and the parent advances it with F10, which
## is the runtime's own step key; `modelFor` rebuilds the whole model from
## scratch every frame, so the child holds no state a replay could diverge from.
##
## ## THE CURSOR IS PARKED PER STEP, AND THAT IS THE BARRIER
##
## `dual_snap.waitForCompleteFrame` reads "the cursor rests at
## `(rows-1, cols-1)`". After the FIRST frame that is already true, so it cannot
## tell a repaint caused by F10 from the frame before it — a barrier that is
## satisfied before the event it is waiting for is exactly the race
## codetracer-specs/Testing/Verification-Harness-Traps.md §3 is about. So this
## app installs a `FrameEpilogue` that parks the cursor at `(0, step + 1)`: the
## CUP is written after the last cell of the last row, the column is different
## for every step, and `waitForCursorAt` is therefore an exact barrier for THAT
## step's frame rather than for some frame. `step + 1` rather than `step`
## because a freshly spawned terminal's cursor is ALREADY at `(0, 0)` and a
## parent waiting for it would be satisfied before the child wrote a byte — see
## `cursorParkColumn`.
##
## ## No mocks
##
## There is no mock here. The layout is the real `Layout`, the gestures are the
## real `layout_interaction` machine, the decorations are `binding
## .decorationsFor` and the paint is `views/shell.shellScreen`.

import std/options

import isonim_tui

import ../../app/views/shell

type
  TransientState* = enum
    ## One state per frame. The order is the F10 order, and it starts with the
    ## UNGESTURED shell on purpose: a comparison that only ever ran over screens
    ## carrying decorations could not tell a decoration that is drawn from one
    ## that is drawn everywhere.
    tsNone = "none"
    tsDockStrips = "dock-strips"
    tsDragging = "dragging"
    tsResizing = "resizing"
    tsRevealing = "revealing"

const
  TransientStateCount* = ord(high(TransientState)) + 1

var currentStep = 0

proc stateFor*(step: int): TransientState =
  ## Which state step `step` paints. Clamped rather than wrapped, so a parent
  ## that pressed F10 once too often gets the last state again instead of
  ## silently going back to the first one and comparing the wrong screens.
  TransientState(max(0, min(step, ord(high(TransientState)))))

proc baseHeader(): HeaderModel =
  ## The same constant header `apps/app_shell.nim` uses, for the same reason:
  ## a model that differed between the two runs would make the comparison a
  ## statement about the model rather than about the renderer.
  initHeaderModel(traceName = "demo.ct", targetArch = "x86_64",
                  recordingKind = "native", status = esStepping,
                  tick = 1420, totalTicks = 8950)

proc modelFor*(state: TransientState; cols, rows: int): ShellModel =
  ## The shell, with `state`'s gesture in flight.
  ##
  ## EVERY GESTURE IS THE MODEL'S OWN. The docked panes come from `apply
  ## (cmdDock(...))`, the drag from `beginDragTab` + `hoverAt` over a pointer
  ## the real hit-test resolved, the resize from `beginResize` +
  ## `proposeShare`, and the reveal from `beginReveal`. Nothing here writes an
  ## `Interaction` field by hand, so what is painted is a state the product can
  ## actually be in.
  result = newShellModel(cols, rows, baseHeader())
  var l = initLayout(result.layout)
  let body = bodyArea(cols, rows)
  case state
  of tsNone:
    discard
  of tsDockStrips:
    for pair in [(paneTimeline, leBottom), (paneCalltrace, leLeft)]:
      let outcome = apply(l, cmdDock(pair[0], pair[1]))
      if outcome.kind == loApplied:
        l = outcome.layout
  of tsDragging:
    let geom = geometryOf(l, body)
    let started = beginDragTab(l, paneCalltrace)
    if started.isSome:
      var interaction = started.get
      let target = geom.regionOfPane(paneState)
      let pointer = pointerAt(l, geom, target.row + target.height div 2,
                              target.col)
      if pointer.isSome:
        interaction = interaction.hoverAt(l, pointer.get)
      result.interaction = interaction
  of tsResizing:
    let started = beginResize(l, paneEditor)
    if started.isSome:
      result.interaction = started.get.proposeShare(l, 0.8)
  of tsRevealing:
    let outcome = apply(l, cmdDock(paneTimeline, leBottom))
    if outcome.kind == loApplied:
      l = outcome.layout
    let revealed = beginReveal(l, paneTimeline)
    if revealed.isSome:
      result.interaction = revealed.get
  result.layout = l.tree
  result.docked = l.docked

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  currentStep = step
  renderShellTree(modelFor(stateFor(step), cols, rows), r, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  buildTree(r, cols, rows, 0)

proc cursorParkColumn*(step, cols: int): int =
  ## Where the epilogue parks the cursor for step `step`.
  ##
  ## `step + 1`, NOT `step`, AND THE OFF-BY-ONE IS THE WHOLE BARRIER. A freshly
  ## spawned terminal's cursor is already at `(0, 0)`, so a parent waiting for
  ## `(0, 0)` would be satisfied on its first poll — before the child had
  ## written a byte — and would snapshot a blank screen. That is
  ## codetracer-specs/Testing/Verification-Harness-Traps.md §3's shape arriving
  ## through a barrier rather than through a timeout: a check satisfied before
  ## the event it names. Parking at column `step + 1` makes every step's
  ## position one the cursor was NOT at a moment earlier, the first included.
  ##
  ## Clamped to the screen, so a geometry narrower than the number of steps
  ## still produces a position the parent can wait for — it just stops
  ## distinguishing the last two, which every geometry this app is run at is far
  ## too wide for.
  min(max(0, step) + 1, max(0, cols - 1))

proc frameEpilogue*(cols, rows: int): string =
  ## `CSI 1 ; <col+1> H` — see this module's header on why the barrier has to
  ## move per step. 1-based, per
  ## <https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>, "Cursor
  ## Position".
  discard rows
  "\x1b[1;" & $(cursorParkColumn(currentStep, cols) + 1) & "H"

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    epilogue = frameEpilogue))
