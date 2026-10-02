## main.nim — the `codetracer-gpui` entrypoint. PLAT-20.
##
## ## The shape, and why it is the terminal front-end's shape
##
## `src/frontend/gpui/` is two layers with one line between them, copied
## deliberately from `src/frontend/tui/`:
##
##   app/    SDK-CONSUMER. Carries a `.sdk-consumer` marker. The shell
##           (`shell.nim`), the dock binding (`dock_projection.nim`) and the
##           leaves (`leaves.nim`). Only `leaves.nim` imports GPUI.
##   host/   NATIVE HOST. Exempt on purpose, and the only place allowed to
##           spawn `replay-server`.
##
## This module is the wiring, so it is the one place both sides are in scope at
## once. It stays small: everything it does is decide, open, draw or exit.
##
## ## WHAT THIS BINARY DOES TODAY, SAID PLAINLY
##
## PLAT-20 is *the shell*: "a GPUI window that hosts the renderer-free shell —
## the same `HeadlessApp` the terminal front-end drives — with the layout
## supplied by PLAT-4's model." The debugger SURFACES are PLAT-21 and the
## editing surface is PLAT-22, so a leaf here draws its pane's identity and
## state and not a call trace.
##
## Two boundaries a reader must take before believing more than that:
##
##   1. **There is no gpui-kit `DockArea` behind this window.** gpui-kit is not
##      a dependency of this workspace; TWO independent blockers were measured
##      and are recorded in PLAT-20's status block. (It was three until
##      2026-09-16, when the toolchain blocker was falsified by compiling
##      gpui-kit with a stable rustc already in this host's store; the package
##      split is what remains.) The arrangement
##      this binary draws is read out of the same projected document a
##      `DockArea` would be handed (`leaves.gpuiKitDockAvailable` is the
##      constant that says so), and the container is a flex `div`.
##   2. **Whether a GPU window actually appears depends on how
##      `isonim-gpui`'s Rust shim was built** — and, until PLAT-37, on
##      something this sentence used to get wrong, so it is corrected here
##      rather than quietly rewritten.
##
##      **TWO SWITCHES ARE OFF, NOT ONE.** The first is the Cargo feature:
##      `gpui-nim-shim`'s `default = []` and `just rust-build` is a bare
##      `cargo build`, so `--features gpui-backend` is off, which is what
##      PLAT-19 through PLAT-23 record. The second is in THIS FILE, and it is
##      the one the old sentence hid. It said *"without `--features
##      gpui-backend` … `createWindow` opens nothing"*, which reads as though
##      the feature were the only thing in the way. It is not:
##      `isonim-gpui`'s `window.rs` carries **no `cfg` outside
##      `#[cfg(test)]`** — `create_window` is a `Vec` push and `show_window` a
##      state transition, byte-identical in both builds — and the ONLY
##      function that branches on the feature is `gpui_launch`, which this
##      binary did not call. So flipping the feature alone would have changed
##      nothing observable here, and a milestone that flipped it would have
##      measured no difference and had to explain why.
##
##      PLAT-37 throws both: the lane builds the shim with the feature, and
##      `launchWindow` below enters `gpui_launch` with a root-builder callback
##      instead of the old `createWindow` → `show()` → `requestRepaint()` →
##      `destroy()` sequence, which touched the registry and never the
##      renderer.
##
##      `--report-plan` still exists and still means what it meant: it prints
##      what GPUI *would* execute and enters no event loop, which is the
##      verification tier PLAT-19 established and what the integration tests
##      read. It is the INTROSPECTION tier. It is not evidence that anything
##      was painted, and PLAT-37's instrument contract says so in a table.

when defined(js):
  {.error: "src/frontend/gpui is native-only: it opens a window.".}

import std/[cpuinfo, json, math, options, os, strutils, tables, times]

import isonim_gpui/renderer
# `isonim_gpui/bindings` AND NOT `isonim_gpui/window`, since PLAT-37. The
# high-level `window.nim` wraps the registry — `createWindow`, `show`,
# `destroy` — which is precisely the layer that has no `cfg` on it and never
# reaches a renderer. The two functions this front-end needs, `gpui_launch`
# and `gpui_quit_after_ms`, are not wrapped there; they are the raw FFI.
import isonim_gpui/bindings

import ./chrome
import ./replay_ops
import ./layout_memory
import ./window_geometry
import ./window_gestures
import ./window_top_bar
import ../viewmodel/views/debug_control_marks
import ../tui/host/native_host   # `loadStopPanes`, the terminal's own producer
import ../styles/generated/design_tokens

# PLAT-34. The editing core, through the sanctioned facade: `editSurfaceFor`
# below OPENS a document rather than handing a string to a derivation, so the
# GPUI editor and the terminal editor hold one value of one type.
import codetracer_embed

import ./app/shell
import ./app/leaves
from ../../common/view_vocabulary/layout_questions import trPaneTitle
import ./app/pane_names
import ./app/edit_arm
import ../view_vocabulary/pane_views   # `sourcePaneView`, for the redraw
import ../viewmodel/host/keymap_preference
import ./host/gpui_host
import ./host/pixel_capture             # PLAT-35: `--pixels-out`'s capture
import ../viewmodel/viewmodels/vcs_vm   # `VCSVM`, `VCSRefreshIntervalMs`: the VCS pane's tick

const DefaultPixelsView* = "window"
  ## What `--pixels-out` records as the view when `--pixels-view` is not
  ## given. Not one of `scenarios.json`'s six names on purpose: a capture
  ## nobody labelled must not be filed under a scenario's view, because the
  ## expected-elements block for that view would then be graded against a
  ## frame that was never driven to it.

const GpuiHelpText = """
codetracer-gpui — CodeTracer's GPUI front-end (PLAT-20: the shell)

USAGE:
  codetracer-gpui [options] <trace-folder>

  Normally reached as `ct replay --ui=gpui <trace-folder>`; `ct` resolves
  `--ui` and execs this binary, and the launcher never learns about the flag.

OPTIONS:
  --report-plan     Build the window's render plan, print it, and exit 0
                    without entering an event loop. What GPUI would execute.
  --report-window-plan
                    PLAT-48. Run the WINDOW's own root builder — the top
                    bar, the arrangement, the auto-hide strips, a revealed
                    pane, the popovers, the pin / unpin buttons and the
                    hover label, exactly as a window draws them — over a
                    detached root, apply `--window-ops`, print that root's
                    render plan and exit 0. No window, no compositor.
  --window-ops=<spec>
                    PLAT-48, with `--report-window-plan`. A comma-separated
                    list of window events, dispatched through the window's
                    OWN pointer and key handlers (in an Edit window a
                    key reaches the editor, which holds the focus):
                      key:<key>[:<mod>+<mod>]   press:<x>:<y>
                      move:<x>:<y>              release:<x>:<y>
                    and the same events aimed at a part of the window by
                    name, read off the window's geometry:
                      menu:<title>  control:<id> (the pointer rests on it)
                      label:<pane> (its strip label)  pin:<pane>  unpin
                      drag:<pane>:top (its tab to the top margin)
                      hold:<pane>:<over> (its tab dragged over another
                      pane's centre, not released)
  --width=<px>      Window width  (default 1440)
  --height=<px>     Window height (default 900)
  --quit-after-ms=<n>
                    Close the window and return after <n> milliseconds.
                    0 (the default) means "stay open until the window is
                    closed". This is what makes the front-end usable from a
                    screenshot harness and from a test lane: `gpui_launch`
                    blocks inside GPUI's platform event loop for exactly as
                    long as the window exists, so without a deadline a
                    windowed run has no bound on it at all.
  --layout=<file>   Open the recording's window with the arrangement a saved
                    layout document describes (the versioned JSON the
                    layout model writes) instead of the default one. A
                    document this build cannot read is an error, not a
                    silent fallback.
  --layout-ops=<spec>
                    PLAT-45. Rearrange the window before it is drawn, and
                    remember the result: a comma-separated list of
                      activate:<pane>  dock:<pane>:<edge>
                      merge:<pane>:<beside>  remove:<pane>
                    applied through the shell (the window's scripted
                    gesture), then written to this product's own layout
                    file — <state root>/gpui-layout.json — which the next
                    start restores. The terminal's and the desktop's
                    remembered layouts are other files and are not read.
  --reset-layout    PLAT-45. Delete this product's remembered layout and open
                    the shared default arrangement.
  --dock-out=<file> PLAT-45. Write the window's projected dock document.
  --replay-ops=<spec>
                    Advance the recording before the window is drawn.
                    <spec> is a comma-separated list over the SAME closed
                    five-member operation vocabulary
                    `src/tests/visual/scenarios.json` publishes:
                      stepIn=<n>  next=<n>  stepOut=<n>  continueForward=<n>
                      setBreakpoint@<row>
                    `<row>` is an offset into the editor's FIRST DRAWN ROW,
                    resolved against the recording's own source, never a
                    literal line number.
                    This exists because the GPUI front-end drives the
                    recording from the command line rather than from the
                    keyboard. It was written when the renderer could not
                    deliver a key at all; PLAT-38 repaired that (a key
                    reaches a focused element with its payload, see
                    `--input-probe`), so what remains is that no BINDING
                    maps a key to a replay operation here yet. That is
                    PLAT-23's `--ui=gui` contract rather than a renderer
                    gap, and this flag stays until it lands.
  --no-flow-overlay
                    Open with the flow overlay hidden (it is shown by default,
                    as `flow.enabled: true` ships).
  --frame-report=<path>
                    PLAT-42. After the window's loop returns, write the
                    frame-timing record: every frame's RENDER-PATH time (the
                    shadow-tree walk, the render plan and the GPUI element
                    tree — NOT GPUI's own layout and paint, which follow),
                    every key-to-next-frame latency, and the host's load
                    average at start and end. A budget is REPORTED, never
                    asserted against a constant (a timing on a shared host is
                    a measurement of that host).
  --edit-keys=<keys>
                    PLAT-44, EDIT mode only. Comma-separated GPUI keystrokes
                    (`x`, `escape`, `control-s`, `shift-a`; `comma` for
                    the `,` key, since `,` separates keys) delivered, one
                    by one, through the SHIM'S OWN dispatch to the focused
                    editor pane — the listener a window's keys reach — before
                    the plan is reported. The headless reading of what a
                    typist in a window does; the window itself is
                    `ci/test/plat44-edit-window.sh`.
  --input-probe=<path>
                    PLAT-38. Declare the first pane focusable, give it
                    element focus, listen for `keydown` on it, and write
                    what the RUST-SIDE ELEMENT STORE held to <path> after
                    the event loop returns. The record is the key names,
                    the modifier lists and the delivery sequence the shim
                    recorded BEFORE each callback ran — which is the one
                    oracle a Nim-side emulation cannot forge, and is what
                    `ci/test/plat38-keystroke.sh` reads back.
                    `CODETRACER_GPUI_PROBE_SENTINEL` names a key whose
                    arrival closes the loop, so a capture can tell "the
                    typist finished" from "the deadline fired".
  --pixels-out=<path>
                    PLAT-35. Render THIS WINDOW'S OWN SCENE off screen and
                    write it to <path> as a PNG, instead of opening a
                    window. The census of the frame — its byte count, its
                    non-zero byte count and how many distinct byte values
                    it holds — goes to <path>.json beside it, and a frame
                    indistinguishable from a blank screen is a FAILURE
                    rather than a file.
                    This is the capture step of
                    `codetracer-specs/spec/Methodologies/visual-design-iteration.md`
                    on a host where the window's pixels cannot be read: it
                    goes through `gpui_render_to_pixels`
                    (`--features gpui-headless`), which needs no
                    compositor and no screen-recording grant. An
                    off-screen buffer is a FRAME AND NOT A WINDOW, so the
                    record says `satisfiesG1: false` — PLAT-23's G1 asks
                    that a window has been observed, and this path opens
                    none.
                    `--pixels-view` and `--pixels-scenario` name what the
                    frame is of; they are recorded, never used to choose
                    what is drawn.
  --pixels-view=<name>
                    The view name written into the capture record (default
                    `window`). The named-view vocabulary is
                    `src/tests/visual/scenarios.json`'s.
  --pixels-scenario=<id>
                    The scenario id written into the capture record. The
                    operations themselves come from `--replay-ops`, so this
                    is a LABEL and a mislabelled capture is a mislabelled
                    capture rather than a differently-driven one.
  --plan-out=<path> Write the render plan the window was built from to
                    <path>, in addition to opening the window. One tree,
                    two readings: a second run would be a second tree.
                    The file is RFC 8259 JSON. That sentence is worth a
                    line because it was FALSE until 2026-09-22: the shim's
                    `render_plan_to_json` escaped `\` and `"` and nothing
                    else, so any text node carrying a newline — a source
                    line, a docstring, a captured stdout line — produced a
                    document no strict parser accepts. Nim's `std/json` is
                    lenient about control characters and read it happily,
                    which is why it went unnoticed; Python's `json.load`
                    did not. Fixed in `isonim-gpui`'s `json_escape`, with
                    a Rust case over the whole C0 range beside the one
                    that had only ever tested quotes.
  --version         Print the version and exit
  --help            Print this and exit

NOT YET, AND REFUSED RATHER THAN IGNORED:
  the debugger panes are PLAT-21 and the editing surface is PLAT-22, so a
  leaf here names its pane and its state. `--headless` belongs to the
  terminal front-end and `ct` refuses it with `--ui=gpui` before this binary
  is reached.
"""

type
  GpuiCommandKind = enum
    gckOpen
    gckHelp
    gckVersion
    gckUsageError

  GpuiCommand = object
    kind: GpuiCommandKind
    traceFolder: string
      ## The recording, in `pmDebug`. In `pmEdit` this is the PROJECT root, and
      ## the field is shared deliberately: `ct` passes one positional and the
      ## mode is what says which it is, exactly as `codetracer-tui` parses
      ## `--edit` into `tckEditProject`.
    product: ProductMode
      ## **PLAT-16's dimension, carried into a second front-end.**
      ##
      ## `ProductMode` and NOT a fourth `GpuiCommandKind`, which is the whole
      ## deliverable: edit mode is a PRODUCT mode and `UiMode`/front-end is a
      ## different axis, so a front-end that expressed it as one more command
      ## shape would be the two-dimensions-into-one collapse PLAT-16's own risk
      ## note is written against. `parseGpuiCommand` sets it; every path below
      ## reads it.
    reportPlan: bool
    reportWindowPlan: bool
      ## PLAT-48. `--report-window-plan`: the window's root builder over a
      ## detached root, `windowOps` applied, the root's plan printed.
    windowOps: seq[string]
      ## PLAT-48. `--window-ops`: window events for `--report-window-plan`.
    width: int
    height: int
    quitAfterMs: uint32
      ## PLAT-37. 0 means "no deadline"; the window stays until it is closed.
      ## Handed to `gpui_quit_after_ms` BEFORE `gpui_launch`, which is the
      ## only moment the shim reads it.
    replayOps: seq[ReplayOp]
    planOut: string
    editKeys: seq[string]
      ## PLAT-44. GPUI keystroke spellings for `--edit-keys`.
    frameReport: string
      ## PLAT-42. A path to write the frame-timing record to after the event
      ## loop returns; empty means none.
    layoutFile: string
      ## PLAT-40. A saved layout document (`layout_model.saveLayout`'s
      ## versioned JSON, docked panes included) to open the recording's
      ## window with, instead of `defaultReplayLayout()`. Empty means the
      ## default.
    layoutOps: seq[LayoutCommand]
      ## PLAT-45. `--layout-ops`: layout commands applied through the shell
      ## before the window is drawn — the window's scripted gesture — and
      ## written through to this product's remembered layout.
    resetLayout: bool
      ## PLAT-45. `--reset-layout`: delete this product's remembered layout
      ## (and only it) and open the shared default.
    dockOut: string
      ## PLAT-45. A path to write the window's projected DOCK DOCUMENT to —
      ## the persisted `DockAreaState` this front-end hands gpui-kit, with
      ## its stack axes and pixel sizes. The three-media arrangement test
      ## reads the window's arrangement out of it (the GPUI front-end's OWN
      ## output) rather than out of the model.
    noFlowOverlay: bool
      ## PLAT-42. Open with the flow overlay hidden — the user's
      ## `EditorVM.showFlowOverlay` toggle, from the command line; the window
      ## lane's negative twin for the drawn overlay.
    pixelsOut: string
      ## PLAT-35. Where to write this window's own scene as a PNG, rendered
      ## off screen through `gpui_render_to_pixels` INSTEAD of opening a
      ## window. Empty means "open the window", which is every ordinary
      ## run.
      ##
      ## It replaces the window rather than following it, and that is
      ## forced rather than chosen: `gpui_launch` does not return while the
      ## window exists, so a run that did both would have to open, wait out
      ## a deadline and then render a tree the window had already been
      ## torn down around.
    pixelsView: string
      ## The view name recorded in the capture's census. A LABEL: nothing
      ## in this binary branches on it, so a capture cannot silently draw
      ## something other than what it is called.
    pixelsScenario: string
      ## The scenario id recorded in the capture's census, on the same
      ## terms. The operations are `--replay-ops`'.
    inputProbe: string
      ## PLAT-38. A path to write the KEY-DELIVERY record to, after the event
      ## loop returns. Empty means "do not probe", which is every ordinary
      ## run: declaring a pane focusable and attaching a key listener is what
      ## the product will do unconditionally once there is something for a key
      ## to mean, and until then it is the capture lane's instrument rather
      ## than a behaviour change in the front-end.
    message: string

