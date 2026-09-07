## app_layout_gestures.nim — PLAT-6 snapshot app: the WHOLE FRONT-END, with
## the layout binding opted in, driven by real key bytes.
##
## ## WHY THIS APP EXISTS, AND HOW IT DIFFERS FROM EVERY OTHER ONE HERE
##
## Every other snapshot app in this directory is a tree: it exports a
## `buildTree` and holds, at most, a small `AppState` its input handler edits.
## This one hosts a `TuiRuntime` — the SAME object `main.nim` builds — with
## PLAT-6's layout binding enabled exactly the way `main.nim` enables it under
## `--layout-binding`, and hands every input token to `runtime.handleToken`.
##
## That is the whole point. PLAT-6 landed with "no gesture is driven through a
## real pty", because the binding was reachable only from a test that
## constructed one. What closes that row is not a richer Tier-1 case; it is the
## product's own input path — keymap, modal state, `:` prompt, `runPromptLine`,
## `binding.runLayoutCommand` — carrying real bytes off a real file descriptor
## into a real `Layout`. This app is that path with a renderer bolted to it and
## no debugger behind it.
##
## ## THERE IS NO DEBUGGER HERE, AND THAT COSTS THIS APP NOTHING
##
## `TuiRuntime.dispatcher` is a `Dispatcher` with no ViewModels, which
## `app/commands/interpreter.nim` documents as "not wired" and answers
## `drUnavailable` BY NAME — so §4.3's commands report honestly rather than
## being faked. The twelve LAYOUT verbs need no debugger at all: they act on a
## `Layout`, which is why they are a separate surface in the first place. So the
## gesture this app exists to drive is driven for real, and nothing about it is
## a stand-in.
##
## ## THE CURSOR IS THE BARRIER, AND THE PROMPT MOVES IT
##
## With no prompt open the epilogue is empty and `dual_snap
## .waitForCompleteFrame`'s `(rows-1, cols-1)` holds. With one open,
## `runtime.promptCursor` parks the cursor in the prompt and the parent waits on
## `dual_snap.waitForCursorAt` instead — CTUI-10's arrangement, reached here
## through the runtime's own accessor rather than through a second computation.
## The two positions differ, which is what makes "the prompt opened" and "the
## prompt closed" both observable as barriers rather than as sleeps.

import isonim_tui

import ../../app/runtime
import ../../app/theme/capabilities

const
  Cols* = 80
  Rows* = 24
    ## The geometry this app's Tier-2 suite drives it at, published so the
    ## suite and the app cannot disagree about which profile is on screen.
    ## 80x24 selects Compact, which is the profile with a tab stack — the one
    ## arrangement in which every layout verb has something to act on.

var current: TuiRuntime = nil

proc negotiated(): TerminalCapabilities =
  ## A resolved capability set from a CONSTRUCTED environment, not the
  ## process's own. A child spawned into a pty inherits whatever the lane's
  ## shell had, and a snapshot app whose colours depended on that would not be
  ## a pure function of its geometry.
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newBoundRuntime*(cols, rows: int): TuiRuntime =
  ## A runtime with PLAT-6's layout binding opted in — the same two calls
  ## `main.nim` makes under `--layout-binding`, in the same order.
  ##
  ## Exported so the Tier-2 suite can run the SAME construction in process and
  ## compare the arrangement a gesture produced against the one the terminal
  ## shows.
  result = newTuiRuntime(newTuiApp(), negotiated(), cols, rows)
  discard result.enableLayoutBinding()

proc ensureRuntime(cols, rows: int) =
  if current.isNil:
    current = newBoundRuntime(cols, rows)
  elif current.width != cols or current.height != rows:
    current.resize(cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  ensureRuntime(cols, rows)
  styledRowsTree(r, current.shellScreenOf().styledRows)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## `step` is ignored: this app is driven by real keys, and what changes the
  ## tree is `current`, which `handleInput` changes.
  discard step
  buildTree(r, cols, rows)

proc handleInput*(token: string): bool =
  ## The child's input handler. CHILD-SIDE ONLY: nothing in a test process may
  ## call this, or the in-process runtime the suite builds would stop being a
  ## fresh one.
  if current.isNil:
    return false
  current.handleToken(token, 0'i64).repaint

proc framePrologue*(cols, rows: int): string =
  ## CTUI-9's cursor SHAPE and visibility for the current mode. Before the
  ## frame; it moves nothing.
  discard cols
  discard rows
  if current.isNil: "" else: cursorControlBytes(current.modal.mode)

proc frameEpilogue*(cols, rows: int): string =
  ## The prompt's cursor PARK, or "" when no prompt is open — `main.nim`'s
  ## `paint`, spelled the same way and reading the same accessor.
  discard cols
  if current.isNil:
    return ""
  let (prompting, row, col) = current.promptCursor()
  if not prompting:
    return ""
  "\x1b[" & $(min(row, max(0, rows - 1)) + 1) & ";" & $(col + 1) & "H"

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for `newBoundRuntime` does not carry an unused `std/os` and an
  # unused runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    input = handleInput,
    prologue = framePrologue,
    epilogue = frameEpilogue))
