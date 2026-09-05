## app_shell.nim — CTUI-3 snapshot app: the whole application shell.
##
## One component tree, exported so the Tier-1 half of
## `tests/real_terminal/test_real_shell_geometry.nim` composites the SAME proc
## in process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier and the
## `--reflow` mode.
##
## ## This is the pane's ONE cross-tier equivalence test
##
## docs/tui-testing.md: "a new pane needs exactly one cross-tier equivalence
## test. Not zero, and not one per assertion." CTUI-3 delivers a SHELL rather
## than a pane — a header, a multi-pane body, a timeline strip and a status bar
## — and this app is the single tree that grounds every Tier-1 golden all four
## of them record. Its other states are Tier-1 work.
##
## ## The model is a constant, and that is the point
##
## `shellModel` below takes no arguments and reads nothing: the same header,
## the same tick, the same trace name in both tiers. A tree that differed
## between the two runs would make the comparison a statement about the model
## rather than about the renderer, which is the failure mode CTUI-2's
## "one `buildTree`, two ways" construction exists to rule out.
##
## The SIZE is an input, because the shell is responsive: every screen row is
## composed for a known width (see `app/views/shell.nim` on why the compositor
## cannot put two panes on one row). So this app exports the sized shape
## `buildTree*(r, cols, rows)` rather than CTUI-2's fixed `buildTree*(r)`.

import isonim_tui

import ../../app/views/shell

proc shellModel*(cols, rows: int): ShellModel =
  ## The one model both tiers paint. `esStepping` rather than the default
  ## `esPaused` so the status badge is not the enum's first value — a badge
  ## that rendered the low member of its enum whatever the state would look
  ## right in a golden recorded from a paused session.
  newShellModel(cols, rows, initHeaderModel(
    traceName = "demo.ct", targetArch = "x86_64", recordingKind = "native",
    status = esStepping, tick = 1420, totalTicks = 8950))

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  renderShellTree(shellModel(cols, rows), r, cols, rows)

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