func parseGpuiCommand*(argv: openArray[string]): GpuiCommand =
  ## argv -> a decision. No I/O, so the whole of it is assertable without a
  ## process — `app/cli.parseTuiCommand`'s own split, one binary over.
  result = GpuiCommand(kind: gckOpen, product: pmDebug,
                       width: DefaultGpuiViewport.width,
                       height: DefaultGpuiViewport.height,
                       pixelsView: DefaultPixelsView)
  var positional: seq[string] = @[]
  for arg in argv:
    if arg == "--help" or arg == "-h":
      return GpuiCommand(kind: gckHelp)
    elif arg == "--version":
      return GpuiCommand(kind: gckVersion)
    elif arg == "--edit":
      # PLAT-22. THE SAME SPELLING `codetracer-tui` TAKES, and the same reason:
      # `ct edit <project>`'s positional survives `translateArgs` untouched, so
      # the whole translation for that command is prepending the flag that says
      # the positional is a PROJECT rather than a recording. Without it this
      # binary would resolve the folder as a trace and refuse it for not
      # being a recording, which is a true diagnosis of the wrong question.
      result.product = pmEdit
    elif arg == "--report-plan":
      result.reportPlan = true
    elif arg == "--report-window-plan":
      result.reportWindowPlan = true
    elif arg.startsWith("--window-ops="):
      let spec = arg["--window-ops=".len .. ^1]
      if spec.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --window-ops needs at least one event")
      for op in spec.split(','):
        let head = op.split(':')[0]
        if head notin ["key", "press", "move", "release", "menu", "control",
                       "label", "pin", "unpin", "drag", "hold"]:
          return GpuiCommand(kind: gckUsageError,
            message: "codetracer-gpui: --window-ops: unknown event '" & op &
                     "'")
        result.windowOps.add op
    elif arg.startsWith("--width="):
      try: result.width = parseInt(arg["--width=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --width needs an integer")
    elif arg.startsWith("--height="):
      try: result.height = parseInt(arg["--height=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --height needs an integer")
    elif arg.startsWith("--quit-after-ms="):
      # A NEGATIVE DEADLINE IS REFUSED RATHER THAN CLAMPED. `uint32(-1)` is
      # 4294967295 ms — a little over 49 days — so a clamp here would turn a
      # typo into a run with effectively no bound, which is the silent repair
      # Verification-Harness-Traps §36a names.
      var ms = 0
      try: ms = parseInt(arg["--quit-after-ms=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --quit-after-ms needs an integer")
      if ms < 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --quit-after-ms cannot be negative")
      result.quitAfterMs = uint32(ms)
    elif arg.startsWith("--replay-ops="):
      try:
        result.replayOps = parseReplayOps(arg["--replay-ops=".len .. ^1])
      except ReplayOpError as e:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --replay-ops: " & e.msg)
    elif arg == "--no-flow-overlay":
      result.noFlowOverlay = true
    elif arg.startsWith("--layout="):
      result.layoutFile = arg["--layout=".len .. ^1]
      if result.layoutFile.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --layout needs a path")
    elif arg.startsWith("--layout-ops="):
      try:
        result.layoutOps = parseLayoutOps(arg["--layout-ops=".len .. ^1])
      except ValueError as e:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --layout-ops: " & e.msg)
    elif arg == "--reset-layout":
      result.resetLayout = true
    elif arg.startsWith("--dock-out="):
      result.dockOut = arg["--dock-out=".len .. ^1]
      if result.dockOut.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --dock-out needs a path")
    elif arg.startsWith("--frame-report="):
      result.frameReport = arg["--frame-report=".len .. ^1]
      if result.frameReport.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --frame-report needs a path")
    elif arg.startsWith("--edit-keys="):
      let spec = arg["--edit-keys=".len .. ^1]
      if spec.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --edit-keys needs at least one key")
      result.editKeys = spec.split(',')
    elif arg.startsWith("--pixels-out="):
      result.pixelsOut = arg["--pixels-out=".len .. ^1]
      if result.pixelsOut.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --pixels-out needs a path")
    elif arg.startsWith("--pixels-view="):
      result.pixelsView = arg["--pixels-view=".len .. ^1]
      if result.pixelsView.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --pixels-view needs a name")
    elif arg.startsWith("--pixels-scenario="):
      result.pixelsScenario = arg["--pixels-scenario=".len .. ^1]
      if result.pixelsScenario.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --pixels-scenario needs an id")
    elif arg.startsWith("--input-probe="):
      result.inputProbe = arg["--input-probe=".len .. ^1]
      if result.inputProbe.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --input-probe needs a path")
    elif arg.startsWith("--plan-out="):
      result.planOut = arg["--plan-out=".len .. ^1]
      if result.planOut.len == 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --plan-out needs a path")
    elif arg == "--headless":
      # `ct` already refuses this combination (ui-selection.md §8). Refusing it
      # HERE TOO is deliberate: a user who runs the component directly gets the
      # same answer, and §8's rule does not depend on which door they used.
      return GpuiCommand(kind: gckUsageError,
        message: "codetracer-gpui: '--headless' renders one settled screen in" &
                 " the terminal front-end; the spelling is" &
                 " 'ct replay --ui=tui --headless <trace>'")
    elif arg.startsWith("-"):
      return GpuiCommand(kind: gckUsageError,
        message: "codetracer-gpui: unknown option '" & arg & "'")
    else:
      positional.add arg
  # THE TWO MESSAGES NAME THE TWO MODES SEPARATELY, because a user who typed
  # `ct edit --ui=gpui` and is told to "name a recording folder" has been sent
  # to the wrong documentation. Same defect `--id`'s per-front-end message
  # exists against, one dimension over.
  if positional.len == 0:
    return GpuiCommand(kind: gckUsageError,
      message:
        if result.product == pmEdit:
          "codetracer-gpui: name a project directory" &
          " (ct edit --ui=gpui <project>)"
        else:
          "codetracer-gpui: name a recording folder" &
          " (ct replay --ui=gpui <trace-folder>)")
  if positional.len > 1:
    return GpuiCommand(kind: gckUsageError,
      message: (if result.product == pmEdit: "codetracer-gpui: one project at" &
                  " a time; got " else: "codetracer-gpui: one recording at a" &
                  " time; got ") & $positional.len)
  result.traceFolder = positional[0]

# ---------------------------------------------------------------------------
# THE WINDOW — PLAT-37
# ---------------------------------------------------------------------------
#
# PLAT-20's residue 4 was that this binary "opens the window, draws the leaves
# and exits". It did neither of the first two: `createWindow` pushed a
# `WindowConfig` onto a `Vec`, `show()` moved its `state` field from `Created`
# to `Visible`, and `destroy()` removed it — three mutations of a registry the
# renderer never reads, in a code path with no `cfg` on it, identical in a
# shim built with `--features gpui-backend` and one built without.
#
# `gpui_launch` is the function that branches. Under the feature it calls
# `window::create_window` and then `launch_gpui_app`, which opens a real GPUI
# window over the shadow tree and BLOCKS in `Application::run` until the loop
# stops. Without the feature it builds a root, calls the builder, and returns.
# **That difference is the whole of DIFF-6**: one binary, one compositor, one
# scenario, two shims — and the only instrument that can see it is a picture,
# because the shadow tree both builds is identical.
#
# THE ROOT BUILDER CARRIES NO USER DATA, which is why the three values below
# are module-level rather than captured. `RootBuilderCallback` is
# `extern "C" fn(root: *mut GpuiElement)`; there is no context pointer in the
# ABI, so a closure cannot be handed across it. `isonim-gpui`'s own
# `tests/test_gui.nim` does the same thing with its scene constants.

type
  ProbeArrival = object
    ## **ONE KEY, AS THE RUST-SIDE ELEMENT STORE RECORDED IT.** Read inside
    ## the handler the shim called, out of the node's own record, which the
    ## shim wrote before the callback ran — so nothing in this process can
    ## forge it, and an adapter that emulated delivery by walking the shadow
    ## tree from Nim would leave every field at its initial value. That is the
    ## distinction PLAT-38's gate rests on.
    key: string
    modifiers: seq[string]
    kind: string
    seqNo: int

var
  openArm: GpuiEditArm = nil
  gEditorTab = ""
    ## PLAT-49: what the editor's lone tab says — the open file's name, with
    ## " ●" while an Edit buffer is modified (`product_mode.editorTabLabel`,
    ## the terminal's answer too). "" until a file is open: the tab then
    ## names the pane.
    ## PLAT-44. The open document of an EDIT-mode window, or nil in a replay
    ## window. Module-level for the root builder's reason above.
  editPane: GpuiElement = nil
    ## The editor leaf's element — the one the arm redraws and the keys reach.
  editViewportRows = 0
  pendingOutcome: LeafRenderOutcome
    ## The leaf tree, built BEFORE `gpui_launch` so `--report-plan` and the
    ## window path derive from one render rather than two.
  pendingViewportWidth = 0
  pendingViewportHeight = 0
  pendingDock: JsonNode = nil
    ## The window's projected dock document (`shell.projectionFor`), which the
    ## root builder lays the leaves out by. nil when the projection refused,
    ## and then the leaves are tiled in one row as before.
  builderCalls = 0
  probeEnabled = false
  probeTarget: GpuiElement = nil
  probeArrivals: seq[ProbeArrival] = @[]
  probeSentinel = ""
    ## PLAT-38. When this key arrives, the probe asks the loop to stop. A
    ## SENTINEL rather than a timer, so the capture can tell *"the typist
    ## finished"* from *"the deadline fired"* — two outcomes that a
    ## `--quit-after-ms` run cannot separate, and only one of which is a pass.

func modifierNamesOf(mods: GpuiModifiers): seq[string] =
  for m in mods:
    result.add (case m
      of gmControl: "control"
      of gmAlt: "alt"
      of gmShift: "shift"
      of gmPlatform: "platform"
      of gmFunction: "function")
    ## Asserted by the caller. A `gpui_launch` that returned without calling
    ## the builder would leave an empty window and look, from outside, exactly
    ## like a window that painted nothing (§4).

proc probeHandler(el: GpuiElement): GpuiEventHandler =
  ## The `keydown` listener the input probe installs, built by a SEPARATE
  ## PROC so the element it reads is captured BY VALUE.
  ##
  ## **THIS IS PLAT-21's RECORDED DEFECT AND PLAT-38 WALKED INTO IT.** The
  ## first version built this closure inline inside `for i in 0 ..< panes`,
  ## guarded by `if i == 0`. One closure, so the guard looked sufficient — and
  ## it is not: `pane` is a loop-body `let` that the remaining iterations
  ## REASSIGN, so by the time a key arrived the closure was reading the LAST
  ## pane, which had received nothing. The symptom was a probe dump whose
  ## totals were right (`deliverySeq: 2`, `lastKey: "escape"`, read after the
  ## loop from `probeTarget`) and whose per-arrival readings were all empty
  ## strings — evidence that looked like a broken element store rather than
  ## like a captured variable.
  ##
  ## `gpui_binding.keyHandler` carries the same note for the same reason and
  ## solved it the same way. Taking the argument by value gives the handler
  ## its own environment.
  result = proc(ev: GpuiEvent) =
    discard ev
    probeArrivals.add ProbeArrival(
      key: el.lastEventKey(),
      modifiers: modifierNamesOf(el.lastEventModifiers()),
      kind: (case el.lastEventKind()
             of gekKeyDown: "keydown"
             of gekKeyUp: "keyup"
             of gekPointerDown, gekPointerMove, gekPointerUp, gekWheel:
               "pointer"
             of gekOther: "other"),
      seqNo: el.lastEventSeq())
    if probeSentinel.len > 0 and el.lastEventKey() == probeSentinel:
      # The typist is finished. Quitting from HERE rather than from a timer
      # is what lets the capture distinguish "the work completed" from "the
      # backstop fired"; `gpui_quit` is an atomic store the loop's own poller
      # consumes on this thread.
      gpui_quit()

const KeyDownEvent = "keydown"

proc gpuiKeyEventOf(spec: string): (bool, GpuiEvent) =
  ## `control-s` / `shift-a` / `x` / `escape` → a GPUI key-down event: the
  ## LAST `-`-separated part is GPUI's key name, the rest are modifiers. A
  ## lone `-` is the minus key.
  if spec.len == 0: return (false, GpuiEvent())
  var parts = if spec == "-": @["-"] else: spec.split('-')
  if spec.len > 1 and spec.endsWith("--"):
    parts = spec[0 ..< spec.len - 2].split('-') & @["-"]
  var mods: GpuiModifiers = {}
  for m in parts[0 ..< parts.len - 1]:
    case m
    of "control": mods.incl gmControl
    of "alt": mods.incl gmAlt
    of "shift": mods.incl gmShift
    of "platform": mods.incl gmPlatform
    of "function": mods.incl gmFunction
    else: return (false, GpuiEvent())
  # `comma` is the one spelling this option adds: `,` separates the keys.
  let key = if parts[^1] == "comma": "," else: parts[^1]
  if key.len == 0: return (false, GpuiEvent())
  (true, GpuiEvent(kind: gekKeyDown, key: key, modifiers: mods,
                   repeat: false))

var handlerMs: seq[float] = @[]
  ## PLAT-42. Each key's handler time (decode, the core's `applyKey`, the
  ## redraw), for the frame report — the part of a keystroke the shim's
  ## key-to-frame latency starts AFTER.
let editTrace = getEnv("CODETRACER_GPUI_EDIT_TRACE", "") == "1"

var editArmed = false
  ## Whether the editor pane already has its listener — the headless
  ## `--edit-keys` path arms it before the window builder would.

proc drawArrangement(r: GpuiRenderer): bool
proc windowDrawn(): bool

proc noteEditorTab(r: GpuiRenderer; label: string) =
  ## The editor's tab names `label` from now on; the arrangement is redrawn
  ## when that changes it (a step into another file, the first unsaved edit,
  ## a save), because a tab's width is part of the geometry.
  if label == gEditorTab:
    return
  gEditorTab = label
  if windowDrawn():
    discard drawArrangement(r)

proc isHeading(node: GpuiElement): bool =
  ## Whether `node` is a leaf's heading (`leaves.paneTitleElement`).
  not node.isNil and getAttribute(node, TextRoleAttribute) == $trPaneTitle

proc findEditorPane(root: GpuiElement): GpuiElement =
  ## The editor leaf: the pane `renderEditor` stamped with the medium
  ## attribute. Read back out of the tree rather than remembered, for the
  ## chrome's reason (§4a).
  if root.isNil: return nil
  if getAttribute(root, EditorMediumAttribute).len > 0:
    return root
  for i in 0 ..< childCount(root):
    let found = findEditorPane(nthChild(root, i))
    if not found.isNil: return found
  nil

proc applyTextFaces*(r: GpuiRenderer; node: GpuiElement): int {.discardable.}
  ## PLAT-35: the declared text metric, applied (defined with the chrome
  ## below). Forward-declared because every path that REBUILDS a pane's body
  ## has to re-stamp it — a redraw produces new elements, and an element the
  ## walk never reached keeps the window's inherited proportional face.

proc redrawEditor() =
  ## PLAT-44. Redraw the editor pane from the arm's CURRENT document.
  ##
  ## Everything after the pane's heading is removed and drawn again by
  ## `leaves.renderEditor` — the function that drew it the first time — so
  ## the after-edit tree is the same derivation as the before-edit tree and
  ## not a second, incremental one that could drift (§30). Every removal and
  ## append is a shadow-tree mutation, which is what asks the shim to repaint.
  if openArm.isNil or editPane.isNil: return
  var r: GpuiRenderer
  # A window strips the heading (PLAT-49); the headless `--edit-keys` path
  # draws no window chrome and keeps it.
  let keep = if childCount(editPane) > 0 and
                isHeading(nthChild(editPane, 0)): 1 else: 0
  while childCount(editPane) > keep:
    r.removeChild(editPane, nthChild(editPane, childCount(editPane) - 1))
  discard renderEditor(r, editPane, sourcePaneView(GpuiMedium).root,
                       openArm.surfaceOf(editViewportRows))
  noteEditorTab(r, editorTabLabel(openArm.path, openArm.isDirty))
  applyTextFaces(r, editPane)

proc cancelWindowGesture(): bool
  ## PLAT-47: `Esc` during a layout gesture (defined with the gestures below).

proc editKey(key: string; mods: seq[string]) =
  ## One key of an EDIT window's editor pane: its `keydown` listener's body,
  ## and what `--window-ops`' `key:` dispatches in an edit window (the editor
  ## holds the focus there).
  if openArm.isNil: return
  # PLAT-47: `Esc` cancels a layout gesture in flight, and is not typed.
  if key.toLowerAscii in ["escape", "esc"] and cancelWindowGesture():
    return
  block:
    let started = epochTime()
    let applied = openArm.applyGpuiKey(key, mods, int64(started * 1000))
    if applied.outcome != eoIgnored or applied.saved or
       openArm.status.len > 0:
      redrawEditor()
    let handledMs = (epochTime() - started) * 1000
    handlerMs.add handledMs
    if editTrace:
      # `CODETRACER_GPUI_EDIT_TRACE=1`: one line per key, for diagnosing a
      # window lane (which keys arrived, what the core did, what it cost).
      stderr.writeLine("edit-key " & key & " -> " & applied.name & " " &
                       $applied.outcome & " " & formatFloat(handledMs,
                       ffDecimal, 1) & "ms")
    if probeSentinel.len > 0 and key == probeSentinel:
      gpui_quit()

proc editKeyHandler(el: GpuiElement): GpuiEventHandler =
  ## The editor pane's `keydown` listener. Built by a separate proc so `el`
  ## is captured by value — `probeHandler`'s recorded defect.
  result = proc(ev: GpuiEvent) =
    discard ev
    if openArm.isNil or el.lastEventKind() != gekKeyDown: return
    editKey(el.lastEventKey(), modifierNamesOf(el.lastEventModifiers()))

proc armEditorPane(r: GpuiRenderer) =
  ## Focus the editor pane and give it the key listener. Once.
  if openArm.isNil or editPane.isNil or editArmed: return
  editArmed = true
  setFocusable(editPane)
  discard focusElement(editPane)
  r.addEventListener(editPane, "keydown", editKeyHandler(editPane))


# ---------------------------------------------------------------------------
# PLAT-47 part B — the arrangement, drawn from its geometry, and the pointer
# ---------------------------------------------------------------------------

var
  gShell: GpuiShell = nil
    ## The window's shell: the committed layout lives in its `WindowSet`, and
    ## every gesture's command goes through its one door (`applyIn`).
  gWindow = WindowId(0)
  gRemember = false
    ## Write a committed rearrangement through to this product's remembered
    ## layout: a Debug window whose remembered file was readable. Edit mode
    ## opens its shared default and remembers nothing (PLAT-45).
  gRoot: GpuiElement = nil
  gContainer: GpuiElement = nil
  gTop: GpuiElement = nil
    ## The drawn arrangement's outermost element, replaced on every redraw.
  gOverlay: seq[GpuiElement] = @[]
    ## The drop tint, its caret and the drag ghost: absolutely placed on the
    ## root, above everything.
  gPanes = initTable[string, GpuiElement]()
    ## Every leaf element by pane id — the leaves are built once and MOVED
    ## between arrangements, never rebuilt, so a pane's own state survives a
    ## drop.
  gGeom: WindowGeometry
  gGestures = idle()
  gSession: HeadlessDebugSession = nil
  gLeafSet: GpuiLeafSet
  gCalltraceLoads = 0
    ## How many call-trace sections the window has read (the first, at open,
    ## included) — reported for the paging test.
  gestureTrace = getEnv("CODETRACER_GPUI_GESTURE_TRACE", "") == "1"
    ## One stderr line per gesture step, for a window lane's record.

proc windowDrawn(): bool =
  ## Whether the window's arrangement has been drawn (so a redraw has a root
  ## to draw into).
  not gRoot.isNil and not gShell.isNil

const
  DropTintAlpha = "59"
    ## 0.35 of 255: the translucent quad over the region a drop would take —
    ## the terminal overlay's `DropTintAlpha`, as a GPU colour's alpha byte.
  DropCaretAlpha = "d9"
    ## 0.85: the insertion caret on a tab strip, stronger than the strip's tint.
  CalltraceRowPx = 26
    ## The pixel pitch of one call-trace row in the window — one line of the
    ## pane's text face, measured off the window (26 px from one row to the
    ## next at the shim's default text size). The pane pages by it: the rows
    ## it asks the ViewModel for are the rows that fit, so the last call
    ## scrolled to is on screen, not clipped below the pane.

proc drawTopBar(r: GpuiRenderer)
  ## PLAT-48: the top bar over the window (defined with its handlers below).
proc handleTopPress(r: GpuiRenderer; x, y: int): bool
proc handleTopHover(r: GpuiRenderer; x, y: int)
proc handleTopKey(r: GpuiRenderer; key: string; mods: seq[string]): bool
proc topBarGeometry(): JsonNode

proc traceGesture(line: string) =
  if gestureTrace and line.len > 0:
    stderr.writeLine("gesture " & line)

proc committedLayout(): Layout =
  let idx = gShell.windows.indexOf(gWindow)
  gShell.windows.windows[idx].layout

proc applyTextFaces*(r: GpuiRenderer; node: GpuiElement): int {.discardable.} =
  ## PLAT-35 — **THE DECLARED TEXT METRIC, APPLIED.**
  ##
  ## Walk the subtree and give every element that carries a text metric the
  ## face that metric names: monospace for the editor's code, its gutter and
  ## its inline values, proportional for pane titles and variable names —
  ## `leaves.gpuiMetricFor`'s own table, which was written for the tier-3
  ## comparison and never reached a renderer.
  ##
  ## **IT READS THE ATTRIBUTE BACK OUT OF THE TREE rather than taking a role
  ## list**, for `paintWindowChrome`'s own reason one paragraph up: the
  ## renderer is handed what the tree holds, so the tree is what the face is
  ## computed from. A version that walked `TextRole` and asked each leaf
  ## where its spans were would be describing the tree instead of reading it
  ## (§4a), and would silently miss a span a later pane added.
  ##
  ## **AND IT IS HERE RATHER THAN IN `leaves.nim`**, which is where the face
  ## would more obviously go. `run-plat20-mutations.py`,
  ## `run-plat21-mutations.py`, `run-plat22-mutations.py` and
  ## `run-plat35-visual-mutations.py` all digest `app/leaves.nim` into their
  ## control comparators (§39a), so an edit there stales four harnesses'
  ## controls at once — which is the stated reason the chrome, the input
  ## probe's listener and the editor's key listener are all attached from
  ## this module and not from that one. The face is chrome.
  ##
  ## **ANSWERS HOW MANY ELEMENTS IT STYLED**, which is the only part of its
  ## effect anything outside this process can observe: the shim's ABI has
  ## `gpui_get_attribute` and no style read-back, so a suite cannot ask an
  ## element what face it ended up with. A count it can ask for, and a count
  ## of ZERO over a tree full of declared metrics is the state this walk
  ## exists against — which is why `test_plat35_text_faces.nim` asserts the
  ## number against an independent count of the elements carrying a metric
  ## rather than merely asserting the walk returned.
  if node.isNil:
    return 0
  let family = fontFamilyForMetric(getAttribute(node, TextMetricAttribute))
  if family.len > 0:
    r.setStyle(node, "font-family", family)
    result = 1
  for i in 0 ..< childCount(node):
    result += applyTextFaces(r, nthChild(node, i))

proc stylePaneBox(r: GpuiRenderer; pane: GpuiElement; w, h: int) =
  ## One leaf's own box: its size, its fill, its clip.
  let isEditor = getAttribute(pane, EditorMediumAttribute).len > 0
  r.setStyle(pane, "background-color",
             if isEditor: EditorGround else: chromeOf(crPaneBackground))
  r.setStyle(pane, "color", chromeOf(crWindowForeground))
  r.setStyle(pane, "width", $max(1, w) & "px")
  r.setStyle(pane, "height", (if h > 0: $h & "px" else: "100%"))
  # A PANE CLIPS ITS OWN CONTENT (PLAT-41). A table wider than its pane —
  # the flow pane's five columns — drew over the three panes beside it on
  # the shipped binary; the pane is the boundary a reader expects.
  r.setStyle(pane, "overflow", "hidden")
  r.setStyle(pane, "flex-direction", "column")
  r.setStyle(pane, "padding", $ChromePaddingPx & "px")
  r.setStyle(pane, "rounded", "4px")
  # (No heading to colour since PLAT-49: the window strips it, and the
  # pane's tab strip names the pane.)

proc drawNode(r: GpuiRenderer; i: int): GpuiElement =
  ## One node of the geometry, as elements sized exactly as it says.
  let n = gGeom.nodes[i]
  case n.kind
  of gnSplit:
    let box = r.createElement("div")
    r.setStyle(box, "flex-direction", if n.horizontal: "row" else: "column")
    r.setStyle(box, "gap", $ChromeGapPx & "px")
    r.setStyle(box, "width", $n.rect.w & "px")
    r.setStyle(box, "height", $n.rect.h & "px")
    for c in n.children:
      r.appendChild(box, drawNode(r, c))
    box
  of gnTabs:
    let activePane = n.panes[n.active]
    let leaf = gPanes.getOrDefault(activePane)
    let isEditor = activePane == $paneEditor
    # THE PANE BOX: the tab strip and the pane under it, inside a 1px BORDER
    # — the desktop's selected-panel colour around the focused pane (the
    # editor, where the window's keys go), invisible around the rest
    # (`chrome.paneOutlineStyle`, PLAT-47 B2).
    let box = r.createElement("div")
    r.setAttribute(box, "data-ct-focus-frame", $isEditor)
    r.setStyle(box, "flex-direction", "column")
    r.setStyle(box, "width", $n.rect.w & "px")
    r.setStyle(box, "height", $n.rect.h & "px")
    r.setStyle(box, "background-color",
               if isEditor: EditorGround else: chromeOf(crPaneBackground))
    r.setStyle(box, "rounded", "4px")
    for (key, value) in paneOutlineStyle(isEditor):
      r.setStyle(box, key, value)
    if not n.strip.isEmpty:
      let strip = r.createElement("div")
      r.setAttribute(strip, "data-ct-tabs", n.labels.join(","))
      r.setStyle(strip, "flex-direction", "row")
      r.setStyle(strip, "flex-shrink", "0")
      r.setStyle(strip, "padding-left", $StripInsetPx & "px")
      r.setStyle(strip, "height", $TabStripPx & "px")
      r.setStyle(strip, "items", "center")
      # PLAT-49: the strip on its own ground, distinct from the pane body.
      for (key, value) in stripStyle():
        r.setStyle(strip, key, value)
      # A TAB STRIP SHAPED BY COLOUR AND WEIGHT (PLAT-47), no brackets, no
      # rule — and, by the user's direction (PLAT-49), the selected tab on a
      # background and in a foreground of its own, the others on the strip's.
      # Each tab is exactly as wide as the geometry says, so a click and a
      # drop caret land where the tab is drawn.
      for t, label in n.labels:
        let tab = r.createElement("div")
        r.setAttribute(tab, "data-ct-tab-active", $(t == n.active))
        r.setStyle(tab, "width", $n.tabs[t].w & "px")
        r.setStyle(tab, "flex-shrink", "0")
        r.setStyle(tab, "padding-left", $TabPadPx & "px")
        r.setStyle(tab, "white-space", "nowrap")
        r.setStyle(tab, "overflow", "hidden")
        for (key, value) in tabStyle(t == n.active):
          r.setStyle(tab, key, value)
        r.appendChild(tab, r.createTextNode(label))
        r.appendChild(strip, tab)
      r.appendChild(box, strip)
    if not leaf.isNil:
      stylePaneBox(r, leaf, n.body.w, n.body.h)
      r.appendChild(box, leaf)
    box

proc drawStrip(r: GpuiRenderer; st: GeomStrip;
               revealed: Option[PaneKind]): GpuiElement =
  ## One AUTO-HIDE STRIP: a band on the tab-strip surface along its edge, one
  ## label per docked pane — the revealed one in the active tab's weight, the
  ## others in the inactive tier (PLAT-47's colour-and-weight tabs). A left or
  ## right strip's labels read top to bottom, one character per row.
  let horizontal = st.edge in {leTop, leBottom}
  result = r.createElement("div")
  r.setAttribute(result, "data-ct-dock-strip", $st.edge)
  r.setStyle(result, "flex-direction", if horizontal: "row" else: "column")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "width", $st.rect.w & "px")
  r.setStyle(result, "height", $st.rect.h & "px")
  r.setStyle(result, "background-color", chromeOf(crPaneBackground))
  r.setStyle(result, "rounded", "4px")
  if horizontal:
    r.setStyle(result, "padding-left", $StripInsetPx & "px")
  else:
    r.setStyle(result, "padding-top", $StripInsetPx & "px")
  for sl in st.slots:
    let shown = revealed.isSome and $revealed.get == sl.pane
    let slot = r.createElement("div")
    r.setAttribute(slot, "data-ct-dock-slot", sl.pane)
    r.setAttribute(slot, "data-ct-tab-active", $shown)
    r.setStyle(slot, "flex-shrink", "0")
    r.setStyle(slot, "width", $sl.rect.w & "px")
    r.setStyle(slot, "height", $sl.rect.h & "px")
    r.setStyle(slot, "items", "center")
    for (key, value) in tabStyle(shown):
      r.setStyle(slot, key, value)
    if horizontal:
      r.setStyle(slot, "flex-direction", "row")
      r.setStyle(slot, "padding-left", $TabPadPx & "px")
      r.setStyle(slot, "white-space", "nowrap")
      r.appendChild(slot, r.createTextNode(sl.label))
    else:
      r.setStyle(slot, "flex-direction", "column")
      r.setStyle(slot, "padding-top", $TabPadPx & "px")
      for ch in sl.label:
        let cell = r.createElement("div")
        r.setStyle(cell, "height", $DockCharPx & "px")
        r.setStyle(cell, "flex-shrink", "0")
        r.appendChild(cell, r.createTextNode($ch))
        r.appendChild(slot, cell)
    r.appendChild(result, slot)

proc drawWindowBody(r: GpuiRenderer; revealed: Option[PaneKind]): GpuiElement =
  ## The tree, and — when panes are docked — the auto-hide strips around it,
  ## exactly where `windowGeometryOf` put them: a row of [left strip]
  ## [column of [top strip] [tree] [bottom strip]] [right strip], each gap
  ## `ChromeGapPx`, so the drawn strips and the hit-test's agree to the pixel.
  let tree = drawNode(r, gGeom.root)
  if gGeom.strips.len == 0:
    return tree
  var byEdge: array[LayoutEdge, GpuiElement]
  for st in gGeom.strips:
    byEdge[st.edge] = drawStrip(r, st, revealed)
  result = r.createElement("div")
  r.setAttribute(result, "data-ct-window-body", "strips")
  r.setStyle(result, "flex-direction", "row")
  r.setStyle(result, "gap", $ChromeGapPx & "px")
  r.setStyle(result, "width", $gGeom.area.w & "px")
  r.setStyle(result, "height", $gGeom.area.h & "px")
  if not byEdge[leLeft].isNil: r.appendChild(result, byEdge[leLeft])
  let column = r.createElement("div")
  r.setStyle(column, "flex-direction", "column")
  r.setStyle(column, "gap", $ChromeGapPx & "px")
  r.setStyle(column, "width", $gGeom.inner.w & "px")
  r.setStyle(column, "height", $gGeom.area.h & "px")
  if not byEdge[leTop].isNil: r.appendChild(column, byEdge[leTop])
  r.appendChild(column, tree)
  if not byEdge[leBottom].isNil: r.appendChild(column, byEdge[leBottom])
  r.appendChild(result, column)
  if not byEdge[leRight].isNil: r.appendChild(result, byEdge[leRight])

proc quad(r: GpuiRenderer; rect: PxRect; colour: string): GpuiElement =
  ## An absolutely placed, translucent rectangle on the root.
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $rect.x & "px")
  r.setStyle(result, "top", $rect.y & "px")
  r.setStyle(result, "width", $max(1, rect.w) & "px")
  r.setStyle(result, "height", $max(1, rect.h) & "px")
  r.setStyle(result, "background-color", colour)

proc drawOverlay(r: GpuiRenderer) =
  ## The drag's transient state, drawn over the arrangement: the drop tint
  ## over exactly the region the drop would take and — for a join — the
  ## insertion caret (both from `dropIndicationRects`, i.e. from the model's
  ## `dropIndicationOf`), and the ghost label following the pointer.
  for e in gOverlay:
    r.removeChild(gRoot, e)
  gOverlay = @[]
  # A REVEALED DOCKED PANE, over the tree against its own edge, in the
  # focused pane's outline — never reflowing the arrangement behind it.
  if gGestures.revealing:
    let pane = gPanes.getOrDefault($gGestures.reveal.pane)
    if not pane.isNil:
      let rect = gGeom.revealRectOf(gGestures.reveal.edge)
      let box = r.createElement("div")
      r.setAttribute(box, "data-ct-revealed", $gGestures.reveal.pane)
      r.setStyle(box, "position", "absolute")
      r.setStyle(box, "left", $rect.x & "px")
      r.setStyle(box, "top", $rect.y & "px")
      r.setStyle(box, "width", $rect.w & "px")
      r.setStyle(box, "height", $rect.h & "px")
      r.setStyle(box, "flex-direction", "column")
      r.setStyle(box, "background-color", chromeOf(crPaneBackground))
      r.setStyle(box, "rounded", "4px")
      for (key, value) in paneOutlineStyle(true):
        r.setStyle(box, key, value)
      let parent = r.parentNode(pane)
      if not parent.isNil:
        r.removeChild(parent, pane)
      # PLAT-49: the revealed pane is named by a one-tab strip, as every pane
      # box is (the leaf draws no heading in the window).
      let label = labelOf($gGestures.reveal.pane)
      let strip = r.createElement("div")
      r.setAttribute(strip, "data-ct-tabs", label)
      r.setStyle(strip, "flex-direction", "row")
      r.setStyle(strip, "flex-shrink", "0")
      r.setStyle(strip, "padding-left", $StripInsetPx & "px")
      r.setStyle(strip, "height", $TabStripPx & "px")
      r.setStyle(strip, "items", "center")
      for (key, value) in stripStyle(): r.setStyle(strip, key, value)
      let tab = r.createElement("div")
      r.setAttribute(tab, "data-ct-tab-active", "true")
      r.setStyle(tab, "width", $tabWidthPx(label) & "px")
      r.setStyle(tab, "flex-shrink", "0")
      r.setStyle(tab, "padding-left", $TabPadPx & "px")
      r.setStyle(tab, "white-space", "nowrap")
      for (key, value) in tabStyle(true): r.setStyle(tab, key, value)
      r.appendChild(tab, r.createTextNode(label))
      r.appendChild(strip, tab)
      r.appendChild(box, strip)
      stylePaneBox(r, pane, rect.w - 2 * FocusOutlinePx,
                   max(1, rect.h - 2 * FocusOutlinePx - TabStripPx))
      r.appendChild(box, pane)
      gOverlay.add box
  let ind = gGestures.indication()
  let action = DesignTokenHex[dtColorsUiBorderAction][dmDark]
  if ind.kind != diNone:
    let (tint, caret) = gGeom.dropIndicationRects(ind)
    if not tint.isEmpty:
      let q = quad(r, tint, action & DropTintAlpha)
      r.setAttribute(q, "data-ct-drop", $ind.kind)
      gOverlay.add q
    if not caret.isEmpty:
      let c = quad(r, caret, action & DropCaretAlpha)
      r.setAttribute(c, "data-ct-drop-caret", $ind.slot)
      gOverlay.add c
  if gGestures.kind == gkDragTab and gGestures.moved:
    # GoldenLayout's drag proxy: the dragged tab's label beside the pointer.
    let label = labelOf($gGestures.source)
    let ghost = r.createElement("div")
    r.setAttribute(ghost, "data-ct-drag-ghost", label)
    r.setStyle(ghost, "position", "absolute")
    r.setStyle(ghost, "left", $(gGestures.pointerX + 12) & "px")
    r.setStyle(ghost, "top", $(gGestures.pointerY + 12) & "px")
    r.setStyle(ghost, "width", $tabWidthPx(label) & "px")
    r.setStyle(ghost, "height", $TabStripPx & "px")
    r.setStyle(ghost, "padding-left", $TabPadPx & "px")
    r.setStyle(ghost, "items", "center")
    r.setStyle(ghost, "white-space", "nowrap")
    r.setStyle(ghost, "background-color", chromeOf(crPaneBackground))
    r.setStyle(ghost, "border-width", "1px")
    r.setStyle(ghost, "border-color", action)
    for (key, value) in tabStyle(true):
      r.setStyle(ghost, key, value)
    r.appendChild(ghost, r.createTextNode(label))
    gOverlay.add ghost
  for e in gOverlay:
    r.appendChild(gRoot, e)

let geometryOut = getEnv("CODETRACER_GPUI_GEOMETRY_OUT", "")
  ## A window lane's instrument: where the window drew every pane, tab and
  ## divider, rewritten after every redraw — so a lane can AIM a pointer
  ## (which tab to press, where a divider is). What a gesture did is read
  ## back from the window's pixels, never from this file.

proc writeGeometry() =
  if geometryOut.len == 0:
    return
  proc rect(p: PxRect): JsonNode = %*[p.x, p.y, p.w, p.h]
  var nodes = newJArray()
  for n in gGeom.nodes:
    var j = %*{"path": n.path, "rect": rect(n.rect)}
    case n.kind
    of gnSplit:
      j["kind"] = %"split"
      j["horizontal"] = %n.horizontal
    of gnTabs:
      j["kind"] = %"tabs"
      j["panes"] = %n.panes
      j["labels"] = %n.labels
      j["active"] = %n.active
      j["strip"] = rect(n.strip)
      j["body"] = rect(n.body)
      var tabs = newJArray()
      for t in n.tabs: tabs.add rect(t)
      j["tabs"] = tabs
    nodes.add j
  var dividers = newJArray()
  for d in gGeom.dividers:
    dividers.add %*{"container": d.container, "index": d.index,
                    "horizontal": d.horizontal, "rect": rect(d.rect)}
  var strips = newJArray()
  for st in gGeom.strips:
    var slots = newJArray()
    for sl in st.slots:
      slots.add %*{"pane": sl.pane, "label": sl.label, "rect": rect(sl.rect)}
    strips.add %*{"edge": $st.edge, "rect": rect(st.rect), "slots": slots}
  let revealed =
    if gGestures.revealing:
      %*{"pane": $gGestures.reveal.pane,
         "rect": rect(gGeom.revealRectOf(gGestures.reveal.edge))}
    else: newJNull()
  let top = topBarGeometry()
  try:
    writeFile(geometryOut, $(%*{"area": rect(gGeom.area),
                                "inner": rect(gGeom.inner), "nodes": nodes,
                                "dividers": dividers, "strips": strips,
                                "revealed": revealed, "topBar": top}))
  except IOError:
    discard

proc drawArrangement(r: GpuiRenderer): bool =
  ## Lay the window out from the layout it should show NOW — the committed
  ## one, or, while a divider is dragged, the committed one with the pending
  ## resize applied (`previewLayout`, the model's own `pendingCommand` and
  ## `apply`) — and draw the gesture's overlay over it. Answers whether an
  ## arrangement was drawn (a refused projection leaves the last one).
  let layout = gGestures.previewLayout(committedLayout())
  let projection = projectDock(layout, gShell.viewport)
  if projection.status == dpsRefused:
    return false
  gGeom = windowGeometryOf(layout, projection.state, pendingViewportWidth,
                           pendingViewportHeight, GpuiTopBandPx,
                           @[($paneEditor, gEditorTab)])
  if gGeom.root < 0:
    return false
  # The leaves are MOVED into the new arrangement, never rebuilt.
  for _, pane in gPanes:
    let parent = r.parentNode(pane)
    if not parent.isNil:
      r.removeChild(parent, pane)
  if not gTop.isNil:
    r.removeChild(gContainer, gTop)
  gTop = drawWindowBody(r, (if gGestures.revealing: some(gGestures.reveal.pane)
                            else: none(PaneKind)))
  r.appendChild(gContainer, gTop)
  if not gRoot.isNil:
    drawOverlay(r)
    drawTopBar(r)
  writeGeometry()
  true

proc applyGestureCommand(r: GpuiRenderer; cmd: LayoutCommand) =
  ## A committed gesture, through the shell's one door, and — in a Debug
  ## window whose remembered layout was readable — written through to this
  ## product's remembered layout, as `--layout-ops` is.
  let applied = gShell.applyIn(gWindow, cmd)
  if applied.kind == wsRefused:
    traceGesture("refused " & $cmd & ": " & $applied.problem.kind)
    return
  traceGesture("applied " & $cmd)
  if gRemember:
    let failed = saveGpuiLayoutDocument(gShell.saveWindowLayout(gWindow))
    if failed.len > 0:
      stderr.writeLine("codetracer-gpui: the layout could not be saved: " &
                       failed)

proc stripHeading(r: GpuiRenderer; pane: GpuiElement) =
  ## PLAT-49 (the user, 2026-10-01): NO TITLE ROW INSIDE A PANE. Every pane
  ## box has a tab strip naming it (`window_geometry`), so the window removes
  ## the heading `leaves.renderLeaf` builds as a leaf's first child. The
  ## leaves keep building it — `--report-plan`, the arrangement suites and
  ## four harnesses' controls read the leaf tree as it is — and the WINDOW
  ## does not show it.
  if not pane.isNil and childCount(pane) > 0 and isHeading(nthChild(pane, 0)):
    r.removeChild(pane, nthChild(pane, 0))

proc redrawWindowLeaf(r: GpuiRenderer; pane: GpuiElement; leaf: GpuiLeaf) =
  ## `leaves.redrawLeafBody` for a pane whose heading the window removed:
  ## that procedure keeps its node's FIRST child as the heading and redraws
  ## the rest, so the old content is cleared first and a stand-in first child
  ## held while it runs, then dropped — the pane is left with exactly the
  ## content `renderPaneView` drew.
  if pane.isNil:
    return
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  let stand = r.createElement("div")
  r.appendChild(pane, stand)
  redrawLeafBody(r, pane, leaf)
  r.removeChild(pane, stand)

proc calltraceHeading(): string =
  ## The call-trace pane's title: its name and the WHOLE trace's call count,
  ## the terminal's `Call Trace N call(s)` (the pane holds one section).
  let total =
    if gSession.isNil: 0
    else: int(gSession.session.store.calltrace.totalCallsCount.val)
  gpuiPaneName(paneCalltrace) &
    (if total > 0: " " & $total & " call(s)" else: "")

proc redrawCalltrace(r: GpuiRenderer) =
  let pane = gPanes.getOrDefault($paneCalltrace)
  if pane.isNil:
    return
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == paneCalltrace:
      redrawWindowLeaf(r, pane, leaf)
      applyTextFaces(r, pane)
      break

proc scrollCalltrace(r: GpuiRenderer; rows: int) =
  ## PLAT-47 B3: the wheel over the call-trace pane scrolls it a row per
  ## `CalltraceRowPx`, reading a section past the one held as it scrolls
  ## (`gpui_host.pageCalltrace`, the desktop's paging), then draws the pane
  ## again.
  if gSession.isNil or rows == 0:
    return
  let i = gGeom.tabsNodeOfPane($paneCalltrace)
  if i < 0:
    return
  # The rows the pane shows: its body inside the pane's padding, at the row
  # pitch (no heading row since PLAT-49; the tab strip is outside the body).
  let body = max(1, (gGeom.nodes[i].body.h - 2 * ChromePaddingPx) div
                    CalltraceRowPx)
  let page = gSession.pageCalltrace(body, rows)
  if page.loaded:
    inc gCalltraceLoads
    traceGesture("calltrace-section top=" & $page.top & " loads=" &
                 $gCalltraceLoads)
  traceGesture("calltrace top=" & $page.top & " rows=" & $body & " total=" &
               $page.total)
  redrawCalltrace(r)

proc windowPointer(r0: GpuiRenderer; kind: GpuiEventKind; x, y: int;
                   dy = 0.0) =
  ## One pointer event of the window, wherever it came from: the root's
  ## listener (`pointerHandler`) and `--window-ops` (the plan's scripted
  ## pointer) both call this, so a scripted press is the press a user makes.
  var r = r0
  if gShell.isNil:
    return
  var step: GestureStep
  case kind
  of gekPointerDown:
    # PLAT-48: the top bar, its popovers and the pin / unpin buttons first.
    if handleTopPress(r, x, y):
      return
    step = gGestures.pointerDown(committedLayout(), gGeom, x, y)
  of gekPointerMove:
    if not gGestures.active:
      handleTopHover(r, x, y)
      return
    step = gGestures.pointerMove(committedLayout(), gGeom, x, y)
  of gekPointerUp:
    if not gGestures.active: return
    step = gGestures.pointerUp(committedLayout(), gGeom, x, y)
    if step.command.isSome:
      applyGestureCommand(r, step.command.get)
  of gekWheel:
    if gGeom.activePaneAt(x, y) == $paneCalltrace:
      # GPUI's wheel delta is the CONTENT's motion: a turn toward the user
      # (scroll down) moves the content up, a negative `dy`.
      scrollCalltrace(r, int(round(-dy / float(CalltraceRowPx))))
    return
  else:
    return
  traceGesture(step.status)
  if step.changed:
    discard drawArrangement(r)

proc pointerHandler(r0: GpuiRenderer): GpuiEventHandler =
  ## The root's pointer listener: every pointer event of the window.
  result = proc(ev: GpuiEvent) =
    let p = pointerOf(ev)
    if not p.valid:
      return
    windowPointer(r0, ev.kind, int(p.x), int(p.y), p.dy)

proc windowKey(key: string; mods: seq[string]) =
  ## One key of a replay window, from its `keydown` listener or from
  ## `--window-ops`: the top bar's keys (an open omnibar or menu owns them
  ## all), then `Esc` cancels a layout gesture.
  var r: GpuiRenderer
  if handleTopKey(r, key, mods):
    return
  if key.toLowerAscii in ["escape", "esc"]:
    discard cancelWindowGesture()

proc gestureKeyHandler(el: GpuiElement): GpuiEventHandler =
  ## A replay window's `keydown` listener: `Esc` cancels a layout gesture.
  ## (An edit window's editor listener does the same before typing a key.)
  result = proc(ev: GpuiEvent) =
    discard ev
    if el.lastEventKind() != gekKeyDown: return
    windowKey(el.lastEventKey(), modifierNamesOf(el.lastEventModifiers()))

proc armPointer(r: GpuiRenderer; root: GpuiElement) =
  if gShell.isNil:
    return
  let handler = pointerHandler(r)
  for name in ["mousedown", "mousemove", "mouseup", "wheel"]:
    r.addEventListener(root, name, handler)
  # A REPLAY window's keys: the editor pane takes focus (the pane the focus
  # outline marks) and `Esc` cancels a gesture. Not while the input probe
  # owns focus — its claim is that a key reached the pane IT focused — and
  # not in an edit window, whose editor listener is already armed.
  if openArm.isNil and not probeEnabled:
    let editor = gPanes.getOrDefault($paneEditor)
    if not editor.isNil:
      setFocusable(editor)
      discard focusElement(editor)
      r.addEventListener(editor, "keydown", gestureKeyHandler(editor))

proc cancelWindowGesture(): bool =
  ## `Esc` while a gesture is in flight: cancel it and redraw the committed
  ## arrangement. Answers whether there was one (so the key is consumed).
  if not gGestures.active and not gGestures.revealing:
    return false
  var r: GpuiRenderer
  let step = gGestures.cancelGesture()
  traceGesture(step.status)
  discard drawArrangement(r)
  true


# ---------------------------------------------------------------------------
# PLAT-48 — the top bar: the program menu, the debugger controls (the
# desktop's own marks), the omnibar, the session tabs; the auto-hide strips'
# key, hover label and pin / unpin
# ---------------------------------------------------------------------------

const
  PinButtonPx = 24
  HoverLabelPx = 24

var
  gMenu: MenuVM = nil
    ## THE SHARED MENU VIEWMODEL — the tree the desktop's menu is built from
    ## (`product_menu`), the state every front-end's menu is drawn from.
  gOmnibar: OmnibarVM = nil
  gTopLayout: GTopLayout
  gTopEls: seq[GpuiElement] = @[]
    ## The band, its parts, the popovers and the hover label: absolutely
    ## placed on the root, rebuilt by `drawTopBar`.
  gHoverControl = -1
  gHoverSlot = ""
    ## The auto-hide label under the pointer (its pane id), for the hover
    ## label.
  gHoverAt = (-1, -1)
    ## Where the last hover was handled. The window re-reports a pointer
    ## that has not moved (after a redraw); a keyboard move of the menu's
    ## highlight must not be taken back by it, so a hover counts only when
    ## the pointer really moved — the desktop menu's rule too.
  gIconDir = ""
    ## Where the desktop's marks are written as SVG documents for `img`.
  gSourceService: GpuiSourceService = nil
  gBindings: Table[string, string]
    ## The window's keymap: the desktop's default chords
    ## (`window_top_bar.desktopBindings`), shown in the menu and bound here.

proc gpuiMenuActionAvailable(action: string): bool =
  ## What this window performs from the menu: the debugger's transport and
  ## the panes it can bring forward, and the omnibar's two searches. The
  ## rest are drawn disabled — the same menu, honestly marked.
  action in ["forwardContinue", "reverseContinue", "forwardNext",
             "reverseNext", "forwardStep", "reverseStep", "forwardStepOut",
             "reverseStepOut", "findSymbol", "aFilesystem", "aFullCalltrace",
             "aState", "aEventLog", "aTimeline", "aTerminal", "aScratchpad",
             "aPointList", "aAgentActivity"]

proc markSvgPath(controlIndex: int; enabled: bool): string =
  ## The desktop's mark for a control, written once as an SVG document in
  ## the ink its state is drawn in — `svgMarkup`'s `currentColor` resolved,
  ## as the button's CSS `color` resolves it on the desktop.
  if gIconDir.len == 0:
    gIconDir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(gIconDir)
  let c = TransportControls[controlIndex]
  let path = gIconDir / (c.id & (if enabled: "-on" else: "-off") & ".svg")
  if not fileExists(path):
    let ink = chromeOf(if enabled: crTabActiveForeground
                       else: crTabInactiveForeground)
    var svg = svgMarkup(markFor(c.id)).replace("currentColor", ink)
    svg = svg.replace("<svg ", "<svg width=\"" & $(2 * ControlIconPx) &
                      "\" height=\"" & $(2 * ControlIconPx) & "\" ")
    writeFile(path, svg)
  path

proc controlsEnabled(): seq[bool] =
  if gSession.isNil or gSession.session.debugControlsVM.isNil:
    return newSeq[bool](TransportControls.len)
  for c in TransportControls:
    result.add gSession.session.debugControlsVM.transportAvailable(c.id)

proc absBox(r: GpuiRenderer; rect: PxRect; bg = ""): GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $rect.x & "px")
  r.setStyle(result, "top", $rect.y & "px")
  r.setStyle(result, "width", $max(1, rect.w) & "px")
  r.setStyle(result, "height", $max(1, rect.h) & "px")
  r.setStyle(result, "flex-direction", "row")
  r.setStyle(result, "items", "center")
  if bg.len > 0:
    r.setStyle(result, "background-color", bg)

