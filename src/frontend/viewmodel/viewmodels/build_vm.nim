## viewmodels/build_vm.nim
##
## BuildVM — ViewModel for the Build panel.
##
## Holds reactive state for:
## - The list of rendered output lines (``BuildOutputLine`` seq) — both
##   stdout and stderr, optionally tagged with a parsed source location
##   so the view can render them as clickable jump targets.
## - The list of structured build errors (``BuildErrorLine`` seq) used
##   by the legacy Errors panel.
## - The list of problems (``BuildProblemLine`` seq) consumed by the
##   Problems panel.
## - The current build command (``command``), the active running flag
##   (``running``), the exit code from the last completed build
##   (``code``), the auto-scroll preference (``autoScroll``), and the
##   build start timestamp (``buildStartTime``).
##
## Derives:
## - ``status``: ``bsRunning`` while a build is in progress, ``bsFailed``
##   when the last build returned a non-zero exit code with output
##   present, ``bsSucceeded`` when the last build returned zero with
##   output present, and ``bsIdle`` otherwise.
##
## The VM has no auto-load effect: the legacy ``BuildComponent`` event
## handlers (``onBuildCommand`` / ``onBuildStdout`` / ``onBuildStderr``
## / ``onBuildCode``) feed the VM via the ``setCommand`` / ``appendLine``
## / ``setCode`` actions.  Mirrors the contract of the
## ``TerminalOutputVM``: events arrive through the legacy mediator
## subscriptions; the VM is a platform-neutral facade so headless tests
## under ``src/tests/gui/tests/views/isonim_views_test.nim`` can drive
## the full reactive flow without needing the JS-only ANSI splitter.
##
## Usage::
##
##   let vm = createBuildVM(store)
##   vm.setCommand("cargo build")
##   vm.appendLine(BuildOutputLine(htmlText: "Compiling foo", isStdout: true))
##   vm.setCode(0)
##   echo vm.output.val.len           # 1
##   echo vm.status.val               # bsSucceeded
##
## When the user clicks the Stop button, the view calls
## ``vm.cancelBuild()``.  The VM dispatches ``ct/build-cancel`` via the
## backend.  In production the legacy ``BuildComponent`` still listens
## on its IPC channel for actual cancellation; the VM exposing the same
## action keeps the signal flow self-contained for headless tests.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  BuildStatus* = enum
    ## Coarse build-status enum derived from running/code/output state.
    ## Drives the Karax-equivalent header text ("running ...", "build
    ## succeeded", "build failed (exit code N)") and the header CSS
    ## modifier classes (``build-failed`` / ``build-succeeded``).
    bsIdle       ## No build has run, or the panel was cleared.
    bsRunning    ## A build is currently in progress.
    bsSucceeded  ## Last build returned exit code 0 with output present.
    bsFailed     ## Last build returned a non-zero exit code with output.

  BuildVM* = ref object of ViewModel
    ## Reactive state for the Build panel.
    ##
    ## Mutable signals:
    ##   output           — stdout/stderr lines in arrival order.
    ##   errors           — structured build errors (path/line/message).
    ##   problems         — Problems-panel rows.
    ##   command          — the current build command string.
    ##   running          — true while the build is in progress.
    ##   code             — exit code of the last completed build (0
    ##                      when none).
    ##   autoScroll       — when true, the view scrolls the output
    ##                      container to the bottom after each append.
    ##   buildStartTime   — milliseconds-since-epoch timestamp; 0 when
    ##                      no build is running.
    ##
    ## Derived memos:
    ##   status           — coarse ``BuildStatus`` from the above flags.
    ##   isRunning        — convenience alias for ``status == bsRunning``.
    ##   hasOutput        — true when ``output`` is non-empty.
    store*: ReplayDataStore

    # -- Mutable state --
    output*: Signal[seq[BuildOutputLine]]
    errors*: Signal[seq[BuildErrorLine]]
    problems*: Signal[seq[BuildProblemLine]]
    command*: Signal[string]
    running*: Signal[bool]
    code*: Signal[int]
    autoScroll*: Signal[bool]
    buildStartTime*: Signal[float]

    # -- Derived state --
    status*: Memo[BuildStatus]
    isRunning*: Memo[bool]
    hasOutput*: Memo[bool]

    # -- Callbacks wired by the host (ui_js.nim) after VM creation --
    onJumpToLine*: proc(path: string; line: int)
      ## Open a diagnostic row's file at its line.
      ##
      ## The pane's own header has documented `click→jumpToLocation` on these
      ## rows since the Karax→IsoNim migration, `lineClass` still puts
      ## `build-clickable` on every row with a parsed location, and
      ## `styles/components/status_bar.styl:106` still gives that class a
      ## `cursor: pointer` and a hover underline. The handler was dropped in
      ## commit 20e24939 and never replaced, so the rows have looked clickable
      ## and done nothing since — and `real-compiler-errors.spec.ts` asserts
      ## the CLASS, by name, which passes over exactly that.
      ##
      ## No column: `BuildOutputLine` carries `locationPath` and
      ## `locationLine` only. The PROBLEMS pane's rows carry a column and
      ## navigate with it; this is the coarser of the two surfaces and says so
      ## rather than passing a zero that looks like a real answer.
    runBuild*: proc() ## Trigger a build-only (no re-record) action.
    cancelBuildProc*: proc()
      ## Stop the in-flight build, when the host has a way to.
      ##
      ## The pair of `runBuild`, and added for the same reason: the pane has
      ## one ■ and there is more than one thing that can be running behind it.
      ## `cancelBuild` below dispatches `ct/build-cancel` on the backend, which
      ## is the desktop `ct` process's channel — a browser tab has no such
      ## process, and its build is a wasm module in a Worker that stops by
      ## `worker.terminate()` and by nothing else.
      ##
      ## Nil on the desktop, where the backend dispatch is the right and only
      ## answer. A host that sets this is saying "I own the running thing",
      ## and the fallback below is skipped rather than also fired: sending
      ## `ct/build-cancel` into a browser's stub backend would resolve `{}` and
      ## make a Stop that did nothing look like one that worked.

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setCommand*(vm: BuildVM; command: string) =
  ## Set the active build command label.  Called by the legacy
  ## ``onBuildCommand`` handler.
  vm.command.val = command

