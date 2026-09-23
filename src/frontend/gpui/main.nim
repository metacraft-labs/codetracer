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

import std/[cpuinfo, json, os, strutils, times]

import isonim_gpui/renderer
# `isonim_gpui/bindings` AND NOT `isonim_gpui/window`, since PLAT-37. The
# high-level `window.nim` wraps the registry — `createWindow`, `show`,
# `destroy` — which is precisely the layer that has no `cfg` on it and never
# reaches a renderer. The two functions this front-end needs, `gpui_launch`
# and `gpui_quit_after_ms`, are not wrapped there; they are the raw FFI.
import isonim_gpui/bindings

import ./chrome
import ./replay_ops

# PLAT-34. The editing core, through the sanctioned facade: `editSurfaceFor`
# below OPENS a document rather than handing a string to a derivation, so the
# GPUI editor and the terminal editor hold one value of one type.
import codetracer_embed

import ./app/shell
import ./app/leaves
import ./app/edit_arm
import ../view_vocabulary/pane_views   # `sourcePaneView`, for the redraw
import ../viewmodel/host/keymap_preference
import ./host/gpui_host

const GpuiHelpText = """
codetracer-gpui — CodeTracer's GPUI front-end (PLAT-20: the shell)

USAGE:
  codetracer-gpui [options] <trace-folder>

  Normally reached as `ct replay --ui=gpui <trace-folder>`; `ct` resolves
  `--ui` and execs this binary, and the launcher never learns about the flag.

OPTIONS:
  --report-plan     Build the window's render plan, print it, and exit 0
                    without entering an event loop. What GPUI would execute.
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
    noFlowOverlay: bool
      ## PLAT-42. Open with the flow overlay hidden — the user's
      ## `EditorVM.showFlowOverlay` toggle, from the command line; the window
      ## lane's negative twin for the drawn overlay.
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
                       height: DefaultGpuiViewport.height)
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
      # binary would resolve the folder as a trace and refuse it for having no
      # `trace.json`, which is a true diagnosis of the wrong question.
      result.product = pmEdit
    elif arg == "--report-plan":
      result.reportPlan = true
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
    ## PLAT-44. The open document of an EDIT-mode window, or nil in a replay
    ## window. Module-level for the root builder's reason above.
  editPane: GpuiElement = nil
    ## The editor leaf's element — the one the arm redraws and the keys reach.
  editViewportRows = 0
  pendingOutcome: LeafRenderOutcome
    ## The leaf tree, built BEFORE `gpui_launch` so `--report-plan` and the
    ## window path derive from one render rather than two.
  pendingViewportWidth = 0
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
  while childCount(editPane) > 1:
    r.removeChild(editPane, nthChild(editPane, childCount(editPane) - 1))
  discard renderEditor(r, editPane, sourcePaneView(GpuiMedium).root,
                       openArm.surfaceOf(editViewportRows))

proc editKeyHandler(el: GpuiElement): GpuiEventHandler =
  ## The editor pane's `keydown` listener. Built by a separate proc so `el`
  ## is captured by value — `probeHandler`'s recorded defect.
  result = proc(ev: GpuiEvent) =
    discard ev
    if openArm.isNil or el.lastEventKind() != gekKeyDown: return
    let key = el.lastEventKey()
    let started = epochTime()
    let applied = openArm.applyGpuiKey(key,
      modifierNamesOf(el.lastEventModifiers()),
      int64(started * 1000))
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

proc armEditorPane(r: GpuiRenderer) =
  ## Focus the editor pane and give it the key listener. Once.
  if openArm.isNil or editPane.isNil or editArmed: return
  editArmed = true
  setFocusable(editPane)
  discard focusElement(editPane)
  r.addEventListener(editPane, "keydown", editKeyHandler(editPane))

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
  ## out of the shadow tree, so `gpui/app/leaves.nim` is untouched by this
  ## milestone. That matters for a reason that is not aesthetic:
  ## `run-plat20-mutations.py`, `run-plat21-mutations.py`,
  ## `run-plat22-mutations.py` and `run-plat35-visual-mutations.py` all digest
  ## that file into their control comparators, and an edit here would have
  ## staled four harnesses' controls at once (§39a).
  inc builderCalls
  var r: GpuiRenderer
  # The window surface. `apply_styles_to_div` in `gpui_app.rs` reads `bg`,
  # `w`, `h`, `flex_direction`, `p`, `m`, `gap`, `text_color`, `rounded`,
  # `items`, `justify` and `cursor` — and NOTHING ELSE. In particular it does
  # not read `display`, which is the only style `leaves.nim` sets, so the
  # tree as built carries no visual instruction at all.
  r.setStyle(root, "background-color", chromeOf(crWindowBackground))
  r.setStyle(root, "color", chromeOf(crWindowForeground))
  r.setStyle(root, "width", "100%")
  r.setStyle(root, "height", "100%")
  r.setStyle(root, "flex-direction", "row")
  r.setStyle(root, "padding", $ChromePaddingPx & "px")
  r.setStyle(root, "gap", $ChromeGapPx & "px")

  let container = pendingOutcome.root
  r.setStyle(container, "width", "100%")
  r.setStyle(container, "height", "100%")
  r.setStyle(container, "flex-direction", "row")
  r.setStyle(container, "gap", $ChromeGapPx & "px")

  # THE PANES ARE READ BACK OUT OF THE TREE, not counted from `leafSet`.
  # Reading the input and calling it an observation is §4a; the renderer is
  # handed what the tree holds, so the tree is what the widths are computed
  # from.
  let panes = childCount(container)
  let paneW = paneWidthPx(pendingViewportWidth, panes)
  for i in 0 ..< panes:
    let pane = nthChild(container, i)
    if pane.isNil: continue
    r.setStyle(pane, "background-color", chromeOf(crPaneBackground))
    r.setStyle(pane, "color", chromeOf(crWindowForeground))
    r.setStyle(pane, "width", $paneW & "px")
    r.setStyle(pane, "height", "100%")
    r.setStyle(pane, "flex-direction", "column")
    r.setStyle(pane, "padding", $ChromePaddingPx & "px")
    r.setStyle(pane, "rounded", "4px")
    # The heading, when the leaf drew one. `leaves.renderLeaf` appends it
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
    if probeEnabled and i == 0:
      setFocusable(pane)
      discard focusElement(pane)
      probeTarget = pane
      r.addEventListener(pane, "keydown", probeHandler(pane))
    # The heading, when the leaf drew one. `leaves.renderLeaf` appends it
    # first, so index 0 is it — and a leaf that drew no heading (a refusal,
    # or an unloaded extension) has a text node there instead, which takes
    # no style and is harmless.
    if childCount(pane) > 0:
      let heading = nthChild(pane, 0)
      if not heading.isNil:
        r.setStyle(heading, "color", chromeOf(crPaneTitleForeground))

  # PLAT-44 — THE EDITOR TAKES KEYS. Attached here for the probe's reason:
  # `leaves.nim` is digested into four harnesses' controls.
  armEditorPane(r)

  r.appendChild(root, container)

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

proc launchWindow(cmd: GpuiCommand; title: string;
                  outcome: LeafRenderOutcome): int =
  ## Open the window, run the event loop, and return when it stops.
  ##
  ## Returns the process exit code. The event loop's own termination is the
  ## first result, and it is a result rather than a formality: PLAT-19
  ## measured that a windowed client ran past a 12 s and a 90 s cap before
  ## `gpui_quit_after_ms` existed, because `gpui_launch` does not return while
  ## the window does.
  pendingOutcome = outcome
  pendingViewportWidth = cmd.width
  builderCalls = 0
  probeEnabled = cmd.inputProbe.len > 0
  probeArrivals = @[]
  probeTarget = nil
  probeSentinel = getEnv("CODETRACER_GPUI_PROBE_SENTINEL", "")
  if cmd.quitAfterMs > 0'u32:
    gpui_quit_after_ms(cmd.quitAfterMs)
  let loadStart = loadAverage()
  if cmd.frameReport.len > 0:
    gpui_frame_stats_reset()
  let startedAt = epochTime()
  gpui_launch(title.cstring, float(cmd.width), float(cmd.height),
              paintWindowChrome)
  let elapsedMs = int((epochTime() - startedAt) * 1000)
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

proc editSurfaceFor(cmd: GpuiCommand): EditorSurface =
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
  editViewportRows = editorRowsForViewport(cmd.height)
  openArm.surfaceOf(editViewportRows)

proc runEdit(cmd: GpuiCommand): int =
  ## `ct edit --ui=gpui <project>`, end to end, with NO recording open.
  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  let surface = editSurfaceFor(cmd)
  # `openWindow` and not `openWindowForSession`: there is no session. That is a
  # real product state rather than a test affordance — `shell.openWindow`'s own
  # header says so — and it is exactly the state edit mode is in, because edit
  # mode's subject is the working tree and a `HeadlessSessionSlot` is a replay
  # session.
  let windowId = WindowId(0)
  let opened = shell.openWindow(windowId, initLayout(defaultReplayLayout()))
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1
  var r: GpuiRenderer
  let leafSet = shell.leavesFor(windowId)
  let drawn = renderLeaves(r, leafSet, surface)
  editPane = findEditorPane(drawn.root)
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
  if cmd.reportPlan:
    if not leafPlanIsValid(r, drawn):
      stderr.writeLine("codetracer-gpui: the render plan did not verify")
      return 1
    echo leafPlanJson(r, drawn)
    return 0
  launchWindow(cmd, "CodeTracer — " & cmd.traceFolder & " [EDIT]", drawn)

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
  let slot = shell.app.openSession(session.backend.toBackendService(),
                                   title = cmd.traceFolder,
                                   adopt = session.sdk)
  let windowId = WindowId(0)
  let opened = shell.openWindowForSession(windowId, slot.id)
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1

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
    if cmd.product == pmEdit: paneEditor else: paneDebugControls)

  # The source window. PLAT-22: the editor is wired to the same `SourceVM` the
  # terminal's editor uses, and the host is what fills it — see
  # `gpui_host.newGpuiSourceService`. `editorRowsForViewport` is derived from
  # the window height rather than chosen, so a taller window holds more lines
  # and `followExecutionPointer` scrolls the window the editor actually draws.
  let sourceService = newGpuiSourceService(session, cmd.traceFolder,
                                           editorRowsForViewport(cmd.height))
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
  try:
    session.requestAndLoadLocals()
  except CatchableError:
    discard
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
    points.add EditorPoint(path: session.getCurrentFile(), line: at,
                           kind: epkBreakpoint, enabled: true)

  let surface = editorSurfaceFor(
    source = sourceService.vm,
    editor = session.session.editorVM,
    state = session.session.stateVM,
    flow = session.session.flowVM,
    availability = sourceService.availability(),
    budget = gpuiRowBudget(),
    medium = GpuiMedium,
    points = points)

  var r: GpuiRenderer
  let leafSet = shell.leavesFor(windowId)
  let drawn = renderLeaves(r, leafSet, surface)

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
  launchWindow(cmd, "CodeTracer — " & cmd.traceFolder, drawn)

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