proc pinButtonRect(n: GeomNode): PxRect =
  ## The PIN button of a pane box: the right end of its tab strip (every
  ## pane box has one since PLAT-49).
  let top = if n.strip.isEmpty: n.body.y else: n.strip.y
  PxRect(x: n.rect.x + n.rect.w - PinButtonPx - 2, y: top + 3,
         w: PinButtonPx, h: TabStripPx - 6)

proc overlayRects(): seq[PxRect] =
  ## What `drawOverlay` draws OVER the tree right now: the revealed pane, a
  ## drag's drop tint and caret, and its ghost label — the rectangles no
  ## control of the tree may paint over.
  if gGestures.revealing:
    result.add gGeom.revealRectOf(gGestures.reveal.edge)
  let ind = gGestures.indication()
  if ind.kind != diNone:
    let (tint, caret) = gGeom.dropIndicationRects(ind)
    if not tint.isEmpty: result.add tint
    if not caret.isEmpty: result.add caret
  if gGestures.kind == gkDragTab and gGestures.moved:
    result.add PxRect(x: gGestures.pointerX + 12, y: gGestures.pointerY + 12,
                      w: tabWidthPx(labelOf($gGestures.source)),
                      h: TabStripPx)

proc unpinButtonRect(): PxRect =
  let rr = gGeom.revealRectOf(gGestures.reveal.edge)
  PxRect(x: rr.x + rr.w - 72, y: rr.y + 4, w: 64, h: TabStripPx - 8)