proc setRunning*(vm: BuildVM; running: bool) =
  ## Toggle the running flag.  Used by the legacy onBuildCommand /
  ## onBuildCode handlers when the build starts and finishes.
  vm.running.val = running

proc setBuildStartTime*(vm: BuildVM; ms: float) =
  ## Set the build start timestamp.  ``0`` means no build is running.
  vm.buildStartTime.val = ms

proc setCode*(vm: BuildVM; code: int) =
  ## Record the exit code of the last completed build and flip the
  ## running flag to false.  Combines the two writes the legacy
  ## ``onBuildCode`` handler used to do separately so the derived
  ## ``status`` memo recomputes once instead of twice.
  vm.running.val = false
  vm.code.val = code

proc appendLine*(vm: BuildVM; line: BuildOutputLine) =
  ## Append a single rendered line to the output stream.
  ## Used by the legacy ``processBuildOutput`` after it has split the
  ## raw stdout/stderr chunk by newline and run ``parseBuildLocation``.
  var lines = vm.output.val
  lines.add(line)
  vm.output.val = lines

proc appendError*(vm: BuildVM; entry: BuildErrorLine) =
  ## Append a structured build error (used by the Errors panel).
  var entries = vm.errors.val
  entries.add(entry)
  vm.errors.val = entries

proc appendProblem*(vm: BuildVM; problem: BuildProblemLine) =
  ## Append a Problems-panel row.
  var entries = vm.problems.val
  entries.add(problem)
  vm.problems.val = entries

proc jumpToLine*(vm: BuildVM; line: BuildOutputLine) =
  ## Open the file a diagnostic row names, at the line it names.
  ##
  ## A no-op for a row with no parsed location — which is most of them, since
  ## every line of build output becomes a row and only the ones
  ## `parseBuildLocation` matched carry a path. The guard is here rather than
  ## in the view so that both renderer arms get it.
  if line.locationPath.len == 0 or line.locationLine <= 0:
    return
  if vm.onJumpToLine.isNil:
    return
  vm.onJumpToLine(line.locationPath, line.locationLine)

