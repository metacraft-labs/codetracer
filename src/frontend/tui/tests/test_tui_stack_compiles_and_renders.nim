## test_tui_stack_compiles_and_renders.nim — CTUI-0.
##
## ## The premise this file exists to keep true
##
## The whole TUI campaign rests on one claim: `isonim_tui`'s terminal renderer
## and CodeTracer's entire ViewModel graph co-compile and co-run **in one
## process, on the Nim C backend, with no serialization between them**. That was
## established by a throwaway probe — a file importing both, mounting a
## `TerminalTestHarness`, rendering, and constructing a `DebuggerSession` — and
## a throwaway probe protects nothing. This is that probe, promoted, so the
## premise fails the moment it stops holding rather than the moment somebody
## next tries to build a pane.
##
## It is therefore as much a LINK test as a behaviour test. Most of what can
## break here breaks before `main` runs: a Yoga submodule that was never
## initialised, a grammar archive that was never built, a `-ltree-sitter` the
## host cannot resolve, an ORC-vs-refc mismatch between the two halves. All of
## those present as a compile or link failure of this file, which is why the
## lane compiles and runs it as separate steps — see
## ci/lib/run-nim-test-lane.sh's header on why conflating them loses the one
## line that names the cause.
##
## ## WHY `MockBackendService` IS PERMITTED HERE, AND ONLY HERE
##
## The mocking policy for this campaign is in
## CodeTracer-TUI.milestones.org §"Mocking policy": no mocks of ViewModels or
## trace engines, tests load real `.ct` containers driven by a real
## `replay-server`. `MockBackendService` is admitted in EXACTLY this file, and
## the justification is that the assertion here is about the **type graph
## linking**, not about debugger behaviour:
##
##   * `newDebuggerSession` is passive — it sends nothing — so a real backend
##     would add a spawned `replay-server` process, a DAP handshake and a trace
##     folder to an assertion that is entirely about whether the two halves of
##     the binary resolve each other's symbols;
##   * and it would make the failure modes indistinguishable. If this file
##     linked against a real backend and went red, "the renderer and the
##     ViewModel layer no longer co-compile" and "replay-server is not built on
##     this host" would look identical from the outside — and the second is the
##     common case, so the first would be assumed away.
##
## No pane test may use it. CTUI-1 delivers the fixture corpus and every
## milestone after it asserts against real recordings.

import std/[os, strutils, unicode, unittest]

import isonim_tui
import codetracer_embed

import ../app/tui_app
import ../app/cli

# THE HOST LAYER, COMPILED HERE ON PURPOSE.
#
# `just build-tui` compiles `host/` only under `--mm:orc -d:release`, and
# CTUI-0 asks for both that configuration AND the default debug flags the test
# lane uses. Importing it here is what gives the second arm a compile — and it
# is legitimate from a test, which is not `app/` and carries no
# `.sdk-consumer` marker: the rule this campaign enforces is that the
# APPLICATION layer cannot reach a process, not that nothing may.
import ../host/native_host

# The product version the TUI reports. Imported here as well as in `app/cli.nim`
# so the assertion below compares two independent readings of it rather than
# comparing the CLI module against itself.
import ../../../ct/version

const ExpectedAssertions = 32

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc rowText(h: TerminalTestHarness; row, width: int): string =
  ## The runes on one screen row, as a string. Reads the composited buffer
  ## through the harness's public accessor, which is the same surface CTUI-2's
  ## cross-tier equivalence will compare against a real terminal.
  result = ""
  for col in 0 ..< width:
    result.add($h.cellAt(row, col).rune)

