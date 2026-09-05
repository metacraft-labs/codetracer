## test_ipc_settled_frame.nim — CTUI-2, the determinism half.
##
## ## What the IPC channel replaces
##
## `waitForText("line 42", 5s)` races by construction: it passes on a partially
## painted frame that happens to contain the needle, and when it fails it fails
## as a timeout, which is a symptom rather than a diagnosis
## (codetracer-specs/Testing/Verification-Harness-Traps.md §3). TermAssert
## hosts a Unix socket, passes `$TERM_ASSERT_URI` to the child, and records
## whatever the child asks it to record under a label — so the frame the test
## asserts on is the frame the APPLICATION declared final.
##
## This suite asserts three things about that, and the third is the one the
## milestone singles out.
##
##   1. The label arrives, and the frame recorded under it EQUALS the frame the
##      in-process harness composited from the same tree. A label that arrived
##      carrying a half-painted screen would satisfy "the label arrived" and
##      nothing else, so the equality is what makes the arrival mean something.
##   2. A child that never emits the label fails as "LABEL NEVER ARRIVED",
##      naming the label, the labels that DID arrive, whether the child is
##      still alive and what is on its screen — never as a bare timeout.
##   3. A MISWIRED SOCKET is a third, separately reported state. Without it,
##      "label never arrived" would cover both "the child chose not to ask" and
##      "the child could not have asked", which is the two-states-for-three
##      problem the traps document is about.
##
## ## The race this suite would have had, and how it is closed
##
## The pty and the IPC socket are two unordered channels, and TermAssert's
## `pump` services IPC BETWEEN 4096-byte reads of the pty. A child that
## requested a screenshot immediately after painting would be serviced with the
## tail of its own paint still unread, and the harness would record a partial
## frame — silently, and more often on the larger geometry.
##
## So the child waits to be asked. The parent reaches the cursor barrier first
## (which proves it has consumed the whole frame), then sends one byte, and
## only then does the child call `requestScreenshot`. What the child still owns
## is the decision to ANSWER, which is what `--never-settle` withholds and what
## arm 2 measures. No sleep anywhere.

import std/[options, os, osproc, posix, strutils, times, unittest]

import term_assert

import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_ipc_settled as ipcApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a runtime assertion count.
const ExpectedAssertions = 36