proc drawTopBar(r: GpuiRenderer) =
  ## The band and everything over it, from the shared ViewModels.
  if gRoot.isNil or gMenu.isNil:
    return
  for e in gTopEls:
    r.removeChild(gRoot, e)
  gTopEls = @[]
  let tabs = if gShell.isNil: @[] else: gShell.app.tabsOf()
  gTopLayout = gpuiTopBarLayout(gMenu, gOmnibar, tabs, pendingViewportWidth)
  let band = absBox(r, gTopLayout.band, chromeOf(crPaneBackground))
  r.setAttribute(band, "data-ct-top-bar", "band")
  r.setStyle(band, "rounded", "4px")
  gTopEls.add band
  let enabled = controlsEnabled()
  for sg in gTopLayout.segs:
    case sg.part
    of gtMenuButton:
      let b = absBox(r, sg.rect)
      r.setAttribute(b, "data-ct-menu-button", $gMenu.isOpen)
      r.setStyle(b, "padding-left", $TabPadPx & "px")
      for (k, v) in tabStyle(gMenu.isOpen): r.setStyle(b, k, v)
      r.appendChild(b, r.createTextNode("≡"))
      gTopEls.add b
    of gtControl:
      let on = sg.index < enabled.len and enabled[sg.index]
      let b = absBox(r, sg.rect,
                     if gHoverControl == sg.index: chromeOf(crWindowBackground)
                     else: "")
      r.setAttribute(b, "data-ct-control", TransportControls[sg.index].id)
      r.setAttribute(b, "data-ct-enabled", $on)
      r.setStyle(b, "justify", "center")
      let icon = r.createElement("img")
      r.setAttribute(icon, "src", markSvgPath(sg.index, on))
      r.setStyle(icon, "width", $ControlIconPx & "px")
      r.setStyle(icon, "height", $ControlIconPx & "px")
      r.appendChild(b, icon)
      gTopEls.add b
    of gtOmnibar:
      # PLAT-49: AN INPUT BOX on the input surface; empty, it shows the
      # Omnibar ViewModel's placeholder — the desktop's and the terminal's
      # words — and open, the query with its caret (a thin bar while
      # inserting, a block while overwriting) where the ViewModel's
      # `cursor` is.
      let b = absBox(r, sg.rect, chromeOf(crInputBackground))
      r.setAttribute(b, "data-ct-omnibar", $gOmnibar.isOpen)
      r.setStyle(b, "padding-left", $TabPadPx & "px")
      r.setStyle(b, "rounded", "4px")
      r.setStyle(b, "white-space", "nowrap")
      r.setStyle(b, "overflow", "hidden")
      let text =
        if gOmnibar.isOpen and gOmnibar.query.len > 0:
          let c = min(gOmnibar.cursor, gOmnibar.query.len)
          "⌕ " & gOmnibar.query[0 ..< c] &
            (if gOmnibar.overwrite: "█" else: "▏") &
            gOmnibar.query[c .. ^1]
        elif gOmnibar.isOpen: "⌕ " & (if gOmnibar.overwrite: "█" else: "▏") &
                              OmnibarPlaceholder
        elif gTopLayout.omnibarField: "⌕ " & OmnibarPlaceholder
        else: "⌕"
      r.setAttribute(b, "data-ct-omnibar-placeholder",
                     $(gOmnibar.query.len == 0))
      r.setStyle(b, "color", chromeOf(
        if gOmnibar.isOpen and gOmnibar.query.len > 0: crTabActiveForeground
        else: crTabInactiveForeground))
      r.appendChild(b, r.createTextNode(text))
      gTopEls.add b
    of gtTab:
      let t = tabs[sg.index]
      let b = absBox(r, sg.rect)
      r.setAttribute(b, "data-ct-session-tab", t.title)
      r.setAttribute(b, "data-ct-tab-active", $t.active)
      r.setStyle(b, "padding-left", $TabPadPx & "px")
      for (k, v) in tabStyle(t.active): r.setStyle(b, k, v)
      r.appendChild(b, r.createTextNode(t.title))
      gTopEls.add b
  # PIN BUTTONS on every pane box. Drawn BEFORE the popovers and the
  # omnibar's results, which open over the panes' tab strips and must cover
  # them, and not at all under an overlay of the tree — a revealed pane, a
  # drag's drop indication (`pinButtonShown`, `overlayRects`).
  let covers = overlayRects()
  for n in gGeom.nodes:
    if n.kind != gnTabs:
      continue
    let pr = pinButtonRect(n)
    if not pinButtonShown(pr, covers):
      continue
    let pb = absBox(r, pr)
    r.setAttribute(pb, "data-ct-pin", n.panes[n.active])
    r.setStyle(pb, "justify", "center")
    r.setStyle(pb, "color", chromeOf(crTabInactiveForeground))
    r.appendChild(pb, r.createTextNode("⇲"))
    gTopEls.add pb
  # THE MENU'S POPOVERS: a native-looking menu — rows on the pane surface,
  # the open path and the highlight lifted, the chord right-aligned.
  for p in gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                            pendingViewportHeight):
    let box = absBox(r, p.rect, chromeOf(crPaneBackground))
    r.setAttribute(box, "data-ct-menu-popover", $p.folderPath)
    r.setStyle(box, "rounded", "6px")
    for (k, v) in paneOutlineStyle(true): r.setStyle(box, k, v)
    gTopEls.add box
    let levels = gMenu.openLevels()
    var lv: MenuLevelView
    for l in levels:
      if l.folderPath == p.folderPath: lv = l
    for row in p.rows:
      if row.item < 0:
        continue
      let it = lv.items[row.item]
      let rb = absBox(r, row.rect,
                      if it.active: chromeOf(crWindowBackground) else: "")
      r.setAttribute(rb, "data-ct-menu-item", it.label)
      r.setAttribute(rb, "data-ct-menu-active", $it.active)
      r.setStyle(rb, "padding-left", $TabPadPx & "px")
      r.setStyle(rb, "color", chromeOf(
        if not it.enabled: crTabInactiveForeground
        elif it.active: crTabActiveForeground
        else: crWindowForeground))
      if it.active:
        r.setStyle(rb, "font-weight", "bold")
      var label = it.label
      if it.shortcut.len > 0: label.add "   " & it.shortcut
      if it.folder: label.add "  ›"
      r.appendChild(rb, r.createTextNode(label))
      gTopEls.add rb
  # THE OMNIBAR'S RESULTS.
  let op = gpuiOmnibarPopover(gOmnibar, gTopLayout, pendingViewportHeight)
  if op.rows.len > 0:
    let box = absBox(r, op.rect, chromeOf(crPaneBackground))
    r.setAttribute(box, "data-ct-omnibar-results", $gOmnibar.results.len)
    for (k, v) in paneOutlineStyle(true): r.setStyle(box, k, v)
    gTopEls.add box
    for row in op.rows:
      let selected = row.item >= 0 and row.item == gOmnibar.selected
      let rb = absBox(r, row.rect,
                      if selected: chromeOf(crWindowBackground) else: "")
      r.setStyle(rb, "padding-left", $TabPadPx & "px")
      r.setStyle(rb, "white-space", "nowrap")
      r.setStyle(rb, "overflow", "hidden")
      let text =
        if row.item < 0: "no match"
        else:
          let e = gOmnibar.results[row.item].entry
          e.label & (if e.detail.len > 0: "   " & e.detail else: "")
      if row.item >= 0:
        r.setAttribute(rb, "data-ct-omnibar-result",
                       gOmnibar.results[row.item].entry.label)
      r.setStyle(rb, "color", chromeOf(if selected: crTabActiveForeground
                                       else: crWindowForeground))
      r.appendChild(rb, r.createTextNode(text))
      gTopEls.add rb
  # UNPIN on a revealed pane (the PIN buttons are drawn before the
  # popovers, below).
  if gGestures.revealing:
    let ub = absBox(r, unpinButtonRect(), chromeOf(crWindowBackground))
    r.setAttribute(ub, "data-ct-unpin", $gGestures.reveal.pane)
    r.setStyle(ub, "justify", "center")
    r.setStyle(ub, "rounded", "4px")
    for (k, v) in tabStyle(true): r.setStyle(ub, k, v)
    r.appendChild(ub, r.createTextNode("Unpin"))
    gTopEls.add ub
  # THE HOVER LABEL: a control's tooltip and key, or an auto-hide label's
  # pane, beside the pointer's target.
  var hoverText = ""
  var hoverAt = PxRect()
  if gHoverControl >= 0:
    let sg = gTopLayout.segOf(gtControl, gHoverControl)
    hoverText = controlTooltip(gHoverControl,
                               gMenu.shortcutFor(
                                 TransportControls[gHoverControl].clientAction))
    hoverAt = PxRect(x: sg.rect.x, y: sg.rect.y + sg.rect.h + 2,
                     w: textPx(hoverText) + 2 * TabPadPx, h: HoverLabelPx)
  elif gHoverSlot.len > 0:
    for st in gGeom.strips:
      for sl in st.slots:
        if sl.pane == gHoverSlot:
          hoverText = sl.label & " — click to show, drag to place"
          let w = textPx(hoverText) + 2 * TabPadPx
          hoverAt =
            case st.edge
            of leBottom: PxRect(x: sl.rect.x, y: sl.rect.y - HoverLabelPx - 2,
                                w: w, h: HoverLabelPx)
            of leTop: PxRect(x: sl.rect.x, y: sl.rect.y + sl.rect.h + 2,
                             w: w, h: HoverLabelPx)
            of leLeft: PxRect(x: sl.rect.x + sl.rect.w + 2, y: sl.rect.y,
                              w: w, h: HoverLabelPx)
            of leRight: PxRect(x: sl.rect.x - w - 2, y: sl.rect.y, w: w,
                               h: HoverLabelPx)
  if hoverText.len > 0:
    let hb = absBox(r, hoverAt, chromeOf(crWindowBackground))
    r.setAttribute(hb, "data-ct-hover-label", hoverText)
    r.setStyle(hb, "padding-left", $TabPadPx & "px")
    r.setStyle(hb, "white-space", "nowrap")
    for (k, v) in paneOutlineStyle(true): r.setStyle(hb, k, v)
    r.appendChild(hb, r.createTextNode(hoverText))
    gTopEls.add hb
  for e in gTopEls:
    r.appendChild(gRoot, e)
  writeGeometry()
  traceGesture("topbar menu=" & $gMenu.isOpen & " path=" & $gMenu.path &
               " highlight=" & $gMenu.highlight & " omnibar=" &
               $gOmnibar.isOpen & " query=" & gOmnibar.query & " results=" &
               $gOmnibar.results.len)