suite "CTUI-0: the terminal renderer and the ViewModel graph in one process":

  test "an app/ view composites onto a real ScreenBuffer":
    let h = newTerminalTestHarness(60, 4)
    let app = newTuiApp()
    h.mount(proc(r: TerminalRenderer): TerminalNode = app.renderShell(r))

    # The known rune at the known cell. `statusLine` starts with the app title,
    # so cell (0,0) is 'C' — asserted as a rune from the composited buffer, not
    # as a string the test built itself.
    checkpoint("row 0: '" & rowText(h, 0, 60).strip() & "'")
    ck $h.cellAt(0, 0).rune == "C"

    # And the whole line, so a compositor that painted one cell and stopped
    # cannot pass. `statusLine` is a pure function of the app's state, which is
    # what makes this comparable at all — the model side and the screen side
    # are asserted against each other rather than both against a literal.
    ck rowText(h, 0, 60).strip() == app.statusLine()
    ck app.statusLine().startsWith("CodeTracer TUI")
    ck app.statusLine().contains("sessions:0")

    # The paint really did reach the driver.
    ck h.bytesEmitted().len > 0
    h.dispose()
    app.dispose()

  test "a DebuggerSession and its ViewModel graph instantiate beside it":
    let h = newTerminalTestHarness(60, 4)
    let app = newTuiApp()

    # The mock is the injected BackendService — see this file's header for why
    # it is admitted here and nowhere else.
    let backend = newMockBackendService()
    let slot = app.openSession(backend.toBackendService(), title = "probe")

    ck app.sessionCount() == 1
    ck slot != nil
    ck slot.title == "probe"
    ck app.shell.activeSessionId() == slot.id

    # The graph the SDK builds. Each of these is a distinct module in the
    # ViewModel layer, and reaching them from a binary that also links the
    # terminal compositor is the entire claim this file makes.
    ck slot.session != nil
    ck slot.session.phase.val == dspCreated
    ck slot.session.session != nil
    ck slot.session.store != nil
    ck slot.session.backend != nil

    # The layout model the desktop uses, in the terminal front-end's process.
    # CTUI-3 projects this same tree onto Yoga; asserting it is populated now
    # is what makes that a projection rather than a new model.
    ck slot.layout != nil
    ck slot.layout.validate().len == 0
    ck slot.visiblePanes().len > 0

    # And the two halves are live at the same time: re-render after opening a
    # session and the screen reports the new state. A binary in which the
    # renderer and the ViewModel layer merely COEXISTED would still pass every
    # assertion above; this one needs them to compose.
    h.mount(proc(r: TerminalRenderer): TerminalNode = app.renderShell(r))
    checkpoint("row 0 after openSession: '" & rowText(h, 0, 60).strip() & "'")
    ck rowText(h, 0, 60).contains("sessions:1")
    ck rowText(h, 0, 60).contains("active:" & $slot.id)

    h.dispose()
    app.dispose()
    ck app.shell.isDisposed()

  test "the entrypoint's command surface is --help and --version only":
    # `main.nim` is the wiring between `host/` and `app/`, and what it wires at
    # this milestone is exactly this. Asserted here rather than by running the
    # binary because the answer is a value: `parseTuiCommand` performs no I/O,
    # which is the property that makes the whole command surface testable
    # without a terminal.
    ck parseTuiCommand([]).kind == tckHelp
    ck parseTuiCommand(["--help"]).kind == tckHelp
    ck parseTuiCommand(["-v"]).kind == tckVersion
    ck parseTuiCommand(["--nonesuch"]).kind == tckUsageError
    ck parseTuiCommand(["/some/trace"]).tracePath == "/some/trace"
    ck TuiVersionText.contains(CodeTracerVersionStr)

  test "the host layer answers about the filesystem, and never by exception":
    # `host/` is the one directory outside the facade, and its whole job at
    # this milestone is to turn a typed path into either an absolute folder or
    # a message a user can act on. Both halves are asserted, because a resolver
    # that raised on everything would satisfy the failure cases alone.
    var raisedOnEmpty = false
    try:
      discard resolveTraceFolder("")
    except TuiHostError:
      raisedOnEmpty = true
    ck raisedOnEmpty

    var missingMsg = ""
    try:
      discard resolveTraceFolder(getTempDir() / "ctui0-no-such-trace-folder")
    except TuiHostError as e:
      missingMsg = e.msg
    ck missingMsg.contains("no such trace folder")

    let scratch = normalizedPath(
      getTempDir() / ("ctui0-host-probe-" & $getCurrentProcessId()))
    removeDir(scratch)
    createDir(scratch)
    try:
      # THE ACTUAL CONTRACT, asserted rather than restated: `app/cli.nim`
      # returns the path exactly as typed and does no I/O, so resolving a
      # RELATIVE path against the process's working directory is this layer's
      # job. Comparing `resolveTraceFolder(abs)` with `absolutePath(abs)` would
      # have been a tautology — both are the identity on an absolute path.
      let saved = getCurrentDir()
      try:
        setCurrentDir(scratch.parentDir)
        ck normalizedPath(resolveTraceFolder(scratch.lastPathPart)) == scratch
      finally:
        setCurrentDir(saved)

      let notAFolder = scratch / "not-a-folder"
      writeFile(notAFolder, "")
      var fileMsg = ""
      try:
        discard resolveTraceFolder(notAFolder)
      except TuiHostError as e:
        fileMsg = e.msg
      ck fileMsg.contains("is a file")
    finally:
      removeDir(scratch)

    # `findReplayServer` is TOTAL: "" or a path that exists, never an
    # exception. CTUI-1's fixture provider depends on that, because it has to
    # report an absent backend as a named, counted prerequisite rather than
    # catch something.
    let bin = findReplayServer()
    checkpoint("replay-server: '" & bin & "'")
    ck (bin.len == 0 or fileExists(bin))
    ck replayServerRemedy().contains("cargo build")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
