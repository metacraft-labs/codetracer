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
  ## Dispatch a build-cancel request via the backend.  Production code
  ## also calls the legacy IPC channel directly from the view; the VM
  ## exposing the same action keeps the signal flow self-contained for
  ## headless tests.
  discard vm.store.backend.send("ct/build-cancel", %*{})

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