proc topBarGeometry(): JsonNode =
  ## PLAT-48: the top bar's parts and the open popovers, for aiming a pointer
  ## at a control, a menu title or a menu item (the geometry file's
  ## `topBar`). What a gesture DID is read from the window's pixels.
  proc rect(p: PxRect): JsonNode = %*[p.x, p.y, p.w, p.h]
  var top = newJObject()
  if not gMenu.isNil:
    var segs = newJArray()
    for sg in gTopLayout.segs:
      var label = ""
      case sg.part
      of gtControl: label = TransportControls[sg.index].id
      else: discard
      segs.add %*{"part": $sg.part, "index": sg.index, "label": label,
                  "rect": rect(sg.rect)}
    var pops = newJArray()
    let levels = gMenu.openLevels()
    for p in gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                              pendingViewportHeight):
      var rows = newJArray()
      for lv in levels:
        if lv.folderPath == p.folderPath:
          for row in p.rows:
            if row.item >= 0:
              rows.add %*{"label": lv.items[row.item].label,
                          "shortcut": lv.items[row.item].shortcut,
                          "active": lv.items[row.item].active,
                          "rect": rect(row.rect)}
      pops.add %*{"path": p.folderPath, "rect": rect(p.rect), "rows": rows}
    var results = newJArray()
    let op = gpuiOmnibarPopover(gOmnibar, gTopLayout, pendingViewportHeight)
    for row in op.rows:
      if row.item >= 0:
        results.add %*{"label": gOmnibar.results[row.item].entry.label,
                       "rect": rect(row.rect)}
    top = %*{"band": rect(gTopLayout.band), "segs": segs, "popovers": pops,
             "menuOpen": gMenu.isOpen, "menuPath": gMenu.path,
             "highlight": gMenu.highlight, "omnibarOpen": gOmnibar.isOpen,
             "query": gOmnibar.query, "results": results,
             "tick": (if gSession.isNil: 0'u64
                      else: gSession.getCurrentRRTicks())}
  top

proc refreshReplayWindow(r: GpuiRenderer) =
  ## After the debugger moved: the source window, the stop's panes, every
  ## live leaf drawn again from its ViewModel (the call trace with its whole
  ## count), the editor from a fresh surface, and the top bar (the controls'
  ## availability moved too).
  if gSession.isNil:
    return
  if not gSourceService.isNil:
    gSourceService.serveWindow()
  discard gSession.loadStopPanes()
  let editor = gPanes.getOrDefault($paneEditor)
  if not editor.isNil and not gSourceService.isNil:
    let surface = editorSurfaceFor(
      source = gSourceService.vm,
      editor = gSession.session.editorVM,
      state = gSession.session.stateVM,
      flow = gSession.session.flowVM,
      availability = gSourceService.availability(),
      budget = gpuiRowBudget(),
      medium = GpuiMedium,
      points = editorPointsOf(gSession.session.store.pointList.rows.val))
    # No heading in the window (PLAT-49): every child is the editor's own.
    while childCount(editor) > 0:
      r.removeChild(editor, nthChild(editor, childCount(editor) - 1))
    discard renderEditor(r, editor, sourcePaneView(GpuiMedium).root, surface)
    noteEditorTab(r, editorTabLabel(surface.path, false))
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin != paneEditor:
      let pane = gPanes.getOrDefault($leaf.builtin)
      if not pane.isNil and not leaf.vm.isNil:
        redrawWindowLeaf(r, pane, leaf)
  gOmnibar.setIndex(omnibarIndexOf(gSession.session.fileTreeVM,
                                   gSession.session.store, gMenu))
  drawTopBar(r)

proc performControl(r: GpuiRenderer; id: string) =
  ## A debugger control (or its menu item), through the transport
  ## ViewModel the desktop's toolbar calls (`DebugControlsVM`), then the
  ## engine's `stopped` + `ct/complete-move` consumed as the terminal's host
  ## consumes them.
  if gSession.isNil:
    return
  let vm = gSession.session.debugControlsVM
  if vm.isNil or not vm.transportAvailable(id):
    traceGesture("control " & id & " unavailable")
    return
  case id
  of "run-to-entry":
    gSession.gotoTick(0'u64)
  else:
    case id
    of "next": vm.stepForward()
    of "reverse-next": vm.stepBackward()
    of "step-in": vm.stepIn()
    of "step-out": vm.stepOut()
    of "reverse-step-in": vm.reverseStepIn()
    of "reverse-step-out": vm.reverseStepOut()
    of "continue": vm.continueExecution()
    of "reverse-continue": vm.reverseContinue()
    else: discard
    try:
      gSession.consumeNextCompleteMove()
    except CatchableError:
      discard
  traceGesture("control " & id & " tick=" & $gSession.getCurrentRRTicks())
  refreshReplayWindow(r)

proc showPaneFromMenu(r: GpuiRenderer; pane: PaneKind) =
  let layout = committedLayout()
  if layout.dockedIndex(pane) >= 0:
    let shown = beginReveal(layout, pane)
    if shown.isSome:
      gGestures.reveal = shown.get
  elif layout.tree.contains(pane):
    applyGestureCommand(r, cmdActivateTab(pane))
  discard drawArrangement(r)

proc openOmnibar(r: GpuiRenderer; query = "") =
  if gMenu.isOpen: gMenu.close()
  if not gSession.isNil:
    gOmnibar.setIndex(omnibarIndexOf(gSession.session.fileTreeVM,
                                     gSession.session.store, gMenu))
  gOmnibar.open(query)
  drawTopBar(r)

proc runGpuiMenuAction(r: GpuiRenderer; action: string) =
  traceGesture("menu action " & action)
  for c in TransportControls:
    if c.clientAction.len > 0 and c.clientAction == action:
      performControl(r, c.id)
      return
  case action
  of "findSymbol": openOmnibar(r, ":sym ")
  of "aFilesystem": showPaneFromMenu(r, paneFileTree)
  of "aFullCalltrace": showPaneFromMenu(r, paneCalltrace)
  of "aState": showPaneFromMenu(r, paneState)
  of "aEventLog": showPaneFromMenu(r, paneEventLog)
  of "aTimeline": showPaneFromMenu(r, paneTimeline)
  of "aTerminal": showPaneFromMenu(r, paneTerminalOutput)
  of "aScratchpad": showPaneFromMenu(r, paneScratchpad)
  of "aPointList": showPaneFromMenu(r, panePointList)
  of "aAgentActivity": showPaneFromMenu(r, paneAgentActivity)
  else: traceGesture("menu action " & action & " is not available here")
  drawTopBar(r)

proc acceptOmnibar(r: GpuiRenderer) =
  let (ok, entry) = gOmnibar.accept()
  if not ok:
    drawTopBar(r)
    return
  traceGesture("omnibar " & $entry.kind & " " & entry.label & " -> " &
               entry.target)
  case entry.kind
  of omTick, omSymbol:
    if entry.target.len > 0 and not gSession.isNil:
      try:
        gSession.gotoTick(parseBiggestUInt(entry.target))
      except ValueError:
        discard
      refreshReplayWindow(r)
      return
  of omCommand:
    runGpuiMenuAction(r, entry.target)
    return
  else:
    discard
  drawTopBar(r)

proc revealNext(r: GpuiRenderer) =
  ## `Ctrl+O`: reveal the first docked pane, then the next; after the last,
  ## hide — the strips' key (the terminal's `Ctrl+o`).
  let layout = committedLayout()
  if layout.docked.len == 0:
    return
  var next = 0
  if gGestures.revealing:
    for i, d in layout.docked:
      if d.pane == gGestures.reveal.pane:
        next = i + 1
  if next >= layout.docked.len:
    gGestures.reveal = noInteraction()
  else:
    let shown = beginReveal(layout, layout.docked[next].pane)
    gGestures.reveal = if shown.isSome: shown.get else: noInteraction()
  traceGesture(if gGestures.revealing: "revealed " & $gGestures.reveal.pane
               else: "reveal dismissed")
  discard drawArrangement(r)

proc handleTopKey(r: GpuiRenderer; key: string;
                  mods: seq[string]): bool =
  ## The window's keys for the top bar and the strips. Answers whether the
  ## key was taken. An open omnibar, then an open menu, own every key.
  if gMenu.isNil or gOmnibar.isNil:
    return false
  let k = key.toLowerAscii
  let ctrl = "control" in mods
  if gOmnibar.isOpen:
    case k
    of "escape", "esc": gOmnibar.close()
    of "enter", "return":
      acceptOmnibar(r)
      return true
    of "up": gOmnibar.moveSelection(-1)
    of "down": gOmnibar.moveSelection(1)
    of "backspace": gOmnibar.backspace()
    of "delete": gOmnibar.deleteForward()
    of "left": gOmnibar.moveCursor(-1)
    of "right": gOmnibar.moveCursor(1)
    of "home": gOmnibar.cursorHome()
    of "end": gOmnibar.cursorEnd()
    of "insert": gOmnibar.toggleOverwrite()
    of "space": gOmnibar.typeText(" ")
    else:
      if key.len == 1 and not ctrl:
        gOmnibar.typeText(key)
      else:
        return true
    drawTopBar(r)
    return true
  if gMenu.isOpen:
    # The desktop's cascade (PLAT-49): Up/Down within the open level, Right
    # (or Enter) into a folder's submenu, Left back out, Esc out and closed.
    case k
    of "escape", "esc": gMenu.escape()
    of "m":
      if ctrl: gMenu.close()
      else: gMenu.typeToSelect(key, int64(epochTime() * 1000))
    of "enter", "return":
      let act = gMenu.activate()
      if act.ran:
        runGpuiMenuAction(r, act.action)
        return true
    of "up": gMenu.moveHighlight(-1)
    of "down": gMenu.moveHighlight(1)
    of "right": discard gMenu.enterFolder()
    of "left": discard gMenu.leaveFolder()
    else:
      if key.len == 1 and not ctrl:
        gMenu.typeToSelect(key, int64(epochTime() * 1000))
    drawTopBar(r)
    return true
  # The desktop's chords: `CTRL+M` opens the menu (`aMenu`), the transport
  # and Find Symbol run their action.
  let chord = chordOfKey(key, mods)
  let bound = gBindings.actionForChord(chord)
  if bound == "aMenu":
    gMenu.open(keyboard = true)
    drawTopBar(r)
    return true
  if bound.len > 0 and gpuiMenuActionAvailable(bound):
    runGpuiMenuAction(r, bound)
    return true
  if ctrl and k == "p":
    openOmnibar(r)
    return true
  if ctrl and k == "o":
    revealNext(r)
    return true
  let step = sessionTabStepOf(key, mods)
  if step != 0 and not gShell.isNil:
    # The session tabs (`session_tabs.stepTab`, wrapping); one session has
    # no other tab, and the key is then taken and does nothing.
    if gShell.app.stepTab(step):
      traceGesture("session tab " & $gShell.app.activeTabIndex())
    drawTopBar(r)
    return true
  false

proc handleTopPress(r: GpuiRenderer; x, y: int): bool =
  ## A left press the top bar, a popover, a pin / unpin button or an open
  ## menu / omnibar takes. Answers whether it was taken.
  if gMenu.isNil:
    return false
  let band = gTopLayout.band
  if gMenu.isOpen:
    let pops = gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                                pendingViewportHeight)
    let (inside, path) = gpuiMenuHitAt(pops, gMenu, x, y)
    if inside:
      if path.len > 0:
        let act = gMenu.clickPath(path)
        if act.ran:
          runGpuiMenuAction(r, act.action)
          return true
      drawTopBar(r)
      return true
    if not band.contains(x, y):
      gMenu.close()
      drawTopBar(r)
      return true
  if gOmnibar.isOpen:
    let op = gpuiOmnibarPopover(gOmnibar, gTopLayout, pendingViewportHeight)
    if op.rect.contains(x, y):
      for row in op.rows:
        if row.item >= 0 and row.rect.contains(x, y):
          gOmnibar.select(row.item)
          acceptOmnibar(r)
          return true
      return true
    if not gTopLayout.segOf(gtOmnibar).rect.contains(x, y):
      gOmnibar.close()
      drawTopBar(r)
      if not band.contains(x, y):
        return true
  if gGestures.revealing and unpinButtonRect().contains(x, y):
    let pane = gGestures.reveal.pane
    gGestures.reveal = noInteraction()
    # Back where it was pinned from (`DockedPane.beside`).
    applyGestureCommand(r, cmdRestoreDocked(pane))
    discard drawArrangement(r)
    drawTopBar(r)
    return true
  let covers = overlayRects()
  for n in gGeom.nodes:
    if n.kind == gnTabs and pinButtonRect(n).contains(x, y) and
       pinButtonShown(pinButtonRect(n), covers):
      for k in PaneKind:
        if $k == n.panes[n.active]:
          applyGestureCommand(r, cmdDock(k, leBottom))
      discard drawArrangement(r)
      drawTopBar(r)
      return true
  if not band.contains(x, y):
    return false
  let hit = gTopLayout.topBarHitAt(x, y)
  if hit.index < 0 and hit.rect.w == 0:
    return true
  case hit.part
  of gtMenuButton:
    if gMenu.isOpen: gMenu.close() else: gMenu.open(keyboard = false)
  of gtControl:
    performControl(r, TransportControls[hit.index].id)
    return true
  of gtOmnibar:
    if not gOmnibar.isOpen:
      openOmnibar(r)
      return true
  of gtTab:
    discard gShell.app.activateTab(hit.index)
  drawTopBar(r)
  true