const
  Cols = 80
  Rows = 24
  Label = "settled-frame"
  Stem = "app_ipc_settled"

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "CTUI-2: the IPC settled frame":

  test "the child under --test-ipc records a frame equal to the harness's":
    compileChildApp(Stem)
    var sess = newTuiTest(appBinaryPath(Stem),
                          @["--cols=" & $Cols, "--rows=" & $Rows,
                            "--test-ipc", "--label=" & Label])
      .width(Cols).height(Rows)
      .spawn()
    try:
      # The channel is real before anything is asserted through it: a socket
      # path that did not exist would make every claim below vacuous.
      let sock = sess.ipcSocketPath()
      checkpoint("TERM_ASSERT_URI: " & sock)
      ck sock.len > 0
      # `stat`, not `fileExists`: a bound AF_UNIX socket is not a regular file
      # and `os.fileExists` answers false for one. Asserting it is a SOCKET is
      # also the stronger claim — a stale regular file left at that path would
      # satisfy "the name exists" and refuse every connect.
      var sockStat: Stat
      ck stat(sock.cstring, sockStat) == 0
      ck S_ISSOCK(sockStat.st_mode)

      waitForCompleteFrame(sess, Cols, Rows)
      # Nothing has been recorded yet — the child has painted and is waiting to
      # be asked. This is the positive control for arm 2: it establishes that
      # "no labels recorded" is the state BEFORE the request, so arm 2's
      # emptiness is a refusal rather than a race the parent won.
      ck sess.snapshots().len == 0

      sess.send($TestAppCaptureByte)
      let snap = waitForSnapshotLabel(sess, Label)
      ck snap.label == Label
      ck snap.rows == Rows
      ck snap.cols == Cols

      # THE FRAME THE CHILD DECLARED FINAL, CELL FOR CELL AGAINST THE HARNESS.
      # `ScreenSnapshot.cellmap` is written by the same `renderCellmap` that
      # produces `cellmap.json`, so it goes through the same parser and the
      # same comparison the equivalence suite uses.
      let recorded = parseCellmap(snap.cellmap)
      let reference = harnessCanonFor(ipcApp.buildTree, Cols, Rows,
                                      "ipc-settled-reference")
      let divergences = compareCanon(reference, recorded)
      if divergences.len > 0:
        checkpoint(describe(divergences[0]))
        checkpoint(renderExclusions())
      ck divergences.len == 0
      # And the frame is not empty — an all-blank screen would satisfy the
      # equality above for free if the harness were blank too.
      let painted = countCellsWhere(recorded, proc(c: CanonCell): bool =
        c.rune != " " and c.rune.len > 0)
      checkpoint("painted cells in the labelled frame: " & $painted)
      ck painted > 100
      ck recorded.dialect == "tier2-libvterm"

      # The marker the app paints, read out of the labelled frame's own text,
      # so a reader of a failure can see WHICH frame was recorded.
      checkpoint("labelled screen: " & snap.contents.strip())
      ck snap.contents.contains(ipcApp.SettledMarker)

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "NEGATIVE ARM: a child that never emits the label fails as such":
    # `--never-settle`: the child connects, paints, parks the cursor, hears the
    # capture request and DECLINES. The failure must be "label never arrived",
    # with enough attached state to tell it apart from a hang — because the
    # natural reaction to a bare timeout is to raise the timeout, which is the
    # wrong move for every cause this can have.
    compileChildApp(Stem)
    var sess = newTuiTest(appBinaryPath(Stem),
                          @["--cols=" & $Cols, "--rows=" & $Rows,
                            "--test-ipc", "--never-settle",
                            "--label=" & Label])
      .width(Cols).height(Rows)
      .spawn()
    var raised = ""
    try:
      # The frame barrier passes, which is the whole point: the child IS alive,
      # IS connected and HAS painted. Only the label is missing.
      waitForCompleteFrame(sess, Cols, Rows)
      ck sess.isAlive
      sess.send($TestAppCaptureByte)
      try:
        discard waitForSnapshotLabel(sess, Label, timeoutMs = 2000)
      except DualSnapError as e:
        raised = e.msg
      checkpoint("failure message: " & raised)
      # THE DIAGNOSIS, not a timeout.
      ck raised.len > 0
      ck raised.contains("label never arrived")
      # By name, so a suite with several labels in flight says which one.
      ck raised.contains(Label)
      # The three facts that separate this state from a hang and from a
      # miswired socket: nothing was recorded, and the child is still running.
      ck raised.contains("Labels recorded: []")
      ck raised.contains("child alive=true")
      # And the screen is quoted, which is where a child that had crashed or
      # printed a connect error would show it.
      ck raised.contains(ipcApp.SettledMarker)
      ck sess.snapshots().len == 0
      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "NEGATIVE ARM: a miswired socket is a different failure again":
    # The third state. `TERM_ASSERT_URI` points nowhere, so the child cannot
    # connect at all — and it says so, before painting, with a non-zero exit
    # code of its own. Reported separately from "label never arrived" because
    # folding the two together is how a plumbing defect gets diagnosed as an
    # application defect.
    #
    # Run without a pty deliberately: the child fails before it would paint, so
    # a terminal adds nothing, and driving it through `execCmdEx` reads the
    # exit status directly rather than through the harness under test.
    compileChildApp(Stem)
    let bogus = dualSnapWorkDir() / "no-such-harness.sock"
    removeFile(bogus)
    ck not fileExists(bogus)
    let cmd = "TERM_ASSERT_URI=" & bogus.quoteShell & " " &
              appBinaryPath(Stem).quoteShell & " --test-ipc"
    let (output, code) = execCmdEx(cmd)
    checkpoint("exit " & $code & ", output: " & output.strip())
    ck code == TestAppExitIpc
    ck output.contains("TERM_ASSERT_URI connect failed")
    ck output.contains(bogus)
    # The positive twin, through the same binary and the same code path: with
    # the variable EMPTY the client reports the empty-URI case instead, so the
    # message above is about the path rather than about the flag.
    let (emptyOut, emptyCode) = execCmdEx(
      "TERM_ASSERT_URI= " & appBinaryPath(Stem).quoteShell & " --test-ipc")
    checkpoint("empty-URI exit " & $emptyCode & ": " & emptyOut.strip())
    ck emptyCode == TestAppExitIpc
    ck emptyOut.contains("TERM_ASSERT_URI is empty")

  test "the test-only flag surface is the runtime's, and it is closed":
    # `--test-ipc` is parsed HERE, in test-only code, and nowhere else. The
    # complementary halves — that `app/cli.parseTuiCommand` refuses it, that
    # `TuiHelpText` does not mention it, and that no module under `testing/` is
    # reachable from `main.nim` — are asserted by
    # `src/frontend/tui/tests/test_tui_build_prerequisites.nim`, which is the
    # file CTUI-2 names for that job.
    ck parseTestAppArgs(["--test-ipc"]).testIpc
    ck not parseTestAppArgs([]).testIpc
    ck parseTestAppArgs(["--label=x"]).label == "x"
    ck parseTestAppArgs([]).label == DefaultTestAppLabel
    ck parseTestAppArgs(["--test-ipc", "--never-settle"]).settle == false
    ck parseTestAppArgs([]).settle
    # `--never-settle` without `--test-ipc` is refused: a run that asked for
    # the negative arm and got a plain snapshot app would look like a passing
    # positive arm.
    var refused = ""
    try:
      discard parseTestAppArgs(["--never-settle"])
    except TestAppUsageError as e:
      refused = e.msg
    ck refused.contains("only meaningful with --test-ipc")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
