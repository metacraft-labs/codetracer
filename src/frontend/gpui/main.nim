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
##
##      **A RUN THAT CANNOT OPEN A WINDOW NOW SAYS SO.** With the featureless
##      shim `gpui_launch` returned at once and this binary exited 0 having
##      shown nothing; with the windowed shim and no `DISPLAY` /
##      `WAYLAND_DISPLAY` GPUI picked its headless platform and `gpui_launch`
##      never returned. Both were silent. `launchWindow` now asks first
##      (`window_preflight.nim`: the shim's `gpui_has_window_backend` and the
##      display environment) and refuses by kind on stderr with exit 3,
##      `ExitNoWindow` — the terminal front-end's `ExitNoTerminal` number
##      (`codetracer-pm/spec/CLI/ct/ui-selection.md` §8a). The plan, the
##      window-plan and the pixel paths ask nothing and work everywhere.

when defined(js):
  {.error: "src/frontend/gpui is native-only: it opens a window.".}

import ./design_fonts
import std/[cpuinfo, json, math, options, os, sequtils, sets, strutils, tables,
            times]
when defined(posix):
  import std/posix   # PLAT-53: `tests:kill`

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
import ./welcome_leaf
import headless_app/welcome_tabs
import ./window_top_bar
import ./window_chrome                   # PLAT-69: the top bar as the title bar
import ../../common/window_policy        # PLAT-69: how the window opens
from ../../common/ct_home import ctConfigDir
from ../../ct/trace/ctfs_sources import readCtfsMetaDat
from ../viewmodel/platform/displayed_product import sessionDocumentTitle
import ./window_clicks
import ./window_preflight               # refuse by kind when no window can open
import ./list_scrubber
import ../viewmodel/views/debug_control_marks
import ../viewmodel/viewmodels/history_cursor   # history back / forward: the desktop's cursor rule
import ../viewmodel/viewmodels/[certificate_indicator_vm,
                                certificate_indicator_source]
import ../viewmodel/host/desktop_native   # the certificate indicator's host
import ./design_font_metrics
import ../tui/host/native_host   # `loadStopPanes`, the terminal's own producer
import ../tui/host/session_driver   # HSF-S1: what follows a control or a click, shared with the terminal
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
import ../viewmodel/keymap/alt_tap
import ../viewmodel/host/keybindings_file
import ../viewmodel/host/layout_preferences
import ../viewmodel/host/table_column_widths
import ../viewmodel/host/native_state
import ./host/gpui_host
import ./host/pixel_capture             # PLAT-35: `--pixels-out`'s capture
import headless_app/auto_hide_hover
import headless_app/footer_info
import headless_app/file_tree_menu   # K19: the Files pane's menu
from ../viewmodel/host/native_file_tree import wireNativeFileOperations
from backend/stdio_backend import sendDapRequestNoResponse, drainEvents
import headless_session   # `calltraceJumpByLine`, `requestAndLoadCalltrace`
import pane_viewport     # HSF-V2: a pane's size as the Viewport it reports
import ../viewmodel/viewmodels/vcs_vm   # `VCSVM`, `VCSRefreshIntervalMs`: the VCS pane's tick
import ../viewmodel/host/native_vcs_details   # PLAT-50: commit files, diffs
from std/unicode import runeLen
import ../viewmodel/viewmodels/[point_list_vm, scratchpad_vm, state_vm,
                                calltrace_vm, event_log_vm,
                                origin_chain_types]
# PLAT-52: the Terminal Output pane, drawn natively, and its producer.
import ./terminal_output_leaf
import ./search_results_leaf   # PLAT-57: Find in Files, drawn natively
import ./test_results_leaf     # PLAT-53: Test Results, drawn natively
import ./problems_leaf         # PLAT-55: Problems, drawn natively
# PLAT-55: the window's builds (`:build`, the terminal's runner) and the
# shared reader that fills its Problems pane — PLAT-56's Build Output reads
# the same `BuildSession`.
import ../tui/app/build_session
import ../tui/host/build_runner
import ../tui/host/build_problems
import ../viewmodel/host/native_test_host   # PLAT-53: the desktop's host, native producers
import ./agent_activity_leaf   # PLAT-54: Agent Activity, drawn natively
import ../viewmodel/host/native_agent_host   # PLAT-54: its host
import ../viewmodel/viewmodels/trace_open   # PLAT-54: a test's recording opened
import ../viewmodel/viewmodels/search_results_vm
from ../viewmodel/host/find_in_files import FindInFilesScope, running, pump
import ../viewmodel/host/terminal_output_source

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
                      hold:<pane>:<over>[:left|:strip|:outer-right] (its
                      tab dragged over another pane's centre — or its left
                      quarter, its first tab, or the layout's right edge —
                      not released)
                      hwheel:<pane>:<columns> (PLAT35-F3: a horizontal
                      wheel over a pane's centre, the delta in columns;
                      the editor / the terminal output scroll, clamped)
                      swheel:<pane>:<rows> (PLAT-70: the vertical wheel
                      with Shift held — a horizontal scroll)
                      wheel:<pane>:<lines> (M71, M73: the vertical wheel over a
                      pane's centre, positive toward the user)
                      vbar:editor:track:<permille>, vbar:editor:grab:<at>:<by>, vbar:editor:drag:<from>:
                      <to> (M73: the editor's vertical scrubber)
                      hbar:<pane>:track:<permille>, hbar:<pane>:drag:<from>:
                      <to>, hbar:terminalOutput:corner (PLAT-70: a text
                      pane's horizontal bar)
                    and (PLAT-50) a press on a pane's row, delivered to
                    the row as the window delivers a real press:
                      click:<part>:<key>[:left|right|middle[:ctrl|alt|
                      shift|ctrl+alt]] (part: file, event, header, var,
                      gutter, code, value, call, arg, tab, point,
                      scratch, position, vcsfile, commit, and PLAT-51's
                      statecontrol (key `history|origin|unwatch:<path>|
                      hide-other-process-watches:on|off`),
                      history (key `<ticks>`), addwatch, separator — a code
                      or value key `<line>@<column>`, an arg's
                      `<call>/<arg>`) and
                      ctx:<label> (an entry of the open right-click menu)
                    and (PLAT-51) a list pane's scrollbar scrubber:
                      scrub:<eventLog|calltrace>:track:<permille>
                      scrub:<eventLog|calltrace>:drag:<from>:<to>
                    and (PLAT-52) the Terminal Output pane:
                      term:view:<lines|screen>  term:line:<line>[:<col>]
                      term:track:<permille> (the line scrubber's track)
                      term:drag:<from>:<to> (its thumb, held and moved)
                      term:scrub:<from>:<to>[:hold] (the screen's scrubber)
                      term:key:<key>  term:wheel:<rows>
                    and (PLAT-68) a drag over the editor's text, and what
                    a key would resolve to, traced with no effect:
                      select:<line>@<column>:<line>@<column>
                      probe:<key>[:<mod>+<mod>]
                      modifiers:[<mod>+<mod>] (the held modifiers
                      changed: `modifiers:alt,modifiers:` taps Alt alone)
                    and (PLAT-57) Find in Files (`wait:<ms>` lets a search
                    stream to its end):
                      search:row:<index>
                      search:option:<case|word|regex>
                      search:field  search:wheel:<rows>
                      search:track:<permille>
                    and (PLAT-53) Test Results (`tests:wait` lets a run
                    settle):
                      tests:show  tests:run  tests:wait[:<ms>]
                      tests:row:<test>  tests:refresh:<test>
                      tests:open:<test>[:shift]  tests:key:<operation>
                      tests:kill  tests:wheel:<rows>
                    and (PLAT-55) Problems (`problems:wait` lets the build
                    settle):
                      problems:show  problems:build:<command>
                      problems:wait[:<ms>]  problems:row:<index>
                      problems:filter:<all|errors|warnings>
                      problems:group  problems:next  problems:previous
                      problems:key:<operation>  problems:wheel:<rows>
                    and (PLAT-69) what an open window's renderer reports:
                      resize:<width>:<height> (the content area resized)
                      chrome:<spec> (its frame changed; `--window-chrome`'s
                      spellings, `;` for a layout's commas)
  --width=<px>      Window width  (default 1440)
  --height=<px>     Window height (default 900)
                    PLAT-69: a window opens as the user configured it (the
                    `window:` entry of `.config.yaml`, which the desktop
                    reads too: maximized, restoring to 1900x1400, by
                    default). Either flag OVERRIDES that: the window opens
                    windowed at exactly the size given (the other dimension
                    from the setting), whatever `window.initial` says. The
                    paths that open no window (`--report-plan`,
                    `--report-window-plan`, `--pixels-out`) draw at these
                    sizes and read no setting.
  --window-chrome=<spec>
                    PLAT-69, with `--report-window-plan`: the window's frame,
                    which an open window reports for itself —
                    `server` (the platform draws it: no window buttons, no
                    drag strip) or `client` (the top bar is the title bar),
                    then `+`-separated parts: `maximized`, `no-minimize`,
                    `no-maximize`, `layout=<GNOME button-layout>` (e.g.
                    `client+layout=close,minimize,maximize:`). Default
                    `server`.
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
  --dividers=NAME   PLAT-50. strip (default: the gaps between panes in the
                    window's own ground, as the desktop's splitters) or
                    subtle (a 1px line in each gap between side-by-side
                    panes)
  --no-flow-overlay
                    Open with the flow overlay hidden (it is shown by default,
                    as `flow.enabled: true` ships).
  --focus-highlight=on|off
                    PLAT-51. The focused pane's tab strip and outline in the
                    focus colour (default on; the omnibox's "Focus
                    highlight" commands remember a choice).
  --live-resize=on|off
                    PLAT-51. Panes reflow while a divider is dragged (default
                    on); off draws a guide and reflows on release.
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

WHEN NO WINDOW CAN OPEN:
  a run that would open a window (none of `--report-plan`,
  `--report-window-plan`, `--pixels-out`) first checks that one can, and
  otherwise prints the reason and exits 3 instead of exiting 0 with nothing
  shown or waiting forever:
    the shim has no window backend — isonim-gpui's shim was built without
      `--features gpui-backend` (a bare `just rust-build`);
    no graphical session — on Linux, neither WAYLAND_DISPLAY nor DISPLAY is
      set (or ZED_HEADLESS is), so GPUI would run with no display.
  `--report-plan` checks the build without a window, on any host.

WHEN THE RECORDING DOES NOT OPEN:
  every run, `--report-plan` included, opens the recording first, and a
  recording the replay engine cannot open ends the run with the reason on
  stderr:
    exit 5 — the engine said it cannot read this recording (for example a
      container version this build does not implement); its own sentence is
      printed, and re-recording is the remedy;
    exit 4 — the engine accepted the recording and then sent nothing for
      30 s (one message's budget, not the whole open), so it stopped
      answering. stderr says whether that was while opening (re-recording
      may help) or after the recording opened (it will not: run again).
      Once the window takes input there is no such clock: an operation
      there may take as long as the engine needs.

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
    widthGiven, heightGiven: bool
      ## PLAT-69: `--width` / `--height` were on the command line, so the
      ## user's `window:` setting is overridden (`window_policy`).
    windowChrome: string
      ## PLAT-69: `--window-chrome`, the frame `--report-window-plan` draws
      ## for (`window_chrome.windowChromeOfSpec`). "" is `server`.
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
    reviewSession: string
      ## PLAT-54: `--review-session=<file>` — the agent session `ct review`
      ## resolved (the desktop's `--review-session`), shown in Agent Activity.
    reviewDataset: string
      ## PLAT-54: `--deepreview=<dataset>` — the review this window opens on
      ## (the desktop's `--deepreview`), entered into the VCS pane.
    keymap: string
      ## PLAT-68: `--keymap=<cua|emacs|vim|kakoune>`, this window only — the
      ## terminal's flag, through the same `sessionKeymap` precedence.
    focusHighlight: SettingOverride
      ## PLAT-51: `--focus-highlight=on|off` for this window, beating the
      ## remembered preference (`gpui-preferences`).
    liveResize: SettingOverride
      ## PLAT-51: `--live-resize=on|off`, likewise.
    overflowMarkers: SettingOverride
      ## PLAT-70: `--overflow-markers=on|off` (Horizontal-Overflow.md §4.6;
      ## off by default in this window, OQ-H1), likewise.
    layoutFlags: array[LayoutSetting, string]
      ## Every layout setting's flag value word for this window — the three
      ## above and PLAT-70 Part H's scrollbar options — "" when absent.
    subtleDividers: bool
      ## PLAT-50. `--dividers=subtle`: a 1px ui/border/secondary line in the
      ## vertical gaps between panes; `strip` (the default) leaves the gaps
      ## the window's own ground, the desktop's splitter colour.
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
        # `PLAT35-F3`: `hwheel` BELONGS IN THIS LIST AND WAS LEFT OUT OF IT.
        # Found at adversarial review 2026-10-03, measured rather than read:
        # `--report-window-plan --window-ops=hwheel:editor:43` answered
        # *"codetracer-gpui: --window-ops: unknown event 'hwheel:editor:43'"*
        # and exited 2, while `--help` documented the op and `runWindowOp` had
        # its arm. **This list is a SECOND spelling of `runWindowOp`'s own
        # `case` and that is what §30 is about** — two copies of one set, and
        # the copy nothing exercised was the wrong one. The op is now driven
        # by `test_plat48_gpui_plan.nim`, so an arm added to one and not the
        # other reddens by name instead of being discovered by hand.
        if head notin ["key", "press", "move", "release", "menu", "control",
                       "label", "pin", "unpin", "drag", "hold",
                       "hover-label", "wait", "tab", "tab-close",
                       "tab-add", "hwheel", "swheel", "hbar", "click",
                       # M73 (#840), M71 (#838): the plain vertical wheel.
                       "wheel", "vbar",
                       "ctx", "label-menu",
                       # PLAT-52: the Terminal Output pane's events.
                       "term",
                       # PLAT-51: a list pane's scrollbar scrubber, and
                       # text typed key by key (a Welcome Screen's form).
                       "scrub", "type",
                       # PLAT-68: a drag over the editor's text, and a
                       # key's resolution, probed.
                       "select", "probe", "modifiers",
                       # PLAT-57: Find in Files' rows, toggles and field.
                       "search",
                       # PLAT-53: Test Results' ▶, rows and controls.
                       "tests",
                       # PLAT-54: Agent Activity's rows and buttons.
                       "agent",
                       # PLAT-55: Problems' rows, buttons and builds.
                       "problems",
                       # PLAT-69: the window resized, its frame changed.
                       "resize", "chrome"]:
          return GpuiCommand(kind: gckUsageError,
            message: "codetracer-gpui: --window-ops: unknown event '" & op &
                     "'")
        result.windowOps.add op
    elif arg.startsWith("--width="):
      try: result.width = parseInt(arg["--width=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --width needs an integer")
      if result.width <= 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --width needs a positive number of pixels")
      result.widthGiven = true
    elif arg.startsWith("--height="):
      try: result.height = parseInt(arg["--height=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --height needs an integer")
      if result.height <= 0:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --height needs a positive number of pixels")
      result.heightGiven = true
    elif arg.startsWith("--window-chrome="):
      result.windowChrome = arg["--window-chrome=".len .. ^1]
      let chrome = windowChromeOfSpec(result.windowChrome)
      if not chrome.ok:
        return GpuiCommand(kind: gckUsageError,
                           message: "codetracer-gpui: " & chrome.message)
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
    elif arg.startsWith("--review-session="):
      result.reviewSession = arg["--review-session=".len .. ^1]
    elif arg.startsWith("--deepreview="):
      result.reviewDataset = arg["--deepreview=".len .. ^1]
    elif arg.startsWith("--keymap="):
      let name = arg["--keymap=".len .. ^1]
      let selection = selectKeymap(name, "--keymap")
      if not selection.ok:
        return GpuiCommand(kind: gckUsageError,
                           message: "codetracer-gpui: " & selection.refusal)
      result.keymap = name
    elif parseSettingFlag(arg).isFlag:
      # PLAT-51: the two layout preferences, for this window.
      let flag = parseSettingFlag(arg)
      if not flag.ok:
        return GpuiCommand(kind: gckUsageError,
                           message: "codetracer-gpui: " & flag.message)
      result.layoutFlags[flag.setting] = flag.word
      case flag.setting
      of lsFocusHighlight: result.focusHighlight = flag.value
      of lsLiveResize: result.liveResize = flag.value
      of lsOverflowMarkers: result.overflowMarkers = flag.value
      else: discard
    elif arg.startsWith("--dividers="):
      case arg["--dividers=".len .. ^1]
      of "strip": result.subtleDividers = false
      of "subtle": result.subtleDividers = true
      else:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: unknown dividers '" &
                   arg["--dividers=".len .. ^1] & "'; pick one of strip, subtle")
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
  # PLAT-69: a stand-in frame is for the plan of a window that is not open;
  # an open window reports its own, and a flag that silently lost to it
  # would be a test instrument that does nothing.
  if result.windowChrome.len > 0 and not result.reportWindowPlan:
    return GpuiCommand(kind: gckUsageError,
      message: "codetracer-gpui: --window-chrome stands in for a window's " &
               "frame in --report-window-plan; an open window reports its own")

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

const
  DiffAddedColour = DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
  DiffRemovedColour = DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
    ## PLAT-50 (K34): a diff's added and removed lines, the terminal's
    ## `srChromeSuccess` / `srChromeError` tokens.
  TracepointCommand = ":tracepoint "
  WatchCommand = ":watch "
    ## PLAT-51: the watch field (the Watches tab's "Add watch expression…"
    ## row opens the omnibar with it); `:unwatch EXPR` and
    ## `:watch-edit OLD -> NEW` remove and edit (the row controls).
    ## PLAT-50: the omnibar's tracepoint command ("Add tracepoint").
  CallsCommand = ":calls "
    ## The call trace's search field's omnibox prefix (`runWatchCommand`).

type
  GContent = object
    ## PLAT-50: a text over the window — an event's full content, a value's
    ## history, a value's origin, a changed file's diff.
    open: bool
    title, text: string
    diff: bool
      ## The text is a unified diff, its lines in the diff colours.
    top: int
      ## The first line shown (the wheel and Up / Down scroll it).
    refill: proc(top: int): string {.closure.}
      ## For a text whose lines are read as they are shown (a tracepoint
      ## sweep's hits, whose values are read by window): the text again with
      ## the lines around `top` read. Nil for a fixed text.

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
  gEditArms = initTable[string, GpuiEditArm]()
    ## K19 in Edit mode: every file the Files pane opened, by its absolute
    ## path, so switching back to one finds its buffer as it was left (an
    ## Edit buffer is never dropped by opening another file).
  gEditFiles = initTable[string, FilesystemVM]()
    ## K19 in Edit mode: each opened folder's Files model (`projectTreeOf`
    ## over the project walk, acting on the disk through
    ## `native_file_tree`), by the folder's absolute path — what the Files
    ## leaf of an Edit window or a folder tab draws.
  editViewportRows = 0
  gEditorSurface: EditorSurface
    ## **The surface the editor pane was last drawn from** (`PLAT35-F3`).
    ## Kept so a horizontal scroll can draw the rows again without rebuilding
    ## the surface from the session — a second derivation of one value is
    ## what §30 is about, and in Edit mode there is no session to rebuild it
    ## from at all.
  gEditorViewportPx = 0
    ## The editor pane's inner width, from the window's own geometry
    ## (`window_geometry.editorBodyWidthOf`). Zero until a window has been
    ## laid out, which is exactly the state in which no scrollbar is drawn.
  gEditorView: HorizontalView
    ## PLAT-70 (Horizontal-Overflow.md §4): the editor's horizontal view —
    ## how far right its code is scrolled, the document's exact content
    ## width, the pane's code columns. Moved by the caret
    ## (`editing_core.followView`, before every draw), the wheel and the bar;
    ## clamped by the shared model and never here.
  gEditorFollow: CaretFollow
    ## The caret the view last followed (§4.5: only the caret moves it).
  gEditorBarDrag = false
    ## A press held on the editor bar's thumb: the view follows the pointer.
  gTableBarDrag: tuple[active: bool, pane: PaneKind]
    ## PLAT-70 Part I: a press held on a table pane's sideways bar's thumb.
  gEditorVBarDrag = false
    ## M73 (#840): a press held on the editor's VERTICAL scrubber's thumb: the
    ## source window follows the pointer.
  pendingOutcome: LeafRenderOutcome
    ## The leaf tree, built BEFORE `gpui_launch` so `--report-plan` and the
    ## window path derive from one render rather than two.
  pendingViewportWidth = 0
  pendingViewportHeight = 0
    ## The window's content size in logical pixels: the launch size, and
    ## since PLAT-69 whatever the renderer last reported (`windowResized`) —
    ## every layout below is computed from these two.
  gLaunch = resolveWindowLaunch(DefaultWindowSetting)
    ## PLAT-69: how the window was asked to open (`applyWindowPolicy`).
  gWindowTitle = "CodeTracer"
    ## PLAT-69: what the window is called (`windowTitleFor`).
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
             of gekPointerDown, gekPointerMove, gekPointerUp, gekWheel,
                gekContextMenu, gekAuxDown:
               "pointer"
             of gekModifiers: "modifiers"
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
var armedEditPane: GpuiElement = nil
  ## The element `armEditorPane` gave the Edit window's key listener.
  ## Whether the editor pane already has its listener — the headless
  ## `--edit-keys` path arms it before the window builder would.

proc drawArrangement(r: GpuiRenderer): bool

proc shownWelcome(): NativeWelcome
  ## PLAT-51: forward-declared; defined with the welcome tabs.
proc drawWelcome(r: GpuiRenderer): GpuiElement
proc folderShown(): bool
proc welcomeKey(r: GpuiRenderer; key: string; mods: seq[string]): bool
proc welcomePress(r: GpuiRenderer; x, y: int): bool

var
  gAutoHide = initAutoHideHover()
    ## PLAT-49 part B: the pointer's timing over the auto-hide labels.
  gHoverClockOffsetMs = 0'i64
    ## What `--window-ops`'s `wait:<ms>` advanced the hover clock by.
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

proc drawTerminalPane(r: GpuiRenderer)
proc drawSearchPane(r: GpuiRenderer)
proc drawTestsPane(r: GpuiRenderer)
  ## PLAT-53: forward-declared; defined beside Find in Files' drawing.
proc drawAgentPane(r: GpuiRenderer)
  ## PLAT-54: forward-declared; defined beside Find in Files' drawing.
proc drawProblemsPane(r: GpuiRenderer)
  ## PLAT-55: forward-declared; defined beside Test Results' drawing.
  ## PLAT-57: forward-declared; defined beside the Terminal Output pane's.
  ## PLAT-52: the Terminal Output pane, drawn natively (defined with its
  ## clicks, before `windowPointer`).

proc drawEditorBody(r: GpuiRenderer; pane: GpuiElement;
                    sticky: seq[tuple[line: int; text: string; top: int]] = @[])
  ## PLAT-70: forward-declared; defined with the window's editor helpers.

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
  gEditorSurface = openArm.surfaceOf(editViewportRows)
  drawEditorBody(r, editPane)
  noteEditorTab(r, editorTabLabel(openArm.root / openArm.path, openArm.isDirty))
  applyTextFaces(r, editPane)

proc cancelWindowGesture(): bool
  ## PLAT-47: `Esc` during a layout gesture (defined with the gestures below).

proc editOverlayKey(key: string; mods: seq[string]): bool
  ## K19: forward-declared; defined with Edit mode's Files tree.
proc leaveFilesField(r: GpuiRenderer)
  ## K19: likewise.

proc editKey(key: string; mods: seq[string]) =
  ## One key of an EDIT window's editor pane: its `keydown` listener's body,
  ## and what `--window-ops`' `key:` dispatches in an edit window (the editor
  ## holds the focus there).
  if openArm.isNil: return
  # K19: the Files pane's name field or Delete question takes the keys
  # while it is open; an open right-click menu closes on `Esc`.
  if editOverlayKey(key, mods):
    return
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
  armedEditPane = editPane
  setFocusable(editPane)
  discard focusElement(editPane)
  r.addEventListener(editPane, "keydown", editKeyHandler(editPane))

proc focusEditKeys() =
  ## K19: the Edit window's keys back to its editor's listener — the one
  ## place they are read (`editKey`, which gives the Files pane's open name
  ## field or question its keys first). A press on the Files pane gave that
  ## pane the focus, and it has no listener in an Edit window.
  if not editPane.isNil and editPane == armedEditPane:
    discard focusElement(editPane)


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
  gAgent: GAgentPane = GAgentPane(scroll: initFeedScroll())
    ## PLAT-54: Agent Activity's reading position and held thumb.
  gAgentHosts = initTable[int, NativeAgentHost]()
    ## PLAT-54: each session's Agent Activity host, by the session's address
    ## (`agentHost`): the desktop's `AgentActivityVM` over that session's
    ## store, so a live agent's session is the one its tab reports.
  gSearch = initGSearchPane()
  gTests = initGTestsPane()
    ## PLAT-53: the Test Results pane's reading position and selection.
  gTestsVM: TestResultsVM = nil
    ## PLAT-53: the WINDOW's Test Results ViewModel — its project's tests
    ## (`Test-Results-Pane.md` §8.2), shared by every tab of the window.
  gTestsHost: NativeTestHost = nil
    ## PLAT-53: the desktop's host over the native producers
    ## (`viewmodel/host/native_test_host`), installed on `gTestsVM`.
  gPointerShift = false
    ## PLAT-53: whether Shift was held with the pointer event being handled
    ## (`pointerHandler`), so a press on `⏵` arms it as the desktop's does.
  gTestsRoot = ""
    ## PLAT-53: the window's project (§8.2) — its working directory for a
    ## replay, the project of the Edit window, a folder tab's folder.
  gProblems: BuildProblems = nil
    ## PLAT-55: the WINDOW's Problems ViewModel and the reader that fills it
    ## from the window's builds (`tui/host/build_problems`), shared by every
    ## tab: a build is of the working tree.
  gProblemsPane = initGProblemsPane()
    ## PLAT-55: the Problems pane's reading position and a held scrubber.
  gBuild: RunningBuild = nil
    ## PLAT-55: the window's `:build` in flight, or the last one (the
    ## terminal's runner, `tui/host/build_runner`).
  gBuildRoot = ""
    ## PLAT-55: where a `:build` runs — the window's project, as for the
    ## terminal's `:build` (the Edit window's folder, a folder tab's, a
    ## replay's working directory).
    ## PLAT-57: Find in Files' reading position and a held scrubber thumb.
  gSessionsOpened = initTable[int, HeadlessDebugSession]()
    ## PLAT-49 part B: every session this window holds, by its tab's id —
    ## the one it opened with and each the strip's "+" opened.
  gRecordings: seq[OmnibarEntry] = @[]
    ## The recordings the "+"'s `:open ` lists (`recordingsBeside`).
  gOpenCmd: GpuiCommand
  gCtxMenu: ContextMenuState
    ## PLAT-50: the open right-click menu (`headless_app/pane_clicks`).
  gContent: GContent
    ## PLAT-50: a text over the window (`GContent`).
  gMaximised = none(PaneKind)
    ## PLAT-50 (K7): the pane whose container "Maximise container" shows
    ## alone, until "Minimise container".
  gTracepointsRun = 0
    ## PLAT-50: how many tracepoints the omnibar swept (each its own id).
  gTracepointAt: tuple[path: string, line: int]
    ## PLAT-50: the line the editor menu's "Add tracepoint" was chosen on;
    ## the omnibar's `:tracepoint <expression>` is placed there.
  gPressDedupe: PressDedupe
    ## PLAT-50: the press the deepest row answered (`window_clicks`).
  gViewedFile = ""
    ## PLAT-50: a file opened from the Files pane, shown in the editor until
    ## the debugger next moves.
  gTerminal = initGTerminalPane()
    ## PLAT-52: the Terminal Output pane's own state — where the reader
    ## scrolled, a scrubber held by the pointer, whether its keys are its own.
  gSourceService: GpuiSourceService = nil
    ## The editor's source window (moved up with PLAT-50, which reads its
    ## provider to open a file).
    ## The command the window was opened with (a new tab's editor rows).
  gLeafSet: GpuiLeafSet
  gCalltraceLoads = 0
    ## How many call-trace sections the window has read (the first, at open,
    ## included) — reported for the paging test.
  gDebugDocs = initTable[string, EditingDocument]()
    ## PLAT-68: THE DEBUG-MODE EDITOR'S DOCUMENTS, by path — each file the
    ## editor showed, opened from the recording as an `EditingDocument` with
    ## PLAT-33's read-only filter (the terminal's `runtime.debugBuffer` is
    ## the same value). PLAT-51's CARET (Editor-Pane.md, "The caret in a
    ## read-only editor": placed by a click, moved by the keys, distinct
    ## from the execution pointer) and the selection ARE the shown file's
    ## document's; copy and the motions act on it, edits are refused, and
    ## `editor.toggle-read-only` (`Ctrl+E`) makes the same document
    ## writable. No document for a path: no caret drawn in it.
  gTextDrag = false
    ## PLAT-68: a left press on the editor's text is held — the pointer's
    ## motion extends the selection from where it was pressed.
  gRouter: KeymapRouter
    ## PLAT-68: **THE WINDOW'S KEYMAP** — the active base, the user's
    ## `keybindings.json` over it and the pushed layers of the open
    ## overlays, resolved by the one router every front-end runs
    ## (Base-Keymaps-And-Layer-Stack.md §6). Every replay-window key the menu,
    ## a shown text, the Welcome Screen and the Terminal Output pane do not
    ## own resolves here.
  gAltTap: AltTap
    ## PLAT-68: whether the press of `Alt` in progress is still a tap
    ## (`windowModifiers`).
  gKeybindings: KeybindingsLoad
    ## The user's `keybindings.json` as it last loaded, for the re-read when
    ## it changes on disk.
  gListDrag: ListScrubDrag
    ## PLAT-51: a press held on the Event Log's or the Call Trace's
    ## scrollbar scrubber thumb.
  gEventLogLoads = 0
    ## PLAT-51: how many event-log windows the scrubber has read — reported
    ## for the bounded-fetch test.
  gWelcomeTabs = initWelcomeTabs()
    ## PLAT-51 deliverable 8: the tabs the "+" opened that are not (yet)
    ## replay sessions — the Welcome Screen, or an Edit-mode folder.
  gWelcomes: seq[NativeWelcome] = @[]
    ## Each welcome tab's screen (`viewmodels/native_welcome`), parallel to
    ## `gWelcomeTabs.tabs`.
  gWelcomeLayout: WelcomeLayoutPx
    ## Where the shown Welcome Screen's rows were drawn (the press hit-test).
  gRecentFolders: seq[string] = @[]
  gRecordJob: NativeRecordJob = nil
  gRecordSerial = -1
  gTestJob: NativeRecordJob = nil
    ## The top bar's run-tests, running (`native_host.startRecordTestJob`).
  gFolderArms = initTable[int, GpuiEditArm]()
    ## A folder tab's editing core (`app/edit_arm`), by the tab's serial.
  gLayoutSettings = productDefaults(lpGpui)
    ## PLAT-51: the focus highlight and live resize for this window — the
    ## remembered preference, then the flags (`--focus-highlight`,
    ## `--live-resize`), then the omnibox's commands.
  gFocusPane = $paneEditor
    ## PLAT-51: the FOCUSED pane — the one last pressed (the desktop's
    ## selected panel follows its clicks), the editor until then.
  gEditorGeometryDrawn = false
    ## Whether the replay editor has been drawn against the window's geometry
    ## (the first frame's leaves are rendered before there is one).
  gFocusShown = false
    ## Whether the focus highlight is drawn yet: from the first press on a
    ## pane, as the desktop outlines its selected panel only once one has
    ## been clicked (the editor holds the keys before that, unmarked).
  gestureTrace = getEnv("CODETRACER_GPUI_GESTURE_TRACE", "") == "1"
    ## One stderr line per gesture step, for a window lane's record.

var
  gMainShell: GpuiShell = nil
    ## The replay shell (its sessions, its window) — `gShell` while a session
    ## or a welcome tab is shown.
  gEditShell: GpuiShell = nil
    ## A FOLDER tab's shell: one window on the shared Edit default and no
    ## session (`GpuiShell.openWindow`'s own "window with no session" state).
    ## A shell of its own because a pane is in one window of a set at most
    ## (`wpPaneInTwoWindows`), and the editor is in both arrangements.

proc mainShell(): GpuiShell =
  if gMainShell.isNil: gShell else: gMainShell

proc drawListScrubbers(r: GpuiRenderer)
  ## PLAT-51: forward-declared for the window's redraws.

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
  CalltraceRowPx = CallRowPx
    ## One call-trace row (`leaves.CallRowPx`, the height each is drawn at).
    ## The pixel pitch of one call-trace row in the window — one line of the
    ## pane's text face, measured off the window (26 px from one row to the
    ## next at the shim's default text size). The pane pages by it: the rows
    ## it asks the ViewModel for are the rows that fit, so the last call
    ## scrolled to is on screen, not clipped below the pane.

proc drawTopBar(r: GpuiRenderer)
proc toolAvailable(tool: GToolButton): bool
  ## PLAT-48: the top bar over the window (defined with its handlers below).
proc handleTopPress(r: GpuiRenderer; x, y: int): bool
var gCellHover: HoverClock
  ## The truncated cell the pointer rests on, and since when (§5.3).
var gCellHoverAnchor: tuple[x, y, h, bodyRows: int]
  ## Where that cell was drawn (window px) and its pane's body rows.
var gCellTooltip: seq[string]
  ## The tooltip shown, once the 500 ms are up.

const CellTooltipAttribute* = "data-ct-cell-tooltip"
  ## On the tooltip's box: the cell's row key and column.
var gColumnDrag: tuple[active, moved: bool; col: EventLogColumn;
                       left, grab, startX: int]
  ## An Event Log column separator held: the column, its left (window px),
  ## and where on the grip it was taken (px right of the column's edge), so
  ## a press and release in place leave the width as it was (`moved`: the
  ## pointer left `startX`, the press's x).

proc dismissCellHover(r: GpuiRenderer)
proc pressEventSeparator(r: GpuiRenderer; x, y: int): bool
proc pressEllipsis(r: GpuiRenderer; x, y: int): bool
proc dragEventSeparator(r: GpuiRenderer; x: int; release: bool)
proc showTableDetail(r: GpuiRenderer)
proc resizeEventLogColumn(r: GpuiRenderer; arg: string)
proc rememberEventLogWidths(vm: EventLogVM)
proc applyRememberedColumnWidths()
proc windowSessionFacts(): SessionFacts
proc windowScopePath(): ScopePath
  ## PLAT-70 Part B: forward-declared; defined with the table panes' hover
  ## (and the router's facts, below).
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

proc editorTopInsetPx(): int =
  ## Where the editor's first drawn row starts below its pane's top. At the
  ## top of a file, the desktop's 4 px. Scrolled — the window centred on a
  ## stop (`SourceVM.followExecutionPointer`) — Monaco's sub-row offset too:
  ## it reveals a line with its top at the viewport's middle, so the first
  ## WHOLE line starts `(viewport div 2) mod lineHeight` down (5 px in the
  ## 1920x1080 editor, line 22 at y 75 for a stop on line 44), the line
  ## above it cut off under the band.
  let i = gGeom.tabsNodeOfPane($paneEditor)
  if i < 0 or gEditorSurface.viewportTop <= 1:
    return EditorPadTopPx
  let viewport = gGeom.nodes[i].body.h - EditorPadTopPx
  # At the file's end Monaco rests its last line (the empty one after a
  # final newline counted) on the bottom edge (`GpuiSourceService
  # .bottomAligned`): the window's rows are drawn so, which can start them
  # above the editor's top — a NEGATIVE inset, the rows above cut off.
  if not gSourceService.isNil and gSourceService.bottomAligned:
    # Monaco's scroll height counts the horizontal scrollbar's band under
    # the last line (`scrollBeyondLastLine: false`): the last line rests
    # that band above the bottom edge.
    let shown = gSourceService.monacoLineCount - gEditorSurface.viewportTop + 1
    return EditorPadTopPx + viewport - EditorHScrollBandPx -
           shown * GpuiEditorRowPx
  EditorPadTopPx + (viewport div 2) mod GpuiEditorRowPx

proc stylePaneBox(r: GpuiRenderer; pane: GpuiElement; w, h: int;
                  id = "") =
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
  # The pane's content inset (`window_geometry.paneInsetOf`), the editor's
  # top moving with its scroll (`editorTopInsetPx`).
  let inset = paneInsetOf(if isEditor: $paneEditor else: id)
  r.setStyle(pane, "padding", "0px")
  r.setStyle(pane, "padding-top",
             $(if isEditor: max(0, editorTopInsetPx()) else: inset.top) & "px")
  r.setStyle(pane, "padding-right", $inset.right & "px")
  r.setStyle(pane, "padding-bottom", $inset.bottom & "px")
  r.setStyle(pane, "padding-left", $inset.left & "px")
  r.setStyle(pane, "rounded", $TabRadiusPx & "px")
  # (No heading to colour since PLAT-49: the window strips it, and the
  # pane's tab strip names the pane.)

const
  TabPinIcon = staticRead("../../public/resources/menu/lm_pin_tab_dark.svg")
    ## The desktop's tab icons (`LAYOUT_TAB_PIN_ICON_PATH`,
    ## `LAYOUT_TAB_CLOSE_ICON_PATH`, `styles/default_dark_theme.styl`).
  TabCloseIcon = staticRead("../../public/resources/menu/lm_close_tab_dark.svg")

proc tabIconSvgPath(svg: string): string

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
    # PLAT-51: the focused pane — the one last pressed — when the focus
    # highlight is on: its outline AND its tab strip in the focus colour.
    let focusedHere = gLayoutSettings.focusHighlight and gFocusShown and
                      activePane == gFocusPane
    r.setAttribute(box, "data-ct-focus-frame", $focusedHere)
    r.setStyle(box, "flex-direction", "column")
    r.setStyle(box, "width", $n.rect.w & "px")
    r.setStyle(box, "height", $n.rect.h & "px")
    # No fill of its own: the strip shows the window's ground between its
    # tabs, as the desktop's transparent header does; the body is filled.
    r.setStyle(box, "rounded", $TabRadiusPx & "px")
    r.setStyle(box, "position", "relative")
    if not n.strip.isEmpty:
      let strip = r.createElement("div")
      r.setAttribute(strip, "data-ct-tabs", n.labels.join(","))
      r.setStyle(strip, "flex-direction", "row")
      r.setStyle(strip, "flex-shrink", "0")
      r.setStyle(strip, "height", $TabStripPx & "px")
      r.setStyle(strip, "padding-top", $TabTopPx & "px")
      r.setStyle(strip, "gap", $TabGapPx & "px")
      # The tabs a drop placeholder pushes apart stay inside the stack
      # (GoldenLayout's header clips them).
      r.setStyle(strip, "overflow", "hidden")
      # PLAT-51: the focus colour's ground, on the focused pane. Otherwise the
      # window's own: the desktop's header is transparent over its ground.
      r.setAttribute(strip, "data-ct-strip-focused", $focusedHere)
      if focusedHere:
        for (key, value) in stripStyle(focusedHere):
          r.setStyle(strip, key, value)
      # PLAT-51: GOLDENLAYOUT'S TAB-DROP PLACEHOLDER — during a drag over
      # this strip, a `GlPlaceholderPx` gap before the tab the drop would
      # land at; the tabs after it move right, as GoldenLayout's do.
      let ph = gGestures.placeholderOf()
      let gapAt = if ph.found and ph.stackPath == n.path: ph.index else: -1
      proc gapEl(r: GpuiRenderer): GpuiElement =
        result = r.createElement("div")
        r.setAttribute(result, "data-ct-tab-placeholder", $gapAt)
        r.setStyle(result, "width", $int(GlPlaceholderPx) & "px")
        r.setStyle(result, "flex-shrink", "0")
      # THE DESKTOP'S TABS (`components/golden_layout.styl`, measured on the
      # Electron front-end 2026-10-17): every tab a rounded chip on the panel
      # surface, its title in the label face at 14 px — the active one in the
      # label tier, the others in the disabled tier — and a pin and a close
      # icon at its right end, at 40% on a tab at the back. The ACTIVE tab
      # runs on down into its pane's body, square at the bottom, so tab and
      # panel are one shape (`.lm_active`'s box-shadow bridge). Each tab is
      # exactly as wide as the geometry says, so a click and a drop caret
      # land where the tab is drawn.
      let ground = if isEditor: EditorGround else: chromeOf(crPaneBackground)
      for t, label in n.labels:
        if t == gapAt:
          r.appendChild(strip, gapEl(r))
        let active = t == n.active
        let tab = r.createElement("div")
        r.setAttribute(tab, "data-ct-tab-active", $active)
        # PLAT-50: which pane the tab is, for its right-click menu.
        if t < n.panes.len:
          r.setAttribute(tab, TabPaneAttribute, n.panes[t])
        r.setStyle(tab, "width", $n.tabs[t].w & "px")
        r.setStyle(tab, "height",
                   $(if active: TabStripPx - TabTopPx else: TabHeightPx) & "px")
        r.setStyle(tab, "flex-shrink", "0")
        r.setStyle(tab, "flex-direction", "column")
        # On a strip in the focus colour (PLAT-51's highlight, which the
        # desktop's sheets do not have) a tab at the back shows the strip's
        # ground, so the selected tab is told apart by its own (PLAT-68's
        # `TabGroundContrastFloor`); elsewhere every tab is on the panel
        # surface, as the desktop draws them.
        if focusedHere and active:
          # …and the selected one is lifted off the focus colour onto the
          # window's ground (`chrome.tabStyle`'s PLAT-68 rule).
          r.setStyle(tab, "background-color", chromeOf(crTabStripBackground))
        elif not focusedHere:
          r.setStyle(tab, "background-color",
                     if active: ground else: chromeOf(crPaneBackground))
        r.setStyle(tab, "rounded", $TabRadiusPx & "px")
        if active:
          r.setStyle(tab, "border-bottom-left-radius", "0px")
          r.setStyle(tab, "border-bottom-right-radius", "0px")
        # The tab's own row, `TabHeightPx` high: the active tab's bridge is
        # below it.
        let row = r.createElement("div")
        r.setStyle(row, "flex-direction", "row")
        r.setStyle(row, "items", "center")
        r.setStyle(row, "height", $TabHeightPx & "px")
        r.setStyle(row, "flex-shrink", "0")
        r.setStyle(row, "padding-left", $TabTitleInsetPx & "px")
        r.setStyle(row, "padding-right", $TabTitleInsetPx & "px")
        r.appendChild(tab, row)
        let title = r.createElement("div")
        r.setStyle(title, "flex-grow", "1")
        r.setStyle(title, "flex-shrink", "1")
        r.setStyle(title, "overflow", "hidden")
        r.setStyle(title, "white-space", "nowrap")
        r.setStyle(title, "font-size", "14px")
        r.setStyle(title, "line-height", "18px")
        # `.lm_title`: the active tab's in ui/text/primary/label (#c8c8c8,
        # measured), the others' in the disabled tier.
        r.setStyle(title, "color",
                   if active: DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark]
                   elif focusedHere: chromeOf(crTabFocusedForeground)
                   else: chromeOf(crTabInactiveForeground))
        var shown = label
        for k in PaneKind:
          if t < n.panes.len and $k == n.panes[t] and label == labelOf($k):
            shown = desktopTabTitle(k)
        r.appendChild(title, r.createTextNode(shown))
        r.appendChild(row, title)
        for (icon, side, gapAfter) in [(TabPinIcon, TabPinPx, 4),
                                       (TabCloseIcon, TabClosePx, 0)]:
          let img = r.createElement("img")
          r.setAttribute(img, "src", tabIconSvgPath(icon))
          r.setStyle(img, "width", $side & "px")
          r.setStyle(img, "height", $side & "px")
          r.setStyle(img, "flex-shrink", "0")
          if not active:
            r.setStyle(img, "opacity", "0.4")
          r.appendChild(row, img)
          if gapAfter > 0:
            let gap = r.createElement("div")
            r.setStyle(gap, "width", $gapAfter & "px")
            r.setStyle(gap, "flex-shrink", "0")
            r.appendChild(row, gap)
        r.appendChild(strip, tab)
        if active:
          # `.lm_active::before` / `::after`: the tab flares into its panel
          # with a 6 px concave corner on each side that has a neighbour.
          for (side, x) in [(-1, n.tabs[t].x - n.rect.x - TabRadiusPx),
                            (1, n.tabs[t].x - n.rect.x + n.tabs[t].w)]:
            if (side < 0 and t == 0) or (side > 0 and t == n.labels.high):
              continue
            let corner = r.createElement("div")
            r.setAttribute(corner, "data-ct-tab-flare", $side)
            r.setStyle(corner, "position", "absolute")
            r.setStyle(corner, "left", $x & "px")
            r.setStyle(corner, "top", $(TabStripPx - TabRadiusPx) & "px")
            r.setStyle(corner, "width", $TabRadiusPx & "px")
            r.setStyle(corner, "height", $TabRadiusPx & "px")
            r.setStyle(corner, "overflow", "hidden")
            r.setStyle(corner, "background-color", ground)
            let hole = r.createElement("div")
            r.setStyle(hole, "position", "absolute")
            r.setStyle(hole, "left", $(if side < 0: -TabRadiusPx else: 0) & "px")
            r.setStyle(hole, "top", $(-TabRadiusPx) & "px")
            r.setStyle(hole, "width", $(2 * TabRadiusPx) & "px")
            r.setStyle(hole, "height", $(2 * TabRadiusPx) & "px")
            r.setStyle(hole, "rounded", $TabRadiusPx & "px")
            r.setStyle(hole, "background-color", chromeOf(crWindowBackground))
            r.appendChild(corner, hole)
            r.appendChild(box, corner)
      if gapAt >= n.labels.len:
        r.appendChild(strip, gapEl(r))
      r.appendChild(box, strip)
    if not leaf.isNil:
      stylePaneBox(r, leaf, n.body.w, n.body.h, activePane)
      # The body's corner under the active tab is square where that tab is
      # the first or the last of its strip — the tab and the panel are one
      # shape there (`.lm_stack:has(... .lm_active:first-child)`).
      # Both are set on every draw: a leaf is moved between arrangements,
      # never rebuilt, and keeps the corners its last one gave it.
      let flat = not n.strip.isEmpty
      r.setStyle(leaf, "border-top-left-radius",
                 (if flat and n.active == 0: "0" else: $TabRadiusPx) & "px")
      r.setStyle(leaf, "border-top-right-radius",
                 (if flat and n.active == n.labels.high: "0"
                  else: $TabRadiusPx) & "px")
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
    # The bottom strip is the window's footer (PLAT-49 part B), drawn with
    # the top bar's absolutely placed parts (`drawFooter`).
    if st.edge != leBottom:
      byEdge[st.edge] = drawStrip(r, st, revealed)
  if byEdge[leLeft].isNil and byEdge[leRight].isNil and byEdge[leTop].isNil:
    return tree
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

proc dockedPaneBox(r: GpuiRenderer; paneId: string; rect: PxRect;
                   focused: bool): GpuiElement =
  ## A docked pane drawn in `rect` — previewed over the tree (`focused`, in
  ## the focus outline) or docked open beside it — named by a one-tab strip
  ## as every pane box is (PLAT-49: the leaf draws no heading in the window).
  ## The pane's element is MOVED into the box, never rebuilt. Nil when the
  ## window has no element for that pane.
  let pane = gPanes.getOrDefault(paneId)
  if pane.isNil or rect.isEmpty:
    return nil
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $rect.x & "px")
  r.setStyle(result, "top", $rect.y & "px")
  r.setStyle(result, "width", $rect.w & "px")
  r.setStyle(result, "height", $rect.h & "px")
  r.setStyle(result, "flex-direction", "column")
  r.setStyle(result, "background-color", chromeOf(crPaneBackground))
  r.setStyle(result, "rounded", "4px")
  for (key, value) in paneOutlineStyle(focused):
    r.setStyle(result, key, value)
  let parent = r.parentNode(pane)
  if not parent.isNil:
    r.removeChild(parent, pane)
  let label = labelOf(paneId)
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
  r.appendChild(result, strip)
  stylePaneBox(r, pane, rect.w - 2 * FocusOutlinePx,
               max(1, rect.h - 2 * FocusOutlinePx - TabStripPx))
  r.appendChild(result, pane)

proc drawOverlay(r: GpuiRenderer) =
  ## The drag's transient state, drawn over the arrangement: the drop tint
  ## over exactly the region the drop would take and — for a join — the
  ## insertion caret (both from `dropIndicationRects`, i.e. from the model's
  ## `dropIndicationOf`), and the ghost label following the pointer.
  for e in gOverlay:
    r.removeChild(gRoot, e)
  gOverlay = @[]
  # PLAT-50: `--dividers=subtle` — a 1px ui/border/secondary line down the
  # middle of each gap BETWEEN SIDE-BY-SIDE panes, below their tab strips
  # (a strip row stays the strips' ground, so two strips connect). The
  # default draws nothing: the gaps are the window's own ground, the colour
  # of the desktop's splitters and of the strips.
  if gOpenCmd.subtleDividers:
    for d in gGeom.dividers:
      if not d.horizontal or d.rect.w <= 0 or d.rect.h <= TabStripPx:
        continue
      let line = quad(r, PxRect(x: d.rect.x + d.rect.w div 2,
                                y: d.rect.y + TabStripPx, w: 1,
                                h: d.rect.h - TabStripPx),
                      chromeOf(crFieldBorder))
      r.setAttribute(line, "data-ct-divider-line", d.container & "/" &
                                                   $d.index)
      gOverlay.add line
  # PLAT-49 part B: A DOCKED PANE SHOWN OPEN, in the band the tree gave up
  # (`windowGeometryOf`'s `openDock`) — beside the arrangement, not over it.
  if not gGeom.openDock.isEmpty:
    let box = dockedPaneBox(r, gGeom.openDockPane, gGeom.openDock,
                            focused = false)
    if not box.isNil:
      r.setAttribute(box, "data-ct-docked-open", gGeom.openDockPane)
      gOverlay.add box
  # A REVEALED DOCKED PANE, over the tree against its own edge, in the
  # focused pane's outline — never reflowing the arrangement behind it.
  if gGestures.revealing:
    let box = dockedPaneBox(r, $gGestures.reveal.pane,
                            gGeom.revealRectOf(gGestures.reveal.edge),
                            focused = true)
    if not box.isNil:
      r.setAttribute(box, "data-ct-revealed", $gGestures.reveal.pane)
      gOverlay.add box
  let ind = gGestures.indication()
  let action = DesignTokenHex[dtColorsUiBorderAction][dmDark]
  if ind.kind != diNone:
    let ph = gGestures.placeholderOf()
    let (tint, caret) = gGeom.dropIndicationRects(
      ind, (if ph.found: int(GlPlaceholderPx) else: 0))
    if not tint.isEmpty:
      let q = quad(r, tint, action & DropTintAlpha)
      r.setAttribute(q, "data-ct-drop", $ind.kind)
      gOverlay.add q
    if not caret.isEmpty:
      let c = quad(r, caret, action & DropCaretAlpha)
      r.setAttribute(c, "data-ct-drop-caret", $ind.slot)
      gOverlay.add c
  # PLAT-51 (Layout-ViewModel §4.3a): with live resize OFF, the arrangement
  # stays until the release and a GUIDE shows where the divider would land.
  if gGestures.kind == gkResize and not gLayoutSettings.liveResize:
    let guide = gGestures.resizeGuideOf(gGeom)
    if not guide.isEmpty:
      let g = quad(r, guide, action & DropCaretAlpha)
      r.setAttribute(g, "data-ct-resize-guide", "1")
      gOverlay.add g
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

proc editorVBarRectAsDrawn(): tuple[rect: PxRect; v: EditorVScroll]
  ## M73: defined with the editor's bars, below.

proc editorVScrollbarGeometry(rect: proc (p: PxRect): JsonNode): JsonNode =
  ## The editor's vertical scrubber as the window placed it (M73), for a lane
  ## to AIM at: its track, its thumb and its current-position mark in window
  ## pixels, the thumb's corner radius, and whether it is SHOWN (the pointer
  ## over the editor; hidden, every part is drawn at opacity 0). Null while
  ## the file fits. PLAT-47 B1 reads the execution band's two halves against
  ## it — the band colour up to the track's left edge, the thumb over the band
  ## across its width (Scrollbar-Scrubbers.md §4.1) — so the edge the record
  ## expects is the window's stated one, not one measured off the same pixels.
  let (bar, v) = editorVBarRectAsDrawn()
  if bar.h <= 0:
    return newJNull()
  %*{"rect": rect(bar),
     "thumb": rect(PxRect(x: bar.x, y: bar.y + v.thumbTopPx, w: bar.w,
                          h: v.thumbPx)),
     "thumbRadius": EditorScrollbarThumbRadiusPx,
     "mark": (if v.markTopPx < 0: newJNull()
              else: rect(PxRect(x: bar.x, y: bar.y + v.markTopPx, w: bar.w,
                                h: EditorScrollbarMarkPx))),
     "shown": editorScrollbarShown}

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
  # PLAT-70 Part B: the Event Log's columns as drawn (window px), so a lane
  # aims at a column separator (its grip is the cell's right `EventSeparatorPx`).
  var eventColumns = newJArray()
  let ev = gGeom.tabsNodeOfPane($paneEventLog)
  if ev >= 0 and not gSession.isNil and not gSession.session.eventLogVM.isNil:
    let body = gGeom.nodes[ev].body
    for (col, x, w) in gSession.session.eventLogVM.columns.val.eventColumnsPx(body.w):
      eventColumns.add %*{"column": $col, "x": body.x + x, "w": w,
                          "headerY": body.y + EventHeaderTopPx}
  try:
    # PLAT-49 part B: the footer (the status bar the bottom labels live in)
    # and the docked pane shown open, with its band.
    let openDock =
      if gGeom.openDock.isEmpty: newJNull()
      else: %*{"pane": gGeom.openDockPane, "rect": rect(gGeom.openDock)}
    writeFile(geometryOut, $(%*{"area": rect(gGeom.area),
                                "inner": rect(gGeom.inner), "nodes": nodes,
                                "dividers": dividers, "strips": strips,
                                "revealed": revealed, "topBar": top,
                                "footer": rect(gGeom.footer),
                                "openDock": openDock,
                                "editorVScrollbar":
                                  editorVScrollbarGeometry(rect),
                                "eventColumns": eventColumns}))
  except IOError:
    discard

proc footerInfo(): string =
  ## The footer's file info (`headless_app/footer_info`): the file the editor
  ## shows — the Edit arm's, or the debugger's current one.
  if not openArm.isNil:
    footerFileInfoText(openArm.path)
  elif not gSession.isNil:
    footerFileInfoText(gSession.getCurrentFile())
  else: ""

proc maximisedLayout(layout: Layout; pane: PaneKind): Layout
  ## PLAT-50 (K7): forward-declared; defined with the clicks.

proc stripHeading(r: GpuiRenderer; pane: GpuiElement)
  ## Forward-declared for `adoptNewLeaves`.

proc markPaneScope(r: GpuiRenderer; pane: GpuiElement; id: string) =
  ## PLAT-68: a pane is a scope element of the focus chain.
  r.setAttribute(pane, ScopeKindAttribute, $ekPane)
  r.setAttribute(pane, ScopeIdAttribute, id)

proc armPaneKeys(r: GpuiRenderer; pane: GpuiElement)
  ## PLAT-68: forward-declared; defined beside the pointer.

proc adoptNewLeaves(r: GpuiRenderer) =
  ## PLAT-50: a pane a layout command ADDED (the View menu opening a pane the
  ## arrangement did not place) has no leaf yet — the leaves were rendered
  ## once, at open. Its leaf is taken from the shell's projection as every
  ## other was, rendered, and kept with the rest, so the arrangement below
  ## draws it.
  if gShell.isNil:
    return
  let fresh = gShell.leavesFor(gWindow)
  for adopted in fresh.leaves:
    if adopted.paneId.len == 0 or gPanes.hasKey(adopted.paneId):
      continue
    # K19: a ViewModel the host handed the leaf (a folder tab's Files tree,
    # `attachEditFiles`; its VCS, `attachVcs`) is drawn from the first
    # frame, not only from the leaf's next redraw.
    var leaf = adopted
    if leaf.vm.isNil:
      for known in gLeafSet.leaves:
        if known.paneId == leaf.paneId and not known.vm.isNil:
          leaf.vm = known.vm
          break
    let (node, _) = renderLeaf(r, leaf, gEditorSurface, gEditorViewportPx)
    stripHeading(r, node)
    applyTextFaces(r, node)
    gPanes[leaf.paneId] = node
    markPaneScope(r, node, leaf.paneId)
    if openArm.isNil and not probeEnabled:
      armPaneKeys(r, node)
    gLeafSet.leaves.add leaf
    traceGesture("leaf adopted " & leaf.paneId)

proc redrawReplayEditor(r: GpuiRenderer)
  ## Forward-declared for `drawArrangement`'s first frame.

proc followVcsViewport(r: GpuiRenderer)
  ## Forward-declared for `drawArrangement` and the in-hand scroll gestures;
  ## defined beside the VCS refresh it shares `gVcsDirectory` with.

proc followListViewports(r: GpuiRenderer)
  ## Forward-declared for `drawArrangement`; defined beside the panes'
  ## redraws it calls.

proc drawArrangement(r: GpuiRenderer): bool =
  ## Lay the window out from the layout it should show NOW — the committed
  ## one, or, while a divider is dragged, the committed one with the pending
  ## resize applied (`previewLayout`, the model's own `pendingCommand` and
  ## `apply`) — and draw the gesture's overlay over it. Answers whether an
  ## arrangement was drawn (a refused projection leaves the last one).
  var layout = gGestures.previewLayout(committedLayout(),
                                      gLayoutSettings.liveResize)
  # PLAT-50 (K7): a maximised container is drawn alone.
  if gMaximised.isSome:
    layout = maximisedLayout(layout, gMaximised.get)
  let projection = projectDock(layout, gShell.viewport)
  if projection.status == dpsRefused:
    return false
  gGeom = windowGeometryOf(layout, projection.state, pendingViewportWidth,
                           pendingViewportHeight, GpuiTopBandPx,
                           @[($paneEditor, gEditorTab)],
                           footerLeadPx(footerInfo()))
  if gGeom.root < 0:
    return false
  adoptNewLeaves(r)
  # The first arrangement is where the editor's geometry exists: its sticky
  # headers, sub-row offset and overview ruler are drawn from here.
  if not gEditorGeometryDrawn and not gSourceService.isNil and openArm.isNil:
    gEditorGeometryDrawn = true
    redrawReplayEditor(r)
  # The leaves are MOVED into the new arrangement, never rebuilt.
  for _, pane in gPanes:
    let parent = r.parentNode(pane)
    if not parent.isNil:
      r.removeChild(parent, pane)
  if not gTop.isNil:
    r.removeChild(gContainer, gTop)
  gTop = drawWindowBody(r, (if gGestures.revealing: some(gGestures.reveal.pane)
                            else: none(PaneKind)))
  # PLAT-51 deliverable 8: A NEW TAB'S WELCOME SCREEN takes the layout's
  # place — the panes belong to a session, and this tab has none yet.
  if not shownWelcome().isNil:
    gTop = drawWelcome(r)
  r.appendChild(gContainer, gTop)
  # PLAT-52: the Terminal Output pane is laid out from the box it now has.
  drawTerminalPane(r)
  # PLAT-57: and Find in Files from its own (a docked one's included).
  drawSearchPane(r)
  # PLAT-53: and Test Results from its own.
  drawTestsPane(r)
  # PLAT-54: and Agent Activity from its own.
  drawAgentPane(r)
  # PLAT-55: and Problems from its own.
  drawProblemsPane(r)
  # PLAT-51: and the list panes' scrubbers from theirs.
  drawListScrubbers(r)
  # V6: the VCS history follows the body it was laid out with — once the
  # arrangement is committed, never on the frames of a held divider (the
  # terminal's rule for the source pane, Layout-ViewModel §4.3a).
  if not gGestures.active:
    followVcsViewport(r)
    followListViewports(r)
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
  # PLAT-51: a folder tab's Edit arrangement is never this product's
  # remembered (Debug) layout.
  if gRemember and (gMainShell.isNil or gShell == gMainShell):
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

func inHandRowsOf(kind: PaneKind; body: PxRect): int =
  ## M71 (#838): how many rows the Files / VCS pane's body holds — its
  ## inset off (`paneInsetOf`), at its row pitch.
  let inset = paneInsetOf($kind)
  let pitch = if kind == paneFileTree: FileTreeRowPx else: VcsRowPx
  max(1, (body.h - inset.top - inset.bottom) div pitch)

proc syncInHandRows(g: WindowGeometry) =
  ## The rows the Files and VCS bodies hold, for the leaves to draw a
  ## window of (`leaves.fileTreeScroll`, `vcsScroll`).
  let f = g.tabsNodeOfPane($paneFileTree)
  if f >= 0: fileTreeScroll.rows = inHandRowsOf(paneFileTree, g.nodes[f].body)
  let v = g.tabsNodeOfPane($paneVcs)
  if v >= 0: vcsScroll.rows = inHandRowsOf(paneVcs, g.nodes[v].body)

proc syncLeafContext() =
  ## What the leaves read from the window rather than from a ViewModel: the
  ## debugger's tick and the event log's width (`leaves.eventLogNowTicks`,
  ## `eventLogPaneWidthPx`).
  if not gSession.isNil:
    eventLogNowTicks = gSession.getCurrentRRTicks()
  let i = gGeom.tabsNodeOfPane($paneEventLog)
  if i >= 0:
    eventLogPaneWidthPx = gGeom.nodes[i].body.w
    eventLogPaneHeightPx = gGeom.nodes[i].body.h
  let st = gGeom.tabsNodeOfPane($paneState)
  if st >= 0:
    statePaneSizePx = (gGeom.nodes[st].body.w, gGeom.nodes[st].body.h)
    # HSF-V2: the state pane REPORTS what it shows — its rows under the
    # pane's header strip, at the rows' pitch, scrolled by `stateScroll` —
    # and the stop loader sizes the locals it asks for from it.
    if not gSession.isNil and not gSession.session.stateVM.isNil:
      let b = gGeom.nodes[st].body
      gSession.session.stateVM.setViewport(pixelPaneViewport(
        float(b.h - StateRowsTopPx), float(b.w), float(StateValueRowPx),
        float(stateScroll.top)))
  syncInHandRows(gGeom)
  let ct = gGeom.tabsNodeOfPane($paneCalltrace)
  if ct >= 0:
    callTracePaneWidthPx = gGeom.nodes[ct].body.w
    callTracePaneHeightPx = gGeom.nodes[ct].body.h

proc redrawWindowLeaf(r: GpuiRenderer; pane: GpuiElement; leaf: GpuiLeaf) =
  ## `leaves.redrawLeafBody` for a pane whose heading the window removed:
  ## that procedure keeps its node's FIRST child as the heading and redraws
  ## the rest, so the old content is cleared first and a stand-in first child
  ## held while it runs, then dropped — the pane is left with exactly the
  ## content `renderPaneView` drew.
  syncLeafContext()
  if pane.isNil:
    return
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  let stand = r.createElement("div")
  r.appendChild(pane, stand)
  redrawLeafBody(r, pane, leaf)
  r.removeChild(pane, stand)
  # M71 (#838): the Files and VCS panes' scrollbars were the pane's children
  # too; drawn again over what the leaf now shows.
  if leaf.kind == glkBuiltin and leaf.builtin in {paneFileTree, paneVcs}:
    drawListScrubbers(r)

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
  drawListScrubbers(r)

func callTraceRowsIn(body: PxRect): int =
  ## The call rows a call-trace body shows: under its search field, at the
  ## desktop's fractional pitch.
  max(1, callRowAtPx(body.h - paneInsetOf($paneCalltrace).top -
                     CallRowsTopPx))

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
  let body = callTraceRowsIn(gGeom.nodes[i].body)
  let page = gSession.pageCalltrace(body, rows, gGeom.nodes[i].body.w,
                                    CallIndentPx)
  if page.loaded:
    inc gCalltraceLoads
    traceGesture("calltrace-section top=" & $page.top & " loads=" &
                 $gCalltraceLoads)
  traceGesture("calltrace top=" & $page.top & " rows=" & $body & " total=" &
               $page.total)
  redrawCalltrace(r)

proc debugDocumentFor(path: string; executionLine: int): bool
  ## Forward-declared for `followEditorView`; defined below.

proc followEditorView() =
  ## PLAT-70: THE EDITOR'S HORIZONTAL VIEW before a draw — the content
  ## width of the document the pane shows (the edit arm's, or the shown
  ## file's Debug-mode document, opened here if it is not yet), the pane's
  ## code columns, and §4.5's caret-follow when the caret moved
  ## (`editing_core.followView`, one rule for every front-end). With no
  ## document the drawn rows are the content.
  let cols = editorViewCols(gEditorViewportPx)
  if (openArm.isNil or gEditorSurface.productMode != pmEdit) and
     gEditorSurface.path.len > 0 and gEditorSurface.report.len == 0:
    discard debugDocumentFor(gEditorSurface.path,
                             gEditorSurface.executionLine)
  if not openArm.isNil and gEditorSurface.productMode == pmEdit:
    discard openArm.doc.followView(gEditorView, gEditorFollow, cols)
  elif gDebugDocs.hasKey(gEditorSurface.path):
    discard gDebugDocs[gEditorSurface.path].followView(gEditorView,
                                                      gEditorFollow, cols)
  else:
    gEditorView.setContent(editorCodeColumns(gEditorSurface.rows))
    gEditorView.setViewport(cols)

proc editorCaretMark(): int =
  ## The bar's mark: the caret's display column, -1 with no document.
  if not openArm.isNil and gEditorSurface.productMode == pmEdit:
    openArm.doc.caretViewColumn
  elif gDebugDocs.hasKey(gEditorSurface.path):
    gDebugDocs[gEditorSurface.path].caretViewColumn
  else: -1

proc drawEditorBody(r: GpuiRenderer; pane: GpuiElement;
                    sticky: seq[tuple[line: int; text: string; top: int]] = @[]) =
  ## The editor's rows and bar from `gEditorSurface`, at the window's width
  ## and the followed horizontal view — every draw of the editor's body.
  followEditorView()
  discard renderEditor(r, pane, sourcePaneView(GpuiMedium).root,
                       gEditorSurface, gEditorViewportPx, gEditorView.leftCol,
                       gEditorView.contentCols, editorCaretMark(),
                       gLayoutSettings.overflowMarkers, sticky)
  # The editor is redrawn on its own (the hover that shows its scrollbars, a
  # scroll), without the arrangement's redraw that writes the geometry: write
  # it here too, so the scrubber it reports is the one just drawn.
  writeGeometry()

proc redrawEditorRows(r: GpuiRenderer) =
  ## `PLAT35-F3`. Draw the editor pane's body again from the surface it was
  ## last drawn from, at the window's CURRENT width and horizontal scroll.
  ##
  ## The same shape as `redrawEditor` (the edit arm's) and for its reason:
  ## everything after the heading is removed and handed back to
  ## `leaves.renderEditor`, the function that drew it the first time, so the
  ## after-scroll tree is the same derivation as the before-scroll one.
  let pane = gPanes.getOrDefault($paneEditor)
  if pane.isNil or gEditorSurface.rows.len == 0:
    return
  let keep = if childCount(pane) > 0 and isHeading(nthChild(pane, 0)): 1
             else: 0
  while childCount(pane) > keep:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  drawEditorBody(r, pane)
  applyTextFaces(r, pane)

proc recordedLines(path: string): tuple[lines: seq[string], detail: string] =
  ## The whole of `path` as the recording holds it, read through the source
  ## service's provider.
  if gSourceService.isNil:
    return (@[], "no source service")
  var fetched = SourceFetch(status: sfsProviderUnavailable)
  gSourceService.provider.fetch(
    SourceLineRequest(path: path, sourceGeneration: 0,
                      sourceDigest: "", firstLine: 1, lastLine: high(int32)),
    proc(f: SourceFetch) = fetched = f)
  drainSourceCallbacks()
  result.lines = if fetched.fileLines.len > 0: fetched.fileLines
                 else: fetched.lines
  result.detail = fetched.detail

proc debugDocumentFor(path: string; executionLine: int): bool =
  ## PLAT-68: make sure `gDebugDocs` holds `path`'s Debug-mode document —
  ## opened read-only from the recording, the caret on the execution line
  ## (where Monaco's cursor is when a replay stops). Answers whether there
  ## is one.
  if path.len == 0:
    return false
  if gDebugDocs.hasKey(path):
    return true
  let read = recordedLines(path)
  if read.lines.len == 0:
    return false
  var d = initEditingDocument(path, read.lines.join("\n") & "\n",
                              gRouter.base, delivery = GpuiDelivery)
  d.setReadOnly(true)
  d.moveCaretTo(max(1, executionLine) - 1, 0)
  gDebugDocs[path] = d
  true

proc withDebugDocument(surface: EditorSurface): EditorSurface =
  ## PLAT-68: the editor surface with the shown file's Debug-mode document
  ## on it — its caret and selection over the recording's rows while it is
  ## read-only; the document itself, drawn as Edit mode draws one, once
  ## `Ctrl+E` made it writable (the terminal paints its Edit pane then).
  result = surface
  if not gDebugDocs.hasKey(surface.path):
    return
  let d = gDebugDocs[surface.path]
  if not d.isReadOnly:
    let rows = max(1, editorRowsOf(gGeom))
    let top = if gEditorSurface.path == surface.path and
                 gEditorSurface.productMode == pmEdit:
                gEditorSurface.viewportTop
              else: surface.viewportTop
    result = editorSurfaceForDocument(
      d, GpuiMedium, mutableHere = true,
      viewportTop = followedViewportTop(max(1, top), d.caretLine, rows),
      viewportHeight = rows)
  else:
    result.caretLine = d.caretLine
    result.caretColumn = d.caretColumn + 1
  result.selection = d.selectionCells

proc syncEditorViewport(r: GpuiRenderer) =
  ## `PLAT35-F3`. Take the editor pane's inner width from the geometry the
  ## window was just drawn at, and redraw the pane if it moved.
  ##
  ## **IT IS READ FROM `gGeom` AND NOT FROM THE COMMAND LINE**, which is the
  ## difference between a scrollbar that is right once and one that stays
  ## right: a divider drag changes the pane's width without changing the
  ## window's, and a pane that got wider may no longer have anything off its
  ## edge.
  if gGeom.tabsNodeOfPane($paneEditor) < 0:
    return
  let w = editorBodyWidthOf(gGeom)
  if w == gEditorViewportPx:
    return
  gEditorViewportPx = w
  redrawEditorRows(r)

proc scrollEditorColumns(r: GpuiRenderer; cols: int) =
  ## `PLAT35-F3` / PLAT-70. Scroll the editor's code `cols` columns right
  ## (negative: left), and draw it again. **The clamp is not here** — the
  ## shared model owns it (`horizontal_scroll.scrollBy`), and asking it is
  ## how this learns whether the move changed anything at all. The caret
  ## does not move (§4.5: only the caret moves the view, not the other way).
  if cols == 0 or gEditorSurface.rows.len == 0:
    return
  followEditorView()
  if not gEditorView.scrollBy(cols):
    return
  traceGesture("editor-hscroll leftCols=" & $gEditorView.leftCol & " of " &
               $gEditorView.maxLeftCol)
  redrawEditorRows(r)

proc editorBarRect(): PxRect =
  ## PLAT-70: where `leaves.renderEditorScrollbar` draws the editor's bar
  ## (absolutely, at the pane's bottom, inset by the editor's side padding
  ## `EditorPadSidePx`, as wide as the pane's inner width), in window
  ## pixels; zero while the content fits.
  let i = gGeom.tabsNodeOfPane($paneEditor)
  followEditorView()
  if i < 0 or not gEditorView.overflows:
    return PxRect()
  let body = gGeom.nodes[i].body
  # M73: one vertical scrubber's width shorter while that one is drawn too,
  # as `leaves.renderEditor` draws it (the corner is neither's, §6).
  let v = editorVScrollOf(gEditorSurface, body.h, true)
  PxRect(x: body.x + EditorPadSidePx, y: body.y + body.h - EditorScrollbarPx,
         w: gEditorViewportPx - (if v.present: EditorVScrollbarPx else: 0),
         h: EditorScrollbarPx)

proc editorVBarRectAsDrawn(): tuple[rect: PxRect; v: EditorVScroll] =
  ## `editorVBarRect` over the horizontal view AS IT STANDS — no
  ## `followEditorView` — so the geometry dump (`writeGeometry`) reports the
  ## scrubber the last draw placed without moving the view under it.
  let i = gGeom.tabsNodeOfPane($paneEditor)
  if i < 0:
    return
  let body = gGeom.nodes[i].body
  let v = editorVScrollOf(gEditorSurface, body.h, gEditorView.overflows)
  if not v.present or gEditorViewportPx <= EditorVScrollbarPx:
    return
  (rect: PxRect(x: body.x + EditorPadSidePx + gEditorViewportPx -
                   EditorVScrollbarPx,
                y: body.y + v.trackTopPx, w: EditorVScrollbarPx,
                h: v.trackPx),
   v: v)

proc editorVBarRect(): tuple[rect: PxRect; v: EditorVScroll] =
  ## M73 (#840): where `leaves.renderEditorVScrollbar` draws the editor's
  ## vertical scrubber, in window pixels, and the decision it was drawn from
  ## (`leaves.editorVScrollOf`, over the surface the editor was drawn from);
  ## a zero rectangle while the file fits.
  followEditorView()
  editorVBarRectAsDrawn()

proc scrubEditorBar(r: GpuiRenderer; x: int; click: bool) =
  ## PLAT-70 (Horizontal-Overflow.md §4.2): a press on the editor's bar
  ## centres the column at its fraction; a held thumb follows the pointer.
  ## The view only — the caret, the selection and the debugger stay (HO-4).
  let bar = editorBarRect()
  if bar.w <= 0:
    return
  let f = trackFractionAt(clamp(x - bar.x, 0, bar.w - 1), bar.w)
  let moved = if click: gEditorView.clickTrack(f)
              else: gEditorView.dragThumb(
                      gEditorView.barModel.heldThumbStart(f))
  traceGesture("editor-hbar leftCols=" & $gEditorView.leftCol & " of " &
               $gEditorView.maxLeftCol)
  if moved:
    redrawEditorRows(r)

proc pressEditorBar(r: GpuiRenderer; x, y: int): bool =
  ## A left press on the editor's horizontal bar: the bar's, never a press
  ## on the row under it.
  let bar = editorBarRect()
  if bar.w <= 0 or not bar.contains(x, y):
    return false
  let span = gEditorView.barModel.thumbSpan(bar.w, EditorScrollbarMinThumbPx)
  let local = x - bar.x
  let onThumb = local >= span.start and local < span.start + span.length
  # A press on the bar is not a press on the text: no selection drag
  # continues from an earlier one.
  gTextDrag = false
  gEditorBarDrag = onThumb
  if onThumb:
    gEditorView.barModel.beginBarGrab(
      trackFractionAt(clamp(local, 0, bar.w - 1), bar.w))
  scrubEditorBar(r, x, click = not onThumb)
  true

proc refreshReplayWindow(r: GpuiRenderer)
  ## Forward-declared for `clickCalltrace`; defined beside the controls.

proc scrollEditorLines(r: GpuiRenderer; lines: int)
  ## M73 (#840): FORWARD-DECLARED for the wheel's arm in `windowPointer`;
  ## defined beside `showViewedFile`, whose window it moves too.
proc pressEditorVBar(r: GpuiRenderer; x, y: int): bool
proc scrubEditorVBar(r: GpuiRenderer; y: int; click: bool)
  ## M73: FORWARD-DECLARED for `windowPointer`; defined with the scroll above.

proc clickCalltrace(r: GpuiRenderer; x, y: int): bool =
  ## PLAT-49 part B: a press on the call trace's body. On a row: go to that
  ## call (`ct/calltrace-jump`, the desktop's click) and redraw the window
  ## from the new stop; on the row's toggle: expand or collapse its children
  ## (`ct/expand-calls` / `ct/collapse-calls`) and read the section again.
  ## The rows are the ones `leaves.renderCallTrace` draws, `CalltraceRowPx`
  ## each from the body's padding; the toggle is the first glyph after the
  ## row's depth offset (`CallIndentPx` a level).
  if gSession.isNil or gGeom.activePaneAt(x, y) != $paneCalltrace:
    return false
  let i = gGeom.tabsNodeOfPane($paneCalltrace)
  if i < 0 or not gGeom.nodes[i].body.contains(x, y):
    return false
  let vm = gSession.session.calltraceVM
  if vm.isNil:
    return false
  let rows = vm.callRows()
  let body = gGeom.nodes[i].body
  let rowsTop = body.y + paneInsetOf($paneCalltrace).top + CallRowsTopPx
  let at = callRowAtPx(y - rowsTop)
  if y < rowsTop or at < 0 or at >= rows.len:
    return false
  let row = rows[at]
  let toggleX = body.x + CallToggleLeftPx + row.depth * CallIndentPx
  let store = gSession.session.store
  let local = row.index - store.calltrace.startLineIndex.val
  if local < 0 or local >= store.calltrace.lines.val.len.int64:
    return false
  if row.toggle != crtLeaf and x >= toggleX and x < toggleX + 14:
    traceGesture("calltrace toggle #" & $row.index)
    let why = gSession.toggleCallChildren(row.index)
    if why.len > 0:
      traceGesture("calltrace toggle failed: " & why)
    redrawCalltrace(r)
    return true
  traceGesture("calltrace jump #" & $row.index)
  vm.selectEntry(some(row.index))
  let why = gSession.jumpToCall(row.index)
  if why.len > 0:
    traceGesture("calltrace jump failed: " & why)
    return true
  refreshReplayWindow(r)
  true

proc handlePopoverPress(r: GpuiRenderer; kind: GpuiEventKind;
                        x, y: int): bool
  ## PLAT-50: an open right-click menu or event content takes a press
  ## (defined with the clicks, after the top bar).

proc wireClicks(r: GpuiRenderer)
  ## PLAT-50: every redraw re-wires the rows it made (`window_clicks`).

proc runContextAction(r: GpuiRenderer; action: ContextAction;
                      target: ContextTarget)
  ## PLAT-50: a right-click menu's chosen entry (the keys choose too).

proc openContextMenuAt(r: GpuiRenderer; menu: ContextMenuModel; x, y: int)
  ## PLAT-50: forward-declared for the dock labels' right-click menu.

# ---------------------------------------------------------------------------
# PLAT-52: the Terminal Output pane — drawn natively from the shared model,
# its clicks (K32), its scrollbar scrubber and the screen's built-in one
# ---------------------------------------------------------------------------

proc terminalVM(): TerminalOutputVM =
  if gSession.isNil: nil else: gSession.session.terminalOutputVM

proc terminalBody(): PxRect =
  ## The pane's body in window pixels, or a zero rectangle when it is not
  ## the visible tab of a drawn box.
  let i = gGeom.tabsNodeOfPane($paneTerminalOutput)
  if i < 0:
    return PxRect()
  let n = gGeom.nodes[i]
  if n.panes.len > 0 and n.active >= 0 and n.active < n.panes.len and
     n.panes[n.active] != $paneTerminalOutput:
    return PxRect()
  n.body

proc drawTerminalPane(r: GpuiRenderer) =
  ## Draw the pane from its ViewModel, natively (`terminal_output_leaf`),
  ## replacing whatever the leaf held — the vocabulary list `renderLeaf` built
  ## is the leaf plan's (`--report-plan`), the window draws the runs.
  let pane = gPanes.getOrDefault($paneTerminalOutput)
  let vm = terminalVM()
  if pane.isNil or vm.isNil:
    return
  # THE LINE VIEW HOLDS THE LINES IT SHOWS (Viewport-Driven-Loading Q3): the
  # rows the body fits from the line drawn first. A following view's first
  # line depends on the current line the first answer names, so it reports
  # again until that holds still.
  let body = terminalBody()
  if body.w > 0 and not vm.screenShown:
    let rows = terminalLayout(body, vm, gTerminal).rows
    var reported = -1
    for _ in 0 ..< 3:
      let top = vm.visibleTop(gTerminal, rows)
      if rows <= 0 or top == reported:
        break
      reported = top
      vm.showTerminalLines(Viewport(rows: rows, firstRow: top))
  # PLAT-70: the widest line measured so far over the windows held, and the
  # view at this width (Horizontal-Overflow.md §4.1) — the pane's own state.
  gTerminal.measureContent(vm)
  gTerminal.markers = gLayoutSettings.overflowMarkers
  if body.w > 0:
    gTerminal.hview = terminalLayout(body, vm, gTerminal).view
  if drawTerminalOutput(r, pane, vm, gTerminal, body):
    applyTextFaces(r, pane)

proc terminalJump(r: GpuiRenderer; write: int): bool =
  ## Go to the moment write `write` was produced (`ct/event-jump`, K32), and
  ## the window follows.
  let vm = terminalVM()
  if vm.isNil:
    return false
  # The write is known from the held lines when the writes are not loaded.
  let ev = vm.eventOf(write)
  if ev.eventIndex < 0:
    return false
  try:
    gSession.eventJump(EventLogEntry(content: "", rrTicks: ev.rrTicks,
                                     line: ev.line, file: ev.path,
                                     eventIndex: ev.logIndex))
  except CatchableError as e:
    traceGesture("terminal jump failed: " & e.msg)
    return false
  traceGesture("terminal write " & $write & " at tick " & $ev.rrTicks)
  vm.cancelScrub()
  gViewedFile = ""
  refreshReplayWindow(r)
  drawTerminalPane(r)
  true

proc scrubTerminalLines(r: GpuiRenderer; y: int; click: bool) =
  ## The line view's scrubber: a click centres the row at the fraction of the
  ## WHOLE output; a held thumb follows the pointer. The view, never the
  ## debugger.
  let vm = terminalVM()
  let lay = terminalLayout(terminalBody(), vm, gTerminal)
  if vm.isNil or lay.track.h <= 0:
    return
  let sm = vm.scrubberFor(gTerminal, lay.rows)
  let f = trackFractionAt(y - lay.track.y, lay.track.h)
  gTerminal.scrollTop = if click: sm.clickAt(f)
                        else: sm.dragTo(sm.heldThumbStart(f))
  gTerminal.follow = false
  drawTerminalPane(r)

proc scrubTerminalScreen(r: GpuiRenderer; x: int) =
  ## The screen's scrubber held at `x`. REAL-TIME (the user, 2026-10-06;
  ## Terminal-Output-Pane.md §3): the debugger moves to the write under the
  ## pointer as it is dragged — one jump per write crossed, through the
  ## window's own `ct/event-jump` (`terminalJump`), which waits for the move.
  let vm = terminalVM()
  let lay = terminalLayout(terminalBody(), vm, gTerminal)
  if vm.isNil or lay.screenTrack.w <= 0:
    return
  let w = writeAtFraction(vm.screen.writeCount,
    max(0.0, min(1.0, float(x - lay.screenTrack.x) /
                      float(max(1, lay.screenTrack.w)))))
  if w < 0:
    return
  vm.scrubPreview.val = w
  if w != gTerminal.scrubSent:
    gTerminal.scrubSent = w
    discard terminalJump(r, w)
    # The drag is still held: keep showing the write under the pointer.
    vm.scrubPreview.val = w
  drawTerminalPane(r)

proc scrubTerminalHBar(r: GpuiRenderer; x: int; click: bool) =
  ## PLAT-70 (Horizontal-Overflow.md §4.2): the line view's horizontal bar —
  ## a press on the track centres the column at its fraction, a held thumb
  ## follows the pointer. The view only (HO-4).
  let vm = terminalVM()
  let lay = terminalLayout(terminalBody(), vm, gTerminal)
  if vm.isNil or lay.hbar.w <= 0:
    return
  let f = trackFractionAt(clamp(x - lay.hbar.x, 0, lay.hbar.w - 1),
                          lay.hbar.w)
  var v = lay.view
  discard (if click: v.clickTrack(f)
           else: v.dragThumb(v.barModel.heldThumbStart(f)))
  gTerminal.hview = v
  traceGesture("terminal-hscroll leftCol=" & $v.leftCol & " of " &
               $v.maxLeftCol)
  drawTerminalPane(r)

proc scrollTerminalColumns(r: GpuiRenderer; cols: int): bool =
  ## PLAT-70: the line view's view moved `cols` columns (the wheel, the
  ## `view.*` keys). Answers whether it moved.
  let vm = terminalVM()
  if vm.isNil or vm.screenShown:
    return false
  if not gTerminal.hview.scrollBy(cols):
    return false
  traceGesture("terminal-hscroll leftCol=" & $gTerminal.hview.leftCol &
               " of " & $gTerminal.hview.maxLeftCol)
  drawTerminalPane(r)
  true

proc pressTerminalOutput(r: GpuiRenderer; x, y: int): bool =
  ## A left press on the pane: the toggle, a fragment, a scrubber.
  let vm = terminalVM()
  let body = terminalBody()
  gTerminal.focused = body.w > 0 and body.contains(x, y)
  if vm.isNil or not gTerminal.focused:
    return false
  let hit = terminalHitAt(vm, gTerminal, body, x, y)
  case hit.kind
  of ghNone, ghScreen:
    return false
  of ghViewLines, ghViewScreen:
    vm.setView(if hit.kind == ghViewLines: tvLines else: tvScreen)
    traceGesture("terminal view " & $vm.view.val)
    drawTerminalPane(r)
  of ghWrite:
    return terminalJump(r, hit.write)
  of ghLineTrack:
    scrubTerminalLines(r, y, click = true)
  of ghLineThumb:
    gTerminal.drag = gtdLineThumb
    let lay = terminalLayout(body, vm, gTerminal)
    vm.scrubberFor(gTerminal, lay.rows).beginBarGrab(
      trackFractionAt(y - lay.track.y, lay.track.h))
    scrubTerminalLines(r, y, click = false)
  of ghScreenTrack:
    gTerminal.drag = gtdScreen
    gTerminal.scrubSent = -1
    scrubTerminalScreen(r, x)
  of ghHBarTrack:
    scrubTerminalHBar(r, x, click = true)
  of ghHBarThumb:
    gTerminal.drag = gtdHBarThumb
    let lay = terminalLayout(body, vm, gTerminal)
    lay.view.barModel.beginBarGrab(
      trackFractionAt(clamp(x - lay.hbar.x, 0, lay.hbar.w - 1), lay.hbar.w))
    scrubTerminalHBar(r, x, click = false)
  of ghCorner:
    # HO-7: the corner square takes no gesture.
    discard
  true

proc moveTerminal(r: GpuiRenderer; x, y: int) =
  case gTerminal.drag
  of gtdLineThumb: scrubTerminalLines(r, y, click = false)
  of gtdScreen: scrubTerminalScreen(r, x)
  of gtdHBarThumb: scrubTerminalHBar(r, x, click = false)
  of gtdNone: discard

proc releaseTerminal(r: GpuiRenderer; x, y: int) =
  ## The release of a held scrubber: the screen's drag ends on the write
  ## under the pointer (the debugger is already there, or goes there now);
  ## the line view's just ends.
  let kind = gTerminal.drag
  gTerminal.drag = gtdNone
  if kind == gtdScreen:
    scrubTerminalScreen(r, x)
    gTerminal.scrubSent = -1
    let vm = terminalVM()
    if not vm.isNil:
      vm.cancelScrub()
    drawTerminalPane(r)

proc terminalKey(r: GpuiRenderer; key: string): bool =
  ## The pane's keys while it has the pointer's focus: in the SCREEN view
  ## Left / Right step a write back / forward (Terminal-Output-Pane §3's
  ## step-by-write keys); `v` toggles lines / screen. In the LINE view the
  ## arrows are the view's (PLAT-70, Horizontal-Overflow.md §4.4:
  ## `view.scroll-left` / `-right`, through the router).
  let vm = terminalVM()
  if vm.isNil or not gTerminal.focused:
    return false
  case key.toLowerAscii
  of "left", "arrowleft", "right", "arrowright":
    if not vm.screenShown:
      return false
    let delta = if key.toLowerAscii in ["left", "arrowleft"]: -1 else: 1
    let target = vm.stepTarget(delta)
    if target >= 0:
      discard terminalJump(r, target)
    true
  of "v":
    vm.toggleView()
    drawTerminalPane(r)
    true
  else: false

# ---------------------------------------------------------------------------
# PLAT-57: Find in Files, drawn natively (`search_results_leaf`)
# ---------------------------------------------------------------------------

proc searchVM(): SearchResultsVM =
  if gSession.isNil: nil else: gSession.session.searchResultsVM

proc dockedBodyOf(rect: PxRect): PxRect =
  ## The body of a docked pane's box (`dockedPaneBox`): inside the outline,
  ## below the one-tab strip.
  PxRect(x: rect.x + FocusOutlinePx, y: rect.y + FocusOutlinePx + TabStripPx,
         w: max(0, rect.w - 2 * FocusOutlinePx),
         h: max(0, rect.h - 2 * FocusOutlinePx - TabStripPx))

proc searchBody(): PxRect =
  ## Find in Files' body in window pixels — revealed over the tree, docked
  ## open in its band, or a visible tab of a box — or a zero rectangle.
  if gGestures.revealing and gGestures.reveal.pane == paneSearch:
    return dockedBodyOf(gGeom.revealRectOf(gGestures.reveal.edge))
  if not gGeom.openDock.isEmpty and gGeom.openDockPane == $paneSearch:
    return dockedBodyOf(gGeom.openDock)
  let i = gGeom.tabsNodeOfPane($paneSearch)
  if i < 0:
    return PxRect()
  let n = gGeom.nodes[i]
  if n.panes.len > 0 and n.active >= 0 and n.active < n.panes.len and
     n.panes[n.active] != $paneSearch:
    return PxRect()
  n.body

proc testsBody(): PxRect =
  ## PLAT-53: Test Results' body in window pixels — revealed, docked open, or
  ## the visible tab of a box — or a zero rectangle.
  if gGestures.revealing and gGestures.reveal.pane == paneTestResults:
    return dockedBodyOf(gGeom.revealRectOf(gGestures.reveal.edge))
  if not gGeom.openDock.isEmpty and gGeom.openDockPane == $paneTestResults:
    return dockedBodyOf(gGeom.openDock)
  let i = gGeom.tabsNodeOfPane($paneTestResults)
  if i < 0:
    return PxRect()
  let n = gGeom.nodes[i]
  if n.panes.len > 0 and n.active >= 0 and n.active < n.panes.len and
     n.panes[n.active] != $paneTestResults:
    return PxRect()
  n.body

proc problemsBody(): PxRect =
  ## PLAT-55: Problems' body in window pixels — revealed, docked open, or the
  ## visible tab of a box — or a zero rectangle.
  if gGestures.revealing and gGestures.reveal.pane == paneProblems:
    return dockedBodyOf(gGeom.revealRectOf(gGestures.reveal.edge))
  if not gGeom.openDock.isEmpty and gGeom.openDockPane == $paneProblems:
    return dockedBodyOf(gGeom.openDock)
  let i = gGeom.tabsNodeOfPane($paneProblems)
  if i < 0:
    return PxRect()
  let n = gGeom.nodes[i]
  if n.panes.len > 0 and n.active >= 0 and n.active < n.panes.len and
     n.panes[n.active] != $paneProblems:
    return PxRect()
  n.body

proc drawProblemsPane(r: GpuiRenderer) =
  ## PLAT-55: draw Problems from the window's ViewModel, natively, replacing
  ## whatever the leaf held.
  let pane = gPanes.getOrDefault($paneProblems)
  if pane.isNil or gProblems.isNil:
    return
  if drawProblems(r, pane, gProblems.vm, gProblemsPane, problemsBody()):
    applyTextFaces(r, pane)

proc drawTestsPane(r: GpuiRenderer) =
  ## PLAT-53: draw Test Results from the window's ViewModel, natively,
  ## replacing whatever the leaf held.
  let pane = gPanes.getOrDefault($paneTestResults)
  if pane.isNil or gTestsVM.isNil:
    return
  if drawTestResults(r, pane, gTestsVM, gTests, testsBody()):
    applyTextFaces(r, pane)

proc drawSearchPane(r: GpuiRenderer) =
  ## Draw Find in Files from its ViewModel, natively, replacing whatever the
  ## leaf held (the vocabulary tree `renderLeaf` built is the leaf plan's).
  let pane = gPanes.getOrDefault($paneSearch)
  let vm = searchVM()
  if pane.isNil or vm.isNil:
    return
  if drawSearchResults(r, pane, vm, gSearch, searchBody()):
    applyTextFaces(r, pane)

# ---------------------------------------------------------------------------
# PLAT-54: Agent Activity, drawn natively (`agent_activity_leaf`)
# ---------------------------------------------------------------------------

proc openRecordingInTab(r: GpuiRenderer; path: string)
proc vcsVM(): VCSVM

proc agentHost(): NativeAgentHost =
  ## The shown session's Agent Activity host, made on first use and wired to
  ## this window: a test's recording opens as a session tab, as the "+"'s
  ## choice does; an evidence card's review enters the VCS pane.
  if gSession.isNil:
    return nil
  let key = cast[int](gSession)
  if not gAgentHosts.hasKey(key):
    let h = newNativeAgentHost(gSession.session.store)
    h.openRecording = proc(request: TraceOpenRequest): string =
      var rr: GpuiRenderer
      openRecordingInTab(rr, request.tracePath)
      ""
    gAgentHosts[key] = h
  result = gAgentHosts[key]
  if result.vcs.isNil:
    result.vcs = vcsVM()

proc agentBody(): PxRect =
  ## Agent Activity's body in window pixels — revealed over the tree, docked
  ## open in its band, or a visible tab of a box — or a zero rectangle.
  if gGestures.revealing and gGestures.reveal.pane == paneAgentActivity:
    return dockedBodyOf(gGeom.revealRectOf(gGestures.reveal.edge))
  if not gGeom.openDock.isEmpty and gGeom.openDockPane == $paneAgentActivity:
    return dockedBodyOf(gGeom.openDock)
  let i = gGeom.tabsNodeOfPane($paneAgentActivity)
  if i < 0:
    return PxRect()
  let n = gGeom.nodes[i]
  if n.panes.len > 0 and n.active >= 0 and n.active < n.panes.len and
     n.panes[n.active] != $paneAgentActivity:
    return PxRect()
  n.body

proc drawAgentPane(r: GpuiRenderer) =
  ## Draw Agent Activity from its host's ViewModel, natively, replacing what
  ## the leaf held (the vocabulary tree `renderLeaf` built is the plan's).
  let pane = gPanes.getOrDefault($paneAgentActivity)
  let h = agentHost()
  if pane.isNil or h.isNil:
    return
  let typed = h.vm.inputValue.val
  if drawAgentActivity(r, pane, h.feedRows(),
                       (if typed.len > 0: typed else: promptPlaceholder(h.vm)),
                       typed.len == 0, h.vm.isLoading.val, gAgent,
                       agentBody()):
    applyTextFaces(r, pane)

proc agentLive(): bool =
  for h in gAgentHosts.values:
    if h.vm.isLoading.val:
      return true

proc pressSearch(r: GpuiRenderer; x, y: int): bool
proc pressTests(r: GpuiRenderer; x, y: int): bool
  ## PLAT-53: forward-declared; defined beside the Test Results host.
proc pressAgent(r: GpuiRenderer; x, y: int): bool
proc runAgentPrompt(r: GpuiRenderer; text: string)
proc pressProblems(r: GpuiRenderer; x, y: int): bool
  ## PLAT-55: forward-declared; defined beside the Problems host.
proc runGpuiFindInFiles(r: GpuiRenderer; pattern: string)
proc openFindInFiles(r: GpuiRenderer)
proc stepSearchResult(r: GpuiRenderer; delta: int)
proc wireSearch(s: HeadlessDebugSession)
  ## PLAT-57: forward-declared; defined beside the editor's caret, which
  ## opening a result places.

# ---------------------------------------------------------------------------
# PLAT-51: the Event Log's and the Call Trace's scrollbar scrubbers
# ---------------------------------------------------------------------------

proc visibleBodyIn(g: WindowGeometry; kind: PaneKind): PxRect =
  ## The pane's body in `g`'s window pixels when it is the visible tab of a
  ## drawn box, else a zero rectangle.
  let i = g.tabsNodeOfPane($kind)
  if i < 0:
    return PxRect()
  let n = g.nodes[i]
  if n.panes.len > 0 and n.active >= 0 and n.active < n.panes.len and
     n.panes[n.active] != $kind:
    return PxRect()
  n.body

proc visibleBodyOf(kind: PaneKind): PxRect =
  ## The pane's body in the drawn window (`visibleBodyIn` over `gGeom`).
  visibleBodyIn(gGeom, kind)

func eventLogRowsIn(body: PxRect): int =
  ## The rows an event-log body shows: between its toolbar and header and
  ## its pager, at the desktop's pitch.
  max(1, int(floor(float(body.h - 8 - EventChromeAbovePx - EventChromeBelowPx) /
                   EventRowPitch)))

proc eventLogRows(): int =
  eventLogRowsIn(visibleBodyOf(paneEventLog))

proc callTraceRows(): int =
  callTraceRowsIn(visibleBodyOf(paneCalltrace))

proc reportListViewports(session: HeadlessDebugSession;
                         g: WindowGeometry): tuple[calltrace, events: bool] =
  ## THE CALL TRACE AND THE EVENT LOG REPORT WHAT THEY SHOW, from the window
  ## geometry `g` (Viewport-Driven-Loading V2). The open reads one row of
  ## each (`native_host.loadRecordingPanes`), and a windowed pane asks for
  ## nothing until its view gives it a viewport — so without this report the
  ## call trace drew only `<toplevel>`, and the event log its first event,
  ## until the reader scrolled. The call trace reports through `CalltraceVM`
  ## at the row it is scrolled to (`gpui_host.pageCalltrace`); the event log
  ## reports the window from the row it shows first through `EventLogVM`
  ## (`pageEventLog`, whose request names the stop so the answer also says
  ## which row is "now"). A pane that is
  ## not the visible tab of its box reports nothing and keeps its last
  ## window, as the desktop's panel host does for a hidden pane. Answers
  ## which of the two read a new window.
  if session.isNil:
    return
  let c = visibleBodyIn(g, paneCalltrace)
  if c.w > 0 and c.h > 0:
    result.calltrace = session.pageCalltrace(callTraceRowsIn(c), 0, c.w,
                                             CallIndentPx).loaded
  let e = visibleBodyIn(g, paneEventLog)
  if e.w > 0 and e.h > 0:
    result.events = session.pageEventLog(
      session.session.store.eventLog.loadedStart.val, eventLogRowsIn(e)).loaded

proc eventLogScrubber(): ScrubberModel =
  ## The WHOLE log (the engine's count), the window's first row — the pane
  ## shows the window from its start — and the current event's row.
  if gSession.isNil:
    return scrubberModel(0, 0, 0, totalKnown = false)
  let ev = gSession.session.store.eventLog
  scrubberModel(ev.recordsTotal.val, ev.loadedStart.val, eventLogRows(),
                ev.currentIndex.val, totalKnown = ev.totalReported.val)

var gCallMark: tuple[current: int, ticks: uint64] = (-1, high(uint64))
  ## The call trace scrubber's mark as last established, kept while a
  ## section that cannot say where "now" is is held.

proc callTraceScrubber(): ScrubberModel =
  ## The WHOLE trace at its expansion, the ViewModel's scroll position, and
  ## the mark the desktop's scrubber draws (`isonim_calltrace_view`'s
  ## `current`): the last call entered at or before the debugger's tick
  ## (`currentCallOf` with no stack) — read only off a held section that
  ## reaches past the tick, remembered while one that does not is held, and
  ## dropped when the debugger moves.
  if gSession.isNil or gSession.session.calltraceVM.isNil:
    return scrubberModel(0, 0, 0, totalKnown = false)
  let vm = gSession.session.calltraceVM
  let store = gSession.session.store
  let ticks = store.debugger.val.rrTicks
  let held = store.calltrace.lines.val
  let at = currentCallOf(held, ticks, @[])
  var coversAfter = false
  for l in held:
    if l.rrTicks > ticks:
      coversAfter = true
      break
  if at.isSome and coversAfter:
    gCallMark = (int(at.get), ticks)
  elif ticks != gCallMark.ticks:
    gCallMark = (-1, ticks)
  scrubberModel(int(store.calltrace.totalCallsCount.val),
                int(vm.scrollPosition.val), callTraceRows(), gCallMark.current)

proc redrawPaneOf(r: GpuiRenderer; pane: PaneKind)
  ## Forward-declared; defined with the panes' redraws.

proc builtinVm(kind: PaneKind): ViewModel =
  ## The ViewModel the window's leaf for pane `kind` draws, or nil.
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == kind:
      return leaf.vm
  nil

proc inHandScrubber(kind: PaneKind): ScrubberModel =
  ## M71 (#838): the Files / VCS pane's ordinary scrollbar (Scrollbar-
  ## Scrubbers.md §2) — every row it lists, the reader's place, the rows its
  ## body holds; no current-position mark (its rows are not a timeline).
  let vm = builtinVm(kind)
  let (total, top, rows) =
    if vm.isNil: (0, 0, 0)
    elif kind == paneFileTree: (fileTreeRowCount(FilesystemVM(vm)),
                                fileTreeScroll.top, fileTreeScroll.rows)
    # The VCS pane's rows are counted off the view it drew.
    else: (vcsScroll.total, vcsScroll.top, vcsScroll.rows)
  scrubberModel(total, inHandTop(top, total, rows), rows)

proc setInHandTop(kind: PaneKind; top: int) =
  if kind == paneFileTree: fileTreeScroll.top = top
  else: vcsScroll.top = top

proc traceInHand(kind: PaneKind) =
  ## The gesture trace's line for a Files / VCS scroll: where the view is,
  ## of how many rows, showing how many.
  let sm = inHandScrubber(kind)
  traceGesture($kind & " top=" & $sm.firstVisible & " total=" & $sm.total &
               " rows=" & $sm.visible)

proc listScrubbers(): seq[tuple[kind: PaneKind, sm: ScrubberModel]] =
  ## Every list pane's scrubber: the Event Log's and the Call Trace's over
  ## their whole populations, and (M71) the Files and VCS panes' while their
  ## rows overflow the body.
  result = @[(paneEventLog, eventLogScrubber()),
             (paneCalltrace, callTraceScrubber())]
  for kind in [paneFileTree, paneVcs]:
    let sm = inHandScrubber(kind)
    if sm.visible > 0 and sm.total > sm.visible:
      result.add (kind, sm)

proc drawListScrubbers(r: GpuiRenderer) =
  ## Each list pane's scrubber over what its leaf drew.
  # M71: a Files / VCS pane whose rows now fit loses the bar it had.
  for kind in [paneFileTree, paneVcs]:
    let pane = gPanes.getOrDefault($kind)
    if not pane.isNil:
      clearListScrubber(r, pane)
  for (kind, sm) in listScrubbers():
    let pane = gPanes.getOrDefault($kind)
    let body = visibleBodyOf(kind)
    if pane.isNil or body.w <= 0 or sm.total <= 0:
      continue
    drawListScrubber(r, pane, body, sm, $kind)

proc redrawListPane(r: GpuiRenderer; kind: PaneKind) =
  let pane = gPanes.getOrDefault($kind)
  if pane.isNil:
    return
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == kind:
      redrawWindowLeaf(r, pane, leaf)
      applyTextFaces(r, pane)
      break
  drawListScrubbers(r)
  # M71: the Files and VCS rows drawn again take their presses again.
  if kind in {paneFileTree, paneVcs}:
    wireClicks(r)

proc stateBarTrack(): PxRect =
  ## M71 (#838): the state pane's vertical scrollbar's column, in window
  ## pixels (`leaves.stateScrollbars` draws it), or a zero rectangle while
  ## its rows fit.
  let body = visibleBodyOf(paneState)
  if body.w <= 0 or stateVerticalBar.track <= 0:
    return PxRect()
  PxRect(x: body.x + body.w - StateScrollbarPx, y: body.y + StateRowsTopPx,
         w: StateScrollbarPx, h: stateVerticalBar.track)

proc stateBarModel(): ScrubberModel =
  ## The state pane's scroll as the shared model, in PIXELS: the rows' whole
  ## height, the scroll, the box's visible height — so the §3 click and drag
  ## are the list panes' arithmetic on its own units.
  scrubberModel(stateVerticalBar.content,
                min(stateScroll.top, stateScrollMax.top),
                stateVerticalBar.track)

proc scrubStateBar(r: GpuiRenderer; y: int; dragging: bool) =
  ## §3 on the state pane's bar: a press centres the rows at its fraction, a
  ## held thumb follows the pointer. The view moves; the debugger does not.
  let track = stateBarTrack()
  if track.h <= 0:
    return
  let sm = stateBarModel()
  let local = clamp(y - track.y, 0, track.h - 1)
  let top = sm.scrubTop(trackFractionAt(local, track.h), dragging)
  stateScroll.top = clamp(top, 0, stateScrollMax.top)
  traceGesture("state scroll top=" & $stateScroll.top & " left=" &
               $stateScroll.left)
  redrawPaneOf(r, paneState)

proc scrubListPane(r: GpuiRenderer; kind: PaneKind; y: int; dragging: bool) =
  ## Move the pane's VIEW to the row the scrubber names (Scrollbar-Scrubbers
  ## §3.2 / §3.3) — reading the window it lands on when it is not held. The
  ## debugger does not move.
  if kind == paneState:
    scrubStateBar(r, y, dragging)
    return
  let body = visibleBodyOf(kind)
  if gSession.isNil or body.w <= 0:
    return
  case kind
  of paneEventLog:
    let sm = eventLogScrubber()
    let hit = listScrubHit(body, sm, listTrackRect(body, $kind).x, y, $kind)
    if not hit.onTrack:
      return
    let page = gSession.pageEventLog(sm.scrubTop(hit.fraction, dragging),
                                     eventLogRows())
    if page.loaded:
      inc gEventLogLoads
    traceGesture("eventlog top=" & $page.top & " loads=" & $gEventLogLoads &
                 " total=" & $page.total)
  of paneCalltrace:
    let sm = callTraceScrubber()
    let hit = listScrubHit(body, sm, listTrackRect(body, $kind).x, y, $kind)
    if not hit.onTrack:
      return
    let top = sm.scrubTop(hit.fraction, dragging)
    let page = gSession.pageCalltrace(callTraceRows(), top - sm.firstVisible,
                                      visibleBodyOf(paneCalltrace).w,
                                      CallIndentPx)
    if page.loaded:
      inc gCalltraceLoads
    traceGesture("calltrace top=" & $page.top & " loads=" & $gCalltraceLoads &
                 " total=" & $page.total)
  of paneFileTree, paneVcs:
    # M71 (#838): the rows are in hand — the view moves, nothing is read.
    let sm = inHandScrubber(kind)
    let track = listTrackRect(body, $kind)
    let hit = listScrubHit(body, sm, track.x,
                           clamp(y, track.y, track.y + track.h - 1), $kind)
    if not hit.onTrack:
      return
    setInHandTop(kind, sm.scrubTop(hit.fraction, dragging))
    traceInHand(kind)
  else:
    return
  redrawListPane(r, kind)
  # V6: a scrub that reaches the last commit read reads more at once.
  if kind == paneVcs:
    followVcsViewport(r)

proc tableHBarOf(kind: PaneKind): tuple[rect: PxRect; view: HorizontalView] =
  ## PLAT-70 Part I (Horizontal-Overflow.md §5.5.4): where `leaves.tableHBar`
  ## drew a table pane's sideways bar, in window pixels, and the view it was
  ## drawn from; a zero rectangle while the pane's columns fit.
  let body = visibleBodyOf(kind)
  if body.w <= 0:
    return
  case kind
  of paneCalltrace:
    let v = callTraceHView
    if not v.overflows or callTracePaneHeightPx <= TableHBarPx:
      return
    (PxRect(x: body.x, y: body.y + callTracePaneHeightPx - TableHBarPx,
            w: v.viewportCols, h: TableHBarPx), v)
  of paneEventLog:
    let v = eventLogHView
    if not v.overflows:
      return
    # Under the table's rows; the table shrinks before the toolbar, the bar
    # and the pager do.
    let tableH = min(eventLogTableHeightPx,
                     max(0, body.h - EventToolbarPx - TableHBarPx -
                            EventFooterPx))
    (PxRect(x: body.x, y: body.y + EventToolbarPx + tableH,
            w: v.viewportCols, h: TableHBarPx), v)
  else: (PxRect(), HorizontalView())

proc scrubTableHBar(r: GpuiRenderer; kind: PaneKind; x: int; click: bool) =
  ## A press on a table pane's bar: the track centres the column under it
  ## (§4.2), a held thumb follows the pointer by the point it was taken by
  ## (Scrollbar-Scrubbers §3.3). The view only (HO-4).
  let (bar, v0) = tableHBarOf(kind)
  if bar.w <= 0:
    return
  var v = v0
  let f = trackFractionAt(clamp(x - bar.x, 0, bar.w - 1), bar.w)
  let moved = if click: v.clickTrack(f)
              else: v.dragThumb(v.barModel.heldThumbStart(f))
  if kind == paneCalltrace: callTraceHView = v
  else: eventLogHView = v
  traceGesture($kind & "-hscroll left=" & $v.leftCol)
  if moved:
    redrawPaneOf(r, kind)

proc pressTableHBar(r: GpuiRenderer; x, y: int): bool =
  ## A left press on the Call Trace's or the Event Log's sideways bar: the
  ## bar's, never the row's under it.
  for kind in [paneCalltrace, paneEventLog]:
    let (bar, v) = tableHBarOf(kind)
    if bar.w <= 0 or not bar.contains(x, y):
      continue
    let span = v.barModel.thumbSpan(bar.w, TableHBarMinThumbPx)
    let local = x - bar.x
    let onThumb = local >= span.start and local < span.start + span.length
    gTableBarDrag = (onThumb, kind)
    if onThumb:
      v.barModel.beginBarGrab(trackFractionAt(clamp(local, 0, bar.w - 1),
                                              bar.w))
    scrubTableHBar(r, kind, x, click = not onThumb)
    return true
  false

proc pressListScrubber(r: GpuiRenderer; x, y: int): bool =
  ## A left press on a list pane's scrubber: the track jumps the view, the
  ## thumb starts a drag.
  for (kind, sm) in listScrubbers():
    let body = visibleBodyOf(kind)
    if body.w <= 0 or sm.total <= 0:
      continue
    let hit = listScrubHit(body, sm, x, y, $kind)
    if not hit.onTrack:
      continue
    if hit.onThumb:
      gListDrag = ListScrubDrag(active: true, pane: $kind)
      sm.beginBarGrab(hit.fraction)
    scrubListPane(r, kind, y, dragging = hit.onThumb)
    return true
  # M71 (#838): the state pane's bar takes the same §3 press — its thumb
  # where `leaves.stateScrollbars` drew it.
  let track = stateBarTrack()
  if track.h > 0 and x >= track.x and x < track.x + track.w and
     y >= track.y and y < track.y + track.h:
    let thumb = stateVerticalThumb()
    let local = y - track.y
    let onThumb = local >= thumb.start and
                  local < thumb.start + max(1, thumb.length)
    if onThumb:
      gListDrag = ListScrubDrag(active: true, pane: $paneState)
      stateBarModel().beginBarGrab(
        trackFractionAt(clamp(local, 0, track.h - 1), track.h))
    scrubStateBar(r, y, dragging = onThumb)
    return true
  false

proc moveListScrubber(r: GpuiRenderer; y: int) =
  for kind in [paneEventLog, paneCalltrace, paneFileTree, paneVcs,
               paneState]:
    if $kind == gListDrag.pane:
      scrubListPane(r, kind, y, dragging = true)

proc scrollInHand(r: GpuiRenderer; kind: PaneKind; dy: float) =
  ## M71 (#838): the wheel over the Files / VCS pane scrolls its rows (a
  ## line's worth of pixels at its pitch, at least one row a notch), the
  ## pane focused or not (CodeTracer-TUI.md §4.4's rule, which the desktop
  ## follows too).
  let pitch = if kind == paneFileTree: FileTreeRowPx else: VcsRowPx
  let rows = int(round(-dy / float(pitch)))
  let delta = if rows == 0: (if dy < 0.0: 1 else: -1) else: rows
  let sm = inHandScrubber(kind)
  setInHandTop(kind, clamp(sm.firstVisible + delta, 0, sm.maxFirstVisible))
  traceInHand(kind)
  redrawListPane(r, kind)
  # V6: the wheel at the end of the commits read reads more at once.
  if kind == paneVcs:
    followVcsViewport(r)

proc refreshEventLogMark() =
  ## After a move: ask the engine which row of the whole log is now "now"
  ## (`indexAtTick`, index only — no window, no redraw), so the scrubber's
  ## mark follows the debugger.
  if gSession.isNil:
    return
  let ev = gSession.session.store.eventLog
  let held = max(1, ev.rows.val.len)
  try:
    discard gSession.requestAndLoadEventLog(
      start = ev.loadedStart.val, count = held,
      atRRTicks = int64(gSession.getCurrentRRTicks()))
  except CatchableError:
    discard

proc refreshStateOrigins()
  ## PLAT-51: forward-declared; defined beside the state pane's clicks.

proc refreshMenuShortcuts()
  ## PLAT-68: forward-declared; the menu's chords, from the router.

proc focusWindowPane(r: GpuiRenderer; pane: string)
  ## PLAT-68: forward-declared; the focus, onto a pane's element.

proc dragTextTo(r: GpuiRenderer; x, y: int)
  ## PLAT-68: forward-declared; a held press on the text, moved.

func wheelDeltas*(dy, dx: float; shift: bool): tuple[dy, dx: float] =
  ## PLAT-70 (Horizontal-Overflow.md §4.3): Shift + the vertical wheel is a
  ## horizontal one — `dy` read as `dx` — when the device sent no `dx`.
  if shift and dx == 0.0: (0.0, dy) else: (dy, dx)

const GpuiWheelLinePx = 16.0 * 1.618034
  ## The pixels GPUI turns ONE line of wheel motion into — "the column
  ## equivalent of a line" is measured against it (Horizontal-Overflow.md
  ## §4.3). The shim reports a wheel as `ScrollDelta.pixel_delta(window
  ## .line_height())`, and the window's line height is GPUI's default text
  ## style's: 1 rem (16 px) at a line height of φ. Not a pane's row pitch:
  ## the editor's rows are `EditorLinePx` (22 px) high since the window's
  ## redesign, and dividing by that turned a Wayland notch (three lines,
  ## 77.7 px) into 21 columns instead of 3 × `WheelColumns`.
proc windowPointer(r0: GpuiRenderer; kind: GpuiEventKind; x, y: int;
                   dy = 0.0; dx = 0.0) =
  ## One pointer event of the window, wherever it came from: the root's
  ## listener (`pointerHandler`) and `--window-ops` (the plan's scripted
  ## pointer) both call this, so a scripted press is the press a user makes.
  var r = r0
  if kind in {gekPointerDown, gekContextMenu, gekAuxDown}:
    gAltTap.interrupted()        # Alt+press is not Alt tapped
  if gShell.isNil:
    return
  var step: GestureStep
  # PLAT-50: an open right-click menu or event content first.
  if kind in {gekPointerDown, gekContextMenu, gekAuxDown} and
     handlePopoverPress(r, kind, x, y):
    return
  # K19: a press anywhere leaves the Files pane's name field, which cancels
  # it (a press on a Files row has left it already, `onPaneClick`).
  if kind in {gekPointerDown, gekContextMenu, gekAuxDown}:
    leaveFilesField(r)
  case kind
  of gekContextMenu:
    # PLAT-50 (K42): a right-click on a docked pane's label opens the
    # desktop's strip menu (`ui/auto_hide`'s `onContextMenu`).
    let (si, sl) = gGeom.slotAt(x, y)
    if si >= 0 and sl >= 0:
      let strip = gGeom.strips[si]
      for k in PaneKind:
        if $k == strip.slots[sl].pane:
          openContextMenuAt(r, dockLabelContextMenu(k, strip.edge), x, y)
    return
  of gekPointerDown:
    # PLAT-48: the top bar, its popovers and the pin / unpin buttons first.
    if handleTopPress(r, x, y):
      return
    # PLAT-57: Find in Files' presses — first, because a revealed or
    # docked-open pane is drawn over (or beside) the tree, and the tree's
    # pane under a revealed one must not take the press.
    if pressSearch(r, x, y):
      return
    # PLAT-55: Problems' presses (a row opens its file at its line, a
    # filter, Group by File, the scrubber). A row's open focuses the editor
    # (EMT-D21), so the pane takes the focus only for the others.
    if pressProblems(r, x, y):
      return
    # PLAT-53: Test Results' presses (its ▶, a row's `⟳` / `⏵`, a row).
    if pressTests(r, x, y):
      gFocusShown = true
      if gFocusPane != $paneTestResults:
        focusWindowPane(r, $paneTestResults)
        discard drawArrangement(r)
      return
    # PLAT-54: Agent Activity's presses, on the same rule.
    if pressAgent(r, x, y):
      return
    # PLAT-51: A PRESS FOCUSES THE PANE UNDER IT (the desktop's selected
    # panel follows its clicks) — whatever the pane then does with the press
    # (a call row, a scrubber, the terminal output): its strip and outline
    # take the focus colour when the highlight is on.
    let pressedPane = gGeom.activePaneAt(x, y)
    if pressedPane.len > 0 and (pressedPane != gFocusPane or not gFocusShown):
      gFocusShown = true
      focusWindowPane(r, pressedPane)
      traceGesture("focus " & pressedPane)
      discard drawArrangement(r)
    # K19: an Edit window's Files pane hears no keys of its own; they stay
    # with the editor's listener, which hands the Files pane's name field
    # its keys first.
    if not openArm.isNil and pressedPane == $paneFileTree:
      focusEditKeys()
    # PLAT-51: a list pane's scrollbar scrubber BEFORE the pane's rows: the
    # track is drawn over the rows' right edge, and a press on it moves the
    # view — never the debugger, which a press on the call row under it
    # would.
    if pressListScrubber(r, x, y):
      return
    # PLAT-70: the editor's horizontal bar, before the row under it.
    if pressEditorBar(r, x, y):
      return
    # PLAT-70 Part I: a table pane's sideways bar, before the row under it.
    if pressTableHBar(r, x, y):
      return
    # M73 (#840): and its vertical scrubber.
    if pressEditorVBar(r, x, y):
      return
    # PLAT-70 Part B (Horizontal-Overflow.md §5): a press hides a shown
    # tooltip; an Event Log column separator is held for a resize; a cut
    # cell's `…` opens its row's detail — each before the row under it.
    dismissCellHover(r)
    if pressEventSeparator(r, x, y):
      return
    if pressEllipsis(r, x, y):
      return
    if clickCalltrace(r, x, y):
      return
    # PLAT-52: the Terminal Output pane's presses.
    if pressTerminalOutput(r, x, y):
      return
    # PLAT-51: a new tab's Welcome Screen owns the body.
    if welcomePress(r, x, y):
      return
    step = gGestures.pointerDown(committedLayout(), gGeom, x, y)
  of gekPointerMove:
    if gColumnDrag.active:
      dragEventSeparator(r, x, release = false)
      return
    if gEditorBarDrag:
      scrubEditorBar(r, x, click = false)
      return
    if gTableBarDrag.active:
      scrubTableHBar(r, gTableBarDrag.pane, x, click = false)
      return
    if gEditorVBarDrag:
      scrubEditorVBar(r, y, click = false)
      return
    if gTextDrag:
      dragTextTo(r, x, y)
      return
    if gTerminal.drag != gtdNone:
      moveTerminal(r, x, y)
      return
    if gSearch.dragging:
      let vm = searchVM()
      if not vm.isNil:
        gSearch.scrubSearch(vm, searchBody(), y, dragging = true)
        drawSearchPane(r)
      return
    if gProblemsPane.dragging:
      if not gProblems.isNil:
        gProblemsPane.scrubProblems(gProblems.vm, problemsBody(), y,
                                    dragging = true)
        drawProblemsPane(r)
      return
    if gTests.dragging:
      if not gTestsVM.isNil:
        gTests.scrubTests(gTestsVM, testsBody(), y, dragging = true)
        drawTestsPane(r)
      return
    if gAgent.dragging:
      let h = agentHost()
      if not h.isNil:
        gAgent.scrubAgent(h.feedRows(), agentBody(), y, dragging = true)
        drawAgentPane(r)
      return
    if gListDrag.active:
      moveListScrubber(r, y)
      return
    if not gGestures.active:
      handleTopHover(r, x, y)
      return
    step = gGestures.pointerMove(committedLayout(), gGeom, x, y)
  of gekPointerUp:
    # PLAT-70 Part H: the release ends any thumb's grab (the drag that ends
    # below still reads it for its last position).
    defer: barGrab.held = false
    if gColumnDrag.active:
      dragEventSeparator(r, x, release = true)
      return
    if gEditorBarDrag:
      scrubEditorBar(r, x, click = false)
      gEditorBarDrag = false
      return
    if gTableBarDrag.active:
      scrubTableHBar(r, gTableBarDrag.pane, x, click = false)
      gTableBarDrag.active = false
      return
    if gEditorVBarDrag:
      scrubEditorVBar(r, y, click = false)
      gEditorVBarDrag = false
      return
    if gTextDrag:
      dragTextTo(r, x, y)
      gTextDrag = false
      return
    if gTerminal.drag != gtdNone:
      releaseTerminal(r, x, y)
      return
    if gSearch.dragging:
      gSearch.dragging = false
      return
    if gAgent.dragging:
      gAgent.dragging = false
      return
    if gListDrag.active:
      moveListScrubber(r, y)
      gListDrag = ListScrubDrag()
      return
    if not gGestures.active: return
    step = gGestures.pointerUp(committedLayout(), gGeom, x, y)
    if step.command.isSome:
      let c = step.command.get
      # PLAT-49 part B: a label's click docked its pane open (or closed it):
      # the hover preview and its timers end.
      if c.kind == lcSetAutoHide and c.autoHideDirection in {ahOpen, ahClose}:
        gAutoHide.clicked()
      applyGestureCommand(r, c)
    if not gGestures.revealing:
      gAutoHide.overlayClosed()
  of gekWheel:
    # PLAT-50: a text over the window scrolls under the wheel.
    if gContent.open:
      gContent.top = max(0, gContent.top +
                            (if dy < 0.0: 3 elif dy > 0.0: -3 else: 0))
      drawTopBar(r)
      return
    # PLAT-57: the wheel scrolls Find in Files' rows (revealed or docked
    # open included), before the tree's pane under it.
    let search = searchBody()
    if search.w > 0 and search.contains(x, y) and dy != 0.0:
      let vm = searchVM()
      if not vm.isNil:
        let rows = int(round(-dy / float(SearchRowPx)))
        gSearch.scrollBy(vm, search, (if rows == 0: (if dy < 0: 1 else: -1)
                                      else: rows))
        drawSearchPane(r)
      return
    # PLAT-55: and Problems' list.
    let problemsRect = problemsBody()
    if problemsRect.w > 0 and problemsRect.contains(x, y) and dy != 0.0 and
       not gProblems.isNil:
      let rows = int(round(-dy / float(ProblemsRowPx)))
      gProblemsPane.scrollBy(gProblems.vm, problemsRect,
                             (if rows == 0: (if dy < 0: 1 else: -1) else: rows))
      drawProblemsPane(r)
      return
    # PLAT-53: and Test Results' list.
    let tests = testsBody()
    if tests.w > 0 and tests.contains(x, y) and dy != 0.0 and
       not gTestsVM.isNil:
      let rows = int(round(-dy / float(TestsRowPx)))
      gTests.scrollBy(gTestsVM, tests, (if rows == 0: (if dy < 0: 1 else: -1)
                                        else: rows))
      drawTestsPane(r)
      return
    # PLAT-54: and Agent Activity's lines.
    let agent = agentBody()
    if agent.w > 0 and agent.contains(x, y) and dy != 0.0:
      let h = agentHost()
      if not h.isNil:
        let rows = int(round(-dy / float(AgentRowPx)))
        gAgent.scrollBy(h.feedRows(), agent,
                        (if rows == 0: (if dy < 0: 1 else: -1) else: rows))
        drawAgentPane(r)
      return
    let onPane = gGeom.activePaneAt(x, y)
    # PLAT-70 (Horizontal-Overflow.md §4.3): a horizontal wheel — the
    # shim's `dx`, or Shift + the vertical wheel (`pointerHandler`) — moves
    # a text pane's view sideways, a line's worth of pixels a notch of
    # `WheelColumns` columns, and never its rows.
    if dx != 0.0 and onPane == $paneTerminalOutput:
      discard scrollTerminalColumns(r,
        wheelColumnsOf(-dx, GpuiWheelLinePx))
      return
    # PLAT-70 Part I (§5.5): over a table pane whose columns SCROLL, the
    # horizontal wheel moves its view — in pixels, a notch of
    # `WheelColumns` columns of the code face.
    if dx != 0.0 and onPane in [$paneCalltrace, $paneEventLog]:
      let kind = if onPane == $paneCalltrace: paneCalltrace else: paneEventLog
      let cols = wheelColumnsOf(-dx, GpuiWheelLinePx)
      let moved =
        if kind == paneCalltrace: callTraceHView.scrollBy(cols * gpuiCellUnits())
        else: eventLogHView.scrollBy(cols * gpuiCellUnits())
      if moved:
        traceGesture($kind & "-hscroll left=" &
                     $(if kind == paneCalltrace: callTraceHView.leftCol
                       else: eventLogHView.leftCol))
        redrawPaneOf(r, kind)
      if dy == 0.0:
        return
    if onPane == $paneCalltrace:
      # GPUI's wheel delta is the CONTENT's motion: a turn toward the user
      # (scroll down) moves the content up, a negative `dy`.
      scrollCalltrace(r, int(round(-dy / float(CalltraceRowPx))))
    elif onPane == $paneTerminalOutput and dy != 0.0:
      # PLAT-52: the wheel scrolls the line view, as the call trace's does.
      let vm = terminalVM()
      if not vm.isNil and not vm.screenShown:
        let lay = terminalLayout(terminalBody(), vm, gTerminal)
        let rows = int(round(-dy / float(TerminalRowPx)))
        let maxTop = max(0, vm.lineCount - lay.rows)
        gTerminal.scrollTop = max(0, min(maxTop,
          vm.visibleTop(gTerminal, lay.rows) + (if rows == 0: (if dy < 0: 1
                                                              else: -1)
                                                else: rows)))
        gTerminal.follow = false
        drawTerminalPane(r)
    elif onPane == $paneFileTree and dy != 0.0:
      # M71 (#838): the Files and VCS panes scroll their rows.
      scrollInHand(r, paneFileTree, dy)
    elif onPane == $paneVcs and dy != 0.0:
      scrollInHand(r, paneVcs, dy)
    elif onPane == $paneState and (dx != 0.0 or dy != 0.0):
      # The state scroll box scrolls both ways, as the desktop's does: the
      # rest of a long value and the rows below the box are reached.
      stateScroll = (clamp(stateScroll.top - int(round(dy)), 0, stateScrollMax.top),
                     clamp(stateScroll.left - int(round(dx)), 0, stateScrollMax.left))
      traceGesture("state scroll top=" & $stateScroll.top & " left=" &
                   $stateScroll.left)
      redrawPaneOf(r, paneState)
    elif onPane == $paneEditor and (dx != 0.0 or dy != 0.0):
      # `PLAT35-F3`. **THE EDITOR SCROLLS SIDEWAYS, and this is the half that
      # makes the clipped text reachable rather than merely announced.** The
      # sign convention is the call trace's one line up — the delta is the
      # CONTENT's motion, so content moving left is the view moving right.
      # `dx` is the shim's own (`input.rs` spells a wheel `"x,y,dx,dy"`); it
      # was parsed into `GpuiPointer` and dropped on the floor here until
      # this line, which is why no horizontal gesture reached any pane.
      if dx != 0.0:
        scrollEditorColumns(r, wheelColumnsOf(-dx, GpuiWheelLinePx))
      # M73 (#840): AND DOWN — the vertical wheel over the editor moves the
      # source window (CodeTracer-TUI.md §4.4, the terminal's rule; Monaco
      # scrolls itself on the desktop). Until M73 a `dy` here was dropped,
      # and only a stop moved the window. A line of wheel motion is
      # `GpuiWheelLinePx` (a Wayland notch is three), and at least one line
      # a report, so a fine-grained touchpad delta still moves it.
      if dy != 0.0:
        let lines = int(round(-dy / GpuiWheelLinePx))
        scrollEditorLines(r, (if lines != 0: lines
                              elif dy < 0.0: 1
                              else: -1))
    return
  else:
    return
  traceGesture(step.status)
  if step.relayout:
    # PLAT-51: the drag lifted its pane out (GoldenLayout's drag proxy): the
    # window is laid out without it, and this sample is decided against
    # that arrangement.
    discard drawArrangement(r)
    step = gGestures.pointerMove(committedLayout(), gGeom, x, y)
    traceGesture(step.status)
  if step.changed:
    discard drawArrangement(r)

proc pointerHandler(r0: GpuiRenderer): GpuiEventHandler =
  ## The root's pointer listener: every pointer event of the window. The
  ## root hears a press LAST (GPUI bubbles it from the row under the
  ## pointer), so a row's answer (`window_clicks`) is already in when the
  ## press reaches here; the next press is a new one (`PressDedupe`).
  result = proc(ev: GpuiEvent) =
    gPressDedupe.clear()
    let p = pointerOf(ev)
    if not p.valid:
      return
    let (dy, dx) = wheelDeltas(p.dy, p.dx, gmShift in ev.modifiers)
    gPointerShift = gmShift in ev.modifiers
    windowPointer(r0, ev.kind, int(p.x), int(p.y), dy, dx)

proc routeWindowKey(r: GpuiRenderer; key: string; mods: seq[string])
  ## PLAT-68: forward-declared; defined with the router below.

proc windowKey(key: string; mods: seq[string]) =
  ## One key of a replay window, from a pane's `keydown` listener or from
  ## `--window-ops`. What draws its own key handling first — the open
  ## program menu or a text shown over the window, a new tab's Welcome
  ## Screen, a folder tab's editor, the focused Terminal Output pane — then
  ## THE ROUTER, for everything else: the debugger's keys, the read-only
  ## editor's caret and selection, the palette's and the right-click menu's
  ## keys (their pushed layers), `Esc` ending a layout gesture.
  var r: GpuiRenderer
  # Any key between Alt's press and release makes it a chord, not a tap.
  if key != "alt":
    gAltTap.interrupted()
  # PLAT-70 Part B (§5.3): a key hides a shown table-cell tooltip.
  dismissCellHover(r)
  if handleTopKey(r, key, mods):
    return
  # PLAT-51: a new tab's Welcome Screen, and a folder tab's editor.
  if welcomeKey(r, key, mods):
    return
  if folderShown() and not openArm.isNil:
    editKey(key, mods)
    return
  # PLAT-52: the Terminal Output pane's own keys, while it has focus.
  if mods.len == 0 and terminalKey(r, key):
    return
  routeWindowKey(r, key, mods)

proc gestureKeyHandler(el: GpuiElement): GpuiEventHandler =
  ## A replay window's `keydown` listener: `Esc` cancels a layout gesture.
  ## (An edit window's editor listener does the same before typing a key.)
  result = proc(ev: GpuiEvent) =
    discard ev
    if el.lastEventKind() != gekKeyDown: return
    windowKey(el.lastEventKey(), modifierNamesOf(el.lastEventModifiers()))

proc windowModifiers(mods: seq[string]) =
  ## The held modifiers changed (GPUI's `modifierschange`, or `--window-ops`'
  ## `modifiers:`): `Alt` pressed and released ALONE is the key `Alt`
  ## (CUA-Keymap.md §3.8 — VS Code's menu-bar gesture; `alt_tap` decides).
  if gAltTap.modifiersChanged(keyModifiersOfGpui(mods)):
    traceGesture("alt tapped")
    windowKey("alt", @[])

proc modifiersHandler(el: GpuiElement): GpuiEventHandler =
  result = proc(ev: GpuiEvent) =
    discard ev
    if el.lastEventKind() != gekModifiers: return
    windowModifiers(modifierNamesOf(el.lastEventModifiers()))

proc armPaneKeys(r: GpuiRenderer; pane: GpuiElement) =
  ## A replay window's pane: focusable, its keys to `windowKey`, its modifier
  ## changes to `windowModifiers`.
  setFocusable(pane)
  r.addEventListener(pane, "keydown", gestureKeyHandler(pane))
  r.addEventListener(pane, "modifierschange", modifiersHandler(pane))

proc armPointer(r: GpuiRenderer; root: GpuiElement) =
  if gShell.isNil:
    return
  let handler = pointerHandler(r)
  for name in ["mousedown", "mousemove", "mouseup", "wheel", "contextmenu",
               "auxdown"]:
    r.addEventListener(root, name, handler)
  # A REPLAY window's keys: the editor pane takes focus (the pane the focus
  # outline marks) and `Esc` cancels a gesture. Not while the input probe
  # owns focus — its claim is that a key reached the pane IT focused — and
  # not in an edit window, whose editor listener is already armed.
  if openArm.isNil and not probeEnabled:
    # PLAT-68: EVERY pane takes the focus and hears the keys — the focused
    # one is the end of the focus chain the scope path is read from.
    for id, pane in gPanes:
      armPaneKeys(r, pane)
    focusWindowPane(r, gFocusPane)

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
  gHoverTool = -1
    ## The tool button under the pointer (`GToolButton` ordinal).
  gCertVm: CertificateIndicatorVm = nil
    ## The status bar's certificate indicator, over `gCertDir`.
  gCertDir = ""
  gHoverTab = -1
  gHoverTabAdd = false
    ## PLAT-49 part B: the pointer is on the strip's "+".
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
  gChrome: WindowChrome
    ## PLAT-69: THE WINDOW'S FRAME — whether the top bar is the title bar
    ## (client-side decorations), which window buttons it holds and where,
    ## and whether the window is maximized. Read from the renderer on every
    ## change it reports (`chromeChanged`); the server-side answer — no
    ## buttons, no drag strip — until it has reported one.
  gHoverWindowButton = -1
    ## PLAT-69: the window button under the pointer (its `GWindowButton`
    ## ordinal), drawn at half opacity as the desktop's are.
  gChromeSpec = ""
    ## PLAT-69: `--window-chrome`, the frame `--report-window-plan` draws.

type
  GpuiMenuRouteKind = enum
    ## How this window performs a menu item (`gpuiMenuRouteOf`).
    gmrNone
    gmrControl
      ## A debugger control (`control`), through `performControl`.
    gmrPane
      ## A View-menu pane brought forward (`pane`).
    gmrFindSymbol
    gmrFindInFiles
    gmrExit
      ## File › Exit CodeTracer: the event loop stopped (`gpui_quit`), which
      ## ends the window as its own close does.
    gmrNewTab
      ## File › New Trace Tab: the strip's "+" (`openWelcomeTab`).
    gmrWelcomeOption
      ## File › Open Trace… / Open Trace in New Tab… / Record New Trace…: the
      ## welcome tab's start option (`option`), in a new tab or the shown one.
    gmrStop
      ## M76 (codetracer#843): Debug › Stop — the toolbar's Stop (`gtbStop`),
      ## which the keymap's `debugger.stop` reaches through this table too.
    gmrPoint
      ## M76: a Debug-menu breakpoint or tracepoint item (`point`, the shared
      ## `point_menu_ops` table the terminal's menu reads too).

  GpuiMenuRoute = object
    ## The window's answer for one menu item, now: how it is performed and,
    ## when it cannot be, why (EMT-D14).
    kind: GpuiMenuRouteKind
    control: string
    pane: PaneKind
    option: WelcomeStartOptionKind
    newTab: bool
    point: PointMenuOp
    reason: string

const
  GpuiFileListReason =
    "the window's editor holds one file per tab; there is no list of open " &
    "files to step through"
    ## Close / Reopen / Next / Previous / Switch File act on an editor's open
    ## files; a GPUI edit tab is one file (`GpuiEditArm`).

proc gpuiMenuRouteOf(action: string): GpuiMenuRoute =
  ## THE ONE TABLE from a menu item's `ClientAction` to what this window does
  ## with it, read by both `gpuiMenuAvailability` (what the menu shows
  ## enabled) and `runGpuiMenuAction` (what choosing it does) — the
  ## terminal's `menuRouteOf`, with the performers this window has
  ## (codetracer#841: the enabled set was a separate static list, and it
  ## omitted even Exit).
  for c in TransportControls:
    if c.clientAction.len > 0 and c.clientAction == action:
      return GpuiMenuRoute(kind: gmrControl, control: c.id)
  case action
  of "findSymbol": GpuiMenuRoute(kind: gmrFindSymbol)
  of "findInFiles": GpuiMenuRoute(kind: gmrFindInFiles)
  of "aFilesystem": GpuiMenuRoute(kind: gmrPane, pane: paneFileTree)
  of "aFullCalltrace": GpuiMenuRoute(kind: gmrPane, pane: paneCalltrace)
  of "aState": GpuiMenuRoute(kind: gmrPane, pane: paneState)
  of "aEventLog": GpuiMenuRoute(kind: gmrPane, pane: paneEventLog)
  of "aTerminal": GpuiMenuRoute(kind: gmrPane, pane: paneTerminalOutput)
  of "aScratchpad": GpuiMenuRoute(kind: gmrPane, pane: paneScratchpad)
  of "aPointList": GpuiMenuRoute(kind: gmrPane, pane: panePointList)
  of "aAgentActivity": GpuiMenuRoute(kind: gmrPane, pane: paneAgentActivity)
  of "aExit": GpuiMenuRoute(kind: gmrExit)
  # File: the Welcome Screen's own flows (Multi-Window-Tab-Management.md rule
  # 3, Welcome-Screen.md § The native front-ends), as in the terminal.
  of "aNewTraceTab": GpuiMenuRoute(kind: gmrNewTab)
  of "aOpenTrace", "aOpenTraceInNewTab":
    GpuiMenuRoute(kind: gmrWelcomeOption, option: wsoOpenLocalTrace,
                  newTab: action == "aOpenTraceInNewTab")
  of "aRecordNewTrace":
    GpuiMenuRoute(kind: gmrWelcomeOption, option: wsoRecordNewTrace)
  of "closeTab", "reopenTab", "switchTabRight", "switchTabLeft",
     "switchTabHistory":
    GpuiMenuRoute(kind: gmrNone, reason: GpuiFileListReason)
  of StopMenuAction:
    # M76: Stop ends the session the window shows; with none it is disabled.
    GpuiMenuRoute(kind: gmrStop,
                  reason: (if gSession.isNil: "there is no debugging session to stop"
                           else: ""))
  else:
    let op = pointMenuOpOf(action)
    if op != pmoNone:
      GpuiMenuRoute(kind: gmrPoint, point: op,
                    reason: (if gSession.isNil: "the breakpoint and tracepoint " &
                               "items act on a replay: open a recording to debug it"
                             else: ""))
    else:
      GpuiMenuRoute(kind: gmrNone, reason: "not available in this window")

proc gpuiMenuAvailability(action: string): MenuAvailability =
  ## Whether this window can perform menu item `action` now, and why not.
  let route = gpuiMenuRouteOf(action)
  if route.reason.len > 0: unavailable(route.reason) else: availableNow()

proc refreshGpuiMenuAvailability() =
  ## Mark the menu's items from `gpuiMenuRouteOf` — at start-up and whenever
  ## the menu opens, so what is enabled is what the window can do then. The
  ## rest are drawn disabled — the same menu, honestly marked.
  if not gMenu.isNil:
    gMenu.setAvailability(gpuiMenuAvailability)

const
  MenuLogoIcon = staticRead("../../public/resources/menu/ct_logo_dark.svg")
    ## The desktop's `#menu-logo-img` (`ct-images-logo-dark`).
  SessionTabAddIcon = staticRead(
    "../../public/resources/shared/session_tab_add.svg").replace(
      "#DDDDDD", "#f3f3f3")
    ## `.session-tab-add`'s plus, in its `color: #b0b0b0`.
  StopIcon = staticRead("../../public/resources/debug/stop_16_dark.svg")
    ## `#stop-image` (`ct-images-stop`).
  RunTestsIcon = staticRead("../../public/resources/shared/run_test_img.svg")
    ## `#run-tests-image` (`ct-images-run-tests`).
  CopyPathIcon = staticRead("../../public/resources/menu/copy_file_path_dark.svg")
    ## The status bar's copy-path button (`ct-images-copy-path`).
  OmnibarSearchIcon = staticRead(
    "../../public/resources/shared/input_empty_search_icon_dark.svg")
    ## The omnibox's magnifier (`ct-images-empty-search-icon`).
  ControlInk = DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark]
    ## The ink of an enabled bar button: the desktop's
    ## `ct-button-image-md-secondary` colour, #b4b4b4 (measured 2026-10-17).

proc topBarSvgPath(name, svg: string): string =
  ## An icon of the bar, written once as an SVG file beside the marks.
  if gIconDir.len == 0:
    gIconDir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(gIconDir)
  let path = gIconDir / ("bar-" & name & ".svg")
  if not fileExists(path):
    writeFile(path, svg)
  path

proc toolSvgPath(tool: GToolButton; enabled: bool): string =
  ## A tool button's icon: the desktop's own mark for history and reset
  ## (`debug_control_marks`), its image for run tests and stop — in the
  ## controls' ink, or the disabled tier's when the window cannot act on it.
  let ink = if enabled: ControlInk else: chromeOf(crTabInactiveForeground)
  let suffix = if enabled: "-on" else: "-off"
  # The two images keep their own fills while enabled, as the desktop's
  # `background-image` buttons do.
  case tool
  of gtbRunTests:
    topBarSvgPath("run-tests" & suffix,
                  if enabled: RunTestsIcon else: RunTestsIcon.replace("#DDDDDD", ink))
  of gtbStop:
    topBarSvgPath("stop" & suffix,
                  if enabled: StopIcon else: StopIcon.replace("#ADAEAE", ink))
  else:
    var svg = svgMarkup(markFor($tool)).replace("currentColor", ink)
    svg = svg.replace("<svg ", "<svg width=\"" & $(2 * ControlIconPx) &
                      "\" height=\"" & $(2 * ControlIconPx) & "\" ")
    topBarSvgPath($tool & suffix, svg)

func toolIconSize(tool: GToolButton): (int, int) =
  ## Drawn at the desktop's `auto 1em`: 16 px high.
  case tool
  of gtbRunTests: (21, 16)
  else: (ControlIconPx, ControlIconPx)

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
    let ink = if enabled: ControlInk else: chromeOf(crTabInactiveForeground)
    var svg = svgMarkup(markFor(c.id)).replace("currentColor", ink)
    svg = svg.replace("<svg ", "<svg width=\"" & $(2 * ControlIconPx) &
                      "\" height=\"" & $(2 * ControlIconPx) & "\" ")
    writeFile(path, svg)
  path

const
  WindowButtonIcons: array[GWindowButton, tuple[svg: string; w, h: int]] = [
    (staticRead("../../public/resources/window/minimize_window_dark.svg"), 10, 2),
    (staticRead("../../public/resources/window/maximize_window_dark.svg"), 14, 11),
    (staticRead("../../public/resources/window/close_window_dark.svg"), 10, 10)]
    ## PLAT-69: THE DESKTOP'S OWN WINDOW-BUTTON ICONS (`.window-menu`'s
    ## `WINDOW_*_ICON_PATH`, `styles/default_dark_theme.styl`), compiled in
    ## and drawn at their own size in the 24 px circle, as the desktop draws
    ## them as a centred background. Dark only: this window has no light
    ## theme to take the `_16_white` set for.
  WindowRestoreIcon = (svg: staticRead(
    "../../public/resources/window/restore_window_dark.svg"), w: 14, h: 10)
    ## The maximize button of a MAXIMIZED window restores it, and says so.
    ## The desktop's dark theme points `.restore` at the maximize icon;
    ## this window draws the restore icon beside it in the same directory,
    ## so the swap the state makes is visible (`data-ct-window-button-icon`).

proc windowButtonSvgPath(button: GWindowButton; restore: bool): string =
  ## A window button's icon, written once as an SVG file for `img` beside
  ## the debugger's marks (and removed with them, `removeMarkFiles`).
  if gIconDir.len == 0:
    gIconDir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(gIconDir)
  let name = if restore: "restore" else: $button
  let path = gIconDir / ("window-" & name & ".svg")
  if not fileExists(path):
    writeFile(path, if restore: WindowRestoreIcon.svg
                    else: WindowButtonIcons[button].svg)
  path

proc tabIconSvgPath(svg: string): string =
  ## A tab icon, written once as an SVG file beside the debugger's marks.
  if gIconDir.len == 0:
    gIconDir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(gIconDir)
  let path = gIconDir / (if svg == TabPinIcon: "tab-pin.svg"
                         else: "tab-close.svg")
  if not fileExists(path):
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

proc footerLocation(): string =
  ## The status bar's location — the desktop's `.location-path`,
  ## `<path>:<line>#<ticks>` — or "" with no session.
  if gSession.isNil: ""
  else: gSession.getCurrentFile() & ":" & $gSession.getCurrentLine() & "#" &
        $gSession.getCurrentRRTicks()

proc certificateLabel(): string =
  ## The status bar's test-certificate indicator (`certificate_indicator_vm`,
  ## the desktop's `.test-certificate-label`), over the recording's source
  ## folder, read once per folder through the shipped native reader.
  if gSession.isNil:
    return ""
  let dir = gSession.getCurrentFile().parentDir
  if dir.len == 0:
    return ""
  if gCertVm.isNil or gCertDir != dir:
    gCertDir = dir
    gCertVm = newCertificateIndicatorVm(platformCertificateFactsReader(
      newDesktopNativePlatform(), dir, standardPlatformTriple(hostOS, hostCPU)))
    try:
      discard gCertVm.refresh(citStartup)
    except CatchableError:
      discard
  gCertVm.model.label

proc copyPathRect(): PxRect =
  ## The status bar's copy-path button (`#copy-path-image`, 26 px, 8 px from
  ## the window's right edge).
  if gGeom.footer.isEmpty or gSession.isNil: PxRect()
  else: PxRect(x: gGeom.footer.x + gGeom.footer.w - 34,
               y: gGeom.footer.y + (gGeom.footer.h - 26) div 2, w: 26, h: 26)

proc drawFocusOutline(r: GpuiRenderer) =
  ## PLAT-47 deliverable 9, GPUI's half, since 2026-10-17 an OVERLAY: the
  ## focused pane's 1px outline in the desktop's selected-panel colour
  ## (`chrome.paneOutlineStyle`), drawn over its box with the band's
  ## absolutely placed parts — the desktop's `.ct-selected-outline` — so
  ## focus moving never moves a pane's content and an unfocused pane has no
  ## frame at all.
  if not (gLayoutSettings.focusHighlight and gFocusShown):
    return
  for n in gGeom.nodes:
    if n.kind != gnTabs or n.panes.len == 0 or n.panes[n.active] != gFocusPane:
      continue
    let o = absBox(r, n.rect)
    r.setAttribute(o, "data-ct-focus-outline", gFocusPane)
    r.setStyle(o, "rounded", $TabRadiusPx & "px")
    for (key, value) in paneOutlineStyle(true):
      r.setStyle(o, key, value)
    gTopEls.add o

proc drawFooter(r: GpuiRenderer) =
  ## PLAT-49 part B (finding 9): THE WINDOW'S FOOTER — its status bar, along
  ## the bottom, full width — as the desktop's `#status-base` (measured
  ## 2026-10-17): the file info (language | encoding) on the left, then the
  ## bottom auto-hide labels as chips on the panel surface, each lit while its
  ## pane is previewed or docked open; on the right the test-certificate
  ## indicator, the location (`path:line#ticks`) and its copy button. All in
  ## the label face at 14 px, ui/text/primary/label-subtle.
  if gGeom.footer.isEmpty:
    return
  let ink = DesignTokenHex[dtColorsUiTextPrimaryLabelSubtle][dmDark]
  let f = absBox(r, gGeom.footer, chromeOf(crWindowBackground))
  r.setAttribute(f, "data-ct-footer", "status-bar")
  gTopEls.add f
  proc text(r: GpuiRenderer; parent: GpuiElement; s: string) =
    let t = r.createElement("div")
    r.setStyle(t, "font-size", "14px")
    r.setStyle(t, "white-space", "nowrap")
    r.setStyle(t, "flex-shrink", "0")
    r.appendChild(t, r.createTextNode(s))
    r.appendChild(parent, t)
  let rowY = gGeom.footer.y + (gGeom.footer.h - TabHeightPx) div 2
  # The file info FIRST, as the desktop's status bar opens with it
  # (`#file-info-status`): its parts with the desktop's `.separate-bar`
  # between them; the labels follow it (`footerLeadPx`).
  let info = footerInfo()
  if info.len > 0:
    let fi = absBox(r, PxRect(x: FooterFileInfoX, y: rowY,
                              w: FooterFileInfoPx, h: TabHeightPx))
    r.setAttribute(fi, "data-ct-footer-file-info", info)
    r.setStyle(fi, "color", ink)
    r.setStyle(fi, "gap", "9px")
    r.setStyle(fi, "overflow", "hidden")
    let parts: seq[string] = strutils.split(info, FooterInfoSeparator)
    for i, part in parts:
      if i > 0:
        let bar = r.createElement("div")
        r.setStyle(bar, "width", "1px")
        r.setStyle(bar, "height", "16px")
        r.setStyle(bar, "flex-shrink", "0")
        r.setStyle(bar, "background-color",
                   DesignTokenHex[dtColorsUiDividerPrimary][dmDark])
        r.appendChild(fi, bar)
      text(r, fi, part)
    gTopEls.add fi
  for st in gGeom.strips:
    if st.edge != leBottom or st.rect.isEmpty:
      continue
    # The bottom strip IS a part of the footer: one element naming its edge,
    # its labels inside it (placed relative to it).
    let strip = absBox(r, st.rect)
    r.setAttribute(strip, "data-ct-dock-strip", $st.edge)
    for sl in st.slots:
      let shown = (gGestures.revealing and $gGestures.reveal.pane == sl.pane) or
                  gGeom.openDockPane == sl.pane
      let b = absBox(r, PxRect(x: sl.rect.x - st.rect.x,
                               y: sl.rect.y - st.rect.y,
                               w: sl.rect.w, h: sl.rect.h),
                     chromeOf(if shown: crTabActiveBackground
                              else: crPaneBackground))
      r.setAttribute(b, "data-ct-dock-slot", sl.pane)
      r.setAttribute(b, "data-ct-tab-active", $shown)
      r.setStyle(b, "padding-left", $SlotPadPx & "px")
      r.setStyle(b, "rounded", $TabRadiusPx & "px")
      r.setStyle(b, "color", if shown: chromeOf(crTabActiveForeground) else: ink)
      text(r, b, sl.label)
      r.appendChild(strip, b)
    gTopEls.add strip
  if not gSession.isNil:
    # From the right: the copy button, the location before it, the
    # certificate label before that.
    let copy = copyPathRect()
    let cb = absBox(r, copy)
    r.setAttribute(cb, "data-ct-footer-copy-path", "true")
    r.setStyle(cb, "justify", "center")
    r.setStyle(cb, "rounded", "6px")
    let icon = r.createElement("img")
    r.setAttribute(icon, "src", topBarSvgPath("copy-path", CopyPathIcon))
    r.setStyle(icon, "width", "16px")
    r.setStyle(icon, "height", "16px")
    r.appendChild(cb, icon)
    gTopEls.add cb
    let location = footerLocation()
    let lw = groteskTextPx(location, 14.0)
    let lx = max(gGeom.footer.x, copy.x - 8 - lw)
    let p = absBox(r, PxRect(x: lx, y: rowY, w: copy.x - 8 - lx,
                             h: TabHeightPx))
    r.setAttribute(p, "data-ct-footer-position", location)
    r.setStyle(p, "color", ink)
    r.setStyle(p, "overflow", "hidden")
    text(r, p, location)
    gTopEls.add p
    let cert = certificateLabel()
    if cert.len > 0:
      let cw = groteskTextPx(cert, 14.0)
      let c = absBox(r, PxRect(x: lx - 8 - cw, y: rowY, w: cw, h: TabHeightPx))
      r.setAttribute(c, "data-ct-footer-certificate", cert)
      r.setStyle(c, "color", ink)
      text(r, c, cert)
      gTopEls.add c

proc wrapWords(text: string; maxChars: int): seq[string] =
  ## `text` broken at spaces into lines of at most `maxChars` characters, the
  ## way a desktop tooltip wraps at its maximum width. A word longer than
  ## `maxChars` keeps a line of its own, uncut (cutting could split a UTF-8
  ## sequence). Joining the lines with one space gives back the words.
  var line = ""
  for word in text.splitWhitespace:
    if line.len == 0:
      line = word
    elif line.len + 1 + word.len <= maxChars:
      line.add ' '
      line.add word
    else:
      result.add line
      line = word
  if line.len > 0:
    result.add line

proc menuRefusalLabel(): tuple[text: string, lines: seq[string], at: PxRect] =
  ## EMT-D14: the open menu's highlighted item, when it is disabled — its
  ## reason, and where the hover label shows it: beside the item's row, to
  ## the right of its popover, or to the left where the window ends first (a
  ## desktop menu's tooltip on a greyed-out item). Where neither side holds
  ## it on one line it wraps, into `lines`, on the roomier side, so it never
  ## covers the menu it explains; only a window too narrow for even that
  ## puts it over the popover, wrapped to the window. `lines` has one entry
  ## per drawn line. `("", @[], _)` when the highlighted item is enabled, a
  ## folder, or not drawn.
  const MinSidePx = 20 * TabCharPx + 2 * TabPadPx
    ## The narrowest side a wrapped reason is put on: about three words a
    ## line. Narrower than that, it reads better over the popover.
  if gMenu.isNil or not gMenu.isOpen:
    return
  let it = gMenu.highlightedItem()
  if refusalOf(it).len == 0:
    return
  let text = if it.reason.len > 0: it.reason else: MenuUnavailableReason
  var lv: MenuLevelView
  for l in gMenu.openLevels():
    if l.folderPath == gMenu.path: lv = l
  for p in gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                            pendingViewportHeight):
    if p.folderPath != gMenu.path:
      continue
    for row in p.rows:
      if row.item < 0 or lv.items[row.item].index != gMenu.highlight:
        continue
      let winW = pendingViewportWidth
      let oneLine = textPx(text) + 2 * TabPadPx
      let rightX = p.rect.x + p.rect.w + 4
      let rightRoom = winW - rightX
      let leftRoom = p.rect.x - 4
      # The side: the right where the one line fits, else the left, else
      # wrapped on the roomier of the two; over the popover only when both
      # are too narrow even for that.
      type Side = enum sRight, sLeft, sOver
      let (side, room) =
        if oneLine <= rightRoom: (sRight, rightRoom)
        elif oneLine <= leftRoom: (sLeft, leftRoom)
        elif rightRoom >= MinSidePx and rightRoom >= leftRoom:
          (sRight, rightRoom)
        elif leftRoom >= MinSidePx: (sLeft, leftRoom)
        else: (sOver, winW)
      let lines = wrapWords(text, max(1, (room - 2 * TabPadPx) div TabCharPx))
      var widest = 0
      for l in lines:
        widest = max(widest, textPx(l))
      let w = min(widest + 2 * TabPadPx, max(1, winW))
      let wanted = case side
        of sRight: rightX
        of sLeft: leftRoom - w # flush against the popover's left edge
        of sOver: 0
      let x = max(0, min(wanted, winW - w))
      let h = lines.len * HoverLabelPx
      let y = max(0, min(row.rect.y + (row.rect.h - HoverLabelPx) div 2,
                         pendingViewportHeight - h))
      return (text, lines, PxRect(x: x, y: y, w: w, h: h))

proc drawPopovers(r: GpuiRenderer) =
  ## The right-click menu and an event's content, over the window.
  # PLAT-50: THE RIGHT-CLICK MENU, on the desktop's dropdown surface, and an
  # event's CONTENT.
  if gCtxMenu.open:
    let rect = contextMenuRect(gCtxMenu, pendingViewportWidth,
                               pendingViewportHeight)
    let box = absBox(r, rect, chromeOf(crMenuBackground))
    r.setAttribute(box, "data-ct-context-menu", $gCtxMenu.menu.kind)
    r.setStyle(box, "rounded", "6px")
    r.setStyle(box, "border-width", "1px")
    r.setStyle(box, "border-color", chromeOf(crMenuBorder))
    gTopEls.add box
    for (rr, i) in contextMenuRows(gCtxMenu, rect):
      let e = gCtxMenu.menu.entries[i]
      let selected = i == gCtxMenu.selected and e.enabled
      let rb = absBox(r, rr,
                      if selected: chromeOf(crTabActiveBackground) else: "")
      r.setAttribute(rb, "data-ct-context-entry", e.label)
      r.setAttribute(rb, "data-ct-context-enabled", $e.enabled)
      r.setStyle(rb, "padding-left", $TabPadPx & "px")
      r.setStyle(rb, "white-space", "nowrap")
      r.setStyle(rb, "color", chromeOf(
        if not e.enabled: crTabInactiveForeground
        elif selected: crTabActiveForeground
        else: crWindowForeground))
      r.appendChild(rb, r.createTextNode(
        e.label & (if e.hint.len > 0: "   " & e.hint else: "")))
      gTopEls.add rb
  if gContent.open:
    let w = min(pendingViewportWidth - 80, 960)
    let h = min(pendingViewportHeight - 120, 640)
    let rect = PxRect(x: (pendingViewportWidth - w) div 2,
                      y: (pendingViewportHeight - h) div 2, w: w, h: h)
    let box = absBox(r, rect, chromeOf(crMenuBackground))
    r.setAttribute(box, "data-ct-event-content", gContent.title)
    r.setStyle(box, "rounded", "6px")
    r.setStyle(box, "border-width", "1px")
    r.setStyle(box, "border-color", chromeOf(crMenuBorder))
    r.setStyle(box, "flex-direction", "column")
    r.setStyle(box, "padding", $ChromePaddingPx & "px")
    let title = r.createElement("div")
    r.setStyle(title, "color", chromeOf(crPaneTitleForeground))
    r.appendChild(title, r.createTextNode(gContent.title))
    r.appendChild(box, title)
    if not gContent.refill.isNil:
      gContent.text = gContent.refill(gContent.top)
    let lines = gContent.text.replace("\\n", "\n").splitLines()
    let room = max(1, (h - 2 * ChromePaddingPx) div MenuItemPx - 1)
    for i in min(gContent.top, max(0, lines.high)) ..< lines.len:
      if i - gContent.top >= room:
        break
      let l = lines[i]
      let row = r.createElement("div")
      r.setAttribute(row, "data-ct-content-line", $i)
      r.setStyle(row, "white-space", "nowrap")
      r.setStyle(row, "color",
        if not gContent.diff: chromeOf(crWindowForeground)
        elif l.startsWith("+++") or l.startsWith("---"):
          chromeOf(crPaneTitleForeground)
        elif l.startsWith("+"): DiffAddedColour
        elif l.startsWith("-"): DiffRemovedColour
        elif l.startsWith("@@"): chromeOf(crTabInactiveForeground)
        else: chromeOf(crWindowForeground))
      r.appendChild(row, r.createTextNode(l))
      r.appendChild(box, row)
    gTopEls.add box

proc drawTopBar(r: GpuiRenderer) =
  ## The band and everything over it, from the shared ViewModels.
  if gRoot.isNil:
    return
  for e in gTopEls:
    r.removeChild(gRoot, e)
  gTopEls = @[]
  if gMenu.isNil:
    # K19: an Edit window draws no top bar, and its right-click menu — the
    # Files pane's — is still drawn over the window, and the Files rows a
    # redraw made take their presses.
    drawPopovers(r)
    for e in gTopEls:
      if gChrome.clientDecorated and
         getAttribute(e, WindowRegionAttribute).len == 0:
        r.setAttribute(e, WindowRegionAttribute, $wrNoDrag)
      r.appendChild(gRoot, e)
    wireClicks(r)
    return
  let tabs = if gShell.isNil: @[]
             else: mainShell().app.stripTabsOf(gWelcomeTabs)
  gTopLayout = gpuiTopBarLayout(gMenu, gOmnibar, tabs, pendingViewportWidth,
                                canAddTab = gSessionsOpened.len > 0,
                                windowButtons = gChrome.shownButtons)
  # PLAT-69 (C2): WHERE THE APPLICATION DRAWS THE WINDOW'S FRAME, THE BAR IS
  # ITS TITLE BAR. A transparent strip the width of the window, from its top
  # edge to the band's bottom, is a drag region: a press on any of it that
  # nothing in front of it takes moves the window, a double-click maximizes
  # and a right-click opens the window menu — all the renderer's, none of it
  # code here. It is drawn FIRST, under the band and every part, so the
  # padding above and beside the band drags too, as the desktop's
  # full-width `#menu` does; the parts are marked `no-drag` below. Where the
  # platform draws the frame there is no strip (PLAT-69-AREQ3).
  if gChrome.clientDecorated:
    let strip = absBox(r, PxRect(x: 0, y: 0, w: pendingViewportWidth,
                                 h: TopBarPx))
    r.setAttribute(strip, WindowRegionAttribute, $wrDrag)
    r.setAttribute(strip, "data-ct-window-drag", "title-bar")
    gTopEls.add strip
  # PLAT-50: the band is the desktop's caption bar — the window's own ground
  # (ui/surface/primary/default), no card of its own.
  let band = absBox(r, gTopLayout.band, chromeOf(crWindowBackground))
  r.setAttribute(band, "data-ct-top-bar", "band")
  gTopEls.add band
  # The desktop's `.separate-bar` before each group of buttons.
  for sep in gTopLayout.separators:
    let bar = absBox(r, sep, DesignTokenHex[dtColorsUiDividerPrimary][dmDark])
    r.setAttribute(bar, "data-ct-top-separator", "true")
    gTopEls.add bar
  drawFooter(r)
  drawFocusOutline(r)
  let enabled = controlsEnabled()
  for sg in gTopLayout.segs:
    case sg.part
    of gtMenuButton:
      let b = absBox(r, sg.rect)
      r.setAttribute(b, "data-ct-menu-button", $gMenu.isOpen)
      r.setStyle(b, "justify", "center")
      for (k, v) in tabStyle(gMenu.isOpen): r.setStyle(b, k, v)
      # PLAT-50: the desktop's `#menu-root` — the bar's ground inside a 1px
      # ui/border/secondary border — and, since 2026-10-17, its LOGO
      # (`#menu-logo-img`, 20 px) where this window drew a "≡".
      r.setStyle(b, "rounded", "6px")
      if not gMenu.isOpen:
        r.setStyle(b, "border-width", "1px")
        r.setStyle(b, "border-color", chromeOf(crFieldBorder))
      let logo = r.createElement("img")
      r.setAttribute(logo, "src", topBarSvgPath("logo", MenuLogoIcon))
      r.setStyle(logo, "width", "20px")
      r.setStyle(logo, "height", "20px")
      r.appendChild(b, logo)
      gTopEls.add b
    of gtControl:
      let on = sg.index < enabled.len and enabled[sg.index]
      # PLAT-50: a control has no ground of its own (the desktop's buttons
      # are the bar's); the hovered one is lifted.
      let b = absBox(r, sg.rect,
                     if gHoverControl == sg.index:
                       chromeOf(crTabActiveBackground)
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
    of gtTool:
      # The desktop's bar buttons beside the transport controls: history back
      # and forward, reset, run tests, stop — in the controls' ink, lifted
      # under the pointer like them.
      let tool = GToolButton(sg.index)
      let b = absBox(r, sg.rect,
                     if gHoverTool == sg.index: chromeOf(crTabActiveBackground)
                     else: "")
      r.setAttribute(b, "data-ct-tool", $tool)
      r.setStyle(b, "justify", "center")
      r.setStyle(b, "rounded", "6px")
      let on = toolAvailable(tool)
      r.setAttribute(b, "data-ct-enabled", $on)
      let icon = r.createElement("img")
      r.setAttribute(icon, "src", toolSvgPath(tool, on))
      let (iw, ih) = toolIconSize(tool)
      r.setStyle(icon, "width", $iw & "px")
      r.setStyle(icon, "height", $ih & "px")
      r.appendChild(b, icon)
      gTopEls.add b
    of gtOmnibar:
      # PLAT-49: AN INPUT BOX on the input surface; empty, it shows the
      # Omnibar ViewModel's placeholder — the desktop's and the terminal's
      # words — and open, the query with its caret (a thin bar while
      # inserting, a block while overwriting) where the ViewModel's
      # `cursor` is.
      # PLAT-51 (Commands-And-Omnibox.md, "Omnibox colours on every
      # front-end"): THE EDITOR'S GROUND AND FOREGROUND in every state —
      # idle, hovered, focused / typing — and the placeholder in the
      # editor's muted foreground; the border stays ui/border/secondary.
      # (PLAT-50's input surface, `crInputBackground`, is superseded.)
      # 2026-10-17: the bar's own ground, as the desktop's
      # `.command-input-row` is measured (#1b1b1b) — not the editor's.
      let b = absBox(r, sg.rect, chromeOf(crWindowBackground))
      r.setAttribute(b, "data-ct-omnibar", $gOmnibar.isOpen)
      r.setStyle(b, "rounded", "6px")
      # PLAT-50: bounded as the desktop's `.command-input-row` is.
      r.setStyle(b, "border-width", "1px")
      r.setStyle(b, "border-color", chromeOf(crFieldBorder))
      r.setStyle(b, "white-space", "nowrap")
      r.setStyle(b, "overflow", "hidden")
      # The desktop's field (measured 2026-10-17): its magnifier
      # (`.ct-input-search-image`, 14 px at 0.5em) and the text from 1.875em,
      # in 14 px — the placeholder in the body tier at 45%, a query in the
      # field's own #c8c8c8. Only the magnifier when the band is too narrow
      # for the field.
      let field = gTopLayout.omnibarField or gOmnibar.isOpen
      if not field:
        r.setStyle(b, "justify", "center")
      else:
        r.setStyle(b, "padding-left", "6px")
      let glass = r.createElement("img")
      r.setAttribute(glass, "src", topBarSvgPath("search", OmnibarSearchIcon))
      r.setStyle(glass, "width", "14px")
      r.setStyle(glass, "height", "14px")
      r.setStyle(glass, "flex-shrink", "0")
      r.appendChild(b, glass)
      let showsQuery = gOmnibar.isOpen and gOmnibar.query.len > 0
      r.setAttribute(b, "data-ct-omnibar-placeholder",
                     $(gOmnibar.query.len == 0))
      if field:
        let gap = r.createElement("div")
        r.setStyle(gap, "width", "5px")
        r.setStyle(gap, "flex-shrink", "0")
        r.appendChild(b, gap)
        let text = r.createElement("div")
        r.setStyle(text, "font-size", "14px")
        r.setStyle(text, "white-space", "nowrap")
        r.setStyle(text, "overflow", "hidden")
        let caret = if gOmnibar.overwrite: "█" else: "▏"
        if showsQuery:
          let c = min(gOmnibar.cursor, gOmnibar.query.len)
          r.setStyle(text, "color", "#c8c8c8")
          r.appendChild(text, r.createTextNode(gOmnibar.query[0 ..< c] &
            caret & gOmnibar.query[c .. ^1]))
        else:
          # The desktop's placeholder as it lands: #c8c8c8 (measured).
          r.setStyle(text, "color", DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark])
          r.appendChild(text, r.createTextNode(
            (if gOmnibar.isOpen: caret else: "") & OmnibarPlaceholder))
        r.appendChild(b, text)
      gTopEls.add b
    of gtTab:
      # PLAT-49 part B (finding 7): EACH SESSION TAB A SEPARATE ITEM on its
      # own ground — the active one the strips' selected tab, the others the
      # strip's card — with the agent's indicator and progress in its text,
      # rounded as the desktop's `.session-tab` is.
      let t = tabs[sg.index]
      let b = absBox(r, sg.rect,
                     chromeOf(if t.active: crTabActiveBackground
                              else: crTabStripBackground))
      r.setAttribute(b, "data-ct-session-tab", t.title)
      r.setAttribute(b, "data-ct-tab-active", $t.active)
      r.setAttribute(b, "data-ct-tab-label", sessionTabText(t))
      if t.agent.present:
        r.setAttribute(b, "data-ct-tab-agent", $t.agent.lifecycle)
      r.setStyle(b, "padding-left", $TabPadPx & "px")
      r.setStyle(b, "rounded", "6px")
      r.setStyle(b, "white-space", "nowrap")
      r.setStyle(b, "overflow", "hidden")
      for (k, v) in tabStyle(t.active): r.setStyle(b, k, v)
      r.appendChild(b, r.createTextNode(sessionTabText(t)))
      gTopEls.add b
    of gtTabClose:
      let cb = absBox(r, sg.rect)
      r.setAttribute(cb, "data-ct-session-tab-close", $sg.index)
      r.setStyle(cb, "justify", "center")
      r.setStyle(cb, "color", chromeOf(crTabInactiveForeground))
      r.appendChild(cb, r.createTextNode(SessionTabCloseGlyph))
      gTopEls.add cb
    of gtTabAdd:
      # PLAT-49 part B: the desktop's `.session-tab-add` — a borderless
      # button, lit under the pointer, its tooltip "New tab".
      # Since 2026-10-17 the desktop's circle: a 26 px disc on
      # ui/surface/primary/tertiary with its 12 px plus (`#menu
      # .session-tab-add`), lighter under the pointer.
      let ab = absBox(r, sg.rect,
                      chromeOf(if gHoverTabAdd: crFocusOutline
                               else: crTabActiveBackground))
      r.setAttribute(ab, "data-ct-session-tab-add", NewSessionTabTitle)
      r.setStyle(ab, "justify", "center")
      r.setStyle(ab, "rounded", $(sg.rect.h div 2) & "px")
      let plus = r.createElement("img")
      r.setAttribute(plus, "src", topBarSvgPath("session-tab-add",
                                                SessionTabAddIcon))
      r.setStyle(plus, "width", "12px")
      r.setStyle(plus, "height", "12px")
      r.appendChild(ab, plus)
      gTopEls.add ab
    of gtWindowButton:
      # PLAT-69 (C3): THE DESKTOP'S `.window-menu` BUTTON — a 24 px circle
      # with the desktop's icon centred, at half opacity under the pointer.
      # The REGION is what acts (`data-window-region`: the renderer
      # minimizes, toggles maximize, or closes through the window's own
      # close path, which ends this process as a compositor close does); the
      # press also reaches `handleTopPress`, which takes it and does nothing
      # more.
      let button = GWindowButton(sg.index)
      let restore = button == gwbMaximize and gChrome.maximized
      let icon = if restore: WindowRestoreIcon else: WindowButtonIcons[button]
      let wb = absBox(r, sg.rect)
      r.setAttribute(wb, "data-ct-window-button", $button)
      r.setAttribute(wb, "data-ct-window-button-icon",
                     if restore: "restore" else: $button)
      r.setAttribute(wb, WindowRegionAttribute, $button)
      r.setStyle(wb, "justify", "center")
      r.setStyle(wb, "rounded", $(WindowButtonPx div 2) & "px")
      if gHoverWindowButton == sg.index:
        r.setStyle(wb, "opacity", "0.5")
      let img = r.createElement("img")
      r.setAttribute(img, "src", windowButtonSvgPath(button, restore))
      r.setStyle(img, "width", $icon.w & "px")
      r.setStyle(img, "height", $icon.h & "px")
      r.appendChild(wb, img)
      gTopEls.add wb
  # THE MENU'S POPOVERS: a native-looking menu — rows on the pane surface,
  # the open path and the highlight lifted, the chord right-aligned.
  for p in gpuiMenuPopovers(gMenu, gTopLayout, pendingViewportWidth,
                            pendingViewportHeight):
    # PLAT-50: the desktop's dropdown surface and border, apart from the
    # panes it opens over.
    let box = absBox(r, p.rect, chromeOf(crMenuBackground))
    r.setAttribute(box, "data-ct-menu-popover", $p.folderPath)
    r.setStyle(box, "rounded", "6px")
    r.setStyle(box, "border-width", "1px")
    r.setStyle(box, "border-color", chromeOf(crMenuBorder))
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
                      if it.active: chromeOf(crTabActiveBackground) else: "")
      r.setAttribute(rb, "data-ct-menu-item", it.label)
      r.setAttribute(rb, "data-ct-menu-active", $it.active)
      r.setStyle(rb, "padding-left", $TabPadPx & "px")
      r.setStyle(rb, "color", chromeOf(
        if not it.enabled: crTabInactiveForeground
        elif it.active: crTabActiveForeground
        else: crWindowForeground))
      if it.active:
        r.setStyle(rb, "font-weight", "bold")
      var tail = ""
      if it.shortcut.len > 0: tail.add "   " & it.shortcut
      if it.folder: tail.add "  ›"
      if it.mnemonic >= 0:
        # The folder's access key underlined (CUA-Keymap.md §3.8:
        # `Alt+<letter>`), the label in three runs on one line.
        r.setStyle(rb, "flex-direction", "row")
        let m = it.mnemonic
        if m > 0:
          r.appendChild(rb, r.createTextNode(it.label[0 ..< m]))
        let key = r.createElement("span")
        r.setStyle(key, "text-decoration", "underline")
        r.setAttribute(key, "data-ct-menu-mnemonic", $it.label[m])
        r.appendChild(key, r.createTextNode($it.label[m]))
        r.appendChild(rb, key)
        r.appendChild(rb, r.createTextNode(it.label[m + 1 .. ^1] & tail))
      else:
        r.appendChild(rb, r.createTextNode(it.label & tail))
      gTopEls.add rb
  # THE OMNIBAR'S RESULTS.
  let op = gpuiOmnibarPopover(gOmnibar, gTopLayout, pendingViewportHeight)
  if op.rows.len > 0:
    # PLAT-51: the results list on the EDITOR'S ground too (its border the
    # menu's), the selected row on the editor's selection colour under the
    # editor's foreground.
    let box = absBox(r, op.rect, EditorGround)
    r.setAttribute(box, "data-ct-omnibar-results", $gOmnibar.results.len)
    r.setStyle(box, "border-width", "1px")
    r.setStyle(box, "border-color", chromeOf(crMenuBorder))
    gTopEls.add box
    for row in op.rows:
      let selected = row.item >= 0 and row.item == gOmnibar.selected
      let rb = absBox(r, row.rect,
                      if selected: EditorSelectionColour else: "")
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
      r.setStyle(rb, "color",
                 if row.item < 0: EditorLineNumberColour else: EditorTextColour)
      r.appendChild(rb, r.createTextNode(text))
      gTopEls.add rb
  drawPopovers(r)
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
  # THE HOVER LABEL: a disabled menu item's reason, a control's tooltip and
  # key, or an auto-hide label's pane, beside the pointer's target.
  var hoverText = ""
  var hoverAt = PxRect()
  var hoverLines: seq[string] = @[]
    ## Set only by a wrapped reason: one entry per line drawn.
  let refusal = menuRefusalLabel()
  if refusal.text.len > 0:
    # EMT-D14: the highlighted menu item is disabled, by the keyboard or the
    # pointer — the open menu lies over the band, so its reason comes first.
    (hoverText, hoverAt) = (refusal.text, refusal.at)
    hoverLines = refusal.lines
  elif gHoverControl >= 0:
    let sg = gTopLayout.segOf(gtControl, gHoverControl)
    hoverText = controlTooltip(gHoverControl,
                               gMenu.shortcutFor(
                                 TransportControls[gHoverControl].clientAction))
    hoverAt = PxRect(x: sg.rect.x, y: sg.rect.y + sg.rect.h + 2,
                     w: textPx(hoverText) + 2 * TabPadPx, h: HoverLabelPx)
  elif gHoverTab >= 0 and gHoverTab < tabs.len:
    # PLAT-49 part B: a session tab's tooltip — its title, and with an agent
    # in the session its task, state and progress (`SessionTabView.tooltip`).
    let sg = gTopLayout.segOf(gtTab, gHoverTab)
    hoverText = tabs[gHoverTab].tooltip
    hoverAt = PxRect(x: sg.rect.x, y: sg.rect.y + sg.rect.h + 6,
                     w: textPx(hoverText) + 2 * TabPadPx, h: HoverLabelPx)
  elif gHoverTabAdd:
    let sg = gTopLayout.segOf(gtTabAdd)
    hoverText = NewSessionTabTitle
    hoverAt = PxRect(x: sg.rect.x, y: sg.rect.y + sg.rect.h + 6,
                     w: textPx(hoverText) + 2 * TabPadPx, h: HoverLabelPx)
  # (An auto-hide label's hover shows its PANE — the preview, PLAT-49 part B
  # — not a hint label: the desktop's strip tab has none.)
  if hoverText.len > 0:
    let hb = absBox(r, hoverAt, chromeOf(crWindowBackground))
    r.setAttribute(hb, "data-ct-hover-label", hoverText)
    r.setStyle(hb, "padding-left", $TabPadPx & "px")
    r.setStyle(hb, "white-space", "nowrap")
    for (k, v) in paneOutlineStyle(true): r.setStyle(hb, k, v)
    if hoverLines.len > 1:
      # A wrapped reason: one row per line, stacked.
      r.setStyle(hb, "flex-direction", "column")
      r.setStyle(hb, "items", "start")
      for l in hoverLines:
        let lb = r.createElement("div")
        r.setAttribute(lb, "data-ct-hover-label-line", l)
        r.setStyle(lb, "height", $HoverLabelPx & "px")
        r.setStyle(lb, "items", "center")
        r.setStyle(lb, "white-space", "nowrap")
        r.appendChild(lb, r.createTextNode(l))
        r.appendChild(hb, lb)
    else:
      r.appendChild(hb, r.createTextNode(hoverText))
    gTopEls.add hb
  # PLAT-70 Part B (Horizontal-Overflow.md §5.3): A TRUNCATED CELL'S FULL
  # TEXT, after the pointer rested on it 500 ms — under the cell (above it
  # when the window has no room below), wrapped at min(80 columns, the
  # window), at most `DetailMaxLines` lines.
  if gCellTooltip.len > 0:
    var widest = 0
    for l in gCellTooltip:
      widest = max(widest, l.runeLen)
    let a = gCellHoverAnchor
    let w = min(pendingViewportWidth, pxOfText(widest) + 2 * TabPadPx)
    let h = gCellTooltip.len * HoverLabelPx
    let below = a.y + a.h
    let y = if below + h <= pendingViewportHeight: below else: max(0, a.y - h)
    let x = max(0, min(a.x, pendingViewportWidth - w))
    let tb = absBox(r, PxRect(x: x, y: y, w: w, h: h),
                    chromeOf(crWindowBackground))
    r.setAttribute(tb, CellTooltipAttribute, gCellHover.key & "|" &
                                             gCellHover.column)
    r.setStyle(tb, "display", "flex")
    r.setStyle(tb, "flex-direction", "column")
    r.setStyle(tb, "items", "start")   # the lines left-aligned, as wrapped
    r.setStyle(tb, "padding-left", $TabPadPx & "px")
    r.setStyle(tb, "font-family", MonoFontFamily)
    for (k, v) in paneOutlineStyle(true): r.setStyle(tb, k, v)
    for l in gCellTooltip:
      let line = r.createElement("div")
      r.setStyle(line, "height", $HoverLabelPx & "px")
      r.setStyle(line, "white-space", "nowrap")
      r.appendChild(line, r.createTextNode(l))
      r.appendChild(tb, line)
    gTopEls.add tb
  for e in gTopEls:
    # PLAT-69 (C2): EVERY PART AND POPOVER IS `no-drag`, so a press on one
    # stays a press. They are absolutely placed SIBLINGS of the strip, not
    # its children, and the renderer's rule is that the topmost element
    # under the pointer decides — an element with no listener of its own
    # (every part here: the root's listener hit-tests them) would otherwise
    # let the press through to the strip behind it and move the window.
    # The band itself is the bar's empty space and stays draggable; the
    # strip and the window buttons carry their own regions. Inert where
    # the platform draws the frame, and not written there.
    if gChrome.clientDecorated and
       getAttribute(e, WindowRegionAttribute).len == 0 and
       getAttribute(e, "data-ct-top-bar") != "band":
      r.setAttribute(e, WindowRegionAttribute, $wrNoDrag)
    r.appendChild(gRoot, e)
  # PLAT-50: the rows a redraw made get their click listeners.
  wireClicks(r)
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
      of gtTool: label = $GToolButton(sg.index)
      of gtWindowButton: label = $GWindowButton(sg.index)
      else: discard
      var seg = %*{"part": $sg.part, "index": sg.index, "label": label,
                   "rect": rect(sg.rect)}
      if sg.part == gtWindowButton:
        # PLAT-69: what the button shows — the maximize button of a
        # maximized window shows (and does) restore.
        seg["icon"] = %(if GWindowButton(sg.index) == gwbMaximize and
                           gChrome.maximized: "restore"
                        else: label)
      segs.add seg
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
  # PLAT-69: THE WINDOW'S FRAME, AS THE RENDERER REPORTED IT, and what the
  # window asked for at launch — the app's own account, labelled as such: a
  # window lane reads where the window IS from the compositor, and this is
  # what it compares that with (and the vacuity guard's "the top bar is the
  # title bar").
  proc names(bs: seq[GWindowButton]): JsonNode =
    result = newJArray()
    for b in bs: result.add %($b)
  let shown = gChrome.shownButtons
  top["window"] = %*{
    "clientDecorated": gChrome.clientDecorated,
    "live": gChrome.live,
    "maximized": gChrome.maximized,
    "supported": names(gChrome.supported),
    "preferredLeft": names(gChrome.buttons.left),
    "preferredRight": names(gChrome.buttons.right),
    "left": names(shown.left), "right": names(shown.right),
    "buttonLayout": gChrome.buttonLayout,
    "placementSource": gChrome.placementSource,
    "platform": gChrome.platform,
    "drag": (if gChrome.clientDecorated:
               rect(PxRect(x: 0, y: 0, w: pendingViewportWidth,
                           h: TopBarPx))
             else: newJNull()),
    "content": [pendingViewportWidth, pendingViewportHeight],
    "title": gWindowTitle,
    "appId": windowAppId(),
    "launch": {"maximized": gLaunch.maximized, "width": gLaunch.width,
               "height": gLaunch.height, "minWidth": gLaunch.minWidth,
               "minHeight": gLaunch.minHeight,
               "explicitSize": gLaunch.explicitSize}}
  top

# ---------------------------------------------------------------------------
# PLAT-69 (C4) — what the window is called
# ---------------------------------------------------------------------------

var gProgramOf = initTable[string, string]()
  ## Each recording's program, read once (`recordedProgramOf`).

proc recordedProgramOf(traceFolder: string): string =
  ## The program a recording ran, by its file name — what the desktop's
  ## window title names (`ui_js.traceLoaded`: `baseName(trace.program)`).
  ## Read from the recording's own metadata: a CTFS container's `meta.dat`,
  ## else a materialized recording's `trace_metadata.json`. A recording whose
  ## metadata cannot be read is named by its folder, as its session tab is.
  let folder = traceFolder.strip(leading = false, chars = {'/'})
  if gProgramOf.hasKey(folder):
    return gProgramOf[folder]
  var program = ""
  try:
    for container in walkFiles(folder / "*.ct"):
      program = readCtfsMetaDat(container).program
      if program.len > 0: break
  except CatchableError:
    program = ""
  if program.len == 0 and fileExists(folder / "trace_metadata.json"):
    try:
      let meta = parseJson(readFile(folder / "trace_metadata.json"))
      if meta.kind == JObject and meta{"program"}.kind == JString:
        program = meta["program"].getStr
    except CatchableError:
      program = ""
  result = if program.len > 0: program.extractFilename
           else: folder.extractFilename
  gProgramOf[folder] = result

proc windowTitleFor(session: HeadlessDebugSession): string =
  ## THE DESKTOP'S TITLE FORMAT: `<program> — CodeTracer` while a recording
  ## is shown (`displayed_product.sessionDocumentTitle`, the title the
  ## desktop's page sets and its window shows), and `CodeTracer` otherwise —
  ## an Edit window, a Welcome Screen — as the desktop's is.
  if session.isNil: sessionDocumentTitle("", "CodeTracer")
  else: sessionDocumentTitle(recordedProgramOf(session.tracePath), "CodeTracer")

proc noteWindowTitle(title: string) =
  ## The window is called `title` from now on (the session shown changed).
  if title == gWindowTitle:
    return
  gWindowTitle = title
  setWindowTitle(title)

proc loopZonesOf(surface: EditorSurface): seq[LoopZone] =
  ## The flow's loop controls for the editor's file (`FlowVM.loops`): each
  ## loop's first line, the iteration the debugger is in (the last whose
  ## first tick is at or before the current one) and the iteration count.
  if gSession.isNil or gSession.session.flowVM.isNil or
     not surface.flowOverlayVisible:
    return
  let tick = int(gSession.getCurrentRRTicks())
  for loop in gSession.session.flowVM.loops.val:
    let count = loop.rrTicksForIterations.len
    if count <= 0 or loop.first <= 0: continue
    # Only a loop whose first line is drawn: the zone sits above that row.
    var drawn = false
    for row in surface.rows:
      if row.line == loop.first: drawn = true
    if not drawn: continue
    var iteration = 0
    for i, t in loop.rrTicksForIterations:
      if t <= tick: iteration = i
    result.add LoopZone(line: loop.first, iteration: iteration, count: count)

proc stickyLinesOf(surface: EditorSurface):
    seq[tuple[line: int; text: string; top: int]] =
  ## The sticky scope headers for the editor's view (`leaves.stickyScopeLines`)
  ## over the file's whole text (`GpuiSourceService.fileLines`). The line at
  ## the viewport's top edge is the one partly hidden above the first whole
  ## row when the view sits at a sub-row offset (`editorTopInsetPx`).
  if gSourceService.isNil or surface.viewportTop <= 1 or
     not gSourceService.fileLines.hasKey(surface.path):
    return
  let file = gSourceService.fileLines[surface.path]
  let offset = editorTopInsetPx() - EditorPadTopPx
  for (line, top) in stickyScopeLines(file, surface.viewportTop, offset):
    result.add (line, file[line - 1], top)

proc redrawReplayEditor(r: GpuiRenderer) =
  ## The replay editor drawn again from the source window as it now holds,
  ## at the pane's current width: after a move (`refreshReplayWindow`) and
  ## after the window resized (PLAT-69). The horizontal view is the caret's
  ## to move (PLAT-70, `drawEditorBody`), so neither resets it.
  let editor = gPanes.getOrDefault($paneEditor)
  if editor.isNil or gSourceService.isNil or gSession.isNil:
    return
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
  # PLAT-51: the caret stays where the user put it (a move does not move
  # it), on the file it was placed in — it is the file's document's
  # (PLAT-68), and so is the selection.
  # The flow's values are on the surface already (`editor_surface.
  # flowValuesByLine`, the rule the terminal draws too).
  gEditorSurface = withDebugDocument(surface)
  r.setStyle(editor, "padding-top", $max(0, editorTopInsetPx()) & "px")
  editorLoopZones = loopZonesOf(gEditorSurface)
  block:
    let i = gGeom.tabsNodeOfPane($paneEditor)
    if i >= 0: editorPaneHeightPx = gGeom.nodes[i].body.h
  let sticky = stickyLinesOf(gEditorSurface)
  traceGesture("editor top=" & $gEditorSurface.viewportTop & " inset=" &
               $editorTopInsetPx() & " rows=" & $gEditorSurface.rows.len &
               " end=" & $(not gSourceService.isNil and gSourceService.bottomAligned) &
               " sticky=" & $sticky.len & " full=" &
               $(if gSourceService.isNil: 0 else: gSourceService.fullRows) &
               " total=" & $(if gSourceService.isNil: 0 else: gSourceService.vm.totalLineCount.val) &
               " file=" & $(if gSourceService.isNil: -1
                            elif gSourceService.fileLines.hasKey(gEditorSurface.path):
                              gSourceService.fileLines[gEditorSurface.path].len
                            else: -1))
  drawEditorBody(r, editor, sticky)
  # A negative inset starts the rows above the editor's top: the first row
  # is pulled up by it, the pane's clip cutting off what is above.
  let inset = editorTopInsetPx()
  if inset < 0:
    for k in 0 ..< childCount(editor):
      let child = nthChild(editor, k)
      if getAttribute(child, EditorRowAttribute).len > 0:
        r.setStyle(child, "margin-top", $inset & "px")
        break
  noteEditorTab(r, editorTabLabel(surface.path, false))
  # The state pane's code line (`updateCodeStateLine`, what the desktop's
  # editor feeds it): the stop's line and its source, unindented.
  for row in gEditorSurface.rows:
    if row.pointer == eptExecution and row.held:
      gSession.session.store.updateCodeStateLine(row.line, row.text.strip())

proc refreshReplayWindow(r: GpuiRenderer) =
  ## After the debugger moved: the source window, the stop's panes, every
  ## live leaf drawn again from its ViewModel (the call trace with its whole
  ## count), the editor from a fresh surface, and the top bar (the controls'
  ## availability moved too).
  if gSession.isNil:
    return
  # PLAT-50: a move takes the editor back to the debugger's file.
  gViewedFile = ""
  if not gSourceService.isNil:
    gSourceService.serveWindow()
  discard gSession.loadStopPanes()
  # PLAT-49 part B: the call the debugger is in, selected, as on the desktop.
  gSession.selectCurrentCall()
  # PLAT-51: and the event log's current row, for its scrubber's mark; and
  # the value-origin chains open in the Variables pane, re-read here.
  refreshEventLogMark()
  refreshStateOrigins()
  # PLAT-70: the horizontal view is the CARET's to move (§4.5): a stop that
  # moved the caret is followed by `drawEditorBody`; one that did not leaves
  # the view where the reader put it.
  redrawReplayEditor(r)
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin != paneEditor:
      let pane = gPanes.getOrDefault($leaf.builtin)
      if not pane.isNil and not leaf.vm.isNil:
        redrawWindowLeaf(r, pane, leaf)
  drawTerminalPane(r)
  drawSearchPane(r)
  drawTestsPane(r)
  drawProblemsPane(r)
  drawListScrubbers(r)
  gOmnibar.setIndex(omnibarIndexOf(gSession.session.fileTreeVM,
                                   gSession.session.store, gMenu,
      terminalSettings = false) &
                    gRecordings)
  drawTopBar(r)

proc attachVcs(leafSet: var GpuiLeafSet; directory: string)
  ## Forward-declared for `showSession`; defined beside the ticks.
proc attachTests(leafSet: var GpuiLeafSet)
  ## PLAT-53: forward-declared for `showSession`; defined beside the ticks.
proc attachProblems(leafSet: var GpuiLeafSet)
  ## PLAT-55: forward-declared for `showSession`; defined beside the ticks.

proc showSession(r: GpuiRenderer; id: HeadlessSessionId) =
  ## PLAT-49 part B: the window shows the session behind tab `id` — its
  ## engine, its source window, its ViewModels in every leaf — drawn from
  ## its current stop (`refreshReplayWindow`). The arrangement stays the
  ## window's.
  if gShell.isNil or not gSessionsOpened.hasKey(int(id)):
    return
  if not gShell.showSessionIn(gWindow, id):
    return
  gSession = gSessionsOpened[int(id)]
  applyRememberedColumnWidths()
  let rows = editorRowsOf(gGeom)
  gSourceService = newGpuiSourceService(gSession, gSession.tracePath, rows)
  var leafSet = gShell.leavesFor(gWindow)
  attachVcs(leafSet, getCurrentDir())
  attachTests(leafSet)
  attachProblems(leafSet)
  gLeafSet = leafSet
  traceGesture("session shown " & $id & " " & gSession.tracePath)
  # PLAT-69: the window is called after the recording it shows.
  noteWindowTitle(windowTitleFor(gSession))
  refreshReplayWindow(r)
  discard drawArrangement(r)

proc openRecordingInTab(r: GpuiRenderer; path: string) =
  ## PLAT-49 part B: the "+"'s choice — `path` opened in a new session tab
  ## (spawned, adopted, its panes loaded as the first one's were), then
  ## shown. A folder that is not a recording is refused, and said so.
  var opened: HeadlessDebugSession = nil
  try:
    # The open and the first pane loads, renderer-free in the host
    # (`gpui_host.openTabSession`, where a suite drives it without a window).
    # A folder that does not open, and an engine that read the recording and
    # then went quiet while the tab opened (the open's clock is still on
    # here), are both refused here; the second arrives worded as a stall
    # after the open, its engine already closed rather than left in a tab
    # nobody can use.
    opened = openTabSession(path, FlowOverlayShownByDefault and
                                  not gOpenCmd.noFlowOverlay)
  except CatchableError as e:
    let verdict = if e of GpuiTabStalledError: " stalled: " else: " refused: "
    traceGesture("open " & path & verdict & e.msg.splitLines()[0])
    stderr.writeLine("codetracer-gpui: could not open " & path & ": " &
                     e.msg.splitLines()[0])
    drawTopBar(r)
    return
  # PLAT-52 / Q3: the Terminal Output's lines are asked for as the pane is
  # drawn (`drawTerminalPane`), the window it shows.
  opened.openTerminalOutput()
  # Opened, and from here on it answers the user in this window: the open's
  # clock comes off, as it does for the first session before `launchWindow`.
  liftOpenBound(opened)
  let idx = gShell.windows.indexOf(gWindow)
  let layout = if idx >= 0: gShell.windows.windows[idx].layout
               else: sharedDefaultValue()
  let slot = gShell.app.openSession(
    opened.backend.toBackendService(),
    title = extractFilename(opened.tracePath.strip(chars = {'/'})),
    layout = layout, adopt = opened.sdk)
  wireSearch(opened)
  gSessionsOpened[int(slot.id)] = opened
  traceGesture("opened " & path & " as tab " & $slot.id)
  showSession(r, slot.id)

proc closeSessionTab(r: GpuiRenderer; index: int) =
  ## PLAT-49 part B: tab `index`'s close control — its session and its
  ## engine stopped (rule 4), and the window shows the tab that is active
  ## next. The last tab is not closed (no close control is drawn on it).
  let tabs = gShell.app.tabsOf()
  if index < 0 or index >= tabs.len or tabs.len < 2:
    return
  let id = tabs[index].id
  if not gShell.app.closeTab(index, disconnectBackend = false):
    return
  if gSessionsOpened.hasKey(int(id)):
    # PLAT-54: its Agent Activity host goes with it (keyed by the session's
    # address, which a later session may reuse).
    let key = cast[int](gSessionsOpened[int(id)])
    if gAgentHosts.hasKey(key):
      gAgentHosts[key].close()
      gAgentHosts.del(key)
    gSessionsOpened[int(id)].close()
    gSessionsOpened.del(int(id))
  traceGesture("closed tab " & $id)
  showSession(r, gShell.app.activeSessionId())

# ---------------------------------------------------------------------------
# PLAT-51 deliverable 8: a new tab's Welcome Screen
# ---------------------------------------------------------------------------


proc shownWelcome(): NativeWelcome =
  ## The Welcome Screen being shown, or nil.
  let w = gWelcomeTabs
  if not w.welcomeShown or w.shownTab.kind != wtkWelcome or
     w.active >= gWelcomes.len:
    return nil
  gWelcomes[w.active]

proc folderShown(): bool =
  gWelcomeTabs.welcomeShown and gWelcomeTabs.shownTab.kind == wtkFolder

proc drawWelcome(r: GpuiRenderer): GpuiElement =
  ## The shown Welcome Screen over the layout area, from the shared model's
  ## rows (`welcome_leaf.welcomeLayoutPx` places them).
  let w = shownWelcome()
  let area = gGeom.area
  let root = absBox(r, area, chromeOf(crPaneBackground))
  result = root
  r.setAttribute(root, "data-ct-welcome", "shown")
  r.setStyle(root, "rounded", "4px")
  r.setStyle(root, "flex-direction", "column")
  if w.isNil:
    return
  let rows = w.rowsOf()
  gWelcomeLayout = welcomeLayoutPx(rows, area)
  let lay = gWelcomeLayout
  proc place(rect: PxRect; text, colour: string; bg = ""): GpuiElement =
    let e = r.createElement("div")
    r.setStyle(e, "position", "absolute")
    r.setStyle(e, "left", $(rect.x - area.x) & "px")
    r.setStyle(e, "top", $(rect.y - area.y) & "px")
    r.setStyle(e, "width", $max(1, rect.w) & "px")
    r.setStyle(e, "height", $max(1, rect.h) & "px")
    r.setStyle(e, "items", "center")
    r.setStyle(e, "white-space", "nowrap")
    r.setStyle(e, "overflow", "hidden")
    r.setStyle(e, "color", colour)
    if bg.len > 0:
      r.setStyle(e, "background-color", bg)
    if text.len > 0:
      r.appendChild(e, r.createTextNode(text))
    r.appendChild(root, e)
    e
  let heading = place(lay.heading, NativeWelcomeHeading,
                      chromeOf(crPaneTitleForeground))
  r.setStyle(heading, "justify", "center")
  r.setStyle(heading, "font-weight", "bold")
  r.setStyle(heading, "font-size", "20px")
  var anyFolder, anyTrace = false
  for row in rows:
    if row.kind == nwrRecentFolder: anyFolder = true
    if row.kind == nwrRecentTrace: anyTrace = true
  for (panel, title, any, empty) in [
      (lay.foldersPanel, RecentFoldersHeading, anyFolder, RecentFoldersEmpty),
      (lay.tracesPanel, RecentTracesHeading, anyTrace, RecentTracesEmpty)]:
    discard place(panel, "", chromeOf(crWindowForeground),
                  chromeOf(crTabStripBackground))
    let t = place(PxRect(x: panel.x + 8, y: panel.y + 4, w: panel.w - 16,
                         h: WelcomeRowPx), title, chromeOf(crPaneTitleForeground))
    r.setStyle(t, "font-weight", "bold")
    if not any:
      discard place(PxRect(x: panel.x + 8, y: panel.y + 4 + WelcomeRowPx,
                           w: panel.w - 16, h: WelcomeRowPx), empty,
                    chromeOf(crTabInactiveForeground))
  for i, row in rows:
    let rect = lay.rowRects[i]
    if rect.isEmpty:
      continue
    let focused = i == w.focus and w.form == nwfNone
    let colour =
      if row.kind == nwrOption and not row.enabled:
        chromeOf(crTabInactiveForeground)
      else: chromeOf(crTabActiveForeground)
    let bg =
      if focused: chromeOf(crFocusOutline)
      elif row.kind == nwrOption and row.enabled: chromeOf(crTabActiveBackground)
      else: ""
    let text = if row.kind == nwrOption: row.label
               else: row.label & "   " & row.detail
    let e = place(rect, text, colour, bg)
    if row.kind == nwrOption:
      r.setStyle(e, "justify", "center")
      r.setStyle(e, "rounded", "4px")
    else:
      r.setStyle(e, "padding-left", "6px")
    r.setAttribute(e, "data-ct-welcome-row", $row.kind & ":" & row.key)
    r.setAttribute(e, "data-ct-welcome-enabled", $row.enabled)
    r.setAttribute(e, "data-ct-welcome-focus", $focused)
  if w.form != nwfNone:
    let prompt = formPrompt(w.form)
    let shownText = if w.input.len == 0 and w.placeholder.len > 0:
                      prompt & w.placeholder
                    else: prompt & w.input & "▏"
    let field = place(lay.line, shownText,
                      chromeOf(crWindowForeground), chromeOf(crInputBackground))
    r.setAttribute(field, "data-ct-welcome-input", w.input)
    r.setAttribute(field, "data-ct-welcome-form", $w.form)
    r.setStyle(field, "padding-left", "6px")
    if w.message.len > 0:
      let m = place(PxRect(x: lay.line.x, y: lay.line.y + WelcomeRowPx + 6,
                           w: lay.line.w, h: WelcomeRowPx), w.message,
                    chromeOf(crTabActiveForeground))
      r.setAttribute(m, "data-ct-welcome-message", w.message)
  elif w.message.len > 0:
    let m = place(lay.line, w.message, chromeOf(crTabActiveForeground))
    r.setAttribute(m, "data-ct-welcome-message", w.message)
  elif w.focus >= 0 and w.focus < rows.len and rows[w.focus].kind == nwrOption and
       not rows[w.focus].enabled:
    discard place(lay.line, rows[w.focus].detail,
                  chromeOf(crTabInactiveForeground))

proc armRecordTick()
  ## Forward-declared; defined with the shim's tick below.

proc runWelcomeIntent(r: GpuiRenderer; index: int)

# ---------------------------------------------------------------------------
# K19 in Edit mode: the opened folder's Files tree, acting on the disk
# (codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "In the terminal
# and GPUI") — the terminal's model (`projectTreeOf` over the project walk)
# and its disk half (`native_file_tree`), drawn by `renderFileTree`.
# ---------------------------------------------------------------------------

proc editFileOperationDone(root: string; res: FileTreeOperationResult)

proc editFolderRoot(folder: string): string =
  ## The opened folder, absolute and without a trailing separator — the
  ## spelling of the tree's own row (`projectTreeOf`).
  result = absolutePath(folder).normalizedPath
  while result.len > 1 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc relistEditFiles(vm: FilesystemVM; root: string) =
  ## The opened folder walked again, so the pane follows the disk; the
  ## folders the reader opened stay open, and the folder's own row is.
  vm.setRoot(projectTreeOf(root, listProjectFiles(root).files))
  vm.expandPath(root)

proc editFilesVMOf(folder: string): FilesystemVM =
  ## The opened folder's Files model, made once per folder: Create, Rename
  ## and Delete carried out here by the index process's rules, Delete asking
  ## first.
  let root = editFolderRoot(folder)
  result = gEditFiles.getOrDefault(root)
  if not result.isNil:
    return
  result = createFilesystemVM(nil)
  wireNativeFileOperations(result, proc(): string = root,
    proc(res: FileTreeOperationResult) = editFileOperationDone(root, res))
  relistEditFiles(result, root)
  gEditFiles[root] = result

proc attachEditFiles(leafSet: var GpuiLeafSet; folder: string) =
  ## Hand the Files leaf, when the arrangement places one, the opened
  ## folder's model — as `attachVcs` hands the VCS leaf its own.
  for leaf in leafSet.leaves.mitems:
    if leaf.kind == glkBuiltin and leaf.builtin == paneFileTree:
      leaf.vm = ViewModel(editFilesVMOf(folder))

proc windowFilesVM(): FilesystemVM =
  ## The Files model the window's tree is drawn from: the opened folder's in
  ## Edit mode (an Edit window, a folder tab), else the replay's.
  if not openArm.isNil: editFilesVMOf(openArm.root)
  elif not gSession.isNil: gSession.session.fileTreeVM
  else: nil

proc filesSay(what: string) =
  ## What the Files pane has to say — an operation's outcome, a disabled
  ## entry's reason: in Edit mode the editor's notice (the window has no
  ## status line there), and the gesture trace.
  traceGesture("files: " & what)
  if not openArm.isNil:
    openArm.status = what
    redrawEditor()

proc openEditFile(path: string): bool =
  ## Edit mode's K17 (and the Files menu's Edit, and a new file): the file
  ## at `path` in the editor, through an edit arm of its own — the buffer
  ## of the file shown before is kept, unchanged, for when it is opened
  ## again. False, with the reason as the notice, when it cannot be read.
  if openArm.isNil:
    return false
  let root = editFolderRoot(openArm.root)
  let shown = joinTreePath(root, openArm.path)
  if not gEditArms.hasKey(shown):
    gEditArms[shown] = openArm
  if path == shown:
    return true
  var arm = gEditArms.getOrDefault(path)
  if arm.isNil:
    let rel = relativeToRoot(root, path)
    if rel.len == 0:
      filesSay(path & ": is outside the project folder")
      return false
    var text = ""
    try:
      text = readProjectFile(root, rel)
    except CatchableError as e:
      filesSay(e.msg)
      return false
    arm = newGpuiEditArm(root, rel, text, openArm.doc.model)
    gEditArms[path] = arm
  openArm = arm
  if folderShown():
    gFolderArms[gWelcomeTabs.shownTab.serial] = arm
  traceGesture("editing " & arm.path)
  redrawEditor()
  focusEditKeys()
  true

proc editFileOperationDone(root: string; res: FileTreeOperationResult) =
  ## The disk's answer to a Create, Rename or Delete: the folder listed
  ## again, a new file opened in the editor (Filesystem-Pane.md, "Create
  ## makes an empty file and opens it in the editor"), what changed or why
  ## not said. Open buffers are left alone.
  var r: GpuiRenderer
  let vm = gEditFiles.getOrDefault(root)
  if res.error.len == 0 and not vm.isNil:
    relistEditFiles(vm, root)
  if res.error.len == 0 and res.operation == ftaCreate:
    discard openEditFile(res.path)
  filesSay(describeFileTreeOperation(res, root))
  redrawPaneOf(r, paneFileTree)

proc filesFieldKey(key: string; mods: seq[string]): bool =
  ## A key while the Files model has its name field or Delete's question
  ## open: the field's (`file_tree_menu.applyFilesFieldKey`), the pane drawn
  ## again. False when nothing is open.
  let vm = windowFilesVM()
  if not vm.filesFieldOpen():
    return false
  var r: GpuiRenderer
  case vm.applyFilesFieldKey(canonicalKeyOfGpui(key, mods))
  of ffsNotOpen:
    return false
  of ffsRefused:
    traceGesture("files: " & vm.nameEdit.val.error)
  of ffsCancelled:
    traceGesture("files: cancelled")
  of ffsAbsorbed, ffsTyped, ffsCommitted:
    discard
  redrawPaneOf(r, paneFileTree)
  true

proc editOverlayKey(key: string; mods: seq[string]): bool =
  ## An Edit window's key before its editor: the Files pane's open name field
  ## or question, then `Esc` on an open right-click menu (which the window
  ## draws over the editor, with no top bar of its own to route it).
  if filesFieldKey(key, mods):
    return true
  if gCtxMenu.open and key.toLowerAscii in ["escape", "esc"]:
    var r: GpuiRenderer
    gCtxMenu.close()
    drawTopBar(r)
    return true
  false

proc leaveFilesField(r: GpuiRenderer) =
  ## A press elsewhere while the name field or the question is open:
  ## leaving the field cancels it (Filesystem-Pane.md § "Create and Rename").
  let vm = if openArm.isNil: nil else: windowFilesVM()
  if vm.cancelFilesField():
    traceGesture("files: cancelled")
    redrawPaneOf(r, paneFileTree)

proc showFolderTab(r: GpuiRenderer; index: int): string =
  ## A FOLDER tab shown: the window's Edit default (a shell window of its
  ## own with no session), its editor writing the folder's first file
  ## through the editing core (`app/edit_arm`), keys to it — Edit mode over
  ## the folder, as the terminal's folder tab is.
  if index < 0 or index >= gWelcomeTabs.tabs.len:
    return "that tab is gone"
  let tab = gWelcomeTabs.tabs[index]
  var arm = gFolderArms.getOrDefault(tab.serial)
  if arm.isNil:
    let problem = editProjectProblem(tab.folder)
    if problem.len > 0:
      return problem
    let listing = listProjectFiles(tab.folder)
    if listing.files.len == 0:
      return "no source files under " & tab.folder
    let preference = sessionKeymap(gOpenCmd.keymap)
    arm = newGpuiEditArm(tab.folder, listing.files[0],
                         readProjectFile(tab.folder, listing.files[0]),
                         preference.model)
    if preference.status in {kplRefused, kplMigrated}:
      arm.status = preference.message
    gFolderArms[tab.serial] = arm
  if gMainShell.isNil:
    gMainShell = gShell
  if gEditShell.isNil:
    gEditShell = newGpuiShell(gMainShell.viewport)
    discard gEditShell.openWindow(WindowId(0),
                                  initLayout(sharedEditLayout().tree, sharedEditLayout().docked))
  gWelcomeTabs.active = index
  gShell = gEditShell
  gWindow = WindowId(0)
  var leafSet = gShell.leavesFor(gWindow)
  attachVcs(leafSet, tab.folder)
  attachEditFiles(leafSet, tab.folder)   # K19: the folder's Files tree
  # PLAT-53: the window's project is the folder now (§8.2).
  gTestsRoot = tab.folder
  attachTests(leafSet)
  # PLAT-55: a `:build` runs in the folder now.
  gBuildRoot = tab.folder
  attachProblems(leafSet)
  gLeafSet = leafSet
  openArm = arm
  if editViewportRows <= 0:
    editViewportRows = max(1, editorRowsOf(gGeom))
  gEditorSurface = arm.surfaceOf(editViewportRows)
  gEditorTab = editorTabLabel(arm.root / arm.path, arm.isDirty)
  # The editor leaf is drawn again for this surface (`adoptNewLeaves`).
  for id in [$paneEditor, $paneFileTree, $paneVcs]:
    if gPanes.hasKey(id):
      let pane = gPanes[id]
      let parent = r.parentNode(pane)
      if not parent.isNil:
        r.removeChild(parent, pane)
      gPanes.del(id)
  discard drawArrangement(r)
  editPane = gPanes.getOrDefault($paneEditor)
  redrawEditor()
  drawTopBar(r)
  traceGesture("folder tab " & tab.folder)
  ""

proc leaveFolder(r: GpuiRenderer) =
  ## Back from a folder tab: the replay window and its session's editor.
  if gMainShell.isNil or gShell == gMainShell:
    return
  openArm = nil
  editPane = nil
  gShell = gMainShell
  gWindow = WindowId(0)
  for id in [$paneEditor, $paneFileTree, $paneVcs]:
    if gPanes.hasKey(id):
      let pane = gPanes[id]
      let parent = r.parentNode(pane)
      if not parent.isNil:
        r.removeChild(parent, pane)
      gPanes.del(id)

proc showWelcomeTab(r: GpuiRenderer; index: int) =
  if index < 0 or index >= gWelcomeTabs.tabs.len:
    return
  if gWelcomeTabs.tabs[index].kind == wtkFolder:
    let why = showFolderTab(r, index)
    if why.len > 0:
      traceGesture("folder refused: " & why)
    return
  leaveFolder(r)
  gWelcomeTabs.active = index
  traceGesture("welcome tab " & $index)
  discard drawArrangement(r)
  drawTopBar(r)

proc showSessionTab(r: GpuiRenderer; index: int) =
  leaveFolder(r)
  gWelcomeTabs.active = -1
  discard gShell.app.activateTab(index)
  showSession(r, gShell.app.activeSessionId())
  drawTopBar(r)

proc openWelcomeTab(r: GpuiRenderer) =
  ## The strip's "+" (Multi-Window-Tab-Management.md rule 3): a new tab
  ## showing the Welcome Screen, from the shared model.
  var traces: seq[string] = @[]
  for e in gRecordings:
    traces.add e.target
  leaveFolder(r)
  discard gWelcomeTabs.addWelcomeTab()
  gWelcomes.add newNativeWelcome(gRecentFolders, traces)
  traceGesture("new welcome tab " & $gWelcomeTabs.active)
  discard drawArrangement(r)
  drawTopBar(r)

proc closeWelcomeTabAt(r: GpuiRenderer; index: int) =
  if index < 0 or index >= gWelcomeTabs.tabs.len:
    return
  let wasShown = gWelcomeTabs.active == index
  gWelcomeTabs.closeWelcomeTab(index)
  if index < gWelcomes.len:
    gWelcomes.delete(index)
  if wasShown:
    leaveFolder(r)
    showSession(r, gShell.app.activeSessionId())
  discard drawArrangement(r)
  drawTopBar(r)

proc runWelcomeIntent(r: GpuiRenderer; index: int) =
  ## The welcome tab's choice, performed — the tab turns into the session
  ## it starts (the terminal's `welcomeHost`, the same three flows).
  if index < 0 or index >= gWelcomes.len:
    return
  let w = gWelcomes[index]
  let intent = w.takeIntent()
  case intent.kind
  of niNone:
    discard
  of niOpenTrace:
    let path = absolutePath(intent.path.expandTilde())
    let problem = traceFolderProblem(path)
    if problem.len > 0:
      w.message = path & ": " & problem
    else:
      let before = gShell.app.tabsOf().len
      leaveFolder(r)
      gWelcomeTabs.active = -1
      openRecordingInTab(r, path)
      if gShell.app.tabsOf().len > before:
        gWelcomeTabs.closeWelcomeTab(index)
        gWelcomes.delete(index)
        var known = false
        for e in gRecordings:
          if e.target == path: known = true
        if not known:
          gRecordings.insert(OmnibarEntry(kind: OmnibarMode.omRecording,
                                          label: extractFilename(path),
                                          detail: path.parentDir,
                                          target: path), 0)
      else:
        gWelcomeTabs.active = index
        w.message = "could not open " & path
  of niRecord:
    if not gRecordJob.isNil and not gRecordJob.done:
      w.message = "a recording is already running: " & gRecordJob.program
    else:
      let stamp = now().format("yyyyMMdd-HHmmss")
      let output = nativeStateRoot() / "recordings" /
                   (extractFilename(intent.program).changeFileExt("") & "-" &
                    stamp)
      gRecordJob = startRecordJob(intent.program, intent.args, output)
      gRecordSerial = gWelcomeTabs.tabs[index].serial
      if gRecordJob.done:
        w.message = gRecordJob.message
      else:
        traceGesture("recording " & intent.program & " -> " & output)
        armRecordTick()
  of niOpenFolder:
    let path = absolutePath(intent.path.expandTilde())
    let problem = editProjectProblem(path)
    if problem.len > 0:
      w.message = problem
    else:
      gWelcomeTabs.turnIntoFolder(index, path)
      let at = gRecentFolders.find(path)
      if at >= 0: gRecentFolders.delete(at)
      gRecentFolders.insert(path, 0)
      let why = showFolderTab(r, index)
      if why.len > 0:
        w.message = why
  discard drawArrangement(r)
  drawTopBar(r)

proc pollWelcomeRecording(r: GpuiRenderer): bool =
  ## The background `ct record`, once it finishes: its recording opened in
  ## the tab that asked, or the failure on that tab's screen.
  if not pollRecordJob(gRecordJob):
    return false
  var at = -1
  for i, t in gWelcomeTabs.tabs:
    if t.serial == gRecordSerial: at = i
  if at < 0 or at >= gWelcomes.len:
    return true
  if gRecordJob.ok:
    gWelcomes[at].vm.loadRecentTrace(gRecordJob.outputFolder)
    let wasActive = gWelcomeTabs.active
    gWelcomeTabs.active = at
    runWelcomeIntent(r, at)
    if gWelcomeTabs.active < 0 and wasActive != at:
      discard
  else:
    gWelcomes[at].message = gRecordJob.message
    traceGesture(gRecordJob.message)
    discard drawArrangement(r)
  true

proc pollTestRun(r: GpuiRenderer): bool =
  ## The top bar's `ct record-test`, once it finishes: the recording it
  ## made opened in a session tab, or why not in the trace.
  if not pollRecordJob(gTestJob):
    return false
  if gTestJob.ok:
    let folder = recordingFolderOf(gTestJob.recordingId)
    if folder.len > 0:
      openRecordingInTab(r, folder)
    else:
      traceGesture("run tests: ct record-test reported recording " &
                   gTestJob.recordingId & ", but the trace store has no " &
                   "folder for it")
  else:
    traceGesture("run tests: " & gTestJob.message)
  drawTopBar(r)
  true

proc welcomeKeyName(key: string; mods: seq[string]): string =
  ## A window key in the shared model's names.
  case key.toLowerAscii
  of "up", "arrowup": "Up"
  of "down", "arrowdown": "Down"
  of "left", "arrowleft": "Left"
  of "right", "arrowright": "Right"
  of "tab": (if "shift" in mods: "Shift+Tab" else: "Tab")
  of "enter", "return": "Enter"
  of "escape", "esc": "Esc"
  of "backspace": "Backspace"
  of "space": "Space"
  else:
    if key.len == 1 and "control" notin mods and "ctrl" notin mods: key
    else: ""

proc welcomeKey(r: GpuiRenderer; key: string; mods: seq[string]): bool =
  ## PLAT-51: a key while a Welcome Screen is shown — its form, the arrows,
  ## Enter. True when the screen took it.
  let w = shownWelcome()
  if w.isNil:
    return false
  let name = welcomeKeyName(key, mods)
  if name.len == 0:
    return false
  let folderDefault = getCurrentDir()
  if not w.applyKey(name, folderDefault):
    return false
  runWelcomeIntent(r, gWelcomeTabs.active)
  discard drawArrangement(r)
  true

proc welcomePress(r: GpuiRenderer; x, y: int): bool =
  ## PLAT-51: a press on the shown Welcome Screen. The body is the screen's.
  let w = shownWelcome()
  if w.isNil or not gGeom.area.contains(x, y):
    return false
  let at = gWelcomeLayout.welcomeRowAtPx(x, y)
  if at >= 0:
    w.activate(at, getCurrentDir())
    traceGesture("welcome row " & $at)
    runWelcomeIntent(r, gWelcomeTabs.active)
  discard drawArrangement(r)
  true

proc toolAvailable(tool: GToolButton): bool =
  ## Whether the window performs a tool button now. Run tests: with a
  ## session, and not while a run it started is still going.
  case tool
  of gtbBack:
    not gSession.isNil and not gSession.session.debugControlsVM.isNil and
      gSession.session.debugControlsVM.canGoBack.val
  of gtbForward:
    not gSession.isNil and not gSession.session.debugControlsVM.isNil and
      gSession.session.debugControlsVM.canGoForward.val
  of gtbReset, gtbStop: not gSession.isNil
  of gtbRunTests: not gSession.isNil and (gTestJob.isNil or gTestJob.done)

proc performTool(r: GpuiRenderer; tool: GToolButton) =
  ## A tool button's press — the desktop's `DebugComponent.action`:
  ##   * history back / forward: the cursor moves one stop through the
  ##     session's jump history (`DebugControlsVM`, the desktop's) and the
  ##     replay goes there;
  ##   * reset: the replay restarted — the recording opened afresh, at the
  ##     tick it was at — and the old session closed;
  ##   * stop: the debugging session ended — the recording's folder opened as
  ##     an Edit tab (and the session closed when it is not the last);
  ##   * run tests: the tests of the file the debugger is in recorded in the
  ##     background (`ct record-test`), the recording opened in a session tab
  ##     of its own when it finishes — the desktop's new window
  ##     (`pollTestRun`).
  if gSession.isNil or not toolAvailable(tool):
    traceGesture("tool " & $tool & " unavailable")
    return
  case tool
  of gtbBack, gtbForward:
    # The session's one jump history (`DebugControlsVM`), which records every
    # stop the store reaches — the desktop's history, on this front-end too.
    let direction = if tool == gtbBack: hdOlder else: hdNewer
    discard gSession.historyMove(direction)
    refreshReplayWindow(r)
  of gtbReset:
    let tick = gSession.getCurrentRRTicks()
    let old = gShell.app.activeSessionId()
    openRecordingInTab(r, gSession.tracePath)
    if gShell.app.activeSessionId() != old:
      let fresh = gShell.app.activeSessionId()
      gSession.gotoTick(tick)
      refreshReplayWindow(r)
      let tabs = gShell.app.tabsOf()
      for i, t in tabs:
        if t.id == old:
          closeSessionTab(r, i)
          break
      showSession(r, fresh)
  of gtbStop:
    # M76 (codetracer#843), Debugger-Controls.md § "Ending a session from
    # inside it": the workspace in Edit mode (the recording's folder as an
    # Edit tab, which takes the session tab's place), and the replay backend
    # for the session TERMINATED — in the single-session case too. Until M76
    # the session tab was closed only when it was not the last, so the one
    # session an ordinary user has kept its `replay-server` running behind
    # the Edit tab; and the close was looked up in the Edit shell, which
    # holds no session tabs. The session is ended here through the performer
    # the terminal's Stop uses (`native_host.stopThroughControls`, the
    # session's `DebugControlsVM` Stop), and its slot removed from the
    # REPLAY shell.
    let stopped = gSession
    let folder = stopped.getCurrentFile().parentDir
    let replayShell = if gMainShell.isNil: gShell else: gMainShell
    let current = replayShell.app.activeSessionId()
    openWelcomeTab(r)
    let index = gWelcomeTabs.tabs.high
    gWelcomeTabs.turnIntoFolder(index, folder)
    let why = showFolderTab(r, index)
    if why.len > 0:
      traceGesture("stop: " & why)
    let ended = stopped.stopThroughControls()
    discard replayShell.app.closeSession(current, disconnectBackend = false)
    gSessionsOpened.del(int(current))
    gSession = nil
    traceGesture("stop: " & ended.message & " (replay-server " & $ended.pid &
                 ")")
  of gtbRunTests:
    gTestJob = startRecordTestJob(gSession.getCurrentFile())
    if gTestJob.done:
      traceGesture("run tests: " & gTestJob.message)
    else:
      armRecordTick()
  traceGesture("tool " & $tool)
  drawTopBar(r)

proc performControl(r: GpuiRenderer; id: string) =
  ## A debugger control (or its menu item), through the transport
  ## ViewModel the desktop's toolbar calls (`DebugControlsVM`), with the move
  ## settled as every native host settles it (`session_driver`).
  if gSession.isNil:
    return
  let vm = gSession.session.debugControlsVM
  if vm.isNil or not vm.transportAvailable(id):
    traceGesture("control " & id & " unavailable")
    return
  discard gSession.runDebugControl(id)
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
  else:
    # PLAT-50: a pane the arrangement does not place is OPENED, as the
    # desktop's View menu opens its panel — a tab beside the event log, else
    # at the root (the terminal's rule).
    applyGestureCommand(r, cmdAddPane(pane,
      after = (if layout.tree.contains(paneEventLog): some(paneEventLog)
               else: none(PaneKind))))
  discard drawArrangement(r)

proc openOmnibar(r: GpuiRenderer; query = "") =
  if gMenu.isOpen: gMenu.close()
  # The omnibar lists the menu's ENABLED commands: read them for now.
  refreshGpuiMenuAvailability()
  if not gSession.isNil:
    gOmnibar.setIndex(omnibarIndexOf(gSession.session.fileTreeVM,
                                     gSession.session.store, gMenu,
      terminalSettings = false) &
                      gRecordings)
  gOmnibar.open(query)
  drawTopBar(r)

proc editorPath(): string
proc runGpuiPointMenuOp(r: GpuiRenderer; op: PointMenuOp)

proc runGpuiViewOperation(r: GpuiRenderer; operation: string) =
  ## PLAT-70 (Horizontal-Overflow.md §4.4) / Part I (§5.5): `view.scroll-*`
  ## — from a key or from the palette — on the focused pane's view.
  # PLAT-70 Part I (§5.5): the focused table pane's view while its columns
  # SCROLL — the Call Trace and the Event Log in pixels, a step of
  # `WheelColumns` columns of the code face; the State pane's scroll box.
  if gFocusPane in [$paneCalltrace, $paneEventLog, $paneState]:
    let step = WheelColumns * gpuiCellUnits()
    if gFocusPane == $paneState:
      if stateScrollMax.left <= 0:
        traceGesture("`" & operation & "` scrolls a table pane whose " &
                     "columns do not fit")
        return
      let half = max(1, statePaneSizePx.w div 2)
      let target = case operation
                   of "view.scroll-left": stateScroll.left - step
                   of "view.scroll-right": stateScroll.left + step
                   of "view.scroll-left-half": stateScroll.left - half
                   of "view.scroll-right-half": stateScroll.left + half
                   else: 0
      stateScroll.left = clamp(target, 0, stateScrollMax.left)
      traceGesture("state scroll top=" & $stateScroll.top & " left=" &
                   $stateScroll.left)
      redrawPaneOf(r, paneState)
      return
    let kind = if gFocusPane == $paneCalltrace: paneCalltrace
               else: paneEventLog
    var v = if kind == paneCalltrace: callTraceHView else: eventLogHView
    if not v.overflows:
      traceGesture("`" & operation & "` scrolls a table pane whose " &
                   "columns do not fit")
      return
    let moved = case operation
                of "view.scroll-left": v.scrollBy(-step)
                of "view.scroll-right": v.scrollBy(step)
                of "view.scroll-left-half": v.scrollHalf(right = false)
                of "view.scroll-right-half": v.scrollHalf(right = true)
                else: v.scrollToLineStart()
    if kind == paneCalltrace: callTraceHView = v
    else: eventLogHView = v
    traceGesture($kind & "-hscroll left=" & $v.leftCol)
    if moved:
      redrawPaneOf(r, kind)
    return
  # PLAT-70 (Horizontal-Overflow.md §4.4): the output panes' view — the
  # Terminal Output's line view in this window (Build Output is PLAT-56).
  let vm = terminalVM()
  if vm.isNil or vm.screenShown:
    traceGesture("`" & operation & "` scrolls the Terminal Output's line view")
    return
  var v = gTerminal.hview
  discard (case operation
           of "view.scroll-left": v.scrollBy(-WheelColumns)
           of "view.scroll-right": v.scrollBy(WheelColumns)
           of "view.scroll-left-half": v.scrollHalf(right = false)
           of "view.scroll-right-half": v.scrollHalf(right = true)
           else: v.scrollToLineStart())
  gTerminal.hview = v
  traceGesture("terminal-hscroll leftCol=" & $v.leftCol & " of " &
               $v.maxLeftCol)
  drawTerminalPane(r)

proc runGpuiMenuAction(r: GpuiRenderer; action: string) =
  traceGesture("menu action " & action)
  # PLAT-68: the palette's **Preferences: Select Base Keymap** — every open
  # editor re-keyed (text and history kept), and the choice remembered in
  # the preference both native hosts read.
  let base = parseBaseKeymapCommand(action)
  if base.ok:
    if not openArm.isNil:
      openArm.doc.switchModel(base.model)
    for arm in gFolderArms.values:
      arm.doc.switchModel(base.model)
    for arm in gEditArms.values:
      if arm != openArm:
        arm.doc.switchModel(base.model)
    for d in gDebugDocs.mvalues:
      d.switchModel(base.model)
    gRouter.switchBase(base.model, ksCommand)
    refreshMenuShortcuts()
    let saved = saveKeymapPreference(base.model)
    traceGesture("keymap " & $base.model &
                 (if saved.len > 0: " (" & saved & ")" else: ""))
    discard drawArrangement(r)
    return
  # PLAT-51: the omnibox's layout-setting commands — the focus highlight and
  # live resize, for this window and remembered (`gpui-preferences`).
  var setting = parseSettingCommandTarget(action)
  # PLAT-70: **View: Toggle Overflow Markers** flips the markers.
  let toggle = parseSettingToggleTarget(action)
  if toggle.ok:
    let on = not gLayoutSettings.valueOf(toggle.setting)
    setting = (true, toggle.setting, on, (if on: "on" else: "off"))
  if setting.ok:
    discard gLayoutSettings.assignValue(setting.setting, setting.value)
    let saved = saveLayoutPreference(lpGpui, setting.setting, setting.value)
    traceGesture("setting " & describe(setting.setting, setting.value) &
                 (if saved.len > 0: " (" & saved & ")" else: ""))
    discard drawArrangement(r)
    if setting.setting == lsOverflowMarkers:
      redrawEditorRows(r)
      drawTerminalPane(r)
    return
  # PLAT-70 Part B: the palette's operation entries (**Show Detail**,
  # **Widen Column**, **Narrow Column** — `omnibar_sources.tableCommands`).
  let operation = parseOperationCommand(action)
  if operation.ok:
    let (name, arg) = splitOperation(operation.operation)
    case name
    of "list.show-detail": showTableDetail(r)
    of "table.resize-column": resizeEventLogColumn(r, arg)
    of "view.scroll-left", "view.scroll-right":
      # PLAT-70 Part I: the focused output or table pane's view.
      runGpuiViewOperation(r, name)
    else: traceGesture(operation.operation & " is not available here")
    drawTopBar(r)
    return
  # PLAT-49 part B (finding 14): the omnibar's event-log column commands,
  # over the session's `EventLogVM.columns`, then the event log drawn again.
  let col = parseEventLogColumnCommand(action)
  if col.ok:
    if not gSession.isNil and not gSession.session.eventLogVM.isNil:
      let vm = gSession.session.eventLogVM
      let changed =
        case col.verb
        of "left": vm.moveColumn(col.column, -1)
        of "right": vm.moveColumn(col.column, 1)
        else: vm.toggleColumn(col.column)
      traceGesture("event log columns " & $vm.columns.val.visibleColumns &
                   (if changed: "" else: " (unchanged)"))
      let pane = gPanes.getOrDefault($paneEventLog)
      if not pane.isNil:
        for leaf in gLeafSet.leaves:
          if leaf.kind == glkBuiltin and leaf.builtin == paneEventLog:
            redrawWindowLeaf(r, pane, leaf)
    drawTopBar(r)
    return
  # The table the menu was enabled from (`gpuiMenuRouteOf`), so a command the
  # omnibar listed and an item chosen do what "enabled" promised.
  let route = gpuiMenuRouteOf(action)
  if route.reason.len > 0:
    traceGesture("menu action " & action & " refused: " & route.reason)
    drawTopBar(r)
    return
  case route.kind
  of gmrControl:
    performControl(r, route.control)
    return
  of gmrFindSymbol: openOmnibar(r, ":sym ")
  of gmrFindInFiles: openFindInFiles(r)
  of gmrPane: showPaneFromMenu(r, route.pane)
  of gmrExit:
    traceGesture("exit")
    gpui_quit()
  of gmrStop:
    performTool(r, gtbStop)
    return
  of gmrPoint:
    runGpuiPointMenuOp(r, route.point)
  of gmrNewTab: openWelcomeTab(r)
  of gmrWelcomeOption:
    # The start option's form, the window's dialog — in the shown welcome
    # tab, or a new one (Open Trace in New Tab…, or none shown).
    if route.newTab or shownWelcome().isNil:
      openWelcomeTab(r)
    let w = shownWelcome()
    if not w.isNil:
      w.chooseOption(route.option, getCurrentDir())
      traceGesture("welcome form " & $w.form)
      discard drawArrangement(r)
  of gmrNone:
    # Unreachable: `gpuiMenuRouteOf` gives `gmrNone` a reason.
    traceGesture("menu action " & action & " is not available here")
  drawTopBar(r)

proc showContent(r: GpuiRenderer; title, text: string; diff = false)

proc showTracepointHits(r: GpuiRenderer; hits: seq[TracepointSweepHit];
                        title: string) =
  ## A sweep's hits shown over the window, as the desktop's tracepoint editor
  ## lists them under the line — one `:tracepoint`'s, or the Debug menu's
  ## "Run All Tracepoints" (M76). The values of the hits the overlay shows
  ## are read as it scrolls (Q4).
  let session = gSession
  var held = hits
  let text = session.tracepointHitsText(held, 0)
  showContent(r, title, (if text.len > 0: text else: "the line never ran"))
  if hits.len > 0:
    gContent.refill = proc(top: int): string =
      session.tracepointHitsText(held, top)

proc runGpuiTracepoint(r: GpuiRenderer; path: string; line: int;
                       expression: string) =
  ## PLAT-50: "Add tracepoint" then `:tracepoint <expression>` — the sweep
  ## over the recording (`ct/run-tracepoints`), its hits shown over the
  ## window as the desktop's tracepoint editor lists them under the line, the
  ## point on the point list and in the gutter.
  if gSession.isNil or expression.len == 0:
    return
  inc gTracepointsRun
  var hits: seq[TracepointSweepHit] = @[]
  try:
    hits = gSession.runTracepoints(@[TracepointSweepSpec(
      tracepointId: gTracepointsRun - 1, path: path, line: line,
      expression: expression)])
  except CatchableError as e:
    traceGesture("tracepoint failed: " & e.msg)
    return
  refreshReplayWindow(r)
  showTracepointHits(r, hits,
    "tracepoint `" & expression & "` at " & path.extractFilename & ":" &
    $line & " — " & $hits.len & " hit(s)")

proc runGpuiPointMenuOp(r: GpuiRenderer; op: PointMenuOp) =
  ## M76 (codetracer#843): a Debug-menu breakpoint or tracepoint item. The
  ## ones that name one point act at the editor caret's line in the file the
  ## editor shows (the desktop's `pointsOperationsSetup`). "Add a Tracepoint"
  ## opens this window's tracepoint editor there (the omnibar on
  ## `:tracepoint `, as `editor.toggle-tracepoint` does); every other item
  ## is the performer the terminal's menu calls too
  ## (`session_driver.performPointMenuOp`).
  if gSession.isNil:
    traceGesture("menu " & PointMenuActions[op] &
                 " needs a replay session; open a recording to debug it")
    return
  let path = editorPath()
  let line = if gDebugDocs.hasKey(path): gDebugDocs[path].caretLine
             else: max(1, gEditorSurface.executionLine)
  if op == pmoAddTracepoint:
    gTracepointAt = (path, line)
    traceGesture("tracepoint editor at " & $line)
    openOmnibar(r, TracepointCommand)
    return
  var nextId = gTracepointsRun
  let done = gSession.performPointMenuOp(op, path, line, nextId)
  gTracepointsRun = nextId
  traceGesture("menu " & PointMenuActions[op] & ": " & done.message)
  refreshReplayWindow(r)
  if op == pmoRunAllTracepoints and done.performed:
    showTracepointHits(r, done.swept,
      "tracepoints: " & $done.sweptSpecs & " run — " & $done.swept.len &
      " hit(s)")

proc runWatchCommand(r: GpuiRenderer; query: string): bool
  ## PLAT-51: forward-declared; defined beside the value history.

proc startGpuiBuild(r: GpuiRenderer; command: string): string
  ## PLAT-55: forward-declared; defined with the Problems pane's host.
proc cancelGpuiBuild(): string
  ## PLAT-55: forward-declared; defined with the Problems pane's host.

proc acceptOmnibar(r: GpuiRenderer) =
  # PLAT-51: a watch verb.
  if runWatchCommand(r, gOmnibar.query):
    return
  # PLAT-57: `:grep <text>` is Find in Files (§5.1) — the omnibox closes and
  # the search runs into the pane; `:grep` alone keeps the field open.
  # `:cnext` / `:cprev` (`:cn` / `:cp`) open the next / previous result.
  let (mode, needle) = classifyOmnibarQuery(gOmnibar.query)
  # PLAT-54: `/ai <text>` is the agent query (the desktop's): the omnibox
  # closes, Agent Activity is shown and the prompt goes to the agent.
  if mode == omAgent:
    gOmnibar.close()
    drawTopBar(r)
    if needle.len == 0:
      showPaneFromMenu(r, paneAgentActivity)
    else:
      runAgentPrompt(r, needle)
    return
  if mode == omProgram:
    if needle.len == 0:
      openFindInFiles(r)
    else:
      gOmnibar.close()
      drawTopBar(r)
      runGpuiFindInFiles(r, needle)
    return
  # PLAT-70 Part B (§5.2): `:column-width <column> <cells>`.
  if mode == omCommand and needle.startsWith(ColumnWidthVerb):
    gOmnibar.close()
    drawTopBar(r)
    let parsed = parseColumnWidthLine(needle.splitWhitespace)
    if not parsed.ok:
      traceGesture(parsed.message)
    elif not gSession.isNil and not gSession.session.eventLogVM.isNil:
      let vm = gSession.session.eventLogVM
      discard vm.setColumnWidth(parsed.column, parsed.cells)
      rememberEventLogWidths(vm)
      traceGesture("event log column " & $parsed.column & " " &
                   $vm.columns.val.widths[parsed.column] & " cells")
      redrawListPane(r, paneEventLog)
    return
  # PLAT-55: `:build <command>` and `:cancel` — the terminal's verbs, its
  # runner; the build's diagnostics fill the Problems pane.
  if mode == omCommand and (needle == "build" or needle.startsWith("build ") or
                            needle == "cancel"):
    gOmnibar.close()
    drawTopBar(r)
    traceGesture(if needle == "cancel": cancelGpuiBuild()
                 else: startGpuiBuild(r, needle[min(needle.len, 6) .. ^1].strip()))
    return
  if mode == omCommand and needle in ["cnext", "cn", "cprev", "cp"]:
    gOmnibar.close()
    drawTopBar(r)
    stepSearchResult(r, (if needle in ["cnext", "cn"]: 1 else: -1))
    return
  # PLAT-50: the tracepoint "Add tracepoint" asked for, on its line.
  if gTracepointAt.path.len > 0 and
     gOmnibar.query.startsWith(TracepointCommand):
    let expression = gOmnibar.query[TracepointCommand.len .. ^1].strip()
    let at = gTracepointAt
    gTracepointAt = ("", 0)
    gOmnibar.close()
    drawTopBar(r)
    runGpuiTracepoint(r, at.path, at.line, expression)
    return
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
  of omRecording:
    openRecordingInTab(r, entry.target)
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

const MenuOperations = ["menu.open", "menu.toggle", "menu.open-folder"]
  ## The keymap's menu keys (CUA-Keymap.md §3.8: `Alt` alone, `` Alt+` ``,
  ## `Alt+<mnemonic>`, `F10` in Edit mode; Vim's `F12`).

proc runMenuOperation(operation, argument: string) =
  ## A menu key, whether the menu is open or not: `menu.open-folder(x)`
  ## opens folder x; `menu.open` and `menu.toggle` open the menu when it is
  ## closed and close it when it is open (VS Code's Alt and F10 both toggle).
  # What is enabled is read for the state the menu opens in (codetracer#841).
  if not gMenu.isOpen or operation == "menu.open-folder":
    refreshGpuiMenuAvailability()
  if operation == "menu.open-folder":
    let i = gMenu.folderIndexOf(argument)
    if i >= 0:
      gMenu.openFolder(i)
  elif gMenu.isOpen:
    gMenu.close()
  else:
    gMenu.open(keyboard = true)
  traceGesture("menu " & (if gMenu.isOpen: "open " & $gMenu.path
                          else: "closed"))

proc probeWindowResolution(key: string; mods: seq[string]): EditingResolution

proc handleTopKey(r: GpuiRenderer; key: string;
                  mods: seq[string]): bool =
  ## The keys of what is drawn OVER the window and reads its own keys: a
  ## text shown over it (an event's content, a tracepoint's hits), then the
  ## open program menu, which owns every key. Answers whether the key was
  ## taken. (The palette and the right-click menu are pushed layers of the
  ## router — `routeWindowKey`.)
  if gMenu.isNil or gOmnibar.isNil:
    return false
  let k = key.toLowerAscii
  let ctrl = "control" in mods
  if gContent.open:
    case k
    of "escape", "esc", "enter", "return": gContent = GContent()
    of "up": gContent.top = max(0, gContent.top - 1)
    of "down": gContent.top = gContent.top + 1
    of "pageup": gContent.top = max(0, gContent.top - 10)
    of "pagedown", "space": gContent.top = gContent.top + 10
    else: return true
    drawTopBar(r)
    return true
  if gMenu.isOpen:
    # The keymap's own menu keys keep their meaning inside it: another
    # mnemonic switches folder, `Alt` / `` Alt+` `` / `F10` close it.
    let res = probeWindowResolution(key, mods)
    if res.kind == erOperation and res.operation in MenuOperations:
      runMenuOperation(res.operation, res.argument)
      drawTopBar(r)
      return true
    # The desktop's cascade (PLAT-49): Up/Down within the open level, Right
    # (or Enter) into a folder's submenu, Left back out, Esc out and closed.
    case k
    of "escape", "esc": gMenu.escape()
    of "enter", "return":
      let chosen = gMenu.highlightedItem()
      let act = gMenu.activate()
      if act.ran:
        runGpuiMenuAction(r, act.action)
        return true
      if refusalOf(chosen).len > 0:
        traceGesture("menu refused: " & refusalOf(chosen))
    of "up": gMenu.moveHighlight(-1)
    of "down": gMenu.moveHighlight(1)
    of "right": discard gMenu.enterFolder()
    of "left": discard gMenu.leaveFolder()
    else:
      if key.len == 1 and not ctrl:
        gMenu.typeToSelect(key, int64(epochTime() * 1000))
    drawTopBar(r)
    return true
  false

proc copyToClipboard(text, what: string)
  ## Forward-declared for the status bar's copy button.

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
        let chosen = gMenu.itemAt(path)
        let act = gMenu.clickPath(path)
        if act.ran:
          runGpuiMenuAction(r, act.action)
          return true
        if refusalOf(chosen).len > 0:
          traceGesture("menu refused: " & refusalOf(chosen))
          # The menu stays open on the refused row, highlighted, so the
          # redraw shows its reason beside it (EMT-D14) — also for a press
          # no pointer motion led to.
          gMenu.hoverPath(path)
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
  # A TAB'S PIN AND CLOSE ICONS: the pin docks that tab's pane (to the
  # bottom, as the box's pin button did), the close removes it — not under
  # an overlay of the tree (`pinButtonShown`, `overlayRects`).
  let covers = overlayRects()
  for n in gGeom.nodes:
    if n.kind != gnTabs:
      continue
    for t in 0 ..< min(n.panes.len, n.pins.len):
      let onPin = n.pins[t].contains(x, y) and pinButtonShown(n.pins[t], covers)
      let onCloseIcon = n.closes[t].contains(x, y) and
                        pinButtonShown(n.closes[t], covers)
      if not (onPin or onCloseIcon):
        continue
      for k in PaneKind:
        if $k == n.panes[t]:
          applyGestureCommand(r, if onPin: cmdDock(k, leBottom)
                                 else: cmdRemovePane(k))
      discard drawArrangement(r)
      drawTopBar(r)
      return true
  if copyPathRect().contains(x, y):
    copyToClipboard(footerLocation(), "the location")
    return true
  if not band.contains(x, y):
    return false
  let hit = gTopLayout.topBarHitAt(x, y)
  if hit.index < 0 and hit.rect.w == 0:
    return true
  case hit.part
  of gtMenuButton:
    if gMenu.isOpen:
      gMenu.close()
    else:
      refreshGpuiMenuAvailability()
      gMenu.open(keyboard = false)
  of gtControl:
    performControl(r, TransportControls[hit.index].id)
    return true
  of gtTool:
    performTool(r, GToolButton(hit.index))
    return true
  of gtOmnibar:
    if not gOmnibar.isOpen:
      openOmnibar(r)
      return true
  of gtTab:
    # PLAT-51: a welcome tab (or the folder it became) is shown the same way
    # a session tab is.
    let at = mainShell().app.stripTabAt(gWelcomeTabs, hit.index)
    if at.isWelcome: showWelcomeTab(r, at.welcomeIndex)
    else: showSessionTab(r, at.sessionIndex)
  of gtTabClose:
    # PLAT-49 part B: the desktop's `.session-tab-close` — closing a tab
    # stops its session (Multi-Window-Tab-Management.md, rule 4).
    let at = mainShell().app.stripTabAt(gWelcomeTabs, hit.index)
    if at.isWelcome: closeWelcomeTabAt(r, at.welcomeIndex)
    else:
      leaveFolder(r)
      closeSessionTab(r, at.sessionIndex)
    gHoverTab = -1
  of gtTabAdd:
    # PLAT-51 deliverable 8 (Multi-Window-Tab-Management.md rule 3): the
    # desktop's "New tab" opens a tab showing the WELCOME SCREEN. (PLAT-49
    # part B opened the omnibar on `:open ` here.)
    gHoverTabAdd = false
    openWelcomeTab(r)
    return true
  of gtWindowButton:
    # PLAT-69: the renderer acts on a window button's press itself (its
    # `data-window-region`); the window takes the press so nothing under the
    # band does, and adds nothing to it.
    return true
  drawTopBar(r)
  true

proc hoverNowMs(): int64 =
  ## The auto-hide hover's clock: the wall clock, plus what `--window-ops`'s
  ## `wait:<ms>` advanced it by (a scripted run has no loop to wait in).
  int64(epochTime() * 1000.0) + gHoverClockOffsetMs

proc applyHoverReply(r: GpuiRenderer; reply: AutoHideReply) =
  ## What the hover machine said: open the preview overlay or close it.
  var changed = false
  case reply.cue
  of ahcNone: discard
  of ahcPreview:
    changed = gGestures.previewReveal(committedLayout(), reply.pane)
    if changed: traceGesture("previewed " & $reply.pane)
  of ahcDismiss:
    changed = gGestures.dismissReveal(reply.pane)
    if changed: traceGesture("preview dismissed " & $reply.pane)
  if changed:
    # The whole arrangement, so a side or top strip lights its previewed
    # label too (the footer's labels are redrawn with the top bar).
    if not drawArrangement(r):
      drawOverlay(r)
      drawTopBar(r)
      writeGeometry()

proc hoverTick() {.cdecl.}
proc vcsTick() {.cdecl.}
proc recordTick() {.cdecl.}
proc searchTick() {.cdecl.}
proc agentTick() {.cdecl.}
const AgentPollMs = 100
  ## PLAT-54: how often a live agent's updates are applied.
const SearchPollMs = 15
  ## PLAT-57: how often a streaming Find in Files search is pumped.
const RecordPollMs = 200
  ## PLAT-51: how often a welcome tab's running `ct record` is polled.
var gVcsDirectory = ""
  ## The repository the VCS pane shows, re-read every `VCSRefreshIntervalMs`
  ## by `vcsTick` and on every return to the window by `vcsWindowActivated`;
  ## "" when the window has no VCS pane.

var gArmedTick = (due: -2'i64, vcs: false)
  ## What the shim's tick is armed for: the hover machine's due moment, or
  ## the VCS refresh, or nothing (`due` -1, `vcs` false). The shim restarts
  ## its wait on every arming, so it is re-armed only when this changes —
  ## a pointer moving over the window must not keep postponing either.

proc armHoverTick() =
  ## Wake the loop when the hover machine has something due (a preview, a
  ## dismissal) — the shim's one tick, shared with the VCS refresh.
  var due = gAutoHide.nextDueMs
  # PLAT-70 Part B: and a truncated cell's tooltip, on the same tick.
  let cellDue = gCellHover.dueMs
  if cellDue >= 0 and (due < 0 or cellDue < due):
    due = cellDue
  # PLAT-57: a Find in Files search streaming is pumped on the same tick,
  # every `SearchPollMs`, while it runs.
  if due < 0 and nativeFindInFiles.running:
    gArmedTick = (due: -4'i64, vcs: false)
    gpui_set_tick(uint32(SearchPollMs), searchTick)
    return
  # PLAT-54: a live agent's updates are applied on the same tick, every
  # `AgentPollMs`, while it works.
  if due < 0 and agentLive():
    gArmedTick = (due: -5'i64, vcs: false)
    gpui_set_tick(uint32(AgentPollMs), agentTick)
    return
  # PLAT-51: a welcome tab's `ct record` is polled on the same tick, every
  # `RecordPollMs`, while it runs.
  if due < 0 and ((not gRecordJob.isNil and not gRecordJob.done) or
                  (not gTestJob.isNil and not gTestJob.done) or
                  # PLAT-53: a Test Results run, polled on the same tick.
                  gTestsHost.running or
                  # PLAT-55: a `:build`, polled on the same tick.
                  (not gBuild.isNil and gBuild.session.verdict == bvRunning)):
    gArmedTick = (due: -3'i64, vcs: false)
    gpui_set_tick(uint32(RecordPollMs), recordTick)
    return
  let want = (due: due, vcs: due < 0 and gVcsDirectory.len > 0)
  if want == gArmedTick:
    return
  gArmedTick = want
  if due >= 0:
    # A few ms past the due moment: the loop's timer can fire a little
    # early, and an early tick would only re-arm for the remainder.
    let wait = clamp(due - hoverNowMs() + 5, 10, 1000)
    traceGesture("hover tick in " & $wait & " ms")
    gpui_set_tick(uint32(wait), hoverTick)
  elif want.vcs:
    gpui_set_tick(uint32(VCSRefreshIntervalMs), vcsTick)
  else:
    gpui_set_tick(0'u32, nil)

# ---------------------------------------------------------------------------
# PLAT-70 Part B — the table panes' cut cells: hover, the `…` click, the open
# detail, the Event Log's column widths (Horizontal-Overflow.md §5)
# ---------------------------------------------------------------------------

const TablePaneNames = [$paneState, $paneEventLog, $paneCalltrace]

proc tableDetailPaneOf(pane: string): string =
  ## A pane's name in a `DetailToggle` — the terminal's spelling.
  if pane == $paneState: StateDetailPane
  elif pane == $paneEventLog: EventDetailPane
  else: CallTraceDetailPane

proc tableCellAtWindow(x, y: int):
    tuple[found: bool; pane: string; cut: CutCell; bodyRows: int] =
  ## The cut cell the window drew at `(x, y)`, as the pane's renderer
  ## recorded it (`leaves.stateCuts` / `eventCuts` / `callCuts`, from the
  ## pane body's top-left) — the paint's own geometry, hit-tested.
  let pane = gGeom.activePaneAt(x, y)
  if pane notin TablePaneNames:
    return
  let i = gGeom.tabsNodeOfPane(pane)
  if i < 0 or not gGeom.nodes[i].body.contains(x, y):
    return
  let body = gGeom.nodes[i].body
  let cuts = if pane == $paneState: stateCuts
             elif pane == $paneEventLog: eventCuts
             else: callCuts
  let k = cuts.cutCellAt(y - body.y, x - body.x)
  if k < 0:
    return
  var placed = cuts[k]
  placed.row += body.y
  placed.col += body.x
  placed.ellipsisCol += body.x
  let pitch = max(1, placed.height)
  (true, pane, placed, max(1, body.h div pitch))

proc showCellTooltip() =
  let a = gCellHoverAnchor
  let cols = max(1, pendingViewportWidth div max(1, pxOfText(1)))
  let chord = gRouter.chordFor("list.copy", windowSessionFacts(),
                               windowScopePath(), nmNormal, "")
  gCellTooltip = tooltipView(gCellHover.full, cols, a.bodyRows, chord).lines
  traceGesture("cell tooltip " & $gCellTooltip.len & " line(s)")

proc cellHoverAt(r: GpuiRenderer; x, y: int) =
  ## §5.3: the pointer moving with no button — a truncated cell under it
  ## starts the 500 ms clock; anywhere else hides a shown tooltip.
  let hit = tableCellAtWindow(x, y)
  let entered = hit.found and
    not gCellHover.sameCell(tableDetailPaneOf(hit.pane), hit.cut.key,
                            hit.cut.column)
  let changed =
    if hit.found:
      gCellHoverAnchor = (hit.cut.col, hit.cut.row, hit.cut.height,
                          hit.bodyRows)
      gCellHover.pointerOver(tableDetailPaneOf(hit.pane), hit.cut.key,
                             hit.cut.column, hit.cut.full, true, hoverNowMs())
    else:
      gCellHover.pointerOver("", "", "", "", false, hoverNowMs())
  if entered:
    # Where the paint put the cut cell and its `…`, in window px — what a
    # capture aims at (`ci/test/plat70b_gpui_window.py`).
    let c = hit.cut
    traceGesture("cell hover " & hit.pane & " " & c.column & " cell=" &
                 $c.col & ".." & $(c.col + c.width) & " row=" & $c.row &
                 ".." & $(c.row + max(1, c.height)) & " ellipsis=" &
                 $c.ellipsisCol & ".." &
                 $(c.ellipsisCol + max(1, c.ellipsisWidth)))
  if changed:
    gCellTooltip = @[]
    drawTopBar(r)
  armHoverTick()

proc tickCellHover(r: GpuiRenderer): bool =
  ## The clock: the tooltip shows once the pointer has rested 500 ms.
  if not gCellHover.tick(hoverNowMs()):
    return false
  showCellTooltip()
  drawTopBar(r)
  true

proc dismissCellHover(r: GpuiRenderer) =
  ## A key or a press hides a shown tooltip (§5.3).
  if gCellHover.dismiss():
    gCellTooltip = @[]
    drawTopBar(r)

proc redrawTablePane(r: GpuiRenderer; pane: string) =
  ## A table pane drawn again for a detail or a width — its new rows (and
  ## the Event Log's header cells) wired for their clicks, as
  ## `redrawPaneOf`'s are.
  if pane == $paneCalltrace: redrawCalltrace(r)
  elif pane == $paneState: redrawListPane(r, paneState)
  else: redrawListPane(r, paneEventLog)
  wireClicks(r)

proc toggleTableDetail(r: GpuiRenderer; pane, key, column: string) =
  ## §5.3: the row's full text under it; again closes it; one at a time.
  let before = tableDetail.pane
  let open = tableDetail.toggleDetail(tableDetailPaneOf(pane), key, column)
  tableCopyChord = gRouter.chordFor("list.copy", windowSessionFacts(),
                                    windowScopePath(), nmNormal, "")
  traceGesture("detail " & (if open: "open " else: "closed ") & pane & " " &
               key & (if column.len > 0: " " & column else: ""))
  for p in TablePaneNames:
    if tableDetailPaneOf(p) == before or p == pane:
      redrawTablePane(r, p)

proc ellipsisAtWindow(x, y: int):
    tuple[found: bool; pane: string; cut: CutCell; bodyRows: int] =
  ## The cut cell whose drawn `…` is at `(x, y)`.
  let hit = tableCellAtWindow(x, y)
  if hit.found and [hit.cut].ellipsisAt(y, x) >= 0:
    return hit

proc pressEllipsis(r: GpuiRenderer; x, y: int): bool =
  ## §5.3: a press on a cut cell's `…` opens (or closes) its row's detail.
  let hit = ellipsisAtWindow(x, y)
  if not hit.found:
    return false
  toggleTableDetail(r, hit.pane, hit.cut.key, hit.cut.column)
  true

proc focusedTableRow(): tuple[pane, key: string] =
  ## `list.show-detail`'s row: the focused pane's selected one — the
  ## variable, the event, the call.
  if gSession.isNil:
    return
  case gFocusPane
  of $paneState:
    let vm = gSession.session.stateVM
    if not vm.isNil and vm.selectedPath.val.len > 0:
      return (gFocusPane, vm.selectedPath.val)
  of $paneEventLog:
    let vm = gSession.session.eventLogVM
    if not vm.isNil:
      let rows = vm.eventRows.val
      let sel = vm.selectedRow.val
      let at = if sel.isSome: sel.get else: 0
      if at >= 0 and at < rows.len:
        return (gFocusPane, $rows[at].eventIndex)
  of $paneCalltrace:
    let vm = gSession.session.calltraceVM
    if not vm.isNil:
      for row in vm.callRows():
        if crfSelected in row.flags: return (gFocusPane, $row.index)
  else: discard

proc showTableDetail(r: GpuiRenderer) =
  let (pane, key) = focusedTableRow()
  if pane.len == 0:
    traceGesture("Show Detail works in the Variables, Event Log and Call " &
                 "Trace panes")
    return
  toggleTableDetail(r, pane, key, "")

proc rememberEventLogWidths(vm: EventLogVM) =
  let failure = saveColumnWidths(EventLogTableName,
                                 vm.columns.val.columnWidthEntries)
  if failure.len > 0: traceGesture(failure)

proc applyRememberedColumnWidths() =
  ## §5.2 / HO-9: the session's Event Log opens at the widths the ONE
  ## remembered document (`table-columns`) holds — the terminal's and the
  ## desktop's too.
  if gSession.isNil or gSession.session.eventLogVM.isNil:
    return
  let stored = loadColumnWidths()
  if stored.message.len > 0: traceGesture(stored.message)
  let vm = gSession.session.eventLogVM
  vm.columns.val = vm.columns.val.withColumnWidths(stored.entries)

proc resizeEventLogColumn(r: GpuiRenderer; arg: string) =
  ## `table.resize-column([column,]delta)` on the Event Log (§5.2).
  if gSession.isNil or gSession.session.eventLogVM.isNil:
    return
  let vm = gSession.session.eventLogVM
  let target = vm.columns.val.columnResizeTarget(arg)
  if not target.ok:
    traceGesture(target.message)
    return
  let col = target.col
  var current = 0
  for (c, _, w) in vm.columns.val.eventColumnsPx(eventLogPaneWidthPx):
    if c == col: current = cellsOfPx(w)
  discard vm.resizeColumn(col, target.delta, current)
  rememberEventLogWidths(vm)
  traceGesture("event log column " & $col & " " &
               $vm.columns.val.widths[col] & " cells")
  redrawTablePane(r, $paneEventLog)

proc separatorAtWindow(x, y: int):
    tuple[found: bool; col: EventLogColumn; left, right: int] =
  ## The Event Log column separator at `(x, y)`; `left` is its column's left
  ## edge in window px.
  if gSession.isNil or gSession.session.eventLogVM.isNil or
     gGeom.activePaneAt(x, y) != $paneEventLog:
    return
  let i = gGeom.tabsNodeOfPane($paneEventLog)
  if i < 0:
    return
  let body = gGeom.nodes[i].body
  let vm = gSession.session.eventLogVM
  let hit = vm.columns.val.eventSeparatorAt(body.w, x - body.x, y - body.y)
  if hit.found:
    return (true, hit.col, body.x + hit.left, body.x + hit.right)

proc tableGestureAt(x, y: int): bool =
  ## Whether a press at `(x, y)` is a table pane's own gesture — a cut
  ## cell's `…` or a column separator — which the row or the header under it
  ## must not also answer (a jump, an order): the window's pointer handler
  ## takes it (`pressEllipsis`, `pressEventSeparator`).
  ellipsisAtWindow(x, y).found or separatorAtWindow(x, y).found

proc pressEventSeparator(r: GpuiRenderer; x, y: int): bool =
  ## §5.2: a press on an Event Log column separator holds it.
  let hit = separatorAtWindow(x, y)
  if not hit.found:
    return false
  gColumnDrag = (active: true, moved: false, col: hit.col, left: hit.left,
                 grab: x - hit.right, startX: x)
  traceGesture("column separator " & $hit.col)
  true

proc dragEventSeparator(r: GpuiRenderer; x: int; release: bool) =
  ## The held separator follows the pointer: the column's width is the
  ## distance from its left, in cells, never under the minimum.
  let vm = gSession.session.eventLogVM
  if x != gColumnDrag.startX:
    gColumnDrag.moved = true
  if gColumnDrag.moved:
    discard vm.setColumnWidth(gColumnDrag.col,
                             cellsOfPx(x - gColumnDrag.grab - gColumnDrag.left))
    redrawListPane(r, paneEventLog)
  if release:
    gColumnDrag.active = false
    if not gColumnDrag.moved:
      return
    rememberEventLogWidths(vm)
    wireClicks(r)
    traceGesture("event log column " & $gColumnDrag.col & " " &
                 $vm.columns.val.widths[gColumnDrag.col] & " cells")

proc handleTopHover(r: GpuiRenderer; x, y: int) =
  ## The pointer moving with no button: a control's tooltip, an auto-hide
  ## label's hover label, an open menu's hovered item.
  if gMenu.isNil or (x, y) == gHoverAt:
    return
  gHoverAt = (x, y)
  # PLAT-70 Part B (§5.3): a truncated table cell's tooltip clock.
  cellHoverAt(r, x, y)
  # The editor's scrollbar shows while the pointer is over the editor
  # (Monaco's fading scrollbars).
  block:
    let i = gGeom.tabsNodeOfPane($paneEditor)
    let over = i >= 0 and gGeom.nodes[i].body.contains(x, y)
    if over != editorScrollbarShown:
      editorScrollbarShown = over
      if openArm.isNil: redrawReplayEditor(r)
      else: redrawEditor()
  var control = -1
  var tool = -1
  var tab = -1
  var add = false
  var windowButton = -1
  if gTopLayout.band.contains(x, y):
    let hit = gTopLayout.topBarHitAt(x, y)
    if hit.part == gtControl and hit.rect.w > 0:
      control = hit.index
    elif hit.part == gtTool and hit.rect.w > 0:
      tool = hit.index
    elif hit.part in {gtTab, gtTabClose} and hit.rect.w > 0:
      tab = hit.index
    elif hit.part == gtTabAdd and hit.rect.w > 0:
      add = true
    elif hit.part == gtWindowButton and hit.rect.w > 0:
      windowButton = hit.index
  if tab != gHoverTab or add != gHoverTabAdd or
     windowButton != gHoverWindowButton or tool != gHoverTool:
    gHoverTool = tool
    gHoverTab = tab
    gHoverTabAdd = add
    gHoverWindowButton = windowButton
    drawTopBar(r)
  var slot = ""
  let (si, sj) = gGeom.slotAt(x, y)
  if si >= 0:
    slot = gGeom.strips[si].slots[sj].pane
  var changed = control != gHoverControl or slot != gHoverSlot
  if slot != gHoverSlot:
    traceGesture("hover slot '" & slot & "' at " & $x & "," & $y)
  gHoverControl = control
  gHoverSlot = slot
  # PLAT-49 part B (finding 9): THE DESKTOP'S HOVER — a moment over a label
  # previews its pane as an overlay; leaving the label and the overlay
  # closes the preview a moment later (`auto_hide_hover`).
  block:
    var label = none(PaneKind)
    var open = false
    for k in PaneKind:
      if $k == slot:
        label = some(k)
        open = gGeom.openDockPane == slot
    let inOverlay = gGestures.revealing and
                    gGeom.revealRectOf(gGestures.reveal.edge).contains(x, y)
    # A preview something else closed (Esc, a press outside it) is over.
    if gAutoHide.previewing.isSome and not gGestures.revealing:
      gAutoHide.overlayClosed()
    applyHoverReply(r, gAutoHide.pointerAt(label, inOverlay, open,
                                           hoverNowMs()))
    armHoverTick()
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

proc attachVcs(leafSet: var GpuiLeafSet; directory: string) =
  ## Hand the VCS leaf, when the arrangement places one, the ViewModel the
  ## host read `directory` into. The headless replay session owns no VCS
  ## ViewModel (`headless_app.paneViewModel`), so the host supplies it.
  ## PLAT-54: and the Agent Activity leaf its host's `AgentActivityVM`, on
  ## the same rule.
  for leaf in leafSet.leaves.mitems:
    if leaf.kind == glkBuiltin and leaf.builtin == paneVcs:
      leaf.vm = ViewModel(openGpuiVcs(directory))
      gVcsDirectory = directory
  let h = agentHost()
  if not h.isNil:
    for leaf in leafSet.leaves.mitems:
      if leaf.kind == glkBuiltin and leaf.builtin == paneAgentActivity:
        leaf.vm = ViewModel(h.vm)

proc armRecordTick() =
  armHoverTick()

# ---------------------------------------------------------------------------
# PLAT-53: the Test Results pane's host (`Test-Results-Pane.md` §8)
# ---------------------------------------------------------------------------

const NoSessionTabsInEditText* =
  "this window has no session tabs (it is the Edit window), so the " &
  "recording is not opened here; it is at "
  ## The `⏵` refusal of the GPUI Edit window, followed by the recording's
  ## folder (§8.3): stated on the pane, never a silent no-op.

proc installTestsHost(root: string; openFolder: NativeOpenFolder) =
  ## The window's Test Results ViewModel and the desktop's host over the
  ## native producers, for the project at `root` (§8.2), its catalog read.
  if not gTestsVM.isNil:
    return
  gTestsRoot = root
  gTestsVM = createTestResultsVM()
  gTestsHost = newNativeTestHost(gTestsVM,
    projectRoot = proc(): string = gTestsRoot,
    ctBinary = proc(): string = nativeCtBinary(),
    resolveFolder = proc(id: string): string = recordingFolderOf(id),
    openFolder = openFolder)
  discard gTestsHost.refreshCatalog(force = true)

proc attachTests(leafSet: var GpuiLeafSet) =
  ## Hand the Test Results leaf, when the arrangement places one, the
  ## window's ViewModel — the headless replay session owns none
  ## (`headless_app.paneViewModel`), as it owns no VCS ViewModel.
  if gTestsVM.isNil:
    return
  discard gTestsHost.refreshCatalog()   # a re-rooted window's project
  for leaf in leafSet.leaves.mitems:
    if leaf.kind == glkBuiltin and leaf.builtin == paneTestResults:
      leaf.vm = ViewModel(gTestsVM)

proc pollTestsHost(r: GpuiRenderer): bool =
  ## PLAT-53: a run that ended, settled into the pane (and, for
  ## record-and-open, its recording opened in a new tab).
  if gTestsHost.isNil or not gTestsHost.poll():
    return false
  let note = gTestsHost.takeNote()
  if note.len > 0:
    traceGesture("tests: " & note)
  traceGesture("tests settled: " & gTestsVM.headline.val)
  drawTestsPane(r)
  true

proc stopTestsHost() =
  ## The window ends: a run still going ends with it (its process group).
  if not gTestsHost.isNil:
    gTestsHost.stop()

proc killTestsRun() =
  ## `tests:kill` — the run in flight's whole process group, SIGKILLed from
  ## outside, as a user's `kill -9` would (§5: it must still settle).
  when defined(posix):
    if gTestsHost.running:
      discard posix.kill(Pid(-gTestsHost.job.pid), SIGKILL)

proc testsRowNamed(name: string): int =
  ## The row of the test `name` (its short name or selector), -1 for none.
  if gTestsVM.isNil:
    return -1
  for i, row in gTestsVM.rows.val:
    if row.name == name or row.selector == name or row.testId == name:
      return i
  -1

proc pressTests(r: GpuiRenderer; x, y: int): bool =
  ## A left press on Test Results: the ▶ runs the suite, a row's `⟳`
  ## records it again, `⏵` opens its recording in a new tab (recording it
  ## first when it has none; Shift held arms the re-record, as on the
  ## desktop), a row is selected, the scrubber moves the view. A disabled
  ## control says why (the trace) and runs nothing.
  let body = testsBody()
  if gTestsVM.isNil or body.w <= 0 or not body.contains(x, y):
    return false
  let vm = gTestsVM
  let hit = testsHitAt(vm, gTests, body, x, y)
  case hit.kind
  of gtNone, gtText: discard
  of gtRun:
    if vm.canRun(): vm.startRun()
    else: traceGesture("tests: " & vm.runButtonTitle())
  of gtRow:
    gTests.selected = hit.row
  of gtRefresh, gtOpen:
    gTests.selected = hit.row
    vm.setShiftHeld(gPointerShift)
    let row = vm.rows.val[hit.row]
    if hit.kind == gtRefresh:
      if vm.refreshAbsence().len > 0:
        traceGesture("tests: " & vm.refreshButtonTitle(row))
      else:
        vm.triggerRefresh(row)
    else:
      if vm.openAbsence(row).len > 0:
        traceGesture("tests: " & vm.openButtonTitle(row))
      else:
        traceGesture("tests: open " & row.name & " (" &
                     $vm.openButtonMode(row) & ")")
        vm.triggerOpen(row)
    vm.setShiftHeld(false)
  of gtTrack, gtThumb:
    gTests.dragging = hit.kind == gtThumb
    if gTests.dragging:
      let lay = testsLayout(vm, body)
      gTests.scrubberOf(lay.lines.len, lay.rows).beginBarGrab(hit.fraction)
    gTests.scrubTests(vm, body, y, dragging = gTests.dragging)
  let note = if gTestsHost.isNil: "" else: gTestsHost.takeNote()
  if note.len > 0:
    traceGesture("tests: " & note)
  drawTestsPane(r)
  armRecordTick()
  true

proc testsKey(r: GpuiRenderer; operation: string): bool =
  ## PLAT-53 from the keyboard, the pane focused (§8.4): the list's moves
  ## select a row, `list.activate` is its `⏵`. Whether it was the pane's.
  if gTestsVM.isNil or gFocusPane != $paneTestResults:
    return false
  let n = gTestsVM.rows.val.len
  let sel = gTests.selected
  case operation
  of "list.focus-next": gTests.selected = clamp(sel + 1, 0, max(0, n - 1))
  of "list.focus-previous": gTests.selected = clamp(sel - 1, 0, max(0, n - 1))
  of "list.focus-first": gTests.selected = 0
  of "list.focus-last": gTests.selected = n - 1
  of "list.focus-page-down": gTests.selected = clamp(sel + 10, 0, max(0, n - 1))
  of "list.focus-page-up": gTests.selected = clamp(sel - 10, 0, max(0, n - 1))
  of "list.activate":
    if sel < 0 or sel >= n:
      traceGesture("tests: no test is selected")
      return true
    let row = gTestsVM.rows.val[sel]
    if gTestsVM.openAbsence(row).len > 0:
      traceGesture("tests: " & gTestsVM.openButtonTitle(row))
    else:
      gTestsVM.triggerOpen(row)
      armRecordTick()
  else:
    return false
  if n == 0:
    gTests.selected = -1
  else:
    gTests.revealRow(gTestsVM, testsBody(), gTests.selected)
  drawTestsPane(r)
  true

# ---------------------------------------------------------------------------
# PLAT-55: the Problems pane's host (Build-Output-Pane.md §3.3) and `:build`
# ---------------------------------------------------------------------------

proc wireProblemsJump(r: GpuiRenderer)

proc installProblems(root: string) =
  ## The window's Problems ViewModel and its build reader; `:build` runs in
  ## `root`.
  if not gProblems.isNil:
    return
  gBuildRoot = root
  gProblems = newBuildProblems()
  var rr: GpuiRenderer
  wireProblemsJump(rr)

proc attachProblems(leafSet: var GpuiLeafSet) =
  ## Hand the Problems leaf, when the arrangement places one (the shared
  ## default docks it in the footer), the window's ViewModel — the headless
  ## replay session owns none (`headless_app.paneViewModel`).
  if gProblems.isNil:
    return
  for leaf in leafSet.leaves.mitems:
    if leaf.kind == glkBuiltin and leaf.builtin == paneProblems:
      leaf.vm = ViewModel(gProblems.vm)

proc pollGpuiBuild(r: GpuiRenderer): bool =
  ## PLAT-55: the `:build` in flight advanced — its output read into the
  ## Problems pane as it arrives; its verdict, when it ends, on the trace.
  if gBuild.isNil or gProblems.isNil:
    return false
  let wasRunning = gBuild.session.verdict == bvRunning
  discard pollBuild(gBuild, nowMonoMs())
  let changed = gProblems.follow(gBuild.session)
  if wasRunning and gBuild.session.verdict != bvRunning:
    traceGesture(describeVerdict(gBuild.session))
    traceGesture("problems: " & gProblems.vm.errorBadgeText & " " &
                 gProblems.vm.warningBadgeText & " " &
                 gProblems.vm.totalBadgeText)
  if changed:
    drawProblemsPane(r)
  changed

proc startGpuiBuild(r: GpuiRenderer; command: string): string =
  ## `:build <command>` — the terminal's verb (CodeTracer-TUI-Edit-Mode.md
  ## §5), its runner and its words: one build at a time, in the window's
  ## project, in the background.
  if command.len == 0:
    return ":build needs a command, e.g. ':build just build'"
  if gProblems.isNil:
    installProblems(getCurrentDir())
  if not gBuild.isNil and gBuild.session.verdict == bvRunning:
    return "a " & $gBuild.session.kind & " is already running; :cancel it first"
  let root = if gBuildRoot.len > 0: gBuildRoot else: getCurrentDir()
  gBuild = startBuild(bkBuild, command, root, nowMonoMs())
  discard gProblems.follow(gBuild.session)
  drawProblemsPane(r)
  armRecordTick()
  if gBuild.session.verdict == bvRunning: "build started: " & command
  else: describeVerdict(gBuild.session)

proc cancelGpuiBuild(): string =
  ## `:cancel` — the flag the runner's poll acts on (`requestCancel`).
  if gBuild.isNil or gBuild.session.verdict != bvRunning:
    return "nothing is running"
  gBuild.session.requestCancel()
  "cancelling " & $gBuild.session.kind & " …"

proc stopGpuiBuild() =
  ## The window ends: a build still going is cancelled and polled until its
  ## process is gone.
  if gBuild.isNil or gBuild.session.verdict != bvRunning:
    return
  gBuild.session.requestCancel()
  let deadline = epochTime() + 5.0
  while gBuild.session.verdict == bvRunning and epochTime() < deadline:
    discard pollBuild(gBuild, nowMonoMs())
    sleep(20)

proc showViewedFile(r: GpuiRenderer; atLine = 1; topLine = 0)
  ## PLAT-55: forward-declared; defined with the replay editor.
proc placeCaret(r: GpuiRenderer; path: string; line, column: int)
  ## PLAT-55: forward-declared; defined with Find in Files.

proc openProblemFile(r: GpuiRenderer; path: string; line, col: int): string =
  ## K35: the file of a diagnostic opened at its line — in the Edit window's
  ## editor (its own edit arm, the caret placed and kept in view, the editor
  ## focused: EMT-D21), or in a replay window from the recording, as a Find
  ## in Files result is. "" when it opened, else why not.
  if not openArm.isNil:
    if not openEditFile(path):
      return if openArm.status.len > 0: openArm.status
             else: "could not open " & path
    openArm.doc.moveCaretTo(max(1, line) - 1, max(1, col) - 1)
    openArm.viewportTop = followedViewportTop(openArm.viewportTop,
                                              caretLine(openArm.doc),
                                              max(1, openArm.viewportRows))
    redrawEditor()
    focusEditKeys()
    # `caretLine` is 1-based, `caretColumn` 0-based (`editing_core`).
    traceGesture("caret " & $caretLine(openArm.doc) & ":" &
                 $(caretColumn(openArm.doc) + 1))
    return ""
  gViewedFile = path
  showViewedFile(r, atLine = line)
  if gViewedFile.len == 0:
    return path & " is not in this recording"
  placeCaret(r, path, line, max(1, col))
  ""

proc problemsSay(what: string) =
  ## What the Problems pane has to say — on the trace, and in Edit mode as
  ## the editor's notice (the window has no status line there).
  if what.len == 0:
    return
  traceGesture("problems: " & what)

proc jumpToProblemIn(r: GpuiRenderer; path: string; line, col: int) =
  ## `ErrorsVM.onJumpToProblem` for this window.
  let t = gProblems.targetOf(path, line, col)
  if not t.ok:
    problemsSay(t.why)
    return
  let why = openProblemFile(r, t.path, t.line, t.col)
  problemsSay(if why.len > 0: why
              else: "opened " & path & ":" & $line &
                    (if col > 0: ":" & $col else: ""))

proc wireProblemsJump(r: GpuiRenderer) =
  if gProblems.isNil:
    return
  gProblems.vm.onJumpToProblem = proc(path: string; line, col: int) =
    var rr: GpuiRenderer
    jumpToProblemIn(rr, path, line, col)
  gProblems.vm.onRevealPanel = proc() =
    # EMT-D22.4: navigation reveals the pane without focusing it — revealed
    # from the footer when docked, its tab activated when placed.
    var rr: GpuiRenderer
    let layout = committedLayout()
    if layout.dockedIndex(paneProblems) >= 0:
      if not (gGestures.revealing and gGestures.reveal.pane == paneProblems) and
         not (not gGeom.openDock.isEmpty and
              gGeom.openDockPane == $paneProblems):
        let shown = beginReveal(layout, paneProblems)
        if shown.isSome:
          gGestures.reveal = shown.get
          discard drawArrangement(rr)
    elif layout.tree.contains(paneProblems):
      applyGestureCommand(rr, cmdActivateTab(paneProblems))
      discard drawArrangement(rr)

proc stepProblem(r: GpuiRenderer; next: bool) =
  ## `problems.next` / `problems.previous` (EMT-D22): the next / previous
  ## error selected and opened, wrapping, announced.
  if gProblems.isNil:
    traceGesture("problems: no errors")
    return
  wireProblemsJump(r)
  discard (if next: gProblems.vm.gotoNextError()
           else: gProblems.vm.gotoPreviousError())
  problemsSay(gProblems.vm.statusMessage.val)
  if gProblems.vm.selectedIndex.val >= 0:
    gProblemsPane.revealIndex(gProblems.vm, problemsBody(),
                              gProblems.vm.selectedIndex.val)
  drawProblemsPane(r)

proc openProblem(r: GpuiRenderer; index: int) =
  ## A diagnostic selected and its file opened at its line (K35).
  let vm = gProblems.vm
  if index < 0 or index >= vm.problems.val.len:
    problemsSay("that problem is no longer listed")
    return
  wireProblemsJump(r)
  vm.selectProblemIndex(index)
  vm.jumpToProblem(vm.problems.val[index])
  drawProblemsPane(r)

proc pressProblems(r: GpuiRenderer; x, y: int): bool =
  ## A left press on Problems: a row opens its file at its line and is
  ## selected; a filter button or Group by File acts on the list; the
  ## scrubber moves the view. The desktop opens no menu on a row.
  let body = problemsBody()
  if gProblems.isNil or body.w <= 0 or not body.contains(x, y):
    return false
  let vm = gProblems.vm
  let hit = problemsHitAt(vm, gProblemsPane, body, x, y)
  var focusPane = true
  case hit.kind
  of gpNone, gpText, gpHeader: discard
  of gpFilter:
    vm.setFilter(ProblemFilterTag(hit.index))
    traceGesture("problems filter " & ProblemFilterLabels[vm.filter.val])
  of gpGroup:
    vm.toggleGroupByFile()
    traceGesture("problems group by file " & $vm.groupByFile.val)
  of gpRow:
    focusPane = false
    openProblem(r, hit.index)
  of gpTrack, gpThumb:
    gProblemsPane.dragging = hit.kind == gpThumb
    if gProblemsPane.dragging:
      let lay = problemsLayout(vm, body)
      gProblemsPane.scrubberOf(lay.lines.len, lay.rows).beginBarGrab(
        hit.fraction)
    gProblemsPane.scrubProblems(vm, body, y, dragging = gProblemsPane.dragging)
  drawProblemsPane(r)
  if focusPane:
    gFocusShown = true
    if gFocusPane != $paneProblems:
      focusWindowPane(r, $paneProblems)
      discard drawArrangement(r)
  true

proc problemsKey(r: GpuiRenderer; operation: string): bool =
  ## PLAT-55 from the keyboard, the pane focused (Build-Output-Pane.md §3.3:
  ## arrow keys move, Enter jumps). Whether it was the pane's.
  if gProblems.isNil or gFocusPane != $paneProblems:
    return false
  let vm = gProblems.vm
  var order: seq[int] = @[]
  for d in vm.displayRows():
    if d.kind == pdRow:
      order.add d.index
  let n = order.len
  let at = order.find(vm.selectedIndex.val)
  if n == 0 and operation != "list.activate":
    traceGesture("problems: the Problems pane lists no problem")
    return true
  var next = at
  case operation
  of "list.focus-next": next = if at < 0: 0 else: at + 1
  of "list.focus-previous": next = if at < 0: n - 1 else: at - 1
  of "list.focus-first": next = 0
  of "list.focus-last": next = n - 1
  of "list.focus-page-down": next = if at < 0: 0 else: at + 10
  of "list.focus-page-up": next = if at < 0: 0 else: at - 10
  of "list.activate":
    if at < 0:
      traceGesture("problems: no problem is selected")
    else:
      openProblem(r, order[at])
    return true
  else:
    return false
  vm.selectProblemIndex(order[clamp(next, 0, n - 1)])
  gProblemsPane.revealIndex(vm, problemsBody(), vm.selectedIndex.val)
  drawProblemsPane(r)
  true

proc recordTick() {.cdecl.} =
  ## PLAT-51: the welcome tab's recording, polled; when it finishes its
  ## recording opens in the tab that asked (`pollWelcomeRecording`).
  var r: GpuiRenderer
  gArmedTick = (due: -2'i64, vcs: false)
  discard pollWelcomeRecording(r)
  discard pollTestRun(r)
  discard pollTestsHost(r)
  discard pollGpuiBuild(r)
  armHoverTick()

proc agentTick() {.cdecl.} =
  ## PLAT-54: what a live agent sent since the last tick, applied, and the
  ## pane (and the session tabs' indicator) drawn again; re-armed while it
  ## works.
  var r: GpuiRenderer
  gArmedTick = (due: -2'i64, vcs: false)
  var changed = false
  for h in gAgentHosts.values:
    if h.poll():
      changed = true
  if changed:
    drawAgentPane(r)
    drawTopBar(r)
  armHoverTick()

proc searchTick() {.cdecl.} =
  ## PLAT-57: the search in flight advanced a bounded step, and the pane
  ## drawn again when what it shows moved; re-armed while it runs.
  var r: GpuiRenderer
  gArmedTick = (due: -2'i64, vcs: false)
  let vm = searchVM()
  let before = if vm.isNil: (-1, false) else: (vm.results.val.len,
                                               vm.searching.val)
  discard nativeFindInFiles.pump()
  if not vm.isNil and (vm.results.val.len, vm.searching.val) != before:
    drawSearchPane(r)
  armHoverTick()

proc hoverTick() {.cdecl.} =
  ## The hover machine's due moment arrived (`armHoverTick`): run it, then
  ## re-arm for what is due next — and the VCS refresh it shares the tick
  ## with keeps its own pace.
  var r: GpuiRenderer
  # The arming this tick answered is spent: whatever is due next is armed.
  gArmedTick = (due: -2'i64, vcs: false)
  applyHoverReply(r, gAutoHide.tick(hoverNowMs()))
  discard tickCellHover(r)
  armHoverTick()

proc refreshVcsPane() =
  ## THE VCS PANE REFRESHES AS THE DESKTOP'S DOES, on the desktop's two
  ## triggers (VCS-Panel.md's auto-refresh, `ui/vcs.nim`
  ## `startFileWatching`): the repository is read again, and the pane is
  ## drawn again when what it shows changed — so a file edited, added or
  ## committed in another program appears here as it does on the desktop and
  ## in the terminal, instead of the pane keeping the state it was opened
  ## with. ONE BODY FOR BOTH TRIGGERS (`vcsTick`, `vcsWindowActivated`), so
  ## the interval and the return to the window cannot come to disagree about
  ## what a re-read is or when it earns a frame. The trace line is the one
  ## `ci/test/plat47_gpui_window.py` counts, whichever trigger ran.
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

proc followVcsViewport(r: GpuiRenderer) =
  ## THE VCS HISTORY READS WHAT ITS LIST SHOWS (Viewport-Driven-Loading V6):
  ## the rows the pane's body holds at `VcsRowPx` and the commits the
  ## reader's place has passed (`leaves.vcsHistoryWindow` over the view the
  ## pane draws) are reported as the history list's viewport, so every read
  ## asks `git log` for that many commits plus a lead instead of a fixed 50;
  ## and when the list now reaches the last commit the last read got, the
  ## repository is read again now and the pane drawn again — the native Load
  ## More. Run after each arrangement and each wheel or scrubber move over
  ## the pane.
  if gVcsDirectory.len == 0:
    return
  syncInHandRows(gGeom)
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == paneVcs and
       not leaf.vm.isNil:
      let vm = VCSVM(leaf.vm)
      let w = vcsHistoryWindow(vcsPaneView(vm).root, vcsScroll.top,
                               vcsScroll.rows)
      if followGpuiVcsViewport(vm, gVcsDirectory, w.rows, w.firstRow):
        redrawListPane(r, paneVcs)
        traceGesture("vcs history read to " & $vm.commits.val.len)
      break

proc followListViewports(r: GpuiRenderer) =
  ## The call trace and the event log follow the bodies they were laid out
  ## with (`reportListViewports`) after each committed arrangement — a
  ## resize, a moved divider, a tab brought to the front — and a pane that
  ## read a new window is drawn again from it.
  let loaded = reportListViewports(gSession, gGeom)
  if loaded.calltrace:
    inc gCalltraceLoads
    # A selected call STAYS selected: it names a trace index, and the
    # debugger has not moved (a move selects again, `refreshReplayWindow`).
    # Selecting again over the new section would CLEAR it whenever the
    # reader had scrolled away from the current call, since a section that
    # does not hold it answers `none` (`currentCallInSectionOf`). Only a
    # pane with nothing selected asks again — one that was a hidden tab at
    # the open, whose one-row section could not show the current call.
    if gSession.session.calltraceVM.selectedEntry.val.isNone:
      gSession.selectCurrentCall()
    redrawCalltrace(r)
  if loaded.events:
    inc gEventLogLoads
    redrawPaneOf(r, paneEventLog)

proc vcsTick() {.cdecl.} =
  ## The first trigger: every `VCSRefreshIntervalMs` the loop calls this
  ## (`gpui_set_tick`, on the loop's own thread).
  refreshVcsPane()

proc vcsWindowActivated() =
  ## The second trigger: the user came back to the window from another
  ## program (`window_chrome.subscribeWindow`'s `activated`, the renderer's
  ## inactive-to-active edge, delivered on the loop's thread from inside the
  ## frame that sampled it). The desktop re-reads on its window `focus`
  ## event, so a commit made elsewhere is on screen the moment the user
  ## returns rather than up to `VCSRefreshIntervalMs` later. The interval
  ## keeps its own pace: the tick is not re-armed here, because
  ## `armHoverTick` shares it with the hover, search and recording polls and
  ## re-arming would postpone whichever of them is pending.
  refreshVcsPane()

# ---------------------------------------------------------------------------
# PLAT-50: the desktop's click behaviours on the window's panes
# (`headless_app/pane_clicks.ClickInventory`, wired by `window_clicks`)
# ---------------------------------------------------------------------------

proc redrawPaneOf(r: GpuiRenderer; pane: PaneKind) =
  ## One builtin leaf drawn again from its ViewModel (a folder toggled, a
  ## value expanded), its faces re-stamped and its rows wired.
  let el = gPanes.getOrDefault($pane)
  if el.isNil:
    return
  if pane == paneTerminalOutput:
    drawTerminalPane(r)
    return
  if pane == paneSearch:
    drawSearchPane(r)
    return
  if pane == paneTestResults:
    drawTestsPane(r)
    return
  if pane == paneAgentActivity:
    drawAgentPane(r)
    return
  if pane == paneProblems:
    drawProblemsPane(r)
    return
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == pane:
      redrawWindowLeaf(r, el, leaf)
      applyTextFaces(r, el)
      break
  wireClicks(r)

proc fileEntryOf(vm: FilesystemVM; id: string): FilesystemEntryNode =
  ## The Files node a vocabulary id names (`fileTree.0.1`: child 0, then 1).
  if vm.isNil:
    return
  result = vm.rootEntry.val
  for i in childIndexPath(id, "fileTree"):
    if i < 0 or i >= result.children.len:
      return FilesystemEntryNode()
    result = result.children[i]

proc editorPath(): string =
  ## The file the editor shows: one opened from Files, else the stop's.
  if gViewedFile.len > 0: gViewedFile
  elif gSession.isNil: ""
  else: gSession.getCurrentFile()

proc showViewedFile(r: GpuiRenderer; atLine = 1; topLine = 0) =
  ## PLAT-50 (K17): the editor draws `gViewedFile` — read whole from the
  ## recording through the source service's provider, its breakpoints in the
  ## gutter, the execution pointer only when the debugger is in it — until
  ## the debugger moves (`refreshReplayWindow` clears it), as the desktop's
  ## editor follows the debugger back to the location's file. PLAT-57: from
  ## the window of rows that shows `atLine` (a Find in Files result's line).
  ## M73 (#840): or from `topLine` exactly, when the user scrolled it.
  let editor = gPanes.getOrDefault($paneEditor)
  if editor.isNil or gSourceService.isNil or gViewedFile.len == 0:
    return
  let (lines, detail) = recordedLines(gViewedFile)
  if lines.len == 0:
    traceGesture("could not open " & gViewedFile & ": " & detail)
    gViewedFile = ""
    return
  let shown = min(lines.len, editorRowsOf(gGeom))
  let top = clamp((if topLine > 0: topLine else: atLine - shown div 3), 1,
                  max(1, lines.len - shown + 1))
  var surface = EditorSurface(medium: GpuiMedium, path: gViewedFile,
                              revisionLabel: "@0",
                              provenance: epVerified, viewportTop: top,
                              totalLineCount: lines.len,
                              gutterVisible: true)
  let points = editorPointsOf(gSession.session.store.pointList.rows.val)
  for i in top - 1 ..< top - 1 + shown:
    var mark = emNone
    for p in points:
      if p.path == gViewedFile and p.line == i + 1:
        mark = (if p.kind == epkTracepoint: emTracepoint
                elif p.enabled: emBreakpoint
                else: emBreakpointDisabled)
    surface.rows.add EditorRow(line: i + 1, text: lines[i], held: true,
                               mark: mark)
  # PLAT-68: the surface the editor was drawn from is the one its caret,
  # selection and horizontal scroll are redrawn from.
  gEditorSurface = withDebugDocument(surface)
  while childCount(editor) > 0:
    r.removeChild(editor, nthChild(editor, childCount(editor) - 1))
  drawEditorBody(r, editor)
  applyTextFaces(r, editor)
  noteEditorTab(r, editorTabLabel(gViewedFile, false))
  wireClicks(r)
  traceGesture("opened " & gViewedFile)

# ---------------------------------------------------------------------------
# M73 (#840): THE DEBUG-MODE EDITOR'S WINDOW, MOVED BY THE USER
#
# GPUI draws the same `SourceVM` window the terminal does, and had the same
# defect: only a stop moved it (`serveWindow`). The vertical wheel over the
# editor was dropped, the read-only caret followed only sideways
# (`followEditorView`), and §4.2's scroll keys reached no arm. These move the
# window through `gpui_host`'s `scrollWindowBy` / `centreWindowOnPointer` /
# `followCaretInWindow` — the shared `SourceVM` calls, then the lines served
# without following the pointer — and draw the editor again from it.
# ---------------------------------------------------------------------------

proc debugSourceShown(): bool =
  ## Whether the editor draws the recording's source READ-ONLY now: Debug
  ## mode, a file on it, its document not made writable (`Ctrl+E` hands the
  ## pane to the document's own window, `withDebugDocument`), a source
  ## service to move.
  if gSourceService.isNil or gSession.isNil or
     gEditorSurface.productMode == pmEdit or gEditorSurface.path.len == 0:
    return false
  let path = gEditorSurface.path
  not (gDebugDocs.hasKey(path) and not gDebugDocs[path].isReadOnly)

proc redrawSourceWindow(r: GpuiRenderer) =
  ## The editor drawn again from the window as the user left it — the
  ## resize path's three calls (`redrawReplayEditor`, the text faces, the
  ## clicks wired to the new rows).
  redrawReplayEditor(r)
  let editor = gPanes.getOrDefault($paneEditor)
  if not editor.isNil:
    applyTextFaces(r, editor)
  wireClicks(r)
  traceGesture("editor-vscroll top=" & $gEditorSurface.viewportTop &
               " execution=" & $gEditorSurface.executionLine)

proc scrollEditorLines(r: GpuiRenderer; lines: int) =
  ## The window `lines` lines down (negative: up): the wheel over the editor
  ## and `j` / `k` / `Ctrl+d` / `Ctrl+u` (CodeTracer-TUI.md §4.2, "without
  ## moving execution pointer"). A file shown whole (`gViewedFile`) moves its
  ## own top.
  if lines == 0 or not debugSourceShown():
    return
  if gViewedFile.len > 0:
    showViewedFile(r, topLine = max(1, gEditorSurface.viewportTop + lines))
    traceGesture("editor-vscroll top=" & $gEditorSurface.viewportTop)
    return
  gSourceService.scrollWindowBy(lines)
  redrawSourceWindow(r)

proc centreEditorOnPointer(r: GpuiRenderer) =
  ## `.`: "Reset source scroll so the current execution pointer is
  ## centered" (§4.2). A file shown whole carries no pointer unless the
  ## debugger is in it, and then the stop's own window shows it.
  if not debugSourceShown():
    return
  if gViewedFile.len > 0:
    traceGesture("the execution pointer is not in " & gViewedFile)
    return
  gSourceService.centreWindowOnPointer()
  redrawSourceWindow(r)

proc followCaretInEditor(r: GpuiRenderer; line, column: int): bool =
  ## The read-only caret moved to `line`:`column`: the window follows it by
  ## the least amount (Editor-Pane.md § The caret in a read-only editor).
  ## Answers whether the window moved — and so whether the editor was drawn
  ## again from it.
  if not debugSourceShown():
    return false
  if gViewedFile.len > 0:
    let rows = max(1, min(gEditorSurface.totalLineCount, editorRowsOf(gGeom)))
    let top = topFollowingCursor(gEditorSurface.viewportTop, line, rows,
                                 gEditorSurface.totalLineCount)
    if top == gEditorSurface.viewportTop:
      return false
    showViewedFile(r, topLine = top)
    return true
  let before = gSourceService.vm.visibleFirstLine.val
  gSourceService.followCaretInWindow(line, column)
  if gSourceService.vm.visibleFirstLine.val == before:
    return false
  redrawSourceWindow(r)
  true

proc scrollEditorTo(r: GpuiRenderer; top: int) =
  ## The window with line `top` first — what the vertical scrubber asks for
  ## (Scrollbar-Scrubbers.md §3.2, §3.3). The view only (§3.5).
  if not debugSourceShown():
    return
  if gViewedFile.len > 0:
    showViewedFile(r, topLine = max(1, top))
    traceGesture("editor-vscroll top=" & $gEditorSurface.viewportTop)
    return
  gSourceService.scrollWindowTo(top)
  redrawSourceWindow(r)

proc scrubEditorVBar(r: GpuiRenderer; y: int; click: bool) =
  ## M73 (#840): a press on the vertical track centres the line at its
  ## fraction of the FILE (§3.2); a held thumb follows the pointer, centred on
  ## it (§3.3) — through the shared scrubber model the track was drawn from,
  ## so the press is read against what the user saw.
  let (bar, v) = editorVBarRect()
  if bar.h <= 0:
    return
  let f = trackFractionAt(clamp(y - bar.y, 0, bar.h - 1), bar.h)
  let first = if click: v.model.clickAt(f)
              else: v.model.dragTo(v.model.heldThumbStart(f))
  scrollEditorTo(r, first + 1)

proc pressEditorVBar(r: GpuiRenderer; x, y: int): bool =
  ## A left press on the vertical scrubber: the bar's, never a press on the
  ## row under it. On the thumb a drag starts; on the track the view jumps.
  if not debugSourceShown():
    return false
  let (bar, v) = editorVBarRect()
  if bar.h <= 0 or not bar.contains(x, y):
    return false
  let local = y - bar.y
  let onThumb = local >= v.thumbTopPx and local < v.thumbTopPx + v.thumbPx
  gTextDrag = false
  gEditorVBarDrag = onThumb
  if onThumb:
    v.model.beginBarGrab(trackFractionAt(clamp(local, 0, bar.h - 1), bar.h))
  scrubEditorVBar(r, y, click = not onThumb)
  true

proc lineMarkOf(path: string; line: int): EditorMark =
  ## The breakpoint on `path:line`, as the gutter draws it.
  result = emNone
  if gSession.isNil: return
  for p in editorPointsOf(gSession.session.store.pointList.rows.val):
    if p.path == path and p.line == line and p.kind == epkBreakpoint:
      return (if p.enabled: emBreakpoint else: emBreakpointDisabled)

proc afterMove(r: GpuiRenderer) =
  ## A click moved the debugger: the window follows it, as a step does.
  gViewedFile = ""
  refreshReplayWindow(r)

proc openContextMenuAt(r: GpuiRenderer; menu: ContextMenuModel; x, y: int) =
  gCtxMenu.openAt(menu, y, x)
  traceGesture("context menu " & $menu.kind & " " & menu.labels.join("|"))
  drawTopBar(r)

proc showContent(r: GpuiRenderer; title, text: string; diff = false) =
  ## PLAT-50: a text over the window — an event's content, a value's
  ## history, a value's origin, a changed file's diff.
  gContent = GContent(open: true, title: title, text: text, diff: diff)
  traceGesture("content " & title)
  drawTopBar(r)

proc copyToClipboard(text, what: string) =
  ## PLAT-50: `text` to the system clipboard, through the shim (`gpui_write_
  ## clipboard`, which GPUI's platform clipboard takes on the next frame).
  writeClipboard(text)
  # What the shim now holds for the clipboard, read back: the trace says
  # what was copied, not what was meant to be.
  traceGesture("copied " & what & ": " & clipboardText().strip())

# ---- the editor's columns -------------------------------------------------

proc editorCodeLeftPx(): int =
  ## The window x of the editor's first code column: the pane's body, its
  ## padding and the gutter (`leaves.editorGutterColumns`), as `renderEditor`
  ## lays a row out at `EditorColumnPx` per column.
  let i = gGeom.tabsNodeOfPane($paneEditor)
  if i < 0:
    return -1
  gGeom.nodes[i].body.x + EditorPadSidePx + EditorGutterPx

proc editorColumnAt(x: int): int =
  ## The 1-based text column a press at window x is on (the horizontal
  ## scroll counted), 0 left of the code.
  let left = editorCodeLeftPx()
  if left < 0 or x < left:
    return 0
  int(floor(float(x - left) / EditorColumnPx)) + 1 + gEditorView.leftCol

proc editorXOfColumn(column: int): int =
  ## The inverse: the window x at the middle of `column` (for `--window-ops`,
  ## which presses where a user would).
  let left = editorCodeLeftPx()
  if left < 0:
    return 0
  left + int(round((float(column - 1 - gEditorView.leftCol) + 0.5) *
                   EditorColumnPx))

proc editorRowOf(line: int): EditorRow =
  for row in gEditorSurface.rows:
    if row.line == line:
      return row

proc lineTextOf(path: string; line: int): string =
  ## The text of `path:line` as the editor holds it.
  if gViewedFile.len == 0 or path == gViewedFile:
    let row = editorRowOf(line)
    if row.held:
      return row.text
  ""

proc valueAtColumn(row: EditorRow; column: int): int =
  ## The inline value a press on `column` of `row` is on: the annotation
  ## (`/* a: 1, b: 2 */`) follows the code, and each `name: value` is its
  ## own run of columns — or -1.
  if row.values.len == 0:
    return -1
  var at = drawnCodeText(row).runeLen + 1 + "/* ".len
  for i, v in row.values:
    if i > 0:
      at += ", ".len
    let w = (v.name & ": " & v.value).runeLen
    if column >= at and column < at + w:
      return i
    at += w
  -1

proc lineValuesOf(row: EditorRow): seq[NamedValue] =
  for v in row.values:
    result.add (v.name, v.value)

proc editorMenuAt(path: string; line, column: int): ContextMenuModel =
  ## The editor menu for a press on `column` of `path:line`.
  let session = gSession.session
  let mark = lineMarkOf(path, line)
  var inFile, any = false
  for row in session.store.pointList.rows.val:
    if row.kind == PointKindBreakpoint:
      any = true
      if row.path == path: inFile = true
  let onLine: LineBreakpoint =
    case mark
    of emBreakpoint: lbEnabled
    of emBreakpointDisabled: lbDisabled
    else: lbNone
  let text = lineTextOf(path, line)
  let (token, tokenError) = callTokenAt(text, column,
                                        rust = path.endsWith(".rs"))
  editorTextContextMenu(path, line, lineText = text, column = column,
                        token = token, tokenError = tokenError,
                        breakpoint = onLine, fileHasBreakpoints = inFile,
                        anyBreakpoints = any)

# ---- the window's maximised container --------------------------------------

proc maximisedLayout(layout: Layout; pane: PaneKind): Layout =
  ## PLAT-50 (K7): "Maximise container" — the window shows the stack `pane`
  ## is in (the desktop's GoldenLayout container), alone; the docked panes
  ## stay docked. The committed layout is untouched: minimising shows it
  ## again.
  result = clone(layout)
  let leaf = result.tree.find(pane)
  if leaf.isNil:
    return
  let parent = result.tree.parentOf(leaf)
  let container = if not parent.isNil and parent.kind == lnStack: parent
                  else: leaf
  result.tree = clone(container)
  result.tree.weight = 1.0

proc toggleMaximised(r: GpuiRenderer; pane: PaneKind) =
  gMaximised = if gMaximised.isSome: none(PaneKind) else: some(pane)
  traceGesture(if gMaximised.isSome: "maximised " & $pane
               else: "minimised")
  discard drawArrangement(r)

# ---- the event log's order -------------------------------------------------

proc orderEventLog(r: GpuiRenderer; order: EventLogOrder) =
  ## PLAT-50 (K26): the log in `order` — the engine sorts (`ct/event-load`'s
  ## `sortKey`), the ViewModel records which column (its header shows the
  ## arrow), and the pane is drawn again.
  let vm = gSession.session.eventLogVM
  if vm.isNil:
    return
  vm.sortBy(order)
  # The window the pane shows, re-cut in the new order — not the whole log.
  let held = max(1, gSession.session.store.eventLog.rows.val.len)
  try:
    discard gSession.requestAndLoadEventLog(start = 0, count = held,
                                            order = order)
  except CatchableError as e:
    traceGesture("event order failed: " & e.msg)
  traceGesture("event log order " & $order.column & " " &
               (if order.ascending: "ascending" else: "descending"))
  redrawPaneOf(r, paneEventLog)

# ---- the VCS pane ----------------------------------------------------------

proc vcsVM(): VCSVM =
  for leaf in gLeafSet.leaves:
    if leaf.kind == glkBuiltin and leaf.builtin == paneVcs and
       not leaf.vm.isNil:
      return VCSVM(leaf.vm)

proc toggleVcsCommit(r: GpuiRenderer; index: int) =
  ## PLAT-50 (K53): the desktop's accordion — a commit opens, listing the
  ## files it changed (`git diff-tree`), and the open one closes.
  let vm = vcsVM()
  if vm.isNil:
    return
  let commits = vm.commits.val
  if index < 0 or index >= commits.len:
    return
  if vm.selectedCommitIndices.val == @[index]:
    vm.setCommits(commits, [])
    vm.removeCommitFiles(index)
    traceGesture("commit closed #" & $index)
  else:
    let c = commits[index]
    var rows: seq[VCSFileRow] = @[]
    for (status, path) in commitChangedFiles(
        gVcsDirectory, (if c.fullHash.len > 0: c.fullHash else: c.hash)):
      rows.add VCSFileRow(status: status, path: path,
                          baseName: path.extractFilename)
    vm.syncCommitFilesMap([])
    vm.setCommitFiles(index, rows)
    vm.setCommits(commits, [index], index)
    traceGesture("commit opened #" & $index & " " & $rows.len & " file(s)")
  redrawPaneOf(r, paneVcs)

proc openVcsDiff(r: GpuiRenderer; option: string) =
  ## PLAT-50 (K34): a changed file's diff — `file-<i>` of the working tree,
  ## `commitfile-<commit>-<i>` of an opened commit.
  let vm = vcsVM()
  if vm.isNil:
    return
  var status, path, hash = ""
  let parts = option.split('-')
  try:
    if parts.len == 2 and parts[0] == "file":
      let f = vm.workingTreeFiles.val[parseInt(parts[1])]
      status = f.status
      path = f.path
    elif parts.len == 3 and parts[0] == "commitfile":
      let ci = parseInt(parts[1])
      let fi = parseInt(parts[2])
      for (index, files) in vm.commitFilesMap.val:
        if index == ci and fi < files.len:
          status = files[fi].status
          path = files[fi].path
      let c = vm.commits.val[ci]
      hash = if c.fullHash.len > 0: c.fullHash else: c.hash
  except ValueError, IndexDefect:
    return
  if path.len == 0:
    return
  let text = if hash.len > 0: commitFileDiff(gVcsDirectory, hash, path)
             else: workingTreeFileDiff(gVcsDirectory, path, status)
  showContent(r, "diff " & path &
                   (if hash.len > 0: "  (commit " & hash[0 ..< min(7, hash.len)] &
                                     ")"
                    else: "  (working tree)"),
              (if text.len > 0: text else: "no changes to show for " & path),
              diff = true)

# ---- a value's history and origin -------------------------------------------

proc showValueHistory(r: GpuiRenderer; path: string) =
  ## K28 / K40: "Toggle value history" and the row's history button — the
  ## history OPENS IN THE PANE, under the row (PLAT-51; the desktop's
  ## `div.ct-history-inline-container`); a second toggle closes it. Its
  ## entries are navigation rows (`gcpHistoryEntry`).
  let vm = gSession.session.stateVM
  if vm.isNil:
    return
  var open = vm.expandedHistories.val
  if path in open:
    open.excl path
  else:
    try:
      discard gSession.loadValueHistory(path, gpuiRowBudget())
    except CatchableError as e:
      traceGesture("no history for " & path & ": " & e.msg)
    open.incl path
  vm.expandedHistories.val = open
  traceGesture("history " & path & " " &
               $vm.valueHistory.val.getOrDefault(path).len & " value(s)")
  redrawPaneOf(r, paneState)

proc showValueOrigin(r: GpuiRenderer; path: string) =
  ## K28 / K41: "Show value origin" and the row's origin badge — the chain
  ## OPENS IN THE PANE under the row (PLAT-51; the desktop's in-row chain),
  ## nearest cause first; a second toggle closes it.
  let vm = gSession.session.stateVM
  if vm.isNil:
    return
  var lines = vm.originLines.val
  if lines.hasKey(path):
    lines.del path
  else:
    try:
      lines[path] = gSession.loadValueOrigin(path).originHopLines
    except CatchableError as e:
      traceGesture("no origin for " & path & ": " & e.msg)
      lines[path] = @[]
  vm.originLines.val = lines
  traceGesture("origin " & path & " " & $lines.getOrDefault(path).len &
               " hop(s)")
  redrawPaneOf(r, paneState)

proc runWatchCommand(r: GpuiRenderer; query: string): bool =
  ## PLAT-51: `:watch EXPR`, `:unwatch EXPR`, `:watch-edit OLD -> NEW` — the
  ## desktop's watch field and row controls (Variable-State-Pane.md: watch
  ## expressions "add, edit, remove"); the engine evaluates them inside the
  ## next locals load.
  var text = query.strip()
  if not text.startsWith(":"):
    return false
  text = text[1 .. ^1]
  let sp = text.find(' ')
  let verb = if sp < 0: text else: text[0 ..< sp]
  let arg = if sp < 0: "" else: text[sp + 1 .. ^1].strip()
  if verb == "calls" and not gSession.isNil and
     not gSession.session.calltraceVM.isNil:
    # The call trace's search (`:calls QUERY`; empty clears it).
    gSession.session.calltraceVM.setSearchQuery(arg)
    traceGesture("calls search '" & arg & "'")
    gOmnibar.close()
    redrawCalltrace(r)
    drawTopBar(r)
    return true
  if verb notin ["watch", "unwatch", "watch-edit"] or gSession.isNil or
     gSession.session.stateVM.isNil or arg.len == 0:
    return false
  let vm = gSession.session.stateVM
  case verb
  of "watch": vm.addWatch(arg)
  of "unwatch": vm.removeWatch(arg)
  else:
    let at = arg.find("->")
    if at < 0:
      return false
    vm.editWatch(arg[0 ..< at].strip(), arg[at + 2 .. ^1].strip())
  traceGesture("watches " & vm.watchExpressions.val.join("|"))
  gOmnibar.close()
  refreshReplayWindow(r)
  true

# ---- the actions -----------------------------------------------------------

proc openTreeFile(r: GpuiRenderer; path: string) =
  ## K17 (and the Files menu's Edit): the file in the editor, as the
  ## desktop's `FilesystemVM.openFile` opens it.
  gViewedFile = path
  if gViewedFile == gSession.getCurrentFile():
    gViewedFile = ""
    refreshReplayWindow(r)
  else:
    showViewedFile(r)

proc runContextAction(r: GpuiRenderer; action: ContextAction;
                      target: ContextTarget) =
  ## A right-click menu's chosen entry, routed to the operation the
  ## desktop's entry runs.
  traceGesture("context action " & $action)
  # K19: an Edit window has no session; its Files menu acts on the disk.
  if gSession.isNil and
     action notin {caFileCreate, caFileRename, caFileDelete, caFileEdit}:
    return
  case action
  of caNone: discard
  of caPinLeft, caPinBottom, caPinRight:
    applyGestureCommand(r, cmdDock(target.pane,
      (case action
       of caPinLeft: leLeft
       of caPinRight: leRight
       else: leBottom)))
    discard drawArrangement(r)
  of caUnpin:
    applyGestureCommand(r, cmdRestoreDocked(target.pane))
    discard drawArrangement(r)
  of caClosePane:
    applyGestureCommand(r, cmdRemovePane(target.pane))
    discard drawArrangement(r)
  of caMaximise:
    toggleMaximised(r, target.pane)
  of caCopy:
    # Monaco's Copy with nothing selected copies the caret's line, and the
    # right-click put the caret on it.
    copyToClipboard(target.text & "\n", "line " & $target.line)
  of caFind:
    openOmnibar(r)
  of caJumpToLine, caRunToCursor, caJumpBackwardToLine:
    try:
      gSession.sourceLineJump(target.path, target.line,
        (case action
         of caRunToCursor: "forward"
         of caJumpBackwardToLine: "backward"
         else: "smart"))
    except CatchableError as e:
      traceGesture("line jump failed: " & e.msg)
      return
    afterMove(r)
  of caJumpToCall, caJumpForwardToCall, caJumpBackwardToCall:
    if target.token.len == 0:
      traceGesture(if target.tokenError.len > 0:
                     target.tokenError & " on line " & $target.line & "."
                   else: NoWordSelected)
      return
    try:
      gSession.sourceCallJump(target.path, target.line, target.token,
        (case action
         of caJumpForwardToCall: "forward"
         of caJumpBackwardToCall: "backward"
         else: "smart"))
    except CatchableError as e:
      traceGesture("call jump failed: " & e.msg)
      refreshReplayWindow(r)
      return
    afterMove(r)
  of caAddBreakpoint, caDeleteBreakpoint:
    discard gSession.toggleBreakpoint(target.path, target.line)
    refreshReplayWindow(r)
  of caEnableBreakpoint, caDisableBreakpoint:
    discard gSession.setBreakpointEnabled(target.path, target.line,
                                          action == caEnableBreakpoint)
    refreshReplayWindow(r)
  of caDeleteBreakpointsInFile, caDeleteAllBreakpoints:
    discard gSession.clearAllBreakpoints(
      if action == caDeleteAllBreakpoints: "" else: target.path)
    refreshReplayWindow(r)
  of caAddTracepoint:
    # The desktop opens its tracepoint editor on the line; the window's
    # omnibar takes `:tracepoint <expression>`, placed on this line.
    gTracepointAt = (target.path, target.line)
    openOmnibar(r, TracepointCommand)
  of caToggleCallChildren:
    # The same toggle a click on the row's icon makes (`session_driver`):
    # the expansion, then the ViewModel reads its reported window again.
    let why = gSession.toggleCallChildren(target.index)
    if why.len > 0:
      traceGesture("calltrace toggle failed: " & why)
    redrawCalltrace(r)
  of caToggleValueHistory:
    showValueHistory(r, target.path)
  of caShowValueOrigin:
    showValueOrigin(r, target.path)
  of caAddValueToScratchpad, caAddAllValuesToScratchpad:
    for (name, value) in target.scratchpadSamplesOf(action):
      gSession.addToScratchpad(name, value)
    traceGesture("scratchpad " &
                 $gSession.session.scratchpadVM.entries.val.len & " value(s)")
    redrawPaneOf(r, paneScratchpad)
  of caJumpToValue:
    traceGesture(target.expression & " = " & target.text &
                 " is the value at this step")
  of caFileCreate, caFileRename, caFileDelete, caFileEdit:
    # K19: the Files pane's entries, as the shared Files model decides them
    # now — the replay's tree, or Edit mode's opened folder. Opening a file
    # is this window's editor.
    let vm = windowFilesVM()
    if action == caFileEdit:
      let why = vm.fileTreeEntryReason(target.path, action)
      if why.len > 0:
        filesSay(why)
      elif not openArm.isNil:
        discard openEditFile(target.path)
      else:
        openTreeFile(r, target.path)
      return
    let why = vm.runFileTreeAction(target.path, action)
    if why.len > 0:
      filesSay(why)
    else:
      # A name field or Delete's question is open in the tree now; the keys
      # reach it through the editor's listener.
      traceGesture("files: " & $action)
      redrawPaneOf(r, paneFileTree)
      focusEditKeys()

# ---------------------------------------------------------------------------
# PLAT-68 — the window's keys through the ONE router
# ---------------------------------------------------------------------------

proc drawDebugDocument(r: GpuiRenderer) =
  ## The editor drawn again with its document's caret and selection (or,
  ## once writable, the document itself).
  gEditorSurface = withDebugDocument(gEditorSurface)
  redrawEditorRows(r)

proc placeCaret(r: GpuiRenderer; path: string; line, column: int) =
  ## Put the read-only editor's caret at `line:column` (1-based) of `path` —
  ## the caret of the file's Debug-mode document — and draw it.
  if not debugDocumentFor(path, gEditorSurface.executionLine):
    return
  gDebugDocs[path].moveCaretTo(max(1, line) - 1, max(1, column) - 1)
  if gEditorSurface.path == path:
    drawDebugDocument(r)
  traceGesture("caret " & $gDebugDocs[path].caretLine & ":" &
               $(gDebugDocs[path].caretColumn + 1))

proc wireSearch(s: HeadlessDebugSession) =
  ## PLAT-57: the session's Find in Files searches go to the shared runner,
  ## over this recording's scope (`native_host.recordingSearchScope`).
  if s.isNil:
    return
  let folder = s.tracePath
  wireFindInFiles(s.session.searchResultsVM,
                  proc(): FindInFilesScope = recordingSearchScope(folder))

proc runGpuiFindInFiles(r: GpuiRenderer; pattern: string) =
  ## `:grep <pattern>` (Find-And-Incremental-Search.md §5.1): the search, and
  ## Find in Files shown (`showPaneFromMenu`'s rule: revealed, activated or
  ## opened). Nothing opens — the user's OQ-F2.
  let vm = searchVM()
  if vm.isNil:
    traceGesture("Find in Files needs a recording to search")
    return
  vm.search(pattern)
  gSearch.scrollTop = 0
  traceGesture("find in files '" & pattern & "'")
  showPaneFromMenu(r, paneSearch)
  armHoverTick()

proc openFindInFiles(r: GpuiRenderer) =
  ## `search.find-in-files` with no pattern (`Ctrl+Shift+F`, the Edit menu,
  ## a press on the pane's field): the pane shown and its field — the
  ## omnibox's `:grep` line, holding the pane's query (§5.2).
  showPaneFromMenu(r, paneSearch)
  let vm = searchVM()
  openOmnibar(r, CommandPrefix & "grep " & (if vm.isNil: "" else: vm.query.val))

proc openSearchResult(r: GpuiRenderer; index: int): bool =
  ## K35: result `index` selected and opened in the editor at its line — the
  ## file read from the recording as a Files click's is (`showViewedFile`),
  ## the caret on the match and the match selected. The recording position
  ## does not move (Editor-Pane.md: a Find-in-Files row click does not).
  let vm = searchVM()
  if vm.isNil:
    return false
  let rows = vm.results.val
  if index < 0 or index >= rows.len:
    return false
  vm.selectResult(index)
  let row = rows[index]
  gViewedFile = row.path
  showViewedFile(r, atLine = row.line)
  if gViewedFile.len > 0:
    let column = if row.matchStart > 0 and row.matchStart <= row.text.len:
                   row.text[0 ..< row.matchStart].runeLen
                 else: 0
    if debugDocumentFor(row.path, gEditorSurface.executionLine):
      gDebugDocs[row.path].moveCaretTo(row.line - 1, column)
      if row.matchLength > 0:
        let width = row.text[row.matchStart ..< min(row.text.len,
                      row.matchStart + row.matchLength)].runeLen
        gDebugDocs[row.path].extendSelectionTo(row.line - 1, column + width)
      drawDebugDocument(r)
    traceGesture("opened " & row.path & ":" & $row.line)
  gSearch.revealResult(vm, searchBody(), index)
  drawSearchPane(r)
  gViewedFile.len > 0

proc stepSearchResult(r: GpuiRenderer; delta: int) =
  ## `search.next-result` / `search.previous-result`: the next / previous
  ## result, wrapping, opened.
  let vm = searchVM()
  if vm.isNil or vm.results.val.len == 0:
    traceGesture("there are no search results")
    return
  discard openSearchResult(r, vm.stepResult(delta))

proc toggleSearchOption(r: GpuiRenderer; which: SearchOption) =
  ## One of Find in Files' toggles flipped — a press on it, or its key in the
  ## field (`search.toggle-*`) — and a search that ran runs again with it
  ## (the ViewModel's rule).
  let vm = searchVM()
  if vm.isNil:
    traceGesture("Find in Files has no session")
    return
  vm.toggleOption(which)
  traceGesture("search option " & $which & " " & $vm.options.val.isOn(which))
  drawSearchPane(r)

proc pressSearch(r: GpuiRenderer; x, y: int): bool =
  ## A left press on Find in Files: a result opens, a toggle flips (and a
  ## search that ran runs again — the ViewModel's rule), the field opens the
  ## omnibox's `:grep`, the
  ## scrubber moves the view. Every press on the pane is the pane's.
  let vm = searchVM()
  let body = searchBody()
  if vm.isNil or body.w <= 0 or not body.contains(x, y):
    return false
  let hit = searchHitAt(vm, gSearch, body, x, y)
  case hit.kind
  of gsNone, gsFile: discard
  of gsQuery: openFindInFiles(r)
  of gsOption: toggleSearchOption(r, hit.option)
  of gsMatch: discard openSearchResult(r, hit.index)
  of gsTrack, gsThumb:
    gSearch.dragging = hit.kind == gsThumb
    if gSearch.dragging:
      let total = vm.displayRows().len
      gSearch.scrubberOf(total, searchLayout(body, total).rows).beginBarGrab(
        hit.fraction)
    gSearch.scrubSearch(vm, body, y, dragging = gSearch.dragging)
    drawSearchPane(r)
  armHoverTick()
  true

proc runAgentPrompt(r: GpuiRenderer; text: string) =
  ## PLAT-54: `/ai <text>` — the desktop's agent query: Agent Activity shown
  ## and the prompt sent to the agent.
  showPaneFromMenu(r, paneAgentActivity)
  let h = agentHost()
  if h.isNil:
    traceGesture("agent: no session")
    return
  let why = h.sendPrompt(text)
  traceGesture(if why.len > 0: "agent: " & why else: "agent: sent " & text)
  drawAgentPane(r)
  drawTopBar(r)
  armHoverTick()

proc pressAgent(r: GpuiRenderer; x, y: int): bool =
  ## A left press on Agent Activity: a row runs its action, a button its
  ## button's, the prompt opens the omnibox on `/ai `, Stop stops, the
  ## scrubber moves the view. Every press on the pane is the pane's.
  let h = agentHost()
  let body = agentBody()
  if h.isNil or body.w <= 0 or not body.contains(x, y):
    return false
  let rows = h.feedRows()
  let hit = agentHitAt(rows, gAgent, body, x, y)
  case hit.kind
  of gaNone: discard
  of gaRow, gaButton:
    let row = rows[hit.row]
    let action = if hit.kind == gaRow: row.press
                 elif hit.button < row.buttons.len: row.buttons[hit.button]
                 else: AgentFeedAction()
    if action.kind != faNone:
      discard h.runFeed(row, action)
      traceGesture("agent " & $action.kind & " " & row.key &
                   (if h.message.len > 0: ": " & h.message else: ""))
      h.message = ""
      # An evidence card's review lands in the VCS pane at once.
      redrawPaneOf(r, paneVcs)
    drawAgentPane(r)
  of gaPrompt:
    openOmnibar(r, AgentOmnibarQuery)
  of gaControl:
    if h.vm.isLoading.val:
      h.stopAgent()
      traceGesture("agent: stops after its current turn")
    else:
      openOmnibar(r, AgentOmnibarQuery)
  of gaTrack, gaThumb:
    gAgent.dragging = hit.kind == gaThumb
    let lay = agentLayout(body, rows, gAgent.scroll)
    if gAgent.dragging:
      lay.scrubberOf().beginBarGrab(hit.fraction)
    gAgent.scrubAgent(rows, body, y, dragging = gAgent.dragging)
    drawAgentPane(r)
  armHoverTick()
  true

proc editorLineAt(y: int): int =
  ## The source line of the editor row drawn at window y (the rows below the
  ## source statement, `GpuiEditorRowPx` each), clamped to the rows shown.
  let i = gGeom.tabsNodeOfPane($paneEditor)
  if i < 0 or gEditorSurface.rows.len == 0:
    return 0
  let top = gGeom.nodes[i].body.y + editorTopInsetPx() + EditorLinesAbovePx
  # Row by row, past the loop controls drawn above some of them.
  var rowTop = top
  for k, row in gEditorSurface.rows:
    rowTop += zonesAbove(row.line) * LoopZonePx -
              (if k > 0: zonesAbove(gEditorSurface.rows[k - 1].line) * LoopZonePx
               else: 0)
    if y < rowTop + GpuiEditorRowPx or k == gEditorSurface.rows.high:
      return row.line
    rowTop += GpuiEditorRowPx
  gEditorSurface.rows[^1].line

proc editorYOfLine(line: int): int =
  ## The inverse: the window y at the middle of `line`'s row.
  let i = gGeom.tabsNodeOfPane($paneEditor)
  if i < 0:
    return 0
  for k, row in gEditorSurface.rows:
    if row.line == line:
      return gGeom.nodes[i].body.y + editorTopInsetPx() + EditorLinesAbovePx +
             k * GpuiEditorRowPx + zonesAbove(line) * LoopZonePx +
             GpuiEditorRowPx div 2
  0

proc dragTextTo(r: GpuiRenderer; x, y: int) =
  ## A held press on the text moved: the selection runs from where it was
  ## pressed to the cell under the pointer (`extendSelectionTo`, every
  ## front-end's drag).
  let path = gEditorSurface.path
  if not gDebugDocs.hasKey(path):
    return
  let line = editorLineAt(y)
  if line <= 0:
    return
  gDebugDocs[path].extendSelectionTo(line - 1, max(1, editorColumnAt(x)) - 1)
  drawDebugDocument(r)
  let cells = gDebugDocs[path].selectionCells
  traceGesture("selection " & (if cells.len == 0: "none" else:
    $cells[0].line & ":" & $cells[0].fromColumn & "-" & $cells[^1].line &
    ":" & $cells[^1].toColumn))

proc focusWindowPane(r: GpuiRenderer; pane: string) =
  ## Give `pane` the focus: its element takes GPUI's element focus (the
  ## chain the scope path is read from) and the focus outline follows it.
  gFocusPane = pane
  let el = gPanes.getOrDefault(pane)
  if not el.isNil:
    setFocusable(el)
    discard focusElement(el)

proc editorFocused(): bool =
  gFocusPane == $paneEditor

proc windowSessionFacts(): SessionFacts =
  ## The ViewModels' facts the context keys derive from (`contextKeysOf`) —
  ## the terminal's `runtime.sessionFacts`, from this window's models.
  let path = editorPath()
  let editor =
    if editorFocused() and gDebugDocs.hasKey(path):
      editorFactsOf(gDebugDocs[path].state, false)
    else: sourceViewFacts()
  SessionFacts(product: pmDebug,
               replayLoaded: not gSession.isNil,
               editor: editor,
               paletteVisible: not gOmnibar.isNil and gOmnibar.isOpen,
               contextMenuVisible: gCtxMenu.open,
               dragActive: gGestures.active or gGestures.revealing)

proc windowScopePath(): ScopePath =
  ## **GPUI'S SCOPE PATH** (Base-Keymaps §6.2), read off the window's own
  ## focus chain: the focused element and its ancestors, each scope element
  ## carrying `data-scope-kind` / `data-scope-id` (the window root, the
  ## session tab's container, the panes), then what the focused pane holds —
  ## the editor's document. A window-owned overlay (the palette, the
  ## right-click menu) replaces the chain below the window, as the
  ## terminal's producer does.
  var r: GpuiRenderer
  var chain: seq[ScopeElement] = @[]
  var node = focusedElement()
  while not node.isNil:
    let kind = getAttribute(node, ScopeKindAttribute)
    if kind.len > 0:
      chain.insert(elementOfAttributes(kind, getAttribute(node,
                                                          ScopeIdAttribute)), 0)
    node = r.parentNode(node)
  let window = if chain.len > 0 and chain[0].kind == ekWindow: chain[0]
               else: element(ekWindow, "window")
  if not gOmnibar.isNil and gOmnibar.isOpen:
    return @[window, element(ekOverlay, "palette"),
             paletteFieldOf(gOmnibar.query)]
  if gCtxMenu.open:
    return @[window, element(ekOverlay, "context-menu")]
  if chain.len == 0:
    return @[window]
  result = chain
  let path = editorPath()
  if result[^1].kind == ekPane and result[^1].paneKind == $paneEditor and
     gDebugDocs.hasKey(path):
    result.add element(ekEditor, "editor:" & path)

proc syncOverlayLayers() =
  ## THE PUSHED LAYERS MIRROR THE OVERLAYS (§5.3): the palette's and the
  ## right-click menu's tables are on the stack exactly while they are open,
  ## however they were opened or closed.
  proc want(table, label: string; open: bool) =
    let at = gRouter.stack.indexOfLayer(table, "window")
    if open and at < 0:
      discard gRouter.pushLayer(table, "window", label)
    elif not open and at >= 0:
      discard gRouter.popLayer(gRouter.stack.layers[at].token)
  let palette = not gOmnibar.isNil and gOmnibar.isOpen
  if not gCtxMenu.open: want(ContextMenuTable, "MENU", false)
  if not palette: want(PaletteTable, "PALETTE", false)
  want(PaletteTable, "PALETTE", palette)
  want(ContextMenuTable, "MENU", gCtxMenu.open)

proc refreshMenuShortcuts() =
  ## The menu's chords are THE ROUTER'S (KL-8): each item's operation
  ## (`client_actions`), the chord that runs it from the focus — so a
  ## rebinding in `keybindings.json` is shown the moment it loads.
  if gMenu.isNil:
    return
  syncOverlayLayers()
  let facts = windowSessionFacts()
  let path = windowScopePath()
  var chords = initTable[string, string]()
  for (_, it) in gMenu.root.actionItems():
    let op = operationOfClientAction(it.action)
    if op.len == 0:
      continue
    let (name, arg) = splitOperation(op)
    let chord = gRouter.chordFor(name, facts, path, nmNormal, arg)
    if chord.len > 0:
      chords[it.action] = chord
  gMenu.setShortcuts(chords)

proc applyKeybindings(load: KeybindingsLoad) =
  ## Lay the user's `keybindings.json` over the base; what did not load is
  ## said (the window's trace, which the window lanes read).
  gKeybindings = load
  if load.readError.len > 0:
    traceGesture("keybindings: " & load.readError)
    return
  gRouter.applyUserKeymap(load.keymap)
  if gRouter.errors.len > 0:
    traceGesture("keybindings: " & gRouter.loadSummary)
  refreshMenuShortcuts()

proc wireKeybindings(base: BaseKeymap; source: BaseSource) =
  ## The router this window resolves with: the base, then the ONE user
  ## keymap every front-end reads (Base-Keymaps §3.5) — an old
  ## `.cttui-keys` or edited desktop YAML translated into it once first.
  gRouter = initKeymapRouter(base, GpuiDelivery, source)
  for note in importOldConfigsOnce(defaultOldConfigs(DesktopDefaultConfig)):
    traceGesture("keybindings: " & note)
  applyKeybindings(readKeybindings())

proc pollKeybindings() =
  ## Between frames: the file changed on disk — read it again. A file that
  ## cannot be read keeps the rows that loaded last.
  if gKeybindings.path.len == 0 or not gKeybindings.changedSince:
    return
  let fresh = readKeybindings(gKeybindings.path)
  if fresh.readError.len > 0:
    traceGesture("keybindings: " & fresh.readError)
    gKeybindings.exists = fresh.exists
    gKeybindings.stamp = fresh.stamp
  else:
    applyKeybindings(fresh)

proc runDebugEditorOperation(r: GpuiRenderer; res: EditingResolution;
                             nowMs: int64) =
  ## A vocabulary operation (or a character) on the shown file's document:
  ## the motions and the selection move, a copy reaches GPUI's clipboard, a
  ## paste reads it, an edit is refused while the document is read-only.
  let path = editorPath()
  if not debugDocumentFor(path, gEditorSurface.executionLine):
    traceGesture("`" & res.operation & "` needs a document in the editor")
    return
  if res.operation == "clipboard-paste":
    let pasted = clipboardText()
    if pasted.len > 0:
      gDebugDocs[path].offerClipboard(pasted)
  let caretBefore = (gDebugDocs[path].caretLine, gDebugDocs[path].caretColumn)
  let applied = gDebugDocs[path].applyResolved(res, nowMs)
  if res.operation in ["clipboard-copy", "clipboard-cut"]:
    let copied = gDebugDocs[path].clipboardText
    if copied.len > 0:
      copyToClipboard(copied, $copied.countLines & " line(s)")
  if applied.outcome == eoIgnored and res.kind == erOperation and
     gDebugDocs[path].isReadOnly:
    traceGesture("the editor is read-only — Ctrl+E makes it writable")
  # M73 (#840): A CARET THAT MOVED brings the drawn window with it — the
  # vertical half of `followEditorView`'s caret-follow, which until M73 was
  # sideways only, so a caret walked below the last row left the screen. A
  # key that did not move it (a copy, a refused edit) leaves a window the
  # user scrolled where it is.
  let d = gDebugDocs[path]
  if not (d.isReadOnly and path == gEditorSurface.path and
          (d.caretLine, d.caretColumn) != caretBefore and
          followCaretInEditor(r, d.caretLine, d.caretColumn + 1)):
    drawDebugDocument(r)
  traceGesture("caret " & $gDebugDocs[path].caretLine & ":" &
               $(gDebugDocs[path].caretColumn + 1))

proc focusedRowText(): tuple[text, what: string] =
  ## What `list.copy` copies from the focused list: the row it has
  ## selected, and how to name it.
  if gSession.isNil:
    return ("", "")
  case gFocusPane
  of $paneCalltrace:
    let vm = gSession.session.calltraceVM
    if not vm.isNil:
      for row in vm.callRows():
        if crfSelected in row.flags: return (row.callRowText, "the call")
  of $paneState:
    # PLAT-70 Part B (§5.3): the variable's WHOLE value, untruncated — what
    # its detail and its tooltip show.
    let vm = gSession.session.stateVM
    if not vm.isNil and vm.selectedPath.val.len > 0:
      let path = vm.selectedPath.val
      for row in stateRows(vm, gpuiRowBudget()):
        if row.path == path:
          return (fullValueText(row.presented, row.whole),
                  "the value of " & row.name)
      return (path, "the variable")
  of $paneEventLog:
    let vm = gSession.session.eventLogVM
    if not vm.isNil:
      let rows = vm.eventRows.val
      let sel = vm.selectedRow.val
      let at = if sel.isSome: sel.get else: 0
      if at >= 0 and at < rows.len:
        return (rows[at].value, "event #" & $rows[at].eventIndex)
  else: discard
  ("", "")

proc runWindowOperation(r: GpuiRenderer; res: EditingResolution;
                        nowMs: int64) =
  ## **GPUI'S DISPATCH** of a resolved operation onto its ViewModels — the
  ## terminal's `runtime.runOperation`, this window's half: the editing
  ## vocabulary onto the shown file's document, the overlays' operations
  ## onto the overlay that is open, a `ClientAction` operation onto the
  ## window's menu action (the desktop's own action names). An operation
  ## this window does not perform is INERT AND SAYS SO (IR-6).
  let op = if res.argument.len > 0: res.operation & "(" & res.argument & ")"
           else: res.operation
  traceGesture("operation " & op)
  if '.' notin res.operation:
    runDebugEditorOperation(r, res, nowMs)
    return
  if res.operation.startsWith("palette.") and gOmnibar.isOpen:
    case res.operation
    of "palette.focus-previous": gOmnibar.moveSelection(-1)
    of "palette.focus-next": gOmnibar.moveSelection(1)
    of "palette.focus-page-up": gOmnibar.moveSelection(-10)
    of "palette.focus-page-down": gOmnibar.moveSelection(10)
    of "palette.accept":
      acceptOmnibar(r)
      return
    of "palette.close": gOmnibar.close()
    else: discard
    drawTopBar(r)
    return
  if res.operation.startsWith("input.") and gOmnibar.isOpen:
    case res.operation
    of "input.move-left": gOmnibar.moveCursor(-1)
    of "input.move-right": gOmnibar.moveCursor(1)
    of "input.move-start": gOmnibar.cursorHome()
    of "input.move-end": gOmnibar.cursorEnd()
    of "input.delete-backward": gOmnibar.backspace()
    of "input.delete-forward": gOmnibar.deleteForward()
    of "input.toggle-overwrite": gOmnibar.toggleOverwrite()
    of "input.paste": gOmnibar.typeText(clipboardText())
    of "input.commit":
      acceptOmnibar(r)
      return
    of "input.cancel": gOmnibar.close()
    else: traceGesture("`" & op & "` is not available in the palette")
    drawTopBar(r)
    return
  if res.operation.startsWith("context-menu.") and gCtxMenu.open:
    case res.operation
    of "context-menu.focus-previous": gCtxMenu.move(-1)
    of "context-menu.focus-next": gCtxMenu.move(1)
    of "context-menu.focus-first": gCtxMenu.moveToEnd(last = false)
    of "context-menu.focus-last": gCtxMenu.moveToEnd(last = true)
    of "context-menu.accept":
      let chosen = gCtxMenu.choose(-1)
      if chosen.chosen:
        drawTopBar(r)
        runContextAction(r, chosen.action, chosen.target)
        return
    of "context-menu.close": gCtxMenu.close()
    else: discard
    drawTopBar(r)
    return
  let palette = paletteQueryOf(res.operation)
  if palette.ok:
    openOmnibar(r, palette.query)
    return
  case res.operation
  of "editor.toggle-read-only":
    let path = editorPath()
    if not debugDocumentFor(path, gEditorSurface.executionLine):
      traceGesture("there is no document in the editor to make writable")
      return
    gDebugDocs[path].setReadOnly(not gDebugDocs[path].isReadOnly)
    traceGesture(if gDebugDocs[path].isReadOnly: "the editor is read-only"
                 else: "the editor is writable")
    # Back to read-only: the recording's rows again, from the session.
    if gViewedFile.len > 0: showViewedFile(r)
    else: refreshReplayWindow(r)
    return
  of "editor.toggle-tracepoint":
    # The desktop's `Enter` / `Ctrl+Enter` / `Alt+T` in the read-only
    # editor (`Editor.TracepointCreation`): the tracepoint editor, on the
    # caret's line.
    let path = editorPath()
    let line = if gDebugDocs.hasKey(path): gDebugDocs[path].caretLine
               else: max(1, gEditorSurface.executionLine)
    gTracepointAt = (path, line)
    traceGesture("tracepoint editor at " & $line)
    openOmnibar(r, TracepointCommand)
    return
  of "menu.open", "menu.toggle", "menu.open-folder":
    runMenuOperation(res.operation, res.argument)
    drawTopBar(r)
    return
  of "layout.reveal-next-docked":
    revealNext(r)
    return
  of "layout.cancel-drag":
    discard cancelWindowGesture()
    return
  of "session-tabs.next", "session-tabs.previous", "session-tabs.next-recent",
     "session-tabs.previous-recent":
    if not gShell.isNil:
      let step = if res.operation.endsWith("next") or
                    res.operation.endsWith("next-recent"): 1 else: -1
      if gShell.app.stepTab(step):
        traceGesture("session tab " & $gShell.app.activeTabIndex())
    drawTopBar(r)
    return
  of "list.focus-next", "list.focus-previous", "list.focus-first",
     "list.focus-last", "list.focus-page-down", "list.focus-page-up",
     "list.activate":
    # PLAT-53: the focused Test Results pane's list (other panes say below
    # that the operation is not theirs here, as before).
    if testsKey(r, res.operation):
      return
    # PLAT-55: and the focused Problems pane's.
    if problemsKey(r, res.operation):
      return
  of "list.copy":
    let (text, what) = focusedRowText()
    if text.len == 0: traceGesture("nothing is selected here to copy")
    else: copyToClipboard(text, what)
    return
  of "editor.scroll-line-down", "editor.scroll-line-up",
     "editor.scroll-half-page-down", "editor.scroll-half-page-up",
     "editor.scroll-page-down", "editor.scroll-page-up",
     "editor.center-on-pointer":
    # M73 (#840): §4.2 Source Navigation on the focused read-only editor —
    # `j` / `k` (CUA's `Ctrl+Down` / `Ctrl+Up`) a line, `Ctrl+d` / `Ctrl+u`
    # half the editor (CUA's `Alt+PageDown` / `Alt+PageUp` a page), `.` the
    # pointer centred — the window only, the pointer and the caret stay.
    # Until M73 these were inert here ("not available in this window").
    if editorFocused() and debugSourceShown():
      let rows = max(1, editorRowsOf(gGeom))
      case res.operation
      of "editor.center-on-pointer": centreEditorOnPointer(r)
      of "editor.scroll-line-down": scrollEditorLines(r, 1)
      of "editor.scroll-line-up": scrollEditorLines(r, -1)
      of "editor.scroll-half-page-down": scrollEditorLines(r, max(1, rows div 2))
      of "editor.scroll-half-page-up": scrollEditorLines(r, -max(1, rows div 2))
      of "editor.scroll-page-down": scrollEditorLines(r, rows)
      else: scrollEditorLines(r, -rows)
      return
  of "list.show-detail":
    # PLAT-70 Part B (Horizontal-Overflow.md §5.3).
    showTableDetail(r)
    return
  of "table.resize-column":
    # PLAT-70 Part B (§5.2): the Event Log is the table whose columns resize.
    resizeEventLogColumn(r, res.argument)
    return
  of "view.scroll-left", "view.scroll-right", "view.scroll-left-half",
     "view.scroll-right-half", "view.scroll-to-line-start":
    runGpuiViewOperation(r, res.operation)
    return
  of "find.open", "find.open-backward":
    # GPUI's find is the omnibar's (`:grep` over the files).
    openOmnibar(r, CommandPrefix & "grep ")
    return
  of "search.find-in-files":
    # PLAT-57: with a pattern, the search; without, the pane and its field.
    if res.argument.len > 0: runGpuiFindInFiles(r, res.argument)
    else: openFindInFiles(r)
    return
  of "problems.next", "problems.previous":
    # PLAT-55 (EMT-D22): the desktop's `aGotoNextError` /
    # `aGotoPreviousError` — `F8` / `Shift+F8` in Edit mode, `Ctrl+Alt+N` /
    # `Ctrl+Alt+P`.
    stepProblem(r, res.operation == "problems.next")
    return
  of "search.next-result", "search.previous-result":
    # PLAT-57 (§5.3): `F4` / `Shift+F4`, `Alt+G N` / `Alt+G P`.
    stepSearchResult(r, (if res.operation == "search.next-result": 1 else: -1))
    return
  of "search.toggle-case", "search.toggle-whole-word", "search.toggle-regex":
    # `Alt+C` / `Alt+W` / `Alt+R` in Find in Files' field (the omnibox on
    # `:grep`).
    toggleSearchOption(r, searchOptionOf(res.operation).option)
    drawTopBar(r)
    return
  else: discard
  let action = clientActionOf(op)
  if action.len > 0 and gpuiMenuAvailability(action).enabled:
    runGpuiMenuAction(r, action)
    return
  traceGesture("`" & op & "` (" & operationLabelOf(res.operation) &
               ") is not available in this window")

proc probeWindowResolution(key: string; mods: seq[string]): EditingResolution =
  ## What the keystroke WOULD resolve to here, with no effect — the router
  ## copied, nothing run.
  let name = canonicalKeyOfGpui(key, mods)
  if editorFocused():
    discard debugDocumentFor(editorPath(), gEditorSurface.executionLine)
  syncOverlayLayers()
  var probe = gRouter
  probe.route(windowSessionFacts(), windowScopePath(), nmNormal, name, 0)

proc probeWindowKey(key: string; mods: seq[string]): string =
  ## `probeWindowResolution` spelled (`--window-ops`' `probe:`, and the
  ## cross-front-end differential's reading of this window).
  let res = probeWindowResolution(key, mods)
  canonicalKeyOfGpui(key, mods) & " at " & $windowScopePath() & " -> " &
    describeResolution(res)

proc routeWindowKey(r: GpuiRenderer; key: string; mods: seq[string]) =
  ## One GPUI keystroke through the shared router: decoded to its canonical
  ## name (`canonicalKeyOfGpui`, GPUI's one decoder), resolved for THIS
  ## window's scope path and facts, and run (§6.1 step 5).
  let name = canonicalKeyOfGpui(key, mods)
  if name.len == 0:
    return
  let nowMs = int64(epochTime() * 1000)
  # The user's file changed since it loaded: the key resolves under the new
  # rows (the window's loop has no frame hook of its own to poll from).
  pollKeybindings()
  if editorFocused():
    discard debugDocumentFor(editorPath(), gEditorSurface.executionLine)
  syncOverlayLayers()
  let path = windowScopePath()
  traceGesture("key " & name & " at " & $path)
  let res = gRouter.route(windowSessionFacts(), path, nmNormal, name, nowMs)
  case res.kind
  of erPending:
    traceGesture("pending " & gRouter.pendingLabel)
  of erNothing:
    if res.reason in {nrPrefixAbandoned, nrPrefixTimedOut}:
      traceGesture("pending cleared")
    elif res.reason == nrDisabled:
      # Mode-Transitions §8.1: inert in this product mode — the window has no
      # status line to say it on, so the trace carries it.
      traceGesture("inert " & gRouter.inertNote(res, windowSessionFacts(),
                                                path, nmNormal))
  of erCharacter:
    if gOmnibar.isOpen:
      gOmnibar.typeText(res.character)
      drawTopBar(r)
    elif editorFocused():
      runDebugEditorOperation(r, res, nowMs)
  of erOperation:
    runWindowOperation(r, res, nowMs)

proc refreshStateOrigins() =
  ## PLAT-51: the value-origin chains open in the Variables pane, read at
  ## THIS stop (an origin is the current value's), one line per hop.
  if gSession.isNil or gSession.session.stateVM.isNil:
    return
  let vm = gSession.session.stateVM
  var lines = initTable[string, seq[string]]()
  for path in vm.originLines.val.keys:
    try:
      lines[path] = gSession.loadValueOrigin(path).originHopLines
    except CatchableError:
      lines[path] = @[]
  vm.originLines.val = lines

proc historyPathAt(ticks: uint64): string =
  ## The variable whose open history holds an entry at `ticks`.
  if gSession.isNil or gSession.session.stateVM.isNil:
    return ""
  let vm = gSession.session.stateVM
  for path in vm.expandedHistories.val:
    for e in vm.valueHistory.val.getOrDefault(path):
      if uint64(max(0'i64, e.locationTicks)) == ticks:
        return path
  ""

proc onPaneClick(c: GPaneClick) =
  ## PLAT-50: a press on a row of a pane (`window_clicks`), as the desktop's
  ## click there. An open popover (a menu, the omnibar's results, a
  ## right-click menu, a text over the window) owns the press instead.
  var r: GpuiRenderer
  if gCtxMenu.open or gContent.open or
     (not gMenu.isNil and gMenu.isOpen) or
     (not gOmnibar.isNil and gOmnibar.isOpen):
    return
  # K19: an Edit window has no session, and its Files tree is its own.
  if gSession.isNil and c.part != gcpFileNode:
    return
  # PLAT-70 Part B: a press on a `…` or a column separator is the table's
  # gesture; GPUI hands the row under it the press first, and the row must
  # not jump the debugger or reorder the log for it.
  if c.button == gbLeft and tableGestureAt(c.x, c.y):
    traceGesture("pane click " & $c.part & " left to the table gesture")
    return
  traceGesture("pane click " & $c.part & " " & c.key & " #" & $c.index &
               " line " & $c.line & " " & $c.button &
               (if c.ctrl: "+ctrl" else: "") & (if c.alt: "+alt" else: ""))
  if c.part == gcpFileNode:
    # K17 / K18, and K19: a right-click opens the Files pane's menu, the
    # entries and reasons the shared Files model decides — on the replay's
    # tree, or on Edit mode's opened folder.
    leaveFilesField(r)
    let vm = windowFilesVM()
    let e = fileEntryOf(vm, c.key)
    if e.text.len == 0:
      return
    if c.button == gbRight:
      openContextMenuAt(r, vm.fileTreeContextMenuOf(e.path), c.x, c.y)
      return
    if c.button != gbLeft:
      return
    if e.isFolder:
      vm.toggleExpanded(e.path)
      redrawPaneOf(r, paneFileTree)
    elif not openArm.isNil:
      discard openEditFile(e.path)
    else:
      openTreeFile(r, e.path)
    return
  let session = gSession.session
  case c.part
  of gcpNone, gcpFileNode: discard
  of gcpEventRow:
    # K24 / K25.
    let rows = session.eventLogVM.eventRows.val
    if c.index < 0 or c.index >= rows.len.int64:
      return
    let row = rows[c.index.int]
    if c.button == gbRight:
      showContent(r, "event #" & $row.eventIndex & " at tick " &
                       $row.rrTicks, row.value)
    elif c.button == gbLeft:
      try:
        gSession.eventJump(toEventLogEntry(row))
      except CatchableError as e:
        traceGesture("event jump failed: " & e.msg)
        return
      afterMove(r)
  of gcpEventHeader:
    # K26: the column's header orders the log by it, again to reverse.
    if c.button != gbLeft or session.eventLogVM.isNil:
      return
    let shown = session.eventLogVM.columns.val.visibleColumns
    if c.index < 0 or c.index >= shown.len:
      return
    orderEventLog(r, session.eventLogVM.order.clickedHeader(shown[c.index]))
  of gcpVariable:
    # K27 / K28.
    if c.button == gbRight:
      openContextMenuAt(r, variablesContextMenu(c.key), c.x, c.y)
    elif c.button == gbLeft:
      # PLAT-70 Part B: the pressed variable is the pane's row — the one
      # `list.show-detail` and `list.copy` act on.
      session.stateVM.selectPath(c.key)
      session.stateVM.toggleExpand(c.key)
      redrawPaneOf(r, paneState)
  of gcpGutter:
    # K10 / K11.
    let path = editorPath()
    if c.button == gbLeft:
      discard gSession.toggleBreakpoint(path, c.line)
      if gViewedFile.len > 0: showViewedFile(r) else: refreshReplayWindow(r)
    elif c.button == gbRight:
      let mark = lineMarkOf(path, c.line)
      if mark in {emBreakpoint, emBreakpointDisabled}:
        discard gSession.setBreakpointEnabled(path, c.line,
                                              mark == emBreakpointDisabled)
        if gViewedFile.len > 0: showViewedFile(r)
        else: refreshReplayWindow(r)
  of gcpCode:
    # K12-K15.
    let path = editorPath()
    let column = editorColumnAt(c.x)
    if (c.button == gbLeft and not c.ctrl and not c.alt) or c.button == gbRight:
      # K47 (PLAT-51): a press on the text PLACES THE CARET there, as
      # Monaco's does in a read-only model (a right press too, before its
      # menu opens) — and the editor has the focus.
      if gFocusPane != $paneEditor:
        focusWindowPane(r, $paneEditor)
      placeCaret(r, path, c.line, column)
      # PLAT-68: a held left press SELECTS as the pointer moves.
      gTextDrag = c.button == gbLeft
    if c.button == gbRight:
      openContextMenuAt(r, editorMenuAt(path, c.line, column), c.x, c.y)
    elif c.button == gbLeft and c.ctrl and c.alt:
      # K15: Ctrl+Alt+click on a function's name.
      let (token, err) = callTokenAt(lineTextOf(path, c.line), column,
                                     rust = path.endsWith(".rs"))
      if token.len == 0:
        traceGesture(if err.len > 0: err & " on line " & $c.line & "."
                     else: NoWordSelected)
        return
      try:
        gSession.sourceCallJump(path, c.line, token, "smart")
      except CatchableError as e:
        traceGesture("call jump failed: " & e.msg)
        refreshReplayWindow(r)
        return
      afterMove(r)
    elif c.button == gbLeft and c.alt:
      # K14: Alt+click — a breakpoint anchored at the column, clamped to the
      # line (`column_click_resolver`).
      let width = max(1, lineTextOf(path, c.line).runeLen)
      let col = max(1, min(column, width))
      if gSession.setColumnBreakpoint(path, c.line, col):
        traceGesture("column breakpoint " & $c.line & ":" & $col)
      if gViewedFile.len > 0: showViewedFile(r) else: refreshReplayWindow(r)
    elif c.button == gbMiddle or (c.button == gbLeft and c.ctrl):
      try:
        gSession.sourceLineJump(path, c.line, "smart")
      except CatchableError as e:
        traceGesture("line jump failed: " & e.msg)
        return
      afterMove(r)
  of gcpValue:
    # K36: an inline value — Ctrl+click pins it, a right click opens its
    # menu; a click is the value at this step (the window annotates only the
    # line the debugger is on).
    let row = editorRowOf(c.line)
    let i = valueAtColumn(row, editorColumnAt(c.x))
    if i < 0:
      return
    let v = row.values[i]
    if c.button == gbRight:
      openContextMenuAt(r, flowValueContextMenu(editorPath(), c.line, v.name,
                                                v.value, lineValuesOf(row)),
                        c.x, c.y)
    elif c.button == gbLeft and c.ctrl:
      gSession.addToScratchpad(v.name, v.value)
      traceGesture("scratchpad " &
                   $session.scratchpadVM.entries.val.len & " value(s)")
      redrawPaneOf(r, paneScratchpad)
    elif c.button == gbLeft:
      traceGesture(v.name & " = " & v.value & " is the value at this step")
  of gcpCallRow:
    # K22 (K20 / K21 are `clickCalltrace`'s, by the rows' fixed pitch).
    if c.button != gbRight:
      return
    let store = session.store
    let local = c.index - store.calltrace.startLineIndex.val
    let lines = store.calltrace.lines.val
    if local < 0 or local >= lines.len.int64:
      return
    let line = lines[local.int]
    openContextMenuAt(r, callTraceContextMenu(c.index, line.hasChildren,
                                              line.isExpanded), c.x, c.y)
  of gcpCallArg:
    # K23: an argument's menu (a left press is the row's, `clickCalltrace`).
    if c.button != gbRight:
      return
    for row in session.calltraceVM.callRows():
      if row.index == c.index and c.line >= 0 and c.line < row.args.len:
        let a = row.args[c.line]
        openContextMenuAt(r, callArgumentContextMenu(c.index, a.name, a.value),
                          c.x, c.y)
  of gcpTab:
    if c.button != gbRight:
      return
    for k in PaneKind:
      if $k == c.key:
        openContextMenuAt(r, tabContextMenu(k, gMaximised.isSome), c.x, c.y)
  of gcpStateControl:
    # PLAT-51: a Variables row's value controls — the history button (K40),
    # the origin badge (K41), a watch's remove control.
    if c.button != gbLeft:
      return
    let sep = c.key.find(':')
    if sep < 0:
      return
    let kind = c.key[0 ..< sep]
    let arg = c.key[sep + 1 .. ^1]
    case kind
    of "history": showValueHistory(r, arg)
    of "origin": showValueOrigin(r, arg)
    of "unwatch": discard runWatchCommand(r, ":unwatch " & arg)
    of "hide-other-process-watches":
      # Variable-State-Pane.md § Decisions, 2026-10-24.
      if not gSession.isNil and not gSession.session.stateVM.isNil:
        gSession.session.stateVM.setHideOtherProcessWatches(arg == "on")
        redrawPaneOf(r, paneState)
    else: discard
  of gcpHistoryEntry:
    # PLAT-51: a value-history row is a NAVIGATION ROW — a click goes to the
    # moment its value was recorded; its menu is the desktop's history-row
    # menu.
    var ticks = 0'u64
    try: ticks = parseBiggestUInt(c.key)
    except ValueError: return
    if c.button == gbRight:
      openContextMenuAt(r, valueHistoryEntryContextMenu(
        historyPathAt(ticks), "", ticks), c.x, c.y)
      return
    if c.button != gbLeft:
      return
    try:
      gSession.gotoTick(ticks)
    except CatchableError as e:
      traceGesture("history jump failed: " & e.msg)
      return
    traceGesture("history entry at tick " & $ticks)
    afterMove(r)
  of gcpAddWatch:
    # PLAT-51: the watch field — the omnibar opens with `:watch `.
    if c.button == gbLeft:
      openOmnibar(r, WatchCommand)
  of gcpCallSearch:
    # The call trace's search field — the omnibar opens with `:calls `, its
    # query the field's (`CalltraceVM.setSearchQuery`).
    if c.button == gbLeft:
      let vm = if gSession.isNil: nil else: gSession.session.calltraceVM
      openOmnibar(r, CallsCommand &
                     (if vm.isNil: "" else: vm.searchQuery.val))
  of gcpPoint:
    # K31: the desktop's click selects the point.
    if c.button != gbLeft or session.pointListVM.isNil:
      return
    session.pointListVM.selectPoint(some(int(c.index)))
    traceGesture("point selected #" & $c.index)
    redrawPaneOf(r, panePointList)
  of gcpScratchClose:
    # K33: a pinned value's close button.
    if c.button != gbLeft or session.scratchpadVM.isNil:
      return
    session.scratchpadVM.removeValue(int(c.index))
    traceGesture("scratchpad " &
                 $session.scratchpadVM.entries.val.len & " value(s)")
    redrawPaneOf(r, paneScratchpad)
  of gcpPosition:
    # K37: the footer's location — the current file's path copied, as the
    # desktop's copy control copies it (measured: the path, no line).
    if c.button == gbLeft:
      copyToClipboard(gSession.getCurrentFile(), "the path")
  of gcpVcsFile:
    if c.button == gbLeft:
      openVcsDiff(r, c.key)
  of gcpVcsCommit:
    if c.button == gbLeft and c.key.startsWith("commit-"):
      try: toggleVcsCommit(r, parseInt(c.key["commit-".len .. ^1]))
      except ValueError: discard

proc wireClicks(r: GpuiRenderer) =
  ## Give every row the window draws its click listeners (`window_clicks`).
  # The whole window: the panes (`gContainer`) and the footer, whose
  # location is a click target too (K37).
  if not gRoot.isNil:
    discard wireWindowClicks(r, gRoot, addr gPressDedupe, onPaneClick)
  elif not gContainer.isNil:
    discard wireWindowClicks(r, gContainer, addr gPressDedupe, onPaneClick)

proc handlePopoverPress(r: GpuiRenderer; kind: GpuiEventKind;
                        x, y: int): bool =
  ## PLAT-50: an open right-click menu or event content owns a press: on an
  ## enabled entry (left button) it runs it; anywhere else in the menu,
  ## nothing; outside, the menu closes. The content closes on any press.
  if gCtxMenu.open:
    let rect = contextMenuRect(gCtxMenu, pendingViewportWidth,
                               pendingViewportHeight)
    let (inside, entry) = gCtxMenu.contextMenuHitAt(rect, x, y)
    if inside:
      if kind == gekPointerDown and entry >= 0:
        let chosen = gCtxMenu.choose(entry)
        if chosen.chosen:
          drawTopBar(r)
          runContextAction(r, chosen.action, chosen.target)
        else:
          traceGesture("disabled: " & gCtxMenu.menu.entries[entry].label)
      return true
    gCtxMenu.close()
    drawTopBar(r)
    return true
  if gContent.open:
    gContent = GContent()
    drawTopBar(r)
    return true
  false

# ---------------------------------------------------------------------------
# PLAT-69 — the window as a desktop window: its size and its frame follow
# what the renderer reports
# ---------------------------------------------------------------------------

proc containerHeightPx(): int =
  ## The arrangement's container: the content height less the root's padding
  ## and the top band.
  max(1, pendingViewportHeight - GpuiTopBandPx - FooterPx)

proc refitEditorRows(r: GpuiRenderer) =
  ## The editor holds as many source rows as its pane now shows
  ## (`editorRowsOf`, the reading the window opened with): after a resize a
  ## taller pane is filled, a shorter one asks for no rows it cannot draw.
  let rows = editorRowsOf(gGeom)
  if rows <= 0:
    return
  if not openArm.isNil:
    # An Edit window (or a folder tab's arm): the arm's own surface.
    if rows != editViewportRows:
      editViewportRows = rows
      redrawEditor()
  elif not gSourceService.isNil and not gSourceService.vm.isNil:
    if rows == gSourceService.vm.viewportHeight.val:
      return
    gSourceService.vm.setOverscan(GpuiSourceOverscan)
    gSourceService.vm.setViewport(gSourceService.vm.viewport.withRows(rows))
    gSourceService.visibleRows = editorVisibleRowsOf(gGeom)
    gSourceService.fullRows = editorFullRowsOf(gGeom)
    if gViewedFile.len > 0:
      # A file opened from the Files pane: drawn again at the new height
      # from the line it showed first.
      showViewedFile(r, max(1, gEditorSurface.viewportTop))
    else:
      # M73: a new height follows the pointer as every serve did before the
      # user could scroll (`GpuiSourceService.followOwed`).
      gSourceService.followOwed = true
      gSourceService.serveWindow()
      redrawReplayEditor(r)
    let editor = gPanes.getOrDefault($paneEditor)
    if not editor.isNil:
      applyTextFaces(r, editor)
    wireClicks(r)

proc windowResized(r: GpuiRenderer; width, height: int) =
  ## PLAT-69 (C1): THE CONTENT AREA IS NOW `width` x `height` — the renderer's
  ## report (`gpui_on_resize`, before the frame at that size is built), or
  ## `--window-ops`' `resize:`. Everything is laid out again at the new size
  ## exactly as the window would open at it: the dock viewport the
  ## arrangement is divided over, the arrangement and its strips and footer
  ## (`drawArrangement`), the top bar, the popovers (all drawn from
  ## `pendingViewport*`), and the editor's width and rows.
  ##
  ## NOTHING IS REMEMBERED. The remembered layout is proportional and is
  ## written only by a gesture that changes it (`applyGestureCommand`); a
  ## resize changes no layout, only the pixels it is drawn at.
  if width <= 0 or height <= 0:
    return
  if width == pendingViewportWidth and height == pendingViewportHeight:
    return
  traceGesture("window resized " & $pendingViewportWidth & "x" &
               $pendingViewportHeight & " -> " & $width & "x" & $height)
  pendingViewportWidth = width
  pendingViewportHeight = height
  for shell in [gMainShell, gEditShell, gShell]:
    if not shell.isNil:
      shell.viewport.width = width
      shell.viewport.height = height
  if not gContainer.isNil:
    r.setStyle(gContainer, "height", $containerHeightPx() & "px")
  if windowDrawn() and drawArrangement(r):
    syncEditorViewport(r)
    refitEditorRows(r)
    # The editor's redraw may have moved its tab: the geometry once more.
    writeGeometry()
  else:
    # No arrangement to lay out (a refused projection tiles its leaves):
    # the top bar still spans the window.
    drawTopBar(r)

proc chromeChanged(r: GpuiRenderer; chrome: WindowChrome) =
  ## PLAT-69 (C2, C3): THE WINDOW'S FRAME CHANGED — the compositor granted
  ## client-side decorations (sway does so only once the window is mapped),
  ## the window was maximized or restored, the desktop's button layout was
  ## changed while it is open. The top bar is drawn again: its drag strip,
  ## its window buttons where the desktop now wants them, the maximize
  ## button's restore icon. (A frame that changes the content size is
  ## reported as a resize as well.)
  if chrome == gChrome:
    return
  traceGesture("window chrome csd=" & $chrome.clientDecorated &
               " maximized=" & $chrome.maximized & " layout='" &
               chrome.buttonLayout & "' left=" & $chrome.shownButtons.left &
               " right=" & $chrome.shownButtons.right)
  gChrome = chrome
  if gHoverWindowButton >= 0:
    gHoverWindowButton = -1
  drawTopBar(r)

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
  # The desktop's frame: the caption bar from the window's top edge, the
  # layout `WindowEdgePx` in from either side, the status bar below it.
  r.setStyle(root, "padding-left", $WindowEdgePx & "px")
  r.setStyle(root, "padding-right", $WindowEdgePx & "px")
  let topSpacer = r.createElement("div")
  r.setAttribute(topSpacer, "data-ct-top-bar", "spacer")
  r.setStyle(topSpacer, "width", "100%")
  r.setStyle(topSpacer, "height", $TopBarPx & "px")
  r.setStyle(topSpacer, "flex-shrink", "0")
  r.appendChild(root, topSpacer)

  let container = pendingOutcome.root
  r.setStyle(container, "width", "100%")
  r.setStyle(container, "height", $containerHeightPx() & "px")
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
  # PLAT-50: named, so `--window-ops`' bubbling stops below it (a handle is a
  # fresh pointer per lookup, so it cannot be compared with `gRoot`).
  r.setAttribute(root, WindowRootAttribute, "true")
  # PLAT-68: the scope elements of the focus chain (Base-Keymaps §5.2) —
  # the window, the session tab's container, each pane.
  r.setAttribute(root, ScopeKindAttribute, $ekWindow)
  r.setAttribute(root, ScopeIdAttribute, "window")
  r.setAttribute(container, ScopeKindAttribute, $ekTab)
  r.setAttribute(container, ScopeIdAttribute, "tab:1")
  gContainer = container
  gPanes = initTable[string, GpuiElement]()
  for pane in leaves:
    let id = getAttribute(pane, "data-ct-pane")
    if id.len > 0 and id notin gPanes:
      gPanes[id] = pane
      markPaneScope(r, pane, id)
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
  # PLAT-69 — THE WINDOW'S SIZE AND FRAME, as the renderer reports them from
  # now on. Subscribed from here, the root builder, which is when the
  # launched window exists to subscribe to; the plan and the capture paths
  # have none, and draw the frame `--window-chrome` names (the server-side
  # one by default — no buttons, no drag strip — which is what they drew
  # before).
  let subscribed = subscribeWindow(
    proc(w, h: int) =
      var rr: GpuiRenderer
      windowResized(rr, w, h),
    proc() =
      var rr: GpuiRenderer
      chromeChanged(rr, liveWindowChrome()),
    # The VCS pane's focus-gain refresh (`vcsWindowActivated`).
    vcsWindowActivated)
  gChrome =
    if subscribed: liveWindowChrome()
    elif gChromeSpec.len > 0:
      windowChromeOfSpec(gChromeSpec).chrome
    else: liveWindowChrome()

  r.appendChild(root, container)
  # `PLAT35-F3`. **AFTER the arrangement and BEFORE the faces**: the editor
  # pane's width is only known once `drawArrangement` has run, and a pane
  # this redraws produces new elements that `applyTextFaces` below still has
  # to reach — an editor re-drawn after the walk would keep the window's
  # inherited proportional face, which is the defect that walk exists
  # against.
  syncEditorViewport(r)
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
    of "resize":
      # PLAT-69: what the renderer reports when the content area resizes.
      windowResized(r, at(1), at(2))
      return ""
    of "chrome":
      # PLAT-69: what the renderer reports when the frame changes. The
      # spec's layout commas are spelled `;` here, since `,` separates
      # the events.
      let spec = op["chrome:".len .. ^1].replace(';', ',')
      let chrome = windowChromeOfSpec(spec)
      if not chrome.ok:
        return chrome.message
      chromeChanged(r, chrome.chrome)
      return ""
    of "key":
      let mods = if parts.len > 2: parts[2].split('+') else: @[]
      # `colon` names `:`, which the op's own `:` separator cannot spell
      # (PLAT-49 part B: the omnibar's command mode).
      let key = if parts[1] == "colon": ":" else: parts[1]
      # An edit window's keys reach its editor (which holds the focus); a
      # replay window's, its top bar and gestures.
      if openArm.isNil: windowKey(key, mods)
      else: editKey(key, mods)
    of "type":
      # PLAT-51: `type:<text>` — each character as its own key, as a user
      # types it (a new tab's Welcome Screen form: a folder, a program).
      for ch in op["type:".len .. ^1]:
        if openArm.isNil: windowKey($ch, @[])
        else: editKey($ch, @[])
    of "term":
      # PLAT-52: the Terminal Output pane, aimed from the geometry it was
      # drawn with (`terminal_output_leaf.terminalLayout`):
      #   term:view:<lines|screen>          press a toggle button
      #   term:line:<line>[:<column>]       press a line (scrolled into view)
      #   term:track:<permille>             press the line scrubber's track
      #   term:drag:<from>:<to>             hold its thumb, move, release
      #   term:scrub:<from>:<to>[:hold]     the screen scrubber, dragged
      #   term:key:<key>                    a key while the pane has focus
      #   term:wheel:<rows>                 the wheel over the pane
      #   term:blank                        press the line view below its
      #                                     last line (focuses the pane,
      #                                     moves nothing)
      let vm = terminalVM()
      let body = terminalBody()
      if vm.isNil or body.w <= 0:
        return "the terminal output pane is not drawn"
      let lay = terminalLayout(body, vm, gTerminal)
      proc trackY(permille: int): int =
        lay.track.y + min(lay.track.h - 1, lay.track.h * permille div 1000)
      proc scrubX(permille: int): int =
        lay.screenTrack.x + min(lay.screenTrack.w - 1,
                                lay.screenTrack.w * permille div 1000)
      case parts[1]
      of "blank":
        let shown = vm.lineCount - vm.visibleTop(gTerminal, lay.rows)
        if shown >= lay.rows:
          return "the line view has no blank row"
        pressAt(lay.content.x + 20,
                lay.content.y + shown * TerminalRowPx + TerminalRowPx div 2)
      of "view":
        let b = if parts[2] == "screen": lay.screenButton else: lay.linesButton
        if b.w <= 0:
          return "the screen view is not offered"
        let (x, y) = centreOf(b)
        pressAt(x, y)
      of "line":
        let line = at(2)
        let column = if parts.len > 3: at(3) else: 0
        if line < vm.visibleTop(gTerminal, lay.rows) or
           line >= vm.visibleTop(gTerminal, lay.rows) + lay.rows:
          gTerminal.follow = false
          gTerminal.scrollTop = line
          drawTerminalPane(r)
        let top = vm.visibleTop(gTerminal, lay.rows)
        let y = lay.content.y + (line - top) * TerminalRowPx +
                TerminalRowPx div 2
        let x = lay.content.x + int((float(column) + 0.5) * EditorColumnPx)
        pressAt(x, y)
      of "track":
        if lay.track.h <= 0:
          return "the line view has no scrubber"
        pressAt(lay.track.x + TerminalTrackPx div 2, trackY(at(2)))
      of "drag":
        let x = lay.track.x + TerminalTrackPx div 2
        let sm = vm.scrubberFor(gTerminal, lay.rows)
        let span = sm.thumbSpan(lay.track.h, TerminalMinThumbPx)
        # Hold the THUMB (wherever it is), then move to each step.
        windowPointer(r, gekPointerDown, x, lay.track.y + span.start +
                                            span.length div 2)
        let a = at(2)
        let b = at(3)
        for k in 0 .. 10:
          windowPointer(r, gekPointerMove, x, trackY(a + (b - a) * k div 10))
        windowPointer(r, gekPointerUp, x, trackY(b))
      of "scrub":
        if lay.screenTrack.w <= 0:
          return "the screen view is not shown"
        let y = lay.screenTrack.y + ScreenTrackPx div 2
        let a = at(2)
        let b = at(3)
        windowPointer(r, gekPointerDown, scrubX(a), y)
        for k in 1 .. 8:
          windowPointer(r, gekPointerMove, scrubX(a + (b - a) * k div 8), y)
        if not (parts.len > 4 and parts[4] == "hold"):
          windowPointer(r, gekPointerUp, scrubX(b), y)
      of "key":
        gTerminal.focused = true
        if not terminalKey(r, parts[2]):
          return "the terminal output pane does not take '" & parts[2] & "'"
      of "wheel":
        let (cx, cy) = centreOf(body)
        windowPointer(r, gekWheel, cx, cy, -float(at(2) * TerminalRowPx))
      else:
        return "unknown terminal event '" & parts[1] & "'"
    of "problems":
      # PLAT-55: Problems, aimed from the geometry it was drawn with
      # (`problems_leaf.problemsLayout`):
      #   problems:show                 bring it up (revealed from the footer)
      #   problems:build:<command>      `:build <command>`
      #   problems:wait[:<ms>]          let the build in flight settle
      #   problems:row:<index>          press diagnostic <index>'s row
      #   problems:filter:<name>        press All / Errors / Warnings
      #   problems:group                press Group by File
      #   problems:next / :previous     `problems.next` / `.previous`
      #   problems:key:<operation>      a list operation, the pane focused
      #   problems:wheel:<rows>         the wheel over the pane
      case parts[1]
      of "show":
        showPaneFromMenu(r, paneProblems)
      of "build":
        traceGesture(startGpuiBuild(r, parts[2 .. ^1].join(":")))
      of "wait":
        let budget = if parts.len > 2: at(2) else: 300_000
        let deadline = epochTime() + float(budget) / 1000.0
        while not gBuild.isNil and gBuild.session.verdict == bvRunning and
              epochTime() < deadline:
          sleep(20)
          discard pollGpuiBuild(r)
        discard pollGpuiBuild(r)
        if not gBuild.isNil and gBuild.session.verdict == bvRunning:
          return "the build did not settle within " & $budget & " ms"
      of "next", "previous":
        stepProblem(r, parts[1] == "next")
      of "key":
        gFocusPane = $paneProblems
        if not problemsKey(r, parts[2]):
          return "the Problems pane does not take '" & parts[2] & "'"
      else:
        let body = problemsBody()
        if gProblems.isNil or body.w <= 0:
          return "the Problems pane is not drawn"
        let lay = problemsLayout(gProblems.vm, body)
        case parts[1]
        of "row":
          let index = at(2)
          gProblemsPane.revealIndex(gProblems.vm, body, index)
          drawProblemsPane(r)
          let c = problemsLayout(gProblems.vm, body).rowCentre(gProblemsPane,
                                                              index)
          if not c.ok:
            return "problem " & $index & " is not listed"
          pressAt(c.x, c.y)
        of "filter", "group":
          let i = if parts[1] == "group": lay.buttons.high
                  else: (case parts[2]
                         of "all": 0
                         of "errors": 1
                         of "warnings": 2
                         else: -1)
          if i < 0 or i >= lay.buttons.len:
            return "no Problems button '" & parts[^1] & "'"
          let (x, y) = centreOf(lay.buttons[i])
          pressAt(x, y)
        of "wheel":
          let (cx, cy) = centreOf(body)
          windowPointer(r, gekWheel, cx, cy, -float(at(2) * ProblemsRowPx))
        else:
          return "unknown problems event '" & parts[1] & "'"
    of "tests":
      # PLAT-53: Test Results, aimed from the geometry it was drawn with
      # (`test_results_leaf.testsLayout`):
      #   tests:show                  activate its tab
      #   tests:run                   press the ▶
      #   tests:wait[:<ms>]           let the run in flight settle (polled
      #                               as the window's tick polls it)
      #   tests:row:<name>            press a test's row (selects it)
      #   tests:refresh:<name>        press its `⟳`
      #   tests:open:<name>[:shift]   press its `⏵` (Shift held)
      #   tests:key:<operation>       a list operation, the pane focused
      #   tests:kill                  SIGKILL the run in flight's group
      #   tests:wheel:<rows>          the wheel over the pane
      case parts[1]
      of "show":
        applyGestureCommand(r, cmdActivateTab(paneTestResults))
        discard drawArrangement(r)
      of "wait":
        let budget = if parts.len > 2: at(2) else: 300_000
        let deadline = epochTime() + float(budget) / 1000.0
        while gTestsHost.running and epochTime() < deadline:
          sleep(50)
          discard pollTestsHost(r)
        discard pollTestsHost(r)
        if gTestsHost.running:
          return "the test run did not settle within " & $budget & " ms"
      of "kill":
        if not gTestsHost.running:
          return "no test run is in flight"
        killTestsRun()
      of "key":
        gFocusPane = $paneTestResults
        if not testsKey(r, parts[2]):
          return "the Test Results pane does not take '" & parts[2] & "'"
      else:
        let body = testsBody()
        if gTestsVM.isNil or body.w <= 0:
          return "the Test Results pane is not drawn"
        case parts[1]
        of "run":
          let (x, y) = centreOf(testsLayout(gTestsVM, body).run)
          pressAt(x, y)
        of "row", "refresh", "open":
          let i = testsRowNamed(parts[2])
          if i < 0:
            return "no test " & parts[2]
          gTests.revealRow(gTestsVM, body, i)
          drawTestsPane(r)
          let lay = testsLayout(gTestsVM, body)
          let top = gTests.visibleTop(lay.lines.len, lay.rows)
          let y = lay.list.y + (lay.lineOfRow(i) - top) * TestsRowPx +
                  TestsRowPx div 2
          let a = lay.list.x + lay.fit.starts[4]
          let x = case parts[1]
                  of "row": lay.list.x + TestsActionPx
                  of "refresh": a + TestsActionPx div 2
                  else: a + TestsActionPx + TestsActionPx div 2
          gPointerShift = parts.len > 3 and parts[3] == "shift"
          pressAt(x, y)
          gPointerShift = false
        of "wheel":
          let (cx, cy) = centreOf(body)
          windowPointer(r, gekWheel, cx, cy, -float(at(2) * TestsRowPx))
        else:
          return "unknown tests event '" & parts[1] & "'"
    of "agent":
      # PLAT-54: Agent Activity, aimed from the geometry it was drawn with
      # (`agent_activity_leaf.agentLayout`):
      #   agent:button:<label>[:<nth>]     press the nth button so captioned
      #                                    (scrolled into view)
      #   agent:row:<kind>[:<nth>]         press the nth row of that kind
      #   agent:prompt                     press the prompt
      #   agent:wheel:<lines>              the wheel over the pane
      #   agent:show / agent:vcs           show Agent Activity / the VCS pane
      if parts[1] == "show":
        showPaneFromMenu(r, paneAgentActivity)
        return ""
      if parts[1] == "vcs":
        showPaneFromMenu(r, paneVcs)
        return ""
      let h = agentHost()
      let body = agentBody()
      if h.isNil or body.w <= 0:
        return "the Agent Activity pane is not drawn"
      let rows = h.feedRows()
      let nth = if parts.len > 3: at(3) else: 0
      var target = -1
      var label = ""
      var lay = agentLayout(body, rows, gAgent.scroll)
      let marked = markedRows(rows)
      case parts[1]
      of "button":
        label = "[" & parts[2] & "]"
        var n = 0
        for i, l in lay.lines:
          for sp in l.spans:
            if sp.button > 0 and sp.text == label:
              if n == nth and target < 0: target = i
              inc n
      of "row":
        var n = 0
        for i, l in lay.lines:
          if l.part == 0 and $marked[l.row].kind == parts[2]:
            if n == nth and target < 0: target = i
            inc n
      of "prompt":
        let (x, y) = centreOf(lay.prompt)
        pressAt(x, y)
        return ""
      of "wheel":
        let (cx, cy) = centreOf(lay.list)
        windowPointer(r, gekWheel, cx, cy, -float(at(2) * AgentRowPx))
        return ""
      else:
        return "unknown agent event '" & op & "'"
      if target < 0:
        return "no agent " & parts[1] & " '" & parts[2] & "' #" & $nth
      gAgent.scrollTo(rows, body, target)
      drawAgentPane(r)
      lay = agentLayout(body, rows, gAgent.scroll)
      let y = lay.list.y + (target - lay.top) * AgentRowPx + AgentRowPx div 2
      var x = lay.list.x + 4
      if label.len > 0:
        var at = lay.list.x
        for sp in lay.lines[target].spans:
          let w = pxMeasure(sp.text)
          if sp.text == label:
            x = at + w div 2
            break
          at += w
      pressAt(x, y)
      return ""
    of "search":
      # PLAT-57: Find in Files, aimed from the geometry it was drawn with
      # (`search_results_leaf.searchLayout`):
      #   search:row:<index>               press a result (scrolled into view)
      #   search:option:<case|word|regex>  press a toggle
      #   search:field                     press the field
      #   search:wheel:<rows>              the wheel over the pane
      #   search:track:<permille>          press the scrubber's track
      let vm = searchVM()
      let body = searchBody()
      if vm.isNil or body.w <= 0:
        return "the Find in Files pane is not drawn"
      let rows = vm.displayRows()
      let lay = searchLayout(body, rows.len)
      case parts[1]
      of "row":
        let at = rows.displayRowOf(at(2))
        if at < 0:
          return "no result " & parts[2]
        gSearch.revealResult(vm, body, at(2))
        drawSearchPane(r)
        let top = gSearch.visibleTop(rows.len, lay.rows)
        pressAt(lay.list.x + 40,
                lay.list.y + (at - top) * SearchRowPx + SearchRowPx div 2)
      of "option":
        var which = soCase
        try: which = parseEnum[SearchOption](parts[2])
        except ValueError: return "unknown search option '" & parts[2] & "'"
        let (x, y) = centreOf(lay.optionBoxes[which])
        pressAt(x, y)
      of "field":
        let (x, y) = centreOf(lay.field)
        pressAt(x, y)
      of "wheel":
        let (cx, cy) = centreOf(body)
        windowPointer(r, gekWheel, cx, cy, -float(at(2) * SearchRowPx))
      of "track":
        if not lay.overflow:
          return "the list does not overflow"
        let track = listTrackRect(PxRect(x: body.x,
          y: lay.list.y - ChromePaddingPx, w: body.w,
          h: lay.list.h + 2 * ChromePaddingPx))
        pressAt(track.x + ListTrackPx div 2,
                track.y + min(track.h - 1, track.h * at(2) div 1000))
      else:
        return "unknown search event '" & parts[1] & "'"
    of "scrub":
      # PLAT-51: a list pane's scrollbar scrubber, aimed from the geometry
      # the window drew it at (`list_scrubber.listTrackRect`):
      #   scrub:<eventLog|calltrace>:track:<permille>   press the track
      #   scrub:<eventLog|calltrace>:drag:<from>:<to>   hold the thumb, move
      #                                                 in ten steps, release
      #   M71 (#838): also `fileTree`, `vcs` (while their rows overflow)
      #   and `state` (its vertical bar, while its rows overflow).
      var kind = paneEventLog
      var found = false
      for k in [paneEventLog, paneCalltrace, paneFileTree, paneVcs,
                paneState]:
        if $k == parts[1]:
          kind = k
          found = true
      if not found:
        return "no list scrubber on '" & parts[1] & "'"
      let body = visibleBodyOf(kind)
      if body.w <= 0:
        return "the " & parts[1] & " pane is not drawn"
      var sm: ScrubberModel
      var track: PxRect
      var thumbStart, thumbLen = 0
      case kind
      of paneState:
        track = stateBarTrack()
        (thumbStart, thumbLen) = stateVerticalThumb()
      else:
        sm = case kind
             of paneEventLog: eventLogScrubber()
             of paneCalltrace: callTraceScrubber()
             else: inHandScrubber(kind)
        if kind in {paneFileTree, paneVcs} and sm.total <= sm.visible:
          return "the " & parts[1] & " pane's rows fit: no scrollbar is drawn"
        track = listTrackRect(body, $kind)
        let span = sm.thumbSpan(track.h, ListMinThumbPx)
        (thumbStart, thumbLen) = (span.start, span.length)
      if track.h <= 0:
        return "the " & parts[1] & " pane's rows fit: no scrollbar is drawn"
      let x = track.x + track.w div 2
      proc ty(permille: int): int =
        track.y + min(track.h - 1, track.h * permille div 1000)
      case parts[2]
      of "track":
        pressAt(x, ty(at(3)))
      of "drag":
        windowPointer(r, gekPointerDown, x,
                      track.y + thumbStart + thumbLen div 2)
        let a = at(3)
        let b = at(4)
        for k in 0 .. 10:
          windowPointer(r, gekPointerMove, x, ty(a + (b - a) * k div 10))
        windowPointer(r, gekPointerUp, x, ty(b))
      else:
        return "unknown scrub event '" & parts[2] & "'"
    of "press": windowPointer(r, gekPointerDown, at(1), at(2))
    of "move": windowPointer(r, gekPointerMove, at(1), at(2))
    of "release": windowPointer(r, gekPointerUp, at(1), at(2))
    of "vbar":
      # M73 (#840): the editor's vertical scrubber, aimed from the geometry
      # the window drew it at (`editorVBarRect`):
      #   vbar:editor:track:<permille>       press the track
      #   vbar:editor:drag:<from>:<to>       hold the thumb, move it from
      #                                      `from` to `to` permille of the
      #                                      track in ten steps, release
      #   vbar:editor:grab:<at>:<by>         PLAT-70 Part H: hold the thumb
      #                                      `at` px below its top, move the
      #                                      pointer `by` px, release
      if parts.len < 3 or parts[1] != $paneEditor:
        return "no vertical scrubber on '" & (if parts.len > 1: parts[1]
                                               else: "") & "'"
      let (bar, v) = editorVBarRect()
      if bar.h <= 0:
        return "the editor's file fits: no vertical scrubber is drawn"
      let x = bar.x + bar.w div 2
      proc vy(permille: int): int =
        bar.y + min(bar.h - 1, bar.h * clamp(permille, 0, 1000) div 1000)
      case parts[2]
      of "track": windowPointer(r, gekPointerDown, x, vy(at(3)))
      of "drag":
        windowPointer(r, gekPointerDown, x, bar.y + v.thumbTopPx + v.thumbPx div 2)
        let a = at(3)
        let b = at(4)
        for k in 0 .. 10:
          windowPointer(r, gekPointerMove, x, vy(a + (b - a) * k div 10))
        windowPointer(r, gekPointerUp, x, vy(b))
      of "grab":
        let y0 = bar.y + v.thumbTopPx + at(3)
        windowPointer(r, gekPointerDown, x, y0)
        windowPointer(r, gekPointerMove, x, y0 + at(4) div 2)
        windowPointer(r, gekPointerMove, x, y0 + at(4))
        windowPointer(r, gekPointerUp, x, y0 + at(4))
      else:
        return "unknown vbar event '" & parts[2] & "'"
    of "hbar":
      # PLAT-70: a text pane's horizontal bar, aimed from the geometry the
      # window drew it at (`editorBarRect`, `terminalLayout`'s `hbar` and
      # `corner`):
      #   hbar:<editor|terminalOutput>:track:<permille>   press the track
      #   hbar:<editor|terminalOutput>:drag:<from>:<to>   hold the thumb,
      #                                                   move in ten steps,
      #                                                   release
      #   hbar:terminalOutput:corner                      press the corner
      #   hbar:<pane>:grab:<at>:<by>                      hold the thumb
      #                                                   `at` px into it,
      #                                                   move `by` px
      #   PLAT-70 Part I: also `eventLog` and `calltrace` (their sideways
      #   bars, while their columns scroll).
      var bar, corner: PxRect
      var thumbStart, thumbLen = 0
      case parts[1]
      of $paneEditor:
        bar = editorBarRect()
        let span = gEditorView.barModel.thumbSpan(bar.w,
                                                  EditorScrollbarMinThumbPx)
        (thumbStart, thumbLen) = (span.start, span.length)
      of $paneTerminalOutput:
        let vm = terminalVM()
        if vm.isNil:
          return "the terminal output pane is not drawn"
        let lay = terminalLayout(terminalBody(), vm, gTerminal)
        bar = lay.hbar
        corner = lay.corner
        let span = lay.view.barModel.thumbSpan(bar.w, TerminalMinThumbPx)
        (thumbStart, thumbLen) = (span.start, span.length)
      of $paneEventLog, $paneCalltrace:
        # PLAT-70 Part I: a table pane's sideways bar while it SCROLLS.
        let (rect, v) = tableHBarOf(if parts[1] == $paneEventLog: paneEventLog
                                    else: paneCalltrace)
        bar = rect
        let span = v.barModel.thumbSpan(bar.w, TableHBarMinThumbPx)
        (thumbStart, thumbLen) = (span.start, span.length)
      else:
        return "no horizontal bar on '" & parts[1] & "'"
      if bar.w <= 0:
        return "the " & parts[1] & " pane's content fits: no bar is drawn"
      let y = bar.y + bar.h div 2
      proc bx(permille: int): int = bar.x + min(bar.w - 1, bar.w * permille div 1000)
      case parts[2]
      of "track": pressAt(bx(at(3)), y)
      of "corner":
        if corner.w <= 0: return "no corner on '" & parts[1] & "'"
        pressAt(corner.x + corner.w div 2, corner.y + corner.h div 2)
      of "drag":
        windowPointer(r, gekPointerDown, bar.x + thumbStart + thumbLen div 2, y)
        let a = at(3)
        let b = at(4)
        for k in 0 .. 10:
          windowPointer(r, gekPointerMove, bx(a + (b - a) * k div 10), y)
        windowPointer(r, gekPointerUp, bx(b), y)
      of "grab":
        # PLAT-70 Part H / I: hold the thumb `at` px right of its start,
        # move the pointer `by` px, release.
        let x0 = bar.x + thumbStart + at(3)
        windowPointer(r, gekPointerDown, x0, y)
        windowPointer(r, gekPointerMove, x0 + at(4) div 2, y)
        windowPointer(r, gekPointerMove, x0 + at(4), y)
        windowPointer(r, gekPointerUp, x0 + at(4), y)
      else:
        return "unknown hbar event '" & parts[2] & "'"
    of "wheel":
      # M73 (#840): `wheel:<pane>:<lines>` — the plain VERTICAL wheel over a
      # named pane's centre (lines of GPUI's wheel, `GpuiWheelLinePx`,
      # positive toward the user: the content moves up), through
      # `windowPointer` as a real one reaches it. Until M73 no op sent one,
      # and no suite could see the editor drop it.
      let i = gGeom.tabsNodeOfPane(parts[1])
      if i < 0:
        return "no pane box holds '" & parts[1] & "'"
      let (cx, cy) = centreOf(gGeom.nodes[i].body)
      windowPointer(r, gekWheel, cx, cy, -float(at(2)) * GpuiWheelLinePx, 0.0)
    of "swheel":
      # PLAT-70: `swheel:<pane>:<lines>` — the VERTICAL wheel with Shift held
      # over a named pane (lines of GPUI's wheel, `GpuiWheelLinePx`, positive
      # toward the user),
      # through the same Shift rule the root's listener applies
      # (`wheelDeltas`).
      let i = gGeom.tabsNodeOfPane(parts[1])
      if i < 0:
        return "no pane box holds '" & parts[1] & "'"
      let (cx, cy) = centreOf(gGeom.nodes[i].body)
      let (dy, dx) = wheelDeltas(-float(at(2)) * GpuiWheelLinePx,
                                 0.0, shift = true)
      windowPointer(r, gekWheel, cx, cy, dy, dx)
    of "hwheel":
      # `PLAT35-F3`. `hwheel:<pane>:<columns>` — a horizontal wheel over a
      # named pane, aimed at the pane's own centre from the geometry the
      # window drew, with the delta spelled in COLUMNS so a reader of the op
      # and a reader of the drawn rows are counting the same thing. It goes
      # through `windowPointer` like every other scripted event, so what it
      # exercises is the handler a real wheel reaches.
      let i = gGeom.tabsNodeOfPane(parts[1])
      if i < 0:
        return "no pane box holds '" & parts[1] & "'"
      let (cx, cy) = centreOf(gGeom.nodes[i].body)
      # PLAT-70: a line's worth of pixels is a notch of `WheelColumns`
      # columns (§4.3), so `<columns>` is sent as that share of a line.
      windowPointer(r, gekWheel, cx, cy, 0.0,
                    -float(at(2)) / float(WheelColumns) * GpuiWheelLinePx)
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
    of "tab-add", "tab", "tab-close":
      # PLAT-49 part B: the session strip's "+", tab `n` or its close
      # control, pressed where the band drew it.
      let part = case parts[0]
                 of "tab-add": gtTabAdd
                 of "tab": gtTab
                 else: gtTabClose
      let index = if parts.len > 1: at(1) else: 0
      let sg = gTopLayout.segOf(part, index)
      if sg.rect.w <= 0:
        return "no " & parts[0] & " " & $index & " in the band"
      let (x, y) = centreOf(sg.rect)
      windowPointer(r, gekPointerMove, x, y)
      pressAt(x, y)
      return ""
    of "click":
      # PLAT-50: `click:<part>:<key>[:left|right|middle[:ctrl|alt|shift]]` — a press
      # on a row the window wired (`window_clicks.findClickTarget`),
      # dispatched to it as the shim delivers a press to the element under
      # the pointer, then to the window root, as a real press bubbles.
      var part = gcpNone
      for p in GClickPart:
        if $p == parts[1]: part = p
      var key = if parts.len > 2: parts[2] else: ""
      # PLAT-51: a value control's key is itself `<kind>:<path>`
      # (`history:x`, `origin:x`, `unwatch:x`), so it takes two fields.
      var shift = 0
      if part == gcpStateControl and parts.len > 3:
        key = parts[2] & ":" & parts[3]
        shift = 1
      let button = if parts.len > 3 + shift: parts[3 + shift] else: "left"
      let mods = if parts.len > 4 + shift: parts[4 + shift] else: ""
      let ctrl = "ctrl" in mods
      let alt = "alt" in mods
      # An editor press names its COLUMN too: `<line>@<column>`, pressed at
      # that column's pixel (`editorXOfColumn`, the inverse of the mapping a
      # press is read back with).
      var column = 0
      if part in {gcpCode, gcpValue} and '@' in key:
        try: column = parseInt(key[key.find('@') + 1 .. ^1])
        except ValueError: return "bad column in '" & key & "'"
        key = key[0 ..< key.find('@')]
      # PLAT-70 Part B: a table row's press can name its PIXEL,
      # `<key>@<x>x<y>` (the op's own `,` and `:` are taken) — the row's listeners hear it there, and then the
      # window root's pointer router does, as a real press reaches both (a
      # `…` or a column separator is the root's to take, and the row must
      # leave it).
      var at = (x: -1, y: -1)
      if part in {gcpEventRow, gcpEventHeader, gcpVariable, gcpCallRow} and
         '@' in key:
        let xy = key[key.find('@') + 1 .. ^1].split('x')
        try: at = (parseInt(xy[0]), parseInt(xy[1]))
        except ValueError, IndexDefect: return "bad pixel in '" & key & "'"
        key = key[0 ..< key.find('@')]
      # A LEFT press on a pane tab is the window's own (it activates the tab):
      # pressed where the strip drew the tab.
      if part == gcpTab and button == "left":
        for n in gGeom.nodes:
          if n.kind == gnTabs and key in n.panes and n.tabs.len > 0:
            let (tx, ty) = centreOf(n.tabs[n.panes.find(key)])
            pressAt(tx, ty)
            return ""
        return "no tab '" & key & "' in the window"
      let el = findClickTarget(r, (if gRoot.isNil: gContainer else: gRoot), part,
                               key)
      if el.isNil:
        return "no " & parts[1] & " row '" & key & "' in the window"
      var x = 0
      if column > 0:
        x = editorXOfColumn(column)
      let kind = case button
                 of "right": gekContextMenu
                 of "middle": gekAuxDown
                 else: gekPointerDown
      let name = case button
                 of "right": "contextmenu"
                 of "middle": "auxdown"
                 else: "mousedown"
      # AS A REAL PRESS BUBBLES: the shim delivers a dispatched event to one
      # node, and GPUI delivers a press to every element under the pointer,
      # innermost first — so the row, then each of its ancestors, up to (not
      # including) the window root, whose own listener is the window's
      # pointer router; the root's clearing of the dedupe is done here.
      var modifiers: set[GpuiModifier] = {}
      if ctrl: modifiers.incl gmControl
      if alt: modifiers.incl gmAlt
      # PLAT-51: Shift is delivered like any modifier, and GPUI opens its menu
      # on Shift + right-click like any right-click — a GPUI window has no
      # native menu to fall back to (Native-Front-End-Parity.md §1).
      if "shift" in mods: modifiers.incl gmShift
      let ev = GpuiEvent(kind: kind,
                         key: (if at.x >= 0: $at.x & "," & $at.y else: $x & ",0"),
                         modifiers: modifiers)
      var node = el
      while not node.isNil and
            getAttribute(node, WindowRootAttribute) != "true":
        discard fireEvent(node, name, ev)
        node = r.parentNode(node)
      gPressDedupe.clear()
      if at.x >= 0 and kind == gekPointerDown:
        pressAt(at.x, at.y)
      return ""
    of "modifiers":
      # PLAT-68: `modifiers:[<mod>+<mod>]` — the held modifiers are now these
      # (GPUI's `modifierschange`), through the listener's own path.
      let held = if parts.len > 1 and parts[1].len > 0: parts[1].split('+')
                 else: @[]
      windowModifiers(held)
    of "probe":
      # PLAT-68: `probe:<key>[:<mod>+<mod>]` — what the key would resolve to
      # where the focus is, traced, with no effect.
      let mods = if parts.len > 2: parts[2].split('+') else: @[]
      traceGesture("probe " & probeWindowKey(parts[1], mods))
    of "select":
      # PLAT-68: `select:<line>@<column>:<line>@<column>` — a left press on
      # the editor's text at the first cell, the pointer moved, with the
      # button held, to the second, and released there: a DRAG, through the
      # row's press and the window's own pointer handler.
      if parts.len != 3 or '@' notin parts[1] or '@' notin parts[2]:
        return "select takes <line>@<column>:<line>@<column>"
      let pressed = runWindowOp(r, "click:code:" & parts[1])
      if pressed.len > 0:
        return pressed
      let to = parts[2].split('@')
      let x = editorXOfColumn(parseInt(to[1]))
      let y = editorYOfLine(parseInt(to[0]))
      if y <= 0:
        return "line " & to[0] & " is not drawn in the editor"
      windowPointer(r, gekPointerMove, x, y)
      windowPointer(r, gekPointerUp, x, y)
    of "ctx":
      # PLAT-50: the open right-click menu's entry `parts[1]`, pressed.
      if not gCtxMenu.open:
        return "no right-click menu is open"
      let rect = contextMenuRect(gCtxMenu, pendingViewportWidth,
                                 pendingViewportHeight)
      for (rr, i) in contextMenuRows(gCtxMenu, rect):
        if gCtxMenu.menu.entries[i].label == parts[1]:
          let (x, y) = centreOf(rr)
          pressAt(x, y)
          return ""
      return "no entry '" & parts[1] & "' in the right-click menu"
    of "hover-label":
      # PLAT-49 part B: the pointer onto a strip label, without pressing.
      for st in gGeom.strips:
        for sl in st.slots:
          if sl.pane == parts[1]:
            let (x, y) = centreOf(sl.rect)
            windowPointer(r, gekPointerMove, x, y)
            return ""
      return "no strip label for '" & parts[1] & "'"
    of "wait":
      # PLAT-49 part B: let `ms` pass for the hover machine (a scripted run
      # has no loop to wait in) and run what fell due.
      gHoverClockOffsetMs += int64(at(1))
      applyHoverReply(r, gAutoHide.tick(hoverNowMs()))
      discard tickCellHover(r)
      # PLAT-51: and a welcome tab's running `ct record` — REALLY waited
      # for, up to `ms`, polled as the window's tick polls it.
      if not gRecordJob.isNil and not gRecordJob.done:
        let deadline = epochTime() + float(at(1)) / 1000.0
        while epochTime() < deadline:
          if pollWelcomeRecording(r):
            break
          sleep(RecordPollMs)
      # PLAT-54: and a live agent's turn — REALLY waited for, up to `ms`,
      # its updates applied as the window's tick applies them.
      if agentLive():
        let deadline = epochTime() + float(at(1)) / 1000.0
        while agentLive() and epochTime() < deadline:
          for h in gAgentHosts.values:
            discard h.poll()
          sleep(AgentPollMs)
        for h in gAgentHosts.values:
          discard h.poll()
        drawAgentPane(r)
        drawTopBar(r)
      # PLAT-57: and a Find in Files search streaming — REALLY waited for,
      # up to `ms`, pumped as the window's tick pumps it.
      if nativeFindInFiles.running:
        let deadline = epochTime() + float(at(1)) / 1000.0
        while nativeFindInFiles.running and epochTime() < deadline:
          if not nativeFindInFiles.pump():
            break
          sleep(SearchPollMs)
        drawSearchPane(r)
      return ""
    of "label", "label-menu":
      for st in gGeom.strips:
        for sl in st.slots:
          if sl.pane == parts[1]:
            let (x, y) = centreOf(sl.rect)
            if parts[0] == "label-menu":
              # PLAT-50 (K42): the label's right-click.
              windowPointer(r, gekContextMenu, x, y)
            else:
              pressAt(x, y)
            return ""
      return "no strip label for '" & parts[1] & "'"
    of "pin":
      for n in gGeom.nodes:
        if n.kind == gnTabs and parts[1] in n.panes:
          let (x, y) = centreOf(n.pins[n.panes.find(parts[1])])
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
      # `hold:<pane>:<target>[:left|:strip|:outer-right]` — the target's
      # middle (a join, PLAT-51: the smaller middle), its left quarter (a
      # split), the start of its first tab (a header drop), or the layout's
      # own right edge (GoldenLayout's ground band).
      let tn = gGeom.nodes[dst]
      let tb = tn.body
      let side = if parts.len > 3: parts[3] else: ""
      let (tx, ty) =
        case side
        of "left": (tb.x + tb.w div 8, tb.y + tb.h div 2)
        of "strip":
          if tn.tabs.len > 0: (tn.tabs[0].x + 3, tn.tabs[0].y + tn.tabs[0].h div 2)
          else: (tn.strip.x + 3, tn.strip.y + tn.strip.h div 2)
        of "outer-right": (gGeom.inner.x + gGeom.inner.w - 10,
                           tb.y + tb.h div 2)
        else: centreOf(tb)
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
    return "malformed event '" & op & "': " & getCurrentExceptionMsg()
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
  gChromeSpec = cmd.windowChrome
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

proc opensWindow(cmd: GpuiCommand): bool =
  ## Whether this run opens a window (and not a plan, or an off-screen frame).
  not cmd.reportPlan and not cmd.reportWindowPlan and cmd.pixelsOut.len == 0

proc applyWindowPolicy(cmd: var GpuiCommand) =
  ## PLAT-69 (C5): THE WINDOW OPENS AS THE USER CONFIGURED IT — the
  ## `window:` entry of the configuration file the desktop reads, found the
  ## way the desktop finds it (`window_policy.findUserConfigFile`), resolved
  ## by the one policy both front-ends apply. `--width` / `--height` override
  ## it (a windowed window of exactly that size), which is what keeps every
  ## window lane deterministic. A setting that cannot be used is reported and
  ## replaced by the default; it never stops the window from opening.
  ##
  ## Only for a run that opens a window: the plan and the capture paths draw
  ## at the command line's size (default 1440x900) and read no setting, so a
  ## user's configuration cannot change what a suite reads off them.
  if not opensWindow(cmd):
    return
  var setting = DefaultWindowSetting
  let file = findUserConfigFile(getCurrentDir(), ctConfigDir())
  if file.len > 0:
    try:
      let parsed = windowSettingOfConfigText(readFile(file))
      setting = parsed.setting
      for problem in parsed.problems:
        stderr.writeLine("codetracer-gpui: " & file & ": " & problem)
    except IOError as e:
      stderr.writeLine("codetracer-gpui: cannot read " & file & ": " & e.msg &
                       "; the window opens as the default says")
  gLaunch = resolveWindowLaunch(setting,
                                if cmd.widthGiven: cmd.width else: 0,
                                if cmd.heightGiven: cmd.height else: 0)
  cmd.width = gLaunch.width
  cmd.height = gLaunch.height

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
  # The design system's faces, before anything is drawn — window or pixels.
  discard registerDesignFonts()
  if cmd.pixelsOut.len > 0:
    return capturePixels(cmd)
  # FROM HERE ON THIS RUN EXISTS TO SHOW A WINDOW, so first make sure one can
  # appear. A featureless shim's `gpui_launch` returns at once having opened
  # nothing, and with no graphical session GPUI picks its headless platform
  # and `gpui_launch` never returns; both used to be silent (rc 0, or a hang).
  # Asked HERE rather than before the recording is opened, so the outputs a
  # windowed run writes ahead of the window — `--plan-out`, `--dock-out` —
  # are still written: the PLAT-37 lane's featureless DIFF-6 arm reads its
  # plan from exactly such a run. See `window_preflight.nim`.
  let preflight = currentWindowPreflight(gpui_has_window_backend() == 1'u8)
  if preflight.refusal != wpWindowCanOpen:
    stderr.writeLine("codetracer-gpui: " & preflight.message)
    return ExitNoWindow
  if cmd.quitAfterMs > 0'u32:
    gpui_quit_after_ms(cmd.quitAfterMs)
  armHoverTick()   # nothing hovered yet: the VCS refresh, when there is one
  let loadStart = loadAverage()
  if cmd.frameReport.len > 0:
    gpui_frame_stats_reset()
  # PLAT-69: the window's minimum size, its initial state (maximized, unless
  # the setting or the command line says otherwise) and the app id it shares
  # with the desktop; `gpui_launch`'s size is the windowed (restore) size.
  gWindowTitle = title
  prepareWindowLaunch(gLaunch)
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

proc editorSubRowOffsetFor(layout: Layout; viewport: DockViewport;
                           cmd: GpuiCommand): int =
  ## Monaco's sub-row offset for a centred view of this window's editor
  ## (`editorTopInsetPx`'s second term), before the window is laid out.
  let proj = projectDock(layout, viewport)
  let g = windowGeometryOf(layout,
                           (if proj.status == dpsRefused: nil else: proj.state),
                           cmd.width, cmd.height, GpuiTopBandPx)
  let i = g.tabsNodeOfPane($paneEditor)
  if i < 0: return 0
  ((g.nodes[i].body.h - EditorPadTopPx) div 2) mod GpuiEditorRowPx

proc editorVisibleRowsFor(layout: Layout; viewport: DockViewport;
                          cmd: GpuiCommand): int =
  ## `editorRowsFor`'s companion: the rows wholly in view above the editor's
  ## horizontal scrollbar band (`window_geometry.editorVisibleRowsOf`).
  let proj = projectDock(layout, viewport)
  editorVisibleRowsOf(windowGeometryOf(layout,
                                       (if proj.status == dpsRefused: nil
                                        else: proj.state),
                                       cmd.width, cmd.height, GpuiTopBandPx))

proc editorBodyWidthFor(layout: Layout; viewport: DockViewport;
                        cmd: GpuiCommand): int =
  ## `PLAT35-F3`. How wide the editor pane's content area is, BEFORE the
  ## window has been laid out — the same `windowGeometryOf` the chrome pass
  ## will compute, over the same inputs, so the first frame's scrollbar and
  ## every later one are decided from one rectangle. Written beside
  ## `editorRowsFor` and in the same shape for that reason.
  let proj = projectDock(layout, viewport)
  editorBodyWidthOf(windowGeometryOf(layout,
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
  let preference = sessionKeymap(cmd.keymap)
  openArm = newGpuiEditArm(cmd.traceFolder, relative,
                           readProjectFile(cmd.traceFolder, relative),
                           preference.model)
  if preference.status in {kplRefused, kplMigrated}:
    openArm.status = preference.message
  editViewportRows = rows
  gEditorTab = editorTabLabel(openArm.root / openArm.path, openArm.isDirty)
  openArm.surfaceOf(editViewportRows)

proc runEdit(cmd: GpuiCommand): int =
  ## `ct edit --ui=gpui <project>`, end to end, with NO recording open.
  # PLAT-53: a Test Results run still going ends with the window.
  defer: stopTestsHost()
  # PLAT-55: and a `:build` still going.
  defer: stopGpuiBuild()
  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  let surface = editSurfaceFor(cmd,
    editorRowsFor(initLayout(sharedEditLayout().tree, sharedEditLayout().docked), shell.viewport, cmd))
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
  let opened = shell.openWindow(windowId, initLayout(sharedEditLayout().tree, sharedEditLayout().docked))
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1
  var r: GpuiRenderer
  var leafSet = shell.leavesFor(windowId)
  # PLAT-47 deliverable 4: in Edit mode the VCS pane shows the project.
  if editProjectProblem(cmd.traceFolder).len == 0:
    attachVcs(leafSet, cmd.traceFolder)
    # K19: and the Files pane lists the opened folder, its menu acting on
    # the disk.
    attachEditFiles(leafSet, cmd.traceFolder)
  # PLAT-53: Test Results over the project. This window has no session tabs,
  # so a test's recording is not opened here: the pane says where it is.
  installTestsHost(cmd.traceFolder, proc(folder: string): string =
    NoSessionTabsInEditText & folder)
  attachTests(leafSet)
  # PLAT-55: Problems over this window's builds (`:build` runs in the
  # project).
  installProblems(cmd.traceFolder)
  attachProblems(leafSet)
  # `PLAT35-F3`: the editor pane's inner width, from the geometry this
  # window is about to be laid out at.
  gEditorSurface = surface
  gEditorViewportPx = editorBodyWidthFor(
    initLayout(sharedEditLayout().tree, sharedEditLayout().docked), shell.viewport, cmd)
  let drawn = renderLeaves(r, leafSet, surface, gEditorViewportPx)
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
  # PLAT-69 (C4): the desktop's Edit window is called `CodeTracer`.
  launchWindow(cmd, windowTitleFor(nil), drawn,
               if editDock.status == dpsRefused: nil else: editDock.state)

proc runOpen(cmd: GpuiCommand): int =
  ## Open the recording, build the shell, draw the leaves.
  if cmd.product == pmEdit:
    return runEdit(cmd)
  let session = openGpuiTrace(cmd.traceFolder)
  # THE ENGINE ENDS WITH THIS RUN, on every path out of it: the plan, the
  # window, each `return 1`, and a stall raised after the open. Without this
  # the child was reaped only if it noticed its stdin close when this process
  # exited, and an engine stuck in a computation — the post-open stall this
  # run reports — never reads stdin, so it outlived the front-end.
  # `DapStdioBackend.close` is idempotent and kills a child that does not
  # exit on its own.
  defer: session.backend.close()
  # PLAT-53: and a Test Results run still going ends with it (its group).
  defer: stopTestsHost()
  # PLAT-55: and a `:build` still going.
  defer: stopGpuiBuild()
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
        # The values in scope at every stop, as the desktop's window loads
        # them at each one: the changed-value marks (`StateVM.isChanged`)
        # compare a stop against the one before it, so they need it seen.
        try:
          session.requestAndLoadLocals()
        except CatchableError:
          discard
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
                                   title = extractFilename(
                                     session.tracePath.strip(chars = {'/'})),
                                   layout = layout,
                                   adopt = session.sdk)
  # PLAT-49 part B: the window's first session tab, and the recordings the
  # strip's "+" offers beside it.
  gSessionsOpened[int(slot.id)] = session
  gRecordings = recordingsBeside(cmd.traceFolder)
  gOpenCmd = cmd
  # PLAT-51: the remembered layout preferences, then this window's flags.
  block:
    let stored = loadLayoutPreferences(lpGpui)
    if stored.status == lpsRefused:
      stderr.writeLine("codetracer-gpui: " & stored.message)
    gLayoutSettings = stored.settings
    for which in LayoutSetting:
      gLayoutSettings.applyOverride(which, cmd.layoutFlags[which])
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
  sourceService.visibleRows = editorVisibleRowsFor(
    shell.windows.windows[shell.windows.indexOf(windowId)].layout,
    shell.viewport, cmd)
  block:
    let layout = shell.windows.windows[shell.windows.indexOf(windowId)].layout
    let proj = projectDock(layout, shell.viewport)
    sourceService.fullRows = editorFullRowsOf(windowGeometryOf(layout,
      (if proj.status == dpsRefused: nil else: proj.state),
      cmd.width, cmd.height, GpuiTopBandPx))
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
  discard session.loadRecordingPanes(raiseOnStall = true)
  # PLAT-52 / Q3: the Terminal Output pane asks for the lines it shows as it
  # is drawn (`drawTerminalPane`), as the terminal's does.
  session.openTerminalOutput()
  discard session.loadStopPanes()
  # The current call is selected once the call trace holds the section its
  # pane shows (`reportListViewports`, with the first frame's geometry).
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
    # Monaco's DRAWN rows include the one partly hidden above the first whole
    # line when the view is scrolled to a sub-row offset (`editorTopInsetPx`):
    # the desktop's driver counts it, so this one does too — row `bpRow` is
    # one line above the window's `bpRow`th row then.
    let partial = probe.viewportTop > 1 and
                  editorSubRowOffsetFor(
                    shell.windows.windows[shell.windows.indexOf(windowId)].layout,
                    shell.viewport, cmd) > 0
    let at = if partial and bpRow > 0: probe.rows[min(bpRow - 1, probe.rows.high)].line
             elif partial: probe.rows[0].line - 1
             else: probe.rows[min(bpRow, probe.rows.high)].line
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
  # PLAT-54: the session first, so the Agent Activity leaf gets its host's
  # ViewModel beside the VCS pane's.
  gSession = session
  # PLAT-47 deliverable 4: the VCS pane draws the desktop's `VCSVM`, filled
  # from the repository the desktop would show for a replay — the process's
  # working directory.
  attachVcs(leafSet, getCurrentDir())
  # PLAT-53: Test Results over the same directory, the window's project; a
  # test's recording opens in a NEW SESSION TAB (Test-Results-Pane.md §8.3).
  installTestsHost(getCurrentDir(), proc(folder: string): string =
    let problem = traceFolderProblem(folder)
    if problem.len > 0:
      return "could not open " & folder & ": " & problem
    let before = gSessionsOpened.len
    var rr: GpuiRenderer
    openRecordingInTab(rr, folder)
    if gSessionsOpened.len > before: ""
    else: "could not open " & folder & " in a new tab")
  attachTests(leafSet)
  # PLAT-54: the review this window opens on (`--deepreview`) and the agent
  # session `ct review` resolved for it (`--review-session`), before the
  # first frame, as the desktop enters both on its first render.
  if cmd.reviewDataset.len > 0 or cmd.reviewSession.len > 0:
    let h = agentHost()
    for leaf in leafSet.leaves:
      if leaf.kind == glkBuiltin and leaf.builtin == paneVcs and
         not leaf.vm.isNil:
        h.vcs = VCSVM(leaf.vm)
    if cmd.reviewDataset.len > 0 and not h.loadReviewDataset(cmd.reviewDataset):
      stderr.writeLine("codetracer-gpui: --deepreview: " & h.message)
    if cmd.reviewSession.len > 0:
      discard h.loadReviewSession(cmd.reviewSession)
  # PLAT-55: Problems over the window's builds, run in the same directory.
  installProblems(getCurrentDir())
  attachProblems(leafSet)
  # `PLAT35-F3`: the editor pane's inner width, from the geometry this
  # window is about to be laid out at — the same reading `editorRowsFor`
  # takes for the row count, over the same layout.
  # The session is the window's from here (the first frame's leaves read its
  # flow); it was assigned only after the first frame until 2026-10-17.
  gSession = session
  applyRememberedColumnWidths()
  gEditorSurface = surface
  gEditorViewportPx = editorBodyWidthFor(
    shell.windows.windows[shell.windows.indexOf(windowId)].layout,
    shell.viewport, cmd)
  # What the first frame's leaves read besides their ViewModels: the state
  # pane's code line (`updateCodeStateLine`, as `redrawReplayEditor` feeds it
  # after every move) and the event log's tick and width (`syncLeafContext`).
  for row in gEditorSurface.rows:
    if row.pointer == eptExecution and row.held:
      session.session.store.updateCodeStateLine(row.line, row.text.strip())
  eventLogNowTicks = session.getCurrentRRTicks()
  # And the event log's "now" row, for its scrubber's mark — what a move
  # asks for (`refreshReplayWindow`), asked once for the stop the window
  # opens at.
  refreshEventLogMark()
  block:
    let layout = shell.windows.windows[shell.windows.indexOf(windowId)].layout
    let proj = projectDock(layout, shell.viewport)
    let g = windowGeometryOf(layout,
                             (if proj.status == dpsRefused: nil else: proj.state),
                             cmd.width, cmd.height, GpuiTopBandPx)
    let i = g.tabsNodeOfPane($paneEventLog)
    if i >= 0:
      eventLogPaneWidthPx = g.nodes[i].body.w
      eventLogPaneHeightPx = g.nodes[i].body.h
    let st = g.tabsNodeOfPane($paneState)
    if st >= 0: statePaneSizePx = (g.nodes[st].body.w, g.nodes[st].body.h)
    syncInHandRows(g)
    let ct = g.tabsNodeOfPane($paneCalltrace)
    if ct >= 0:
      callTracePaneWidthPx = g.nodes[ct].body.w
      callTracePaneHeightPx = g.nodes[ct].body.h
    let e = g.tabsNodeOfPane($paneEditor)
    if e >= 0: editorPaneHeightPx = g.nodes[e].body.h
    # The call trace and the event log read the windows their panes show
    # (the open read one row of each), and the current call is selected
    # in the section the call trace now holds.
    discard reportListViewports(session, g)
    session.selectCurrentCall()
  # PLAT-70: the shown file's document, so the editor's horizontal view is
  # its EXACT content width from the first frame (Horizontal-Overflow §4.1).
  gSourceService = sourceService
  discard debugDocumentFor(gEditorSurface.path, gEditorSurface.executionLine)
  followEditorView()
  let drawn = renderLeaves(r, leafSet, gEditorSurface, gEditorViewportPx,
                           gEditorView.leftCol, gEditorView.contentCols,
                           editorCaretMark())
  # PLAT-47 part B: what the window's gestures and the call trace's paging
  # act on. A rearrangement is remembered on the terms `--layout-ops` is:
  # never over a quarantined file, and not for a session opened from a named
  # `--layout` file.
  gShell = shell
  gWindow = windowId
  gRemember = not quarantined and cmd.layoutFile.len == 0
  gSession = session
  applyRememberedColumnWidths()
  wireSearch(session)
  # PLAT-48: the top bar's shared ViewModels. The menu is the product's tree
  # with what this window performs enabled, its chords none (the window has
  # no keymap of its own for the debugger yet); the omnibar searches the
  # session's files, the held call-trace section and the menu's commands —
  # the index the terminal builds for the same recording.
  gMenu = newMenuVM(nativeFrontEndMenu("CodeTracer"))
  refreshGpuiMenuAvailability()
  # PLAT-68: the window's keys resolve through the one router, under the
  # base this session starts with and the user's `keybindings.json`; the
  # menu shows the chords it resolves (`refreshMenuShortcuts`).
  let preference = sessionKeymap(cmd.keymap)
  wireKeybindings(preference.model,
                  case preference.reason
                  of "flag": ksFlag
                  of "stored": ksStored
                  else: ksDefault)
  gOmnibar = newOmnibarVM()
  gOmnibar.setIndex(omnibarIndexOf(session.session.fileTreeVM,
                                   session.session.store, gMenu,
      terminalSettings = false) &
                    gRecordings)
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
  # THE OPEN IS OVER AND THE WINDOW IS ABOUT TO TAKE INPUT, so the engine's
  # clock comes off here and not earlier: everything above, `--replay-ops`
  # and every early `return` without a window included, ran unattended and
  # stays bounded (`gpui_host.openGpuiTrace`, "The bound covers the OPEN, not
  # the window"). A window with `--quit-after-ms` is a scripted capture with
  # nobody at it, so it keeps the clock: a read that blocked there would also
  # block the very event loop whose timer is meant to end the run.
  if cmd.quitAfterMs == 0'u32:
    liftOpenBound(session)
  # PLAT-69 (C4): `<program> — CodeTracer`, the desktop's title.
  result = launchWindow(cmd, windowTitleFor(session), drawn,
                        if dock.status == dpsRefused: nil else: dock.state)
  # PLAT-49 part B: the sessions a "+" opened, and their engines, closed.
  closeTabSessions(toSeq(gSessionsOpened.values), keep = session)

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
    var cmd = cmd
    applyWindowPolicy(cmd)
    try:
      quit(runOpen(cmd))
    except DapLaunchRefusedError as e:
      # A recording this build cannot read is not an unhandled error. The
      # engine stated its reason — the container version it found, the one it
      # requires, and that re-recording is the remedy — and that sentence is
      # what the user gets, whole: `splitLines()[0]` below would truncate it
      # if the engine ever wraps. Exit 5 matches the terminal front-end's
      # `cli.ExitUnreadableRecording`, which both front-ends owe a script
      # driving either of them.
      stderr.writeLine("codetracer-gpui: " & e.msg)
      quit(GpuiExitUnreadableRecording)
    except GpuiOpenStalledError as e:
      # THE ENGINE WENT QUIET WHILE OPENING. `openGpuiTrace` bounds every read
      # of the open (`CODETRACER_GPUI_HANDSHAKE_MS`, 30 s by default); before
      # it did, an engine that acknowledged `launch` and never sent `stopped`
      # left this process blocked in `read` for ever with nothing on either
      # stream. A distinct code and the terminal front-end's wording
      # (`cli.ExitEngineStalled`): a stall is neither a bad command line nor
      # an engine that stated a reason, and a script must be able to tell.
      stderr.writeLine("codetracer-gpui: " & cmd.traceFolder &
                       ": the replay engine stopped answering (" & e.msg & ")")
      stderr.writeLine("  the folder has a recording's shape but the engine" &
                       " could not read it; re-record it, or run" &
                       " `replay-server dap-server --stdio` against it to see" &
                       " what it says.")
      quit(GpuiExitEngineStalled)
    except DapStalledError as e:
      # THE ENGINE WENT QUIET AFTER THE RECORDING OPENED — in the handshake's
      # last wait (`EngineStalledAfterOpenError`, which `openGpuiTrace` keeps
      # as that kind), or while this run was loading panes, replaying
      # `--replay-ops` or building `--report-plan`,
      # all of which stay on the open's clock (`liftOpenBound`). The same code,
      # because it is the same fact for a script, but NOT the open's remedy:
      # the engine read this recording, so re-recording it would not help.
      # The terminal's sentence and remedy (`native_host
      # .stalledAfterOpenReport`), so the two front-ends cannot drift apart.
      for line in stalledAfterOpenReport("codetracer-gpui", cmd.traceFolder,
                                         e.msg, GpuiHandshakeEnvVar):
        stderr.writeLine(line)
      quit(GpuiExitEngineStalled)
    except CatchableError as e:
      stderr.writeLine("codetracer-gpui: " & e.msg.splitLines()[0])
      quit(1)

when isMainModule:
  main()