proc handleTopHover(r: GpuiRenderer; x, y: int) =
  ## The pointer moving with no button: a control's tooltip, an auto-hide
  ## label's hover label, an open menu's hovered item.
  if gMenu.isNil or (x, y) == gHoverAt:
    return
  gHoverAt = (x, y)
  var control = -1
  if gTopLayout.band.contains(x, y):
    let hit = gTopLayout.topBarHitAt(x, y)
    if hit.part == gtControl and hit.rect.w > 0:
      control = hit.index
  var slot = ""
  let (si, sj) = gGeom.slotAt(x, y)
  if si >= 0:
    slot = gGeom.strips[si].slots[sj].pane
  var changed = control != gHoverControl or slot != gHoverSlot
  gHoverControl = control
  gHoverSlot = slot
  if gMenu.isOpen:
    let pops = gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                                pendingViewportHeight)
    let (inside, path) = gpuiMenuHitAt(pops, gMenu, x, y)
    if inside and path.len > 0:
      let before = gMenu.revision
      gMenu.hoverPath(path)
      changed = changed or gMenu.revision != before
  if changed:
    drawTopBar(r)

var gVcsDirectory = ""
  ## The repository the VCS pane shows, re-read every `VCSRefreshIntervalMs`
  ## by `vcsTick`; "" when the window has no VCS pane.

proc attachVcs(leafSet: var GpuiLeafSet; directory: string) =
  ## Hand the VCS leaf, when the arrangement places one, the ViewModel the
  ## host read `directory` into. The headless replay session owns no VCS
  ## ViewModel (`headless_app.paneViewModel`), so the host supplies it.
  for leaf in leafSet.leaves.mitems:
    if leaf.kind == glkBuiltin and leaf.builtin == paneVcs:
      leaf.vm = ViewModel(openGpuiVcs(directory))
      gVcsDirectory = directory

proc vcsTick() {.cdecl.} =
  ## THE VCS PANE REFRESHES AS THE DESKTOP'S DOES: every
  ## `VCSRefreshIntervalMs` the loop calls this (`gpui_set_tick`, on the
  ## loop's own thread), the repository is read again, and the pane is drawn
  ## again when what it shows changed — so a file edited, added or committed
  ## in another program appears here as it does on the desktop and in the
  ## terminal, instead of the pane keeping the state it was opened with.
  if gVcsDirectory.len == 0:
    return
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == paneVcs and
       not leaf.vm.isNil:
      if refreshGpuiVcs(VCSVM(leaf.vm), gVcsDirectory):
        var r: GpuiRenderer
        let pane = gPanes.getOrDefault($paneVcs)
        redrawWindowLeaf(r, pane, leaf)
        applyTextFaces(r, pane)
        traceGesture("vcs refreshed")
      break

proc paintWindowChrome(root: GpuiElement) {.cdecl.} =
  ## The `root_builder` handed to `gpui_launch`, called from inside the shim
  ## before the event loop starts.
  ##
  ## **IT DOES NOT BUILD THE LEAVES**, and that is deliberate rather than
  ## incidental: `renderLeaves` has already run, on the caller's side, so
  ## `--report-plan` and the painted window are two readings of ONE tree. A
  ## builder that rendered a second time would make the plan a description of
  ## a different tree from the one on screen — two copies of one derivation,
  ## which is Verification-Harness-Traps §30 arriving through a callback.
  ##
  ## **IT STYLES FROM HERE AND NOT FROM `leaves.nim`.** The chrome is applied
  ## to the launch root and to the children of the leaf container, read back
  ## out of the shadow tree. That matters for a reason that is not aesthetic:
  ## `run-plat20-mutations.py`, `run-plat21-mutations.py`,
  ## `run-plat22-mutations.py` and `run-plat35-visual-mutations.py` all digest
  ## `leaves.nim` into their control comparators (§39a), so the chrome stays
  ## here. (PLAT-47 B1 did edit `leaves.nim` — the editor's colours are the
  ## editor's own — and those harnesses were regraded for it.)
  inc builderCalls
  var r: GpuiRenderer
  # The window surface. `apply_styles_to_div` in `gpui_app.rs` reads `bg`,
  # `w`, `h`, `flex_direction`, `p`, `m`, `gap`, `text_color`, `rounded`,
  # `items`, `justify` and `cursor` — and NOTHING ELSE. In particular it does
  # not read `display`, which is the only style `leaves.nim` sets, so the
  # tree as built carries no visual instruction at all.
  r.setStyle(root, "background-color", chromeOf(crWindowBackground))
  r.setStyle(root, "color", chromeOf(crWindowForeground))
  r.setStyle(root, "font-family", WindowFontFamily)
  r.setStyle(root, "width", "100%")
  r.setStyle(root, "height", "100%")
  # PLAT-48: A COLUMN — the top bar's band (reserved by a spacer; its parts
  # are placed absolutely from `window_top_bar`, the geometry the pointer
  # reads) above the arrangement.
  r.setStyle(root, "flex-direction", "column")
  r.setStyle(root, "padding", $ChromePaddingPx & "px")
  r.setStyle(root, "gap", $ChromeGapPx & "px")
  let topSpacer = r.createElement("div")
  r.setAttribute(topSpacer, "data-ct-top-bar", "spacer")
  r.setStyle(topSpacer, "width", "100%")
  r.setStyle(topSpacer, "height", $TopBarPx & "px")
  r.setStyle(topSpacer, "flex-shrink", "0")
  r.appendChild(root, topSpacer)

  let container = pendingOutcome.root
  r.setStyle(container, "width", "100%")
  r.setStyle(container, "height",
             $max(1, pendingViewportHeight - 2 * ChromePaddingPx -
                     GpuiTopBandPx) & "px")
  r.setStyle(container, "flex-direction", "row")
  r.setStyle(container, "gap", $ChromeGapPx & "px")

  # THE PANES ARE READ BACK OUT OF THE TREE, not counted from `leafSet`.
  # Reading the input and calling it an observation is §4a; the renderer is
  # handed what the tree holds, so the tree is what the widths are computed
  # from.
  var leaves: seq[GpuiElement] = @[]
  for i in 0 ..< childCount(container):
    let pane = nthChild(container, i)
    if not pane.isNil: leaves.add pane
  var painted = 0
  gRoot = root
  gContainer = container
  gPanes = initTable[string, GpuiElement]()
  for pane in leaves:
    let id = getAttribute(pane, "data-ct-pane")
    if id.len > 0 and id notin gPanes: gPanes[id] = pane
    stripHeading(r, pane)
  proc stylePane(pane: GpuiElement; w, h: int) =
    stylePaneBox(r, pane, w, h)
    # PLAT-38 — THE INPUT PROBE. The first pane is declared FOCUSABLE and is
    # given element focus, and a `keydown` listener records what the RUST
    # element store held when it ran.
    #
    # It is attached here rather than in `renderLeaves` for the reason the
    # chrome is: `gpui/app/leaves.nim` is digested into four mutation
    # harnesses' control comparators, and an edit there would stale all four
    # at once (§39a). It is attached to the FIRST pane rather than to every
    # pane because "the key reached the focused element and nothing else" is
    # the claim, and a listener on every pane would make the negative half
    # unobservable.
    if probeEnabled and painted == 0:
      setFocusable(pane)
      discard focusElement(pane)
      probeTarget = pane
      r.addEventListener(pane, "keydown", probeHandler(pane))
    inc painted

  # PLAT-45 — THE WINDOW DRAWS THE ARRANGEMENT IT WAS GIVEN, and since
  # PLAT-47 part B it draws it from `window_geometry.windowGeometryOf` — the
  # one computation the pointer's hit-test reads too — and draws it AGAIN
  # whenever a gesture moves it (`drawArrangement`). A `StackPanel` is a flex
  # row or column whose children get its sizes in pixels; a `TabPanel` shows
  # its ACTIVE leaf under a strip naming every tab. An inactive tab is not
  # painted, exactly as a desktop tab is not.
  var laidOut = false
  if not gShell.isNil and pendingDock != nil and gPanes.len > 0:
    for pane in leaves:
      r.removeChild(container, pane)
    laidOut = drawArrangement(r)
    if not laidOut:
      for pane in leaves:
        r.appendChild(container, pane)
  if not laidOut:
    # No document to follow (a refused projection draws its refusal as its
    # one leaf): the leaves tile one row, as they always have.
    let paneW = paneWidthPx(pendingViewportWidth, leaves.len)
    for pane in leaves:
      stylePane(pane, paneW, 0)
  elif probeEnabled:
    # The probe's pane: the first one DRAWN, in the arrangement's own order
    # (the geometry lists its nodes depth first, as they are drawn).
    for n in gGeom.nodes:
      if n.kind == gnTabs:
        let first = gPanes.getOrDefault(n.panes[n.active])
        if not first.isNil:
          setFocusable(first)
          discard focusElement(first)
          probeTarget = first
          r.addEventListener(first, "keydown", probeHandler(first))
        break

  # PLAT-44 — THE EDITOR TAKES KEYS. Attached here for the probe's reason:
  # `leaves.nim` is digested into four harnesses' controls.
  armEditorPane(r)
  # PLAT-47 — THE POINTER: a divider drag, a tab drag, the wheel. On the
  # window's root, which covers the whole window, so a drag that leaves the
  # pane it started in keeps reporting.
  armPointer(r, root)

  r.appendChild(root, container)
  drawTopBar(r)
  # PLAT-35. LAST, over the WHOLE window, because `drawArrangement` has by
  # now moved the leaves out of `container` and into the arrangement's own
  # boxes: a walk taken before it would have missed every pane it moved.
  # After `drawTopBar` (PLAT-48) for the same reason, one line later: the top
  # bar's own elements do not exist until it has run, and an element the walk
  # never reached keeps the window's inherited proportional face.
  applyTextFaces(r, root)

