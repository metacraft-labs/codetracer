## test_edit_mode_build.nim — PLAT-16, Tier 1.
##
## `:build`, `:run`, their verdicts, and the cancellation
## CodeTracer-TUI-Edit-Mode.md §5 makes a requirement:
## *"A build that hangs must be cancellable. `DapReadBound`'s clock-and-interrupt
## pattern is the precedent and the requirement."*
##
## ## THE STATE THIS MILESTONE ADDED, AND WHY IT IS NOT `bvFailed`
##
## §5 says the verdict states "are not repeated here" — they are the core's
## `build_vm.BuildStatus`. `BuildVerdict` is those four PLUS `bvCancelled`, and
## the first case below is what makes that addition mean something: a cancelled
## process exits non-zero, so a `finish` that read only the exit code would
## report `bvFailed` and tell the user their code is broken when what happened
## is that they stopped the build. Verification-Harness-Traps §5a is the rule —
## *"a repair that gives an existing return value a new reason merges two
## events"* — and this file is where the two events are held apart.
##
## ## THE DEADLINE IS NOT A CANCELLATION EITHER
##
## Two bounds, two users, two verdicts: a user who pressed the cancel key gets
## `bvCancelled`; a session nobody was watching that ran past its budget gets
## `bvFailed` with the budget named in the output. Collapsing them would tell a
## user they stopped something they did not.
##
## ## No mocks
##
## The state machine and the pane are the product's. The `EditServices` closures
## are the HOST — the same category as CTUI-10's `CommandServices` — and each
## records what it was asked, so what is asserted is what the runtime
## REQUESTED rather than what a fake returned. No compiler is needed here:
## `host/build_runner.nim`'s PROCESS is graded by
## `tests/test_build_runner_process.nim`, which spawns real children —
## including one that says nothing for three seconds, which is the case this
## file structurally cannot see and which caught a `drain` that blocked the
## whole front-end while claiming in its own docstring that it did not.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, unittest]

# `product_mode` — `ProductMode`, `sourceOriginFor`, the stale-trace verdict
# and `slugOfPreservedRow` — comes from the CORE through the sanctioned facade,
# which is the same door the modules under test use.
import codetracer_embed

import ../build_session
import ../edit_binding
import ../runtime
import ../theme/capabilities
import ../views/build_output
import ../views/shell

const ExpectedAssertions = 76

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 40
  FileA = "src/alpha.nim"
  TextA = "proc alpha() =\n  echo 1\n"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc editingRuntime(): TuiRuntime =
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession()
  discard app.editSession.openFile(FileA, TextA)
  newTuiRuntime(app, caps(), Cols, Rows)

proc statusRow(rt: TuiRuntime): string =
  strutils.strip(rt.shellScreenOf().rows[^1], leading = false)

# ---------------------------------------------------------------------------

suite "PLAT-16 §5: the verdict states, and the one this milestone added":

  test "cancellation is a verdict of its own, and the exit code does not decide it":
    # A cancelled process exits non-zero. `finish` must not read that as a
    # failure of the code.
    let cancelled = newBuildSession(bkBuild, "just build", 0)
    cancelled.start(0)
    ck cancelled.verdict == bvRunning
    cancelled.requestCancel()
    ck cancelled.cancelRequested
    cancelled.finish(143)                 # SIGTERM's 128 + 15
    ck cancelled.verdict == bvCancelled
    ck cancelled.verdict != bvFailed

    # THE CONTROL: the SAME non-zero exit code without a cancellation IS a
    # failure. Without this the assertion above is satisfied by a `finish` that
    # answers `bvCancelled` for everything.
    let failed = newBuildSession(bkBuild, "just build", 0)
    failed.start(0)
    failed.finish(143)
    ck failed.verdict == bvFailed
    ck failed.exitCode == 143

    let ok = newBuildSession(bkRun, "just run", 0)
    ok.start(0)
    ok.finish(0)
    ck ok.verdict == bvSucceeded

    # …and a cancel REQUESTED after the process ended does not resurrect it:
    # the flag is read by `finish`, which has already run.
    ok.requestCancel()
    ck ok.verdict == bvSucceeded

  test "the core's four states are reachable and the fifth maps onto idle":
    # `statusOf` is the lossy direction and the only one that exists, so the
    # distinction cannot be lost by a round trip.
    ck statusOf(bvIdle) == bsIdle
    ck statusOf(bvRunning) == bsRunning
    ck statusOf(bvSucceeded) == bsSucceeded
    ck statusOf(bvFailed) == bsFailed
    # `bvCancelled` is `bsIdle` and NOT `bsFailed`: `build_vm` documents
    # `bsFailed` as a claim about the code, and a cancelled build makes none.
    ck statusOf(bvCancelled) == bsIdle
    ck statusOf(bvCancelled) != bsFailed
    # Every core state is the image of something, so the mapping is onto.
    var images: seq[BuildStatus] = @[]
    for v in BuildVerdict:
      if statusOf(v) notin images:
        images.add statusOf(v)
    ck images.len == 4

  test "the deadline is a bound and is NOT reported as a cancellation":
    let s = newBuildSession(bkBuild, "sleep 1d", 1000, deadlineMs = 5000)
    s.start(1000)
    ck not s.expired(5999)
    ck s.expired(6001)
    # An UNSTARTED session never expires, and neither does a finished one —
    # otherwise a deadline would keep firing after the verdict was settled.
    let idle = newBuildSession(bkBuild, "x", 0, deadlineMs = 1)
    ck not idle.expired(1_000_000)
    s.finish(0)
    ck not s.expired(1_000_000)
    # A zero deadline means NO deadline, which is what an interactive session
    # with a cancel key can afford.
    let unbounded = newBuildSession(bkBuild, "x", 0, deadlineMs = 0)
    unbounded.start(0)
    ck not unbounded.expired(1_000_000_000)

  test "output is capped and the cap is REPORTED":
    let s = newBuildSession(bkBuild, "x", 0)
    s.start(0)
    for i in 1 .. MaxBuildLines:
      s.appendLine("line " & $i)
    ck s.lines.len == MaxBuildLines
    ck not s.truncated
    ck s.lines[0] == "line 1"
    s.appendLine("overflow")
    ck s.lines.len == MaxBuildLines
    # THE OLDEST WENT, AND THE PANE IS TOLD. A pane that silently lost the
    # first thousand lines would hide the first error, which is the only line
    # that matters.
    ck s.truncated
    ck s.lines[0] == "line 2"
    ck s.lines[^1] == "overflow"