proc clearOutput*(vm: BuildVM) =
  ## Clear all output / errors / problems and reset the exit code so
  ## the panel returns to ``bsIdle``.  Mirrors the legacy clear-button
  ## handler in ``buildHeaderControls``.
  vm.output.val = @[]
  vm.errors.val = @[]
  vm.problems.val = @[]
  vm.code.val = 0

proc setAutoScroll*(vm: BuildVM; on: bool) =
  ## Set the auto-scroll preference.  The view re-scrolls to the
  ## bottom inside an effect that watches both ``output`` and
  ## ``autoScroll``.
  vm.autoScroll.val = on

proc toggleAutoScroll*(vm: BuildVM) =
  ## Flip the auto-scroll preference.
  vm.autoScroll.val = not vm.autoScroll.val

proc cancelBuild*(vm: BuildVM) =
  ## Ask the host that owns the running build to stop it.
  ##
  ## This used to fall back to ``vm.store.backend.send("ct/build-cancel")``
  ## when no host was installed, described in the comment above it as the
  ## "legacy IPC channel" that "production code also calls directly from the
  ## view". Both halves of that were wrong:
  ##
  ##   * ``ct/build-cancel`` is not an IPC channel. It went to the DAP
  ##     backend, and `backend/dap_dialect.md` §7 records it as one of nine
  ##     commands with no engine implementation — no arm in either dispatch
  ##     table in ``dap_server.rs``.
  ##   * No view calls any build-cancel channel directly. Searching the
  ##     renderer for one turns up ``cancelBuildAutoDismiss`` (which dismisses
  ##     a notification) and nothing else.
  ##
  ## So the fallback stopped nothing, and the view test asserting the dispatch
  ## passed over it.
  ##
  ## **Known product defect:** the only host that installs ``cancelBuildProc``
  ## is the web/Noir pane (``ui/web_noir_build.nim``, which terminates the
  ## Worker). On the desktop the field is nil, so ■ Stop currently does not
  ## stop a desktop build. Removing the dead dispatch does not cause that — it
  ## stops the code from claiming otherwise. Fixing it needs a real desktop
  ## cancellation path, which is a product decision and not a rename.
  if vm.cancelBuildProc.isNil:
    return
  vm.cancelBuildProc()

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createBuildVM*(store: ReplayDataStore): BuildVM =
  ## Create a BuildVM inside a reactive root owned by ``withViewModel``.
  ## The reactive root is disposed via ``vm.dispose()``.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults (no output, not running,
  ##    auto-scroll enabled to match the legacy default).
  ## 2. Derived memos for ``status``, ``isRunning``, and ``hasOutput``.
  withViewModel proc(dispose: proc()): BuildVM =
    let output = createSignal(newSeq[BuildOutputLine]())
    let errors = createSignal(newSeq[BuildErrorLine]())
    let problems = createSignal(newSeq[BuildProblemLine]())
    let command = createSignal("")
    let running = createSignal(false)
    let code = createSignal(0)
    let autoScroll = createSignal(true)
    let buildStartTime = createSignal(0.0)

    # Derived: coarse status, recomputed from running/code/output.
    let status = createMemo[BuildStatus] proc(): BuildStatus =
      if running.val:
        bsRunning
      elif output.val.len == 0:
        bsIdle
      elif code.val != 0:
        bsFailed
      else:
        bsSucceeded

    let isRunning = createMemo[bool] proc(): bool =
      status.val == bsRunning

    let hasOutput = createMemo[bool] proc(): bool =
      output.val.len > 0

    BuildVM(
      store: store,
      output: output,
      errors: errors,
      problems: problems,
      command: command,
      running: running,
      code: code,
      autoScroll: autoScroll,
      buildStartTime: buildStartTime,
      status: status,
      isRunning: isRunning,
      hasOutput: hasOutput,
      disposeProc: dispose,
    )