proc writeInputProbe(path: string; elapsedMs: int; deadlineMs: uint32): bool =
  ## PLAT-38. Write what the element store held, after the loop returned.
  ##
  ## **THE FINAL READINGS COME OUT OF THE STORE AGAIN**, not out of
  ## `probeArrivals`: the per-arrival list was taken from inside the handler
  ## and the totals are taken here, after `Application::run` returned, so the
  ## record outliving the event loop is itself observed rather than assumed.
  ##
  ## `endedOnDeadline` is written from the ELAPSED TIME against the deadline
  ## the caller armed. *"The backstop saved us"* and *"the work finished"* are
  ## different outcomes, and a capture that could not tell them apart would
  ## report a timeout as a delivery.
  var arrivals = newJArray()
  for a in probeArrivals:
    var mods = newJArray()
    for m in a.modifiers: mods.add newJString(m)
    arrivals.add %*{"key": a.key, "modifiers": mods, "kind": a.kind,
                    "seq": a.seqNo}
  let doc = %*{
    "probe": "plat38-input",
    "arrivals": arrivals,
    "deliverySeq": (if probeTarget.isNil: 0 else: probeTarget.lastEventSeq()),
    "deliveryCount": (if probeTarget.isNil: 0
                      else: probeTarget.deliveryCount()),
    "lastKey": (if probeTarget.isNil: "" else: probeTarget.lastEventKey()),
    "focusedCount": focusedCount(),
    "targetFocused": (if probeTarget.isNil: false else: isFocused(probeTarget)),
    "elapsedMs": elapsedMs,
    "deadlineMs": int(deadlineMs),
    "endedOnDeadline": deadlineMs > 0'u32 and elapsedMs >= int(deadlineMs)}
  try:
    writeFile(path, pretty(doc))
  except IOError as e:
    stderr.writeLine("codetracer-gpui: --input-probe: " & e.msg)
    return false
  true

proc loadAverage(): string =
  ## `/proc/loadavg`'s first three fields, or "" where there is none.
  try:
    readFile("/proc/loadavg").splitWhitespace()[0 .. 2].join(" ")
  except CatchableError:
    ""

proc writeFrameReport(path: string; loadStart, loadEnd: string;
                      elapsedMs: int; deadlineMs: uint32): bool =
  ## PLAT-42. The frame-timing record, read out of the shim after the loop.
  var frames, latencies: seq[int64] = @[]
  for i in 0'u64 ..< gpui_frame_count(): frames.add int64(gpui_frame_ns(i))
  for i in 0'u64 ..< gpui_key_latency_count():
    latencies.add int64(gpui_key_latency_ns(i))
  var doc = %*{
    "record": "plat42-frame-budget",
    "renderPathNs": frames,
    "keyToFrameNs": latencies,
    "loadAverageStart": loadStart,
    "loadAverageEnd": loadEnd,
    "cpus": countProcessors(),
    "elapsedMs": elapsedMs,
    "endedOnDeadline": deadlineMs > 0'u32 and
                       elapsedMs >= int(deadlineMs) - 500,
  }
  doc["keyHandlerMs"] = %handlerMs
  if not openArm.isNil:
    doc["documentLines"] = %openArm.doc.state.doc.countLines
    doc["keysApplied"] = %openArm.keys
    doc["viewportRows"] = %openArm.viewportRows
    doc["finalViewportTop"] = %openArm.viewportTop
    # Where the caret ENDED — the edit arm's own state after every key the
    # window delivered, so a lane that types a sequence can check the caret
    # as well as the file (a motion-only sequence leaves the file unchanged).
    doc["caretLine"] = %caretLine(openArm.doc)
    doc["caretColumn"] = %caretColumn(openArm.doc)
  try:
    writeFile(path, doc.pretty & "\n")
    true
  except CatchableError as e:
    stderr.writeLine("codetracer-gpui: --frame-report: " & e.msg)
    false

proc centreOf(r: PxRect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

proc removeMarkFiles() =
  ## The debugger controls' SVG files (`markSvgPath`) live in a directory of
  ## this process's own; it goes when the window does, so a run leaves
  ## nothing behind in the temporary directory.
  if gIconDir.len > 0:
    try: removeDir(gIconDir)
    except OSError: discard
    gIconDir = ""

proc runWindowOp(r: GpuiRenderer; op: string): string =
  ## One `--window-ops` event, through the window's own handlers
  ## (`windowPointer`, `windowKey`). A named target is aimed from the
  ## geometry the window drew — the same aim a user's pointer takes. Answers
  ## "" or why the event could not be aimed.
  let parts = op.split(':')
  proc at(i: int): int = parseInt(parts[i])
  proc pressAt(x, y: int) =
    windowPointer(r, gekPointerDown, x, y)
    windowPointer(r, gekPointerUp, x, y)
  try:
    case parts[0]
    of "key":
      let mods = if parts.len > 2: parts[2].split('+') else: @[]
      # An edit window's keys reach its editor (which holds the focus); a
      # replay window's, its top bar and gestures.
      if openArm.isNil: windowKey(parts[1], mods)
      else: editKey(parts[1], mods)
    of "press": windowPointer(r, gekPointerDown, at(1), at(2))
    of "move": windowPointer(r, gekPointerMove, at(1), at(2))
    of "release": windowPointer(r, gekPointerUp, at(1), at(2))
    of "menu":
      # PLAT-49: the desktop's menu — press the root button (when the menu
      # is not open), then the first-level item `parts[1]` in its popover,
      # which opens that folder's submenu beside it.
      if not gMenu.isOpen:
        let (bx, by) = centreOf(gTopLayout.segOf(gtMenuButton).rect)
        pressAt(bx, by)
      let pops = gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                                  pendingViewportHeight)
      if pops.len == 0:
        return "the menu did not open"
      let levels = gMenu.openLevels()
      for row in pops[0].rows:
        if row.item >= 0 and levels.len > 0 and
           levels[0].items[row.item].label == parts[1]:
          let (x, y) = centreOf(row.rect)
          pressAt(x, y)
          return ""
      return "no first-level menu '" & parts[1] & "' in the root popover"
    of "control":
      for sg in gTopLayout.segs:
        if sg.part == gtControl and TransportControls[sg.index].id == parts[1]:
          let (x, y) = centreOf(sg.rect)
          windowPointer(r, gekPointerMove, x, y)
          return ""
      return "no control '" & parts[1] & "' in the band"
    of "label":
      for st in gGeom.strips:
        for sl in st.slots:
          if sl.pane == parts[1]:
            let (x, y) = centreOf(sl.rect)
            pressAt(x, y)
            return ""
      return "no strip label for '" & parts[1] & "'"
    of "pin":
      for n in gGeom.nodes:
        if n.kind == gnTabs and parts[1] in n.panes:
          let (x, y) = centreOf(pinButtonRect(n))
          pressAt(x, y)
          return ""
      return "no pane box holds '" & parts[1] & "'"
    of "unpin":
      if not gGestures.revealing:
        return "nothing is revealed to unpin"
      let (x, y) = centreOf(unpinButtonRect())
      pressAt(x, y)
    of "hold":
      var src, dst = -1
      for i, n in gGeom.nodes:
        if n.kind == gnTabs and parts[1] in n.panes: src = i
        if n.kind == gnTabs and parts[2] in n.panes: dst = i
      if src < 0 or dst < 0:
        return "no pane box holds '" & parts[1] & "' or '" & parts[2] & "'"
      let n = gGeom.nodes[src]
      let (sx, sy) =
        if n.tabs.len > 0: centreOf(n.tabs[n.panes.find(parts[1])])
        else: (n.body.x + 40, n.body.y + 12)
      let (tx, ty) = centreOf(gGeom.nodes[dst].body)
      windowPointer(r, gekPointerDown, sx, sy)
      for k in 1 .. 6:
        windowPointer(r, gekPointerMove, sx + (tx - sx) * k div 6,
                      sy + (ty - sy) * k div 6)
    of "drag":
      for n in gGeom.nodes:
        if n.kind == gnTabs and parts[1] in n.panes:
          let (sx, sy) =
            if n.tabs.len > 0: centreOf(n.tabs[n.panes.find(parts[1])])
            else: (n.body.x + 40, n.body.y + 12)
          let (tx, ty) = (gGeom.area.x + gGeom.area.w div 2, gGeom.area.y - 3)
          windowPointer(r, gekPointerDown, sx, sy)
          for k in 1 .. 6:
            windowPointer(r, gekPointerMove, sx + (tx - sx) * k div 6,
                          sy + (ty - sy) * k div 6)
          windowPointer(r, gekPointerUp, tx, ty)
          return ""
      return "no pane box holds '" & parts[1] & "'"
    else:
      return "unknown event '" & op & "'"
  except ValueError, IndexDefect:
    return "malformed event '" & op & "'"
  ""

proc reportWindowPlan(cmd: GpuiCommand; outcome: LeafRenderOutcome;
                      dock: JsonNode): int =
  ## `--report-window-plan`: the window's root builder over a detached root,
  ## then `--window-ops`, then the root's render plan on stdout. The SAME
  ## `paintWindowChrome` `gpui_launch` calls, so what this prints is what a
  ## window draws — its top bar, strips, overlays and buttons — not a model
  ## of it.
  pendingOutcome = outcome
  pendingViewportWidth = cmd.width
  pendingViewportHeight = cmd.height
  pendingDock = dock
  builderCalls = 0
  probeEnabled = false
  var r: GpuiRenderer
  let root = r.createElement("div")
  paintWindowChrome(root)
  for op in cmd.windowOps:
    let failure = runWindowOp(r, op)
    if failure.len > 0:
      stderr.writeLine("codetracer-gpui: --window-ops: " & failure)
      return 1
  if not r.verifyRenderPlan(root):
    stderr.writeLine("codetracer-gpui: the window's render plan did not verify")
    return 1
  # The marks' SVG files STAY: the plan names them (`img src`) and they are
  # what a reader of the plan checks the drawn marks against. The reader
  # removes them (`test_plat48_gpui_plan.nim` does).
  echo r.renderPlanJson(root)
  0

proc capturePixels(cmd: GpuiCommand): int =
  ## PLAT-35 — THE WINDOW'S OWN SCENE, RENDERED OFF SCREEN.
  ##
  ## Called from `launchWindow` in place of `gpui_launch`, with the same
  ## `pending*` state already set, so the tree this renders is the tree
  ## that window would have painted and not a second derivation of it. The
  ## root builder is called from HERE, by hand, exactly once — the shim
  ## calls it for the window path, and nothing calls it off the window
  ## path, so the caller has to.
  ##
  ## **`builderCalls` IS ASSERTED THE SAME WAY THE WINDOW PATH ASSERTS
  ## IT.** A capture over a root the builder never populated renders an
  ## empty div, and an empty div at 1920x1080 is a correctly-sized buffer
  ## of one colour — which is indistinguishable from a renderer that could
  ## not draw, unless something says the tree was built.
  builderCalls = 0
  let root = gpui_create_element("div".cstring)
  if root.isNil:
    stderr.writeLine("codetracer-gpui: --pixels-out: the shim returned no " &
                     "root element")
    return 1
  paintWindowChrome(root)
  if builderCalls != 1:
    stderr.writeLine("codetracer-gpui: --pixels-out: the root builder ran " &
                     $builderCalls & " times, expected exactly 1")
    return 1
  let shot = renderRootToPixels(root, cmd.width, cmd.height)
  # The marks' SVG files GO, as they do when the window closes
  # (`launchWindow`), and UNLIKE `--report-window-plan`, which leaves them
  # because the plan it prints names them and a reader checks them. This path
  # prints no plan: the renderer has already rasterised them into `shot`, so
  # after this line nothing can read them and leaving them would leak a
  # temporary directory per capture. Added 2026-10-02 when PLAT-48's top bar
  # arrived ahead of this change — the capture path had no mark files to
  # remove before `drawTopBar` existed.
  removeMarkFiles()
  let failed = writeCapture(cmd.pixelsOut, shot, cmd.pixelsView,
                            cmd.pixelsScenario)
  if failed.len > 0:
    stderr.writeLine("codetracer-gpui: --pixels-out: " & failed)
    stderr.writeLine("codetracer-gpui: --pixels-out: the census is at " &
                     recordPathFor(cmd.pixelsOut))
    return 1
  # A BLANK FRAME IS A FAILURE AND NOT A FILE. The image and the census are
  # both on disk by now — a reader has to be able to see what was captured
  # in order to diagnose it — and the exit code refuses it, because a lane
  # that asserted only "the file exists" would pass on a buffer of zeroes.
  if shot.captureIsBlank:
    stderr.writeLine("codetracer-gpui: --pixels-out: the frame is " &
                     "indistinguishable from a blank screen (" &
                     $shot.nonZeroBytes & " of " & $shot.bytes &
                     " bytes non-zero, " & $shot.distinctByteValues &
                     " distinct byte values)")
    return 1
  echo "codetracer-gpui: captured ", cmd.width, "x", cmd.height, " to ",
       cmd.pixelsOut, " (", shot.nonZeroBytes, " of ", shot.bytes,
       " bytes non-zero, ", shot.distinctByteValues,
       " distinct byte values)"
  0

proc launchWindow(cmd: GpuiCommand; title: string;
                  outcome: LeafRenderOutcome; dock: JsonNode = nil): int =
  ## Open the window, run the event loop, and return when it stops.
  ##
  ## Returns the process exit code. The event loop's own termination is the
  ## first result, and it is a result rather than a formality: PLAT-19
  ## measured that a windowed client ran past a 12 s and a 90 s cap before
  ## `gpui_quit_after_ms` existed, because `gpui_launch` does not return while
  ## the window does.
  if cmd.reportWindowPlan:
    return reportWindowPlan(cmd, outcome, dock)
  pendingOutcome = outcome
  pendingViewportWidth = cmd.width
  pendingViewportHeight = cmd.height
  pendingDock = dock
  builderCalls = 0
  probeEnabled = cmd.inputProbe.len > 0
  probeArrivals = @[]
  probeTarget = nil
  probeSentinel = getEnv("CODETRACER_GPUI_PROBE_SENTINEL", "")
  # PLAT-35: the off-screen capture takes the place of the window, with the
  # tree already built above.
  if cmd.pixelsOut.len > 0:
    return capturePixels(cmd)
  if cmd.quitAfterMs > 0'u32:
    gpui_quit_after_ms(cmd.quitAfterMs)
  if gVcsDirectory.len > 0:
    gpui_set_tick(uint32(VCSRefreshIntervalMs), vcsTick)
  let loadStart = loadAverage()
  if cmd.frameReport.len > 0:
    gpui_frame_stats_reset()
  let startedAt = epochTime()
  gpui_launch(title.cstring, float(cmd.width), float(cmd.height),
              paintWindowChrome)
  let elapsedMs = int((epochTime() - startedAt) * 1000)
  removeMarkFiles()
  if cmd.frameReport.len > 0:
    if not writeFrameReport(cmd.frameReport, loadStart, loadAverage(),
                            elapsedMs, cmd.quitAfterMs):
      return 1
  if probeEnabled:
    if not writeInputProbe(cmd.inputProbe, elapsedMs, cmd.quitAfterMs):
      return 1
  if builderCalls != 1:
    # LOUD, not silent. `gpui_launch` calls the builder exactly once, before
    # the loop; zero calls means the shadow tree the renderer read was never
    # populated by this process, and a window that painted an empty tree is
    # indistinguishable from a window that painted nothing.
    stderr.writeLine("codetracer-gpui: the root builder ran " &
                     $builderCalls & " times, expected exactly 1")
    return 1
  0

proc editorRowsFor(layout: Layout; viewport: DockViewport;
                   cmd: GpuiCommand): int =
  ## How many source rows the editor pane of `layout` shows in this window:
  ## the window geometry's own answer (`window_geometry.editorRowsOf`), so
  ## the fetch window holds exactly the rows drawn, each a full line high.
  let proj = projectDock(layout, viewport)
  editorRowsOf(windowGeometryOf(layout,
                                (if proj.status == dpsRefused: nil
                                 else: proj.state),
                                cmd.width, cmd.height, GpuiTopBandPx))

proc editSurfaceFor(cmd: GpuiCommand; rows: int): EditorSurface =
  ## PLAT-22. **Edit mode's surface: the WORKING TREE, and no recording.**
  ##
  ## `product_mode.sourceContractFor(pmEdit)` is what decides this, and it is
  ## read rather than re-implemented — *"this is a core question, not a terminal
  ## one, and the answer applies to every front-end"*. It says the origin is the
  ## working tree, the model is a text buffer and NOT `SourceVM` (§2.1: *"Edit
  ## mode does not use `SourceVM`"*), so nothing here opens a recording, spawns
  ## a `replay-server` or constructs a source window.
  ##
  ## **PLAT-44: THIS FRONT-END NOW WRITES THE EDITING CORE** (`app/edit_arm`),
  ## and the history below is kept because it says why it could not before.
  ##
  ## **UNTIL PLAT-44 THIS FRONT-END DERIVED FROM THE EDITING CORE AND COULD NOT
  ## WRITE TO IT — AND THE REASON CHANGED UNDER PLAT-34, WHICH IS WORTH READING.**
  ##
  ## PLAT-22 gave the reason as the SUBSTRATE: *"PLAT-16's editing substrate is
  ## `isonim-tui`'s `TextAreaWidget` … and it is a TERMINAL widget: the
  ## `gpui-shell` lane links no `isonim_tui` at all."* That reason is now
  ## **retired rather than still true**. There is no widget on the editing
  ## path in either front-end; the buffer is `editing_core.EditingDocument`,
  ## which is pure Nim over `viewmodel/editor/` and links nothing this lane
  ## refuses. The document below is a real one and this surface is derived
  ## from it — not from a string this function read and split.
  ##
  ## **WHAT STILL MAKES IT READ-ONLY IS `isonim-gpui`, MEASURED BY PLAT-21:**
  ##
  ##   * `PLAT21-VG1` — `addEventListener` takes a `proc()` with no parameter
  ##     and `gpui_dispatch_event` carries no payload, so no key can be
  ##     delivered to a view at all;
  ##   * `PLAT21-VG3` — focus is per WINDOW; there is no element focus, so
  ##     there is nothing for a key to be delivered TO.
  ##
  ## Those were gaps in the renderer binding, not in this model, and PLAT-38
  ## closed both: a key reaches a focused element with its payload. So
  ## `mutableHere` is now `true`, the read-only notice is gone, and the
  ## contract and the surface agree.
  let problem = editProjectProblem(cmd.traceFolder)
  if problem.len > 0:
    return EditorSurface(medium: GpuiMedium, productMode: pmEdit,
                         report: problem)
  let listing = listProjectFiles(cmd.traceFolder)
  if listing.files.len == 0:
    # A project with no files is a REAL state and is reported as itself. The
    # `scanned` count is what tells it from a listing that read nothing:
    # zero files out of zero entries is an empty project, zero files out of
    # many is a defect in the walk (Verification-Harness-Traps §4).
    return EditorSurface(medium: GpuiMedium, productMode: pmEdit,
                         report: "no source files under " & cmd.traceFolder &
                                 " (" & $listing.scanned & " entries scanned)")
  let relative = listing.files[0]
  # THE DOCUMENT IS OPENED, NOT THE TEXT PASSED ON. One `EditingDocument`,
  # which is the same value the terminal's `EditBuffer` holds, and the surface
  # is a derivation of it.
  #
  # PLAT-44: it is held by an EDIT ARM now, because this front-end WRITES it.
  # The model is the user's stored choice, read through the same
  # `loadKeymapPreference` the terminal reads (PLAT-43's GPUI half: one
  # selector, two front-ends). A refused stored value is shown as the notice
  # and the product default runs, exactly as in the terminal.
  let preference = loadKeymapPreference()
  openArm = newGpuiEditArm(cmd.traceFolder, relative,
                           readProjectFile(cmd.traceFolder, relative),
                           preference.model)
  if preference.status == kplRefused:
    openArm.status = preference.message
  editViewportRows = rows
  gEditorTab = editorTabLabel(openArm.path, openArm.isDirty)
  openArm.surfaceOf(editViewportRows)

proc runEdit(cmd: GpuiCommand): int =
  ## `ct edit --ui=gpui <project>`, end to end, with NO recording open.
  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  let surface = editSurfaceFor(cmd,
    editorRowsFor(initLayout(sharedEditLayout().tree), shell.viewport, cmd))
  # `openWindow` and not `openWindowForSession`: there is no session. That is a
  # real product state rather than a test affordance — `shell.openWindow`'s own
  # header says so — and it is exactly the state edit mode is in, because edit
  # mode's subject is the working tree and a `HeadlessSessionSlot` is a replay
  # session.
  let windowId = WindowId(0)
  # PLAT-45: EDIT MODE OPENS THE SHARED EDIT DEFAULT — the arrangement the
  # desktop's edit mode and the terminal's show — at depth 0 (this front-end
  # has no pixel minimums, so it never folds). Not remembered: this product's
  # remembered file holds its Debug arrangement, as the terminal's does.
  let opened = shell.openWindow(windowId, initLayout(sharedEditLayout().tree))
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1
  var r: GpuiRenderer
  var leafSet = shell.leavesFor(windowId)
  # PLAT-47 deliverable 4: in Edit mode the VCS pane shows the project.
  if editProjectProblem(cmd.traceFolder).len == 0:
    attachVcs(leafSet, cmd.traceFolder)
  let drawn = renderLeaves(r, leafSet, surface)
  editPane = findEditorPane(drawn.root)
  # PLAT-47 part B: the window's gestures act on this shell; edit mode opens
  # its shared default and remembers nothing (PLAT-45).
  gShell = shell
  gWindow = windowId
  gRemember = false
  gLeafSet = leafSet
  if cmd.editKeys.len > 0:
    # PLAT-44, HEADLESS. The keys go through the SHIM'S OWN focus dispatch to
    # the editor pane's listener — the path a window's keys take — and not
    # into the arm directly. A window is created and told it holds focus,
    # because `sendKeyToFocus` answers 0 when no window does (PLAT-38's
    # negative twin), and a key that reached nothing must fail this run.
    if openArm.isNil or editPane.isNil:
      stderr.writeLine("codetracer-gpui: --edit-keys: there is no open " &
                       "document to type into")
      return 1
    armEditorPane(r)
    let win = gpui_create_window("codetracer-gpui --edit-keys",
                                 cdouble(cmd.width), cdouble(cmd.height))
    discard gpui_show_window(win)
    gpui_notify_focus(win, 1)
    for spec in cmd.editKeys:
      let (ok, ev) = gpuiKeyEventOf(spec)
      if not ok:
        stderr.writeLine("codetracer-gpui: --edit-keys: cannot spell '" &
                         spec & "' as a GPUI keystroke")
        return 1
      if sendKeyToFocus(KeyDownEvent, ev) != 1:
        stderr.writeLine("codetracer-gpui: --edit-keys: '" & spec &
                         "' reached no focused element")
        return 1
    gpui_reset_windows()
  # PLAT-45: the edit window's dock document, as `runOpen` writes its own.
  if cmd.dockOut.len > 0:
    try:
      writeFile(cmd.dockOut, pretty(shell.projectionFor(windowId).state) & "\n")
    except IOError as e:
      stderr.writeLine("codetracer-gpui: --dock-out: " & e.msg)
      return 1
  if cmd.reportPlan:
    if not leafPlanIsValid(r, drawn):
      stderr.writeLine("codetracer-gpui: the render plan did not verify")
      return 1
    echo leafPlanJson(r, drawn)
    return 0
  let editDock = shell.projectionFor(windowId)
  launchWindow(cmd, "CodeTracer — " & cmd.traceFolder & " [EDIT]", drawn,
               if editDock.status == dpsRefused: nil else: editDock.state)

proc runOpen(cmd: GpuiCommand): int =
  ## Open the recording, build the shell, draw the leaves.
  if cmd.product == pmEdit:
    return runEdit(cmd)
  let session = openGpuiTrace(cmd.traceFolder)
  # The shipped product default for the flow overlay — the same constant the
  # terminal host applies, pinned against `default_config.yaml` by a test.
  if not session.session.editorVM.isNil:
    session.session.editorVM.showFlowOverlay.val =
      FlowOverlayShownByDefault and not cmd.noFlowOverlay

  # PLAT-37. `--replay-ops`, applied BEFORE anything is projected or drawn,
  # because every pane's content is a function of where the debugger is
  # stopped.
  #
  # **THE PERFORMED COUNT IS ASSERTED AGAINST THE DECLARED ONE, EXACTLY.**
  # PLAT-35's Electron capture was validated against a corpus that counted
  # CLICKS rather than MOVES, so the recorded states were one operation
  # behind and two scenarios silently collided on one screen — which is the
  # population defect (§34) the scenario set exists to prevent. "At least one
  # operation ran" would be satisfied by a driver that stopped after the
  # first step, so the comparison is an equality (§4b).
  block replay:
    if cmd.replayOps.len == 0:
      break replay
    var performed = 0
    for op in cmd.replayOps:
      if op.kind == BreakpointOpKind:
        # A breakpoint is not a motion: it is applied to the SURFACE below,
        # against the editor's own first drawn row. It contributes nothing
        # to the motion count, which is why `declaredOperations` skips it.
        continue
      for _ in 0 ..< op.times:
        case op.kind
        of "stepIn": session.stepIn()
        of "next": session.stepForward()
        of "stepOut": session.stepOut()
        of "continueForward": session.continueForward()
        else:
          # Unreachable: `parseReplayOps` rejects anything else. Kept loud
          # rather than `discard`ed, because an `else` that swallows is how
          # a vocabulary grows a member nothing performs.
          stderr.writeLine("codetracer-gpui: no driver for operation '" &
                           op.kind & "'")
          return 1
        discard session.drainEvents()
        inc performed
    let declared = declaredOperations(cmd.replayOps)
    if performed != declared:
      stderr.writeLine("codetracer-gpui: performed " & $performed & " of " &
                       $declared & " declared operations")
      return 1

  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  # `toBackendService` is the adapter `headless_session` itself uses to inject
  # the stdio transport as the SDK's `BackendService` (spec §3.1). The shell
  # takes its backend BY INJECTION and never constructs one — that is
  # `HeadlessApp.openSession`'s own rule — so the host owns the process and the
  # shell owns nothing that can spawn.
  #
  # `adopt = session.sdk` IS THE WHOLE OF WHY THE PANES DRAW ANYTHING. Without
  # it `openSession` builds a SECOND `DebuggerSession` over the same transport,
  # in `dspCreated`, with nil panel ViewModels and an empty store — so
  # `leavesFor` reports every pane as not launched while this process holds a
  # live debugger. Measured on the shipped binary against `calc` before the
  # repair: five leaves, five `— waiting for the session to launch`, rc 0.
  # `headless_app.openSession`'s own doc comment carries the finding.
  # PLAT-40. A saved arrangement, when one was asked for. REFUSED rather than
  # replaced by the default when it cannot be read: a user who named a layout
  # and got another one would be looking at panes they did not ask for with
  # nothing saying so.
  #
  # THE WHOLE DOCUMENT, DOCKED PANES INCLUDED. `restoreLayoutDocument` rather
  # than the tree-only `restoreLayout`, which refuses any document with a
  # docked pane (`ldeDockedPanesUnsupported`) — so a layout the terminal
  # saved after `:dock bottom`, or one this front-end's own window wrote after
  # a dock, could not be opened here. The session slot holds a whole `Layout`,
  # and `openSession`'s `Layout` overload validates it as one.
  #
  # PLAT-45 DELIVERABLES 6 AND 8: WITHOUT `--layout`, THE WINDOW OPENS WHAT
  # THIS PRODUCT REMEMBERS — or the ONE SHARED DEFAULT every product opens
  # with (`layout_model.sharedDefaultLayout()`, at depth 0: this front-end has
  # no pixel minimums, so it never folds). The remembered arrangement is this
  # product's OWN file (`layout_memory.gpuiLayoutDocumentPath`), never the
  # terminal's or the desktop's. An unreadable one is REPORTED by kind and
  # left alone, and the window opens on the default rather than failing.
  var layout = sharedDefaultValue()
  var quarantined = false
  if cmd.resetLayout:
    let failed = resetGpuiLayout()
    if failed.len > 0:
      stderr.writeLine("codetracer-gpui: the remembered layout could not be " &
                       "removed: " & failed)
  elif cmd.layoutFile.len > 0:
    try:
      layout = restoreLayoutDocument(parseJson(readFile(cmd.layoutFile)))
    except CatchableError as e:
      stderr.writeLine("codetracer-gpui: --layout: cannot open '" &
                       cmd.layoutFile & "': " & e.msg.splitLines()[0])
      return 1
  else:
    let remembered = restoreGpuiLayout()
    layout = remembered.layout
    if remembered.status == grsUnreadable:
      quarantined = true
      stderr.writeLine("codetracer-gpui: " & remembered.message)
  let slot = shell.app.openSession(session.backend.toBackendService(),
                                   title = cmd.traceFolder,
                                   layout = layout,
                                   adopt = session.sdk)
  let windowId = WindowId(0)
  let opened = shell.openWindowForSession(windowId, slot.id)
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1

  # PLAT-45: THE WINDOW'S SCRIPTED GESTURE, through the shell's one door, and
  # WRITTEN THROUGH to this product's remembered layout — unless this session
  # started from a file it could not read, which is left exactly as it was
  # (the terminal's quarantine rule). No gesture, no document.
  if cmd.layoutOps.len > 0:
    for op in cmd.layoutOps:
      let applied = shell.applyIn(windowId, op)
      if applied.kind == wsRefused:
        stderr.writeLine("codetracer-gpui: --layout-ops: " & $op &
                         " was refused: " & $applied.problem.kind)
        return 1
    if quarantined:
      stderr.writeLine("codetracer-gpui: the rearranged layout was not " &
                       "saved: the remembered file could not be read and " &
                       "was left alone")
    else:
      let failed = saveGpuiLayoutDocument(shell.saveWindowLayout(windowId))
      if failed.len > 0:
        stderr.writeLine("codetracer-gpui: the layout could not be saved: " &
                         failed)

  # PLAT-22. THE PRODUCT MODE DECIDES WHICH PANE IS IN FRONT, and it does it
  # through `headless_app.activatePane` — which, measured on 2026-09-16, had
  # FIVE call sites and every one of them in `test_headless_app_entrypoint.nim`.
  # PLAT-14's own audit recorded that as *"no production caller in this
  # repository"*, PLAT-20 recorded it again, and this is the first route that
  # genuinely needs it: `ct --ui=gpui edit .` arrives with the editor as the
  # thing the user asked for, and a front-end that opened on the debug-controls
  # pane would be answering a different request.
  #
  # It is called for BOTH modes, not only for edit, so the call is on the
  # ordinary path rather than behind a flag nobody sets — a production caller
  # that only one command word reaches is one command word away from being no
  # production caller again.
  discard slot.activatePane(
    # PLAT-45: the shared default carries no debug-controls pane (the
    # desktop draws them as its toolbar), so Debug mode brings the call trace
    # to the front — the first tab of its stack, which it already is, so
    # this is the ordinary path doing nothing visible rather than a special
    # case.
    if cmd.product == pmEdit: paneEditor else: paneCalltrace)

  # The source window. PLAT-22: the editor is wired to the same `SourceVM` the
  # terminal's editor uses, and the host is what fills it — see
  # `gpui_host.newGpuiSourceService`. The row count is the editor pane's own
  # (`editorRowsFor`, from the window geometry), so a taller pane holds more lines
  # and `followExecutionPointer` scrolls the window the editor actually draws.
  let sourceService = newGpuiSourceService(session, cmd.traceFolder,
    editorRowsFor(shell.windows.windows[shell.windows.indexOf(windowId)].layout,
                  shell.viewport, cmd))
  sourceService.serveWindow()

  # THE VALUES IN SCOPE AT THE STOP, requested here because nothing else does.
  #
  # `StateVM.currentVariables` is filled by `ct/load-locals`, and the terminal's
  # `tui_session.refresh` is the only thing in this repository that asks for it.
  # Without this call the state pane renders "locals — no variables at this
  # position" and the editor shows no inline value, on every session, for ever —
  # which is the same "the mechanism works and nothing feeds it" shape as the
  # dock reader, `gpuiRowBudget` and `activatePane`. Measured on `calc` before
  # the call was added.
  #
  # TOTAL, like the terminal's: `requestAndLoadLocals` raises when the engine
  # declines, and a front-end that let that escape would drop a window over a
  # pane that would merely have been empty.
  #
  # PLAT-40: THE SAME PRODUCERS THE TERMINAL CALLS (`native_host`), so no pane
  # is fed on one native front-end and starved on the other. Until
  # 2026-09-23 this asked for the locals alone, and the call-trace pane drew
  # "no call trace has been loaded" on every recording.
  discard session.loadRecordingPanes()
  discard session.loadStopPanes()
  # PLAT-37. THE BREAKPOINT IS RESOLVED AGAINST THE RECORDING'S OWN SOURCE,
  # never against a literal. `--replay-ops=setBreakpoint@<row>` names an
  # offset into the FIRST ROW THE EDITOR ACTUALLY DREW, which is why the
  # surface is built twice: once to learn where the editor is looking, and
  # once with the point on it. A hardcoded line number would make the
  # scenario about this file rather than about the program, and would move
  # silently the next time the fixture's source changes.
  var points: seq[EditorPoint] = @[]
  let bpRow = breakpointRow(cmd.replayOps)
  if bpRow >= 0:
    let probe = editorSurfaceFor(
      source = sourceService.vm,
      editor = session.session.editorVM,
      state = session.session.stateVM,
      flow = session.session.flowVM,
      availability = sourceService.availability(),
      budget = gpuiRowBudget(),
      medium = GpuiMedium)
    if probe.rows.len == 0:
      stderr.writeLine("codetracer-gpui: --replay-ops asked for a breakpoint" &
                       " and the editor drew no rows to place it on")
      return 1
    let at = probe.rows[min(bpRow, probe.rows.high)].line
    # THROUGH THE ENGINE (PLAT-40), by the producer the terminal's `:break`
    # uses: the store's point list gets the line the engine VERIFIED, and the
    # editor draws what the store holds. Until 2026-09-23 this drew a point at
    # `at` without asking the engine anything, so the two front-ends could
    # mark different lines for one request.
    if not session.toggleBreakpoint(session.getCurrentFile(), at):
      stderr.writeLine("codetracer-gpui: --replay-ops: the engine refused a" &
                       " breakpoint at line " & $at)
      return 1
  points = editorPointsOf(session.session.store.pointList.rows.val)

  let surface = editorSurfaceFor(
    source = sourceService.vm,
    editor = session.session.editorVM,
    state = session.session.stateVM,
    flow = session.session.flowVM,
    availability = sourceService.availability(),
    budget = gpuiRowBudget(),
    medium = GpuiMedium,
    points = points)
  gEditorTab = editorTabLabel(surface.path, false)

  var r: GpuiRenderer
  var leafSet = shell.leavesFor(windowId)
  # PLAT-47 deliverable 4: the VCS pane draws the desktop's `VCSVM`, filled
  # from the repository the desktop would show for a replay — the process's
  # working directory.
  attachVcs(leafSet, getCurrentDir())
  let drawn = renderLeaves(r, leafSet, surface)
  # PLAT-47 part B: what the window's gestures and the call trace's paging
  # act on. A rearrangement is remembered on the terms `--layout-ops` is:
  # never over a quarantined file, and not for a session opened from a named
  # `--layout` file.
  gShell = shell
  gWindow = windowId
  gRemember = not quarantined and cmd.layoutFile.len == 0
  gSession = session
  gSourceService = sourceService
  # PLAT-48: the top bar's shared ViewModels. The menu is the product's tree
  # with what this window performs enabled, its chords none (the window has
  # no keymap of its own for the debugger yet); the omnibar searches the
  # session's files, the held call-trace section and the menu's commands —
  # the index the terminal builds for the same recording.
  gMenu = newMenuVM(nativeFrontEndMenu("CodeTracer"))
  gMenu.setEnabled(gpuiMenuActionAvailable)
  gBindings = desktopBindings()
  gMenu.setShortcuts(gBindings)
  gOmnibar = newOmnibarVM()
  gOmnibar.setIndex(omnibarIndexOf(session.session.fileTreeVM,
                                   session.session.store, gMenu))
  gLeafSet = leafSet
  gCalltraceLoads =
    if session.session.store.calltrace.lines.val.len > 0: 1 else: 0
  for i in 0 ..< childCount(drawn.root):
    let node = nthChild(drawn.root, i)
    if getAttribute(node, "data-ct-pane") == $paneCalltrace and
       getAttribute(node, "data-ct-state") == "live":
      setHeadingText(r, node, calltraceHeading())

  # PLAT-45: the window's projected dock document, for a reader that must
  # take the arrangement from this front-end's OWN output.
  if cmd.dockOut.len > 0:
    let projection = shell.projectionFor(windowId)
    try:
      writeFile(cmd.dockOut, pretty(projection.state) & "\n")
    except IOError as e:
      stderr.writeLine("codetracer-gpui: --dock-out: " & e.msg)
      return 1

  if cmd.reportPlan:
    # No window and no event loop: print what GPUI would execute and stop.
    # `verifyRenderPlan` is asserted rather than assumed, because a plan that
    # cannot be built is a defect this binary must not exit 0 over.
    if not leafPlanIsValid(r, drawn):
      stderr.writeLine("codetracer-gpui: the render plan did not verify")
      return 1
    echo leafPlanJson(r, drawn)
    return 0

  # PLAT-37. `--plan-out`: the INTROSPECTION reading of the very tree that is
  # about to be painted.
  #
  # **ONE TREE, TWO READINGS, AND THAT IS THE POINT.** The alternative — run
  # the binary once with `--report-plan` and once windowed — produces two
  # trees from two processes, and the OCR join would then be comparing the
  # strings one run reported against the pixels a different run drew. That is
  # not a weaker join, it is a join about nothing: `PLAT35-PD3` is a measured
  # case of this very front-end's locals arriving in five runs out of six, so
  # two runs genuinely can disagree.
  if cmd.planOut.len > 0:
    if not leafPlanIsValid(r, drawn):
      stderr.writeLine("codetracer-gpui: the render plan did not verify")
      return 1
    try:
      writeFile(cmd.planOut, leafPlanJson(r, drawn))
    except IOError as e:
      stderr.writeLine("codetracer-gpui: --plan-out: " & e.msg)
      return 1

  # PLAT-20 ENDED HERE, AND PLAT-37 IS WHERE IT STOPS ENDING HERE. The
  # sentence that used to close this function — *"entering an event loop that
  # dispatches input into `shell.applyIn` … is PLAT-21's"* — conflated two
  # things that turn out to be separable, and the separation is this
  # milestone's whole shape: ENTERING the loop and painting a frame is one
  # act, and DELIVERING INPUT into it is another.
  #
  # **PLAT-38 TOOK THE SECOND.** `PLAT21-VG1` (no payload on
  # `gpui_dispatch_event`) and `PLAT21-VG3` (focus per window rather than per
  # element) were measured defects in the renderer binding and are retired:
  # the shim's event ABI carries a payload, elements hold focus exclusively,
  # and `gpui_app.rs` attaches a real `on_key_down` to a tracked-focus root,
  # so a compositor key reaches the element store. What is still not here is a
  # BINDING from a key to a replay operation — that is PLAT-23's `--ui=gui`
  # contract, and `--replay-ops` is what stands in for it meanwhile.
  # `--input-probe` is the instrument that shows the delivery half works.
  let dock = shell.projectionFor(windowId)
  launchWindow(cmd, "CodeTracer — " & cmd.traceFolder, drawn,
               if dock.status == dpsRefused: nil else: dock.state)

proc main() =
  let cmd = parseGpuiCommand(commandLineParams())
  case cmd.kind
  of gckHelp:
    echo GpuiHelpText
    quit(0)
  of gckVersion:
    echo "codetracer-gpui " & gpuiFrontEndVersion()
    quit(0)
  of gckUsageError:
    stderr.writeLine(cmd.message)
    quit(2)
  of gckOpen:
    try:
      quit(runOpen(cmd))
    except CatchableError as e:
      stderr.writeLine("codetracer-gpui: " & e.msg.splitLines()[0])
      quit(1)

when isMainModule:
  main()