suite "PLAT-16 §5: the verdict is in a PANE, in words and in colour":

  test "each verdict has its own colour, and no two share one":
    var colours: seq[string] = @[]
    var verdicts = 0
    for v in BuildVerdict:
      inc verdicts
      let style = verdictStyle(v)
      checkpoint($v & " -> " & style.fg)
      ck style.fg.len > 0
      ck style.fg notin colours
      colours.add style.fg
    ck verdicts == 5
    ck colours.len == 5

  test "the pane says the verdict in words, and paints the output":
    let s = newBuildSession(bkBuild, "just build", 0)
    s.start(0)
    s.appendLine("src/alpha.nim(2, 3) Error: undeclared identifier: 'ehco'")
    s.finish(1)
    ck s.verdict == bvFailed
    let model = buildPaneModelFor(s)
    var g = newStyledGrid(Cols, Rows)
    let screen = paintBuildOutput(
      g, CellArea(col: 0, row: 0, width: 90, height: 6), model)
    var text = ""
    for row in 0 ..< 6:
      text.add g.rowText(row) & "\n"
    checkpoint(text)
    ck screen.renderedLines == 1
    ck text.contains(BuildPaneTitle)
    ck text.contains("[failed]")
    ck text.contains("just build")
    ck text.contains("exit 1")
    ck text.contains("undeclared identifier")
    # AND THE COLOUR IS ON THE TITLE CELL, so a Tier-2 `cellAt` read can say
    # which verdict it is looking at without reading a glyph.
    ck g.styleAt(0, 0).fg == verdictStyle(bvFailed).fg
    ck g.styleAt(0, 0).fg != verdictStyle(bvSucceeded).fg

  test "an idle pane is a statement rather than a blank":
    # `shell.paintPane` has no emptiness guard on this pane, deliberately: a
    # user who has just pressed `:build` needs to see the verdict change, and a
    # pane that painted a generic title until the first byte of output arrived
    # would show nothing for the whole of a cold compile.
    let model = buildPaneModelFor(nil)
    var g = newStyledGrid(Cols, Rows)
    discard paintBuildOutput(g, CellArea(col: 0, row: 0, width: 60, height: 3),
                             model)
    let row0 = g.rowText(0)
    checkpoint(row0)
    ck row0.contains(BuildPaneTitle)
    ck row0.contains("[idle]")
    ck row0.contains("no build has been run")

  test "the error heuristic offers lines and hides none":
    let s = newBuildSession(bkBuild, "x", 0)
    s.start(0)
    for line in ["compiling alpha.nim",
                 "src/alpha.nim(2, 3) Error: undeclared identifier",
                 "note: this is fine",
                 "beta.c:9:1: warning: unused variable"]:
      s.appendLine(line)
    let offered = s.errorLines()
    checkpoint("offered: " & offered.join(" | "))
    ck offered.len == 2
    ck offered[0].contains("undeclared identifier")
    ck offered[1].contains("unused variable")
    # IT DECIDES WHAT IS OFFERED, NEVER WHAT IS SHOWN: every line is still in
    # `lines`, so a diagnostic the heuristic misses is one the user scrolls to
    # rather than one they never see.
    ck s.lines.len == 4
    ck "note: this is fine" in s.lines

suite "PLAT-16 §5: `:build`, `:run` and `:cancel` on the prompt":

  test "the verbs reach the host seam, and only in Edit mode":
    let rt = editingRuntime()
    var asked: seq[string] = @[]
    rt.editServices.startBuild = proc(kind: BuildKind;
                                      command: string): BuildStartResult =
      asked.add $kind & ":" & command
      rt.app.build = newBuildSession(kind, command, 0)
      rt.app.build.start(0)
      BuildStartResult(ok: true, message: $kind & " started: " & command)

    var outcome = RuntimeOutcome()
    discard rt.prompt.open(pkCommand)
    for ch in ":build just build":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    checkpoint("asked: " & asked.join(", "))
    ck asked == @["build:just build"]
    ck not rt.app.build.isNil
    ck rt.app.build.verdict == bvRunning
    ck statusRow(rt).contains("build started")

    # A SECOND ONE IS REFUSED WHILE THE FIRST RUNS. Two compilers writing into
    # one pane produce interleaved output that belongs to neither.
    discard rt.prompt.open(pkCommand)
    for ch in ":run ./a.out":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    ck asked.len == 1
    ck statusRow(rt).contains("already running")

    # `:cancel` SETS THE FLAG rather than killing anything: `app/` does not own
    # the process, and the host's poll loop is what reads this.
    discard rt.prompt.open(pkCommand)
    for ch in ":cancel":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    ck rt.app.build.cancelRequested
    ck statusRow(rt).contains("cancelling")

    # …AND IN DEBUG MODE THE SAME LINE IS THE UNKNOWN COMMAND IT HAS ALWAYS
    # BEEN. This is the control for "the verbs are a prefix on the Edit path"
    # rather than a seventeenth row of §4.3's published table.
    let debugRt = editingRuntime()
    debugRt.app.modes = initModeRegister(pmDebug)
    debugRt.editServices.startBuild = proc(kind: BuildKind;
                                           command: string): BuildStartResult =
      asked.add "SHOULD-NOT-HAPPEN"
      BuildStartResult(ok: true)
    discard debugRt.prompt.open(pkCommand)
    for ch in ":build just build":
      discard debugRt.prompt.applyKey($ch, @[])
    discard debugRt.handleToken("\r", 0)
    ck asked.len == 1
    ck debugRt.app.build.isNil

  test "a missing runner is reported, not a crash":
    # A nil seam is the state a Debug-only session is in, and `:build` says so
    # rather than raising.
    let rt = editingRuntime()
    discard rt.prompt.open(pkCommand)
    for ch in ":build just build":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    checkpoint(statusRow(rt))
    ck statusRow(rt).contains("no runner")
    ck rt.app.build.isNil
    # …and so is a verb with no argument.
    discard rt.prompt.open(pkCommand)
    for ch in ":build":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    ck statusRow(rt).contains("needs a command")

  test "`:w` writes through the host seam and clears the dirty marker":
    let rt = editingRuntime()
    var written: seq[string] = @[]
    rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
      written.add relative & "=" & text
      EditWriteResult(ok: true)
    discard rt.focus.focusPaneKind(paneEditor)
    discard rt.handleToken("Z", 0)
    let buf = rt.app.editSession.activeBuffer()
    ck buf.isDirty
    discard rt.prompt.open(pkCommand)
    for ch in ":w":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    checkpoint("written: " & written.join(", "))
    ck written.len == 1
    ck written[0].startsWith(FileA & "=")
    ck written[0].contains("Z")
    ck not buf.isDirty
    # THE TWO PREDICATES PART HERE, AND THAT IS THE POINT. `isDirty` is "there
    # is unsaved work" and drives the `[+]` marker; `outrunsRecording` is "this
    # file has moved off what the recording saw" and drives the staleness
    # notice. They were ONE comparison until PLAT-16's landing pass, and
    # `markSaved` answering the first one `false` silently answered the second
    # one `false` too — Verification-Harness-Traps §5a, with the dangerous
    # event read as the benign one.
    ck buf.outrunsRecording
    ck rt.app.editSession.editedPaths == @[FileA]
    # …AND THE LIST IS NOT THE CLAIM. `editedPaths` was `@[FileA]` here even
    # while the defect was live — it is pruned at the moment of the SWITCH, not
    # at the save — so this line was green over a product that had stopped
    # telling the user anything. The effect is asserted where a user meets it,
    # in `test_edit_mode_source.nim`'s "a saved edit is still an edit the
    # recording predates", and through the shipped binary in
    # `tests/real_terminal/test_real_edit_mode.nim`.

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
