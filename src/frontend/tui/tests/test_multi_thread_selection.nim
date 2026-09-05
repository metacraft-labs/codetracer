## test_multi_thread_selection.nim — CTUI-6, and it is the milestone's ONE
## gated case.
##
## ## What this file is
##
## CTUI-6 names `app/views/thread_selector.nim` and this suite, and its own risk
## mitigation says what happens if the `threads` fixture proves unobtainable:
## *"the thread selector is cut from CTUI-6 and tracked as its own blocked item,
## rather than being counted as delivered."*
##
## **THE RISK LANDED, AND THE SELECTOR IS CUT.** There is no
## `app/views/thread_selector.nim` in this tree. This file is what replaces it:
## a counted, named `MISSING-PREREQ SKIP` for the selection case, and — beside
## it — a case that MEASURES the limitation on every run against a fixture that
## does exist, so the blocker is re-established by the lane rather than quoted
## from a document.
##
## ## Why a skip is sanctioned here and nowhere else
##
## `docs/tui-testing.md`'s rule 1: "No skipped tests for a missing prerequisite…
## The one sanctioned exception is the fixture corpus's counted
## `MISSING-PREREQ SKIP:` — and an all-skipped run fails the lane." The `threads`
## fixture is DECLARED in `fixtures/fixture_provider.nim`'s `DeclaredFixtures`
## with a non-empty `blockedOn`, so resolving it is already a named skip. This
## suite inherits that name; it does not invent a second silence.
##
## The skip arm still asserts, and the second case makes the suite non-vacuous:
## it opens a REAL trace and reads DAP `threads` back, so the run reports the
## number the engine gives rather than the number this file expects. **The day
## the engine grows a per-thread surface, that case goes red** — which is
## exactly the signal that unblocks the selector, and it is the reason the case
## asserts `== 1` rather than `<= 1`.
##
## ## What was verified, and by whom, and when
##
## Re-verified for CTUI-6 on 2026-09-05, by measurement and by reading, not by
## reference to CTUI-1:
##
##   * DAP `threads` on `calc`, `wide_state` and `noir_space_ship` each answers
##     `{"threads":[{"id":1,"name":"<thread 1>"}]}` — one entry.
##   * `ReplaySession::list_processes` — the trait method the `threads` request
##     goes through — has exactly TWO implementations in `src/db-backend/`: the
##     trait default at `replay.rs:238`, which returns one synthetic
##     `ProcessInfo { pid: 0, command: "main" }` unconditionally and is the arm
##     every CTFS trace takes, and `recreator_session.rs:1068`, which forwards
##     `GetProcessInfo` to the rr worker — a PROCESS table. (A `grep` for
##     `fn list_processes` finds a third hit, `session_handler.rs:289`; that is
##     a different, inherent function serving `ct/listProcesses`, and the only
##     thread provider passed to it — `dap_server.rs:893` — hard-codes
##     `(1, "<thread 1>")`, so it reinforces the finding rather than qualifying
##     it.)
##   * `dap_handler.rs:6285`'s `threads` maps one DAP `Thread` per PROCESS, and
##     says so in its own comment.
##
## ## No mocks

import std/[json, strutils, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/replay_data_store

import ../app/call_stack_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 18

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  BlockedFixture = "threads"
  AvailableFixture = "calc"
    ## A fixture that DOES resolve, so the limitation is measured rather than
    ## inferred from the blocked one's absence.

  ChecksSkipArm = 6
  ChecksMeasuredArm = 9
  ChecksSummary = 3

var
  skipArmRan = false
  measuredArmRan = false
  reportedThreads = -1

proc threadsBody(session: HeadlessDebugSession): JsonNode =
  session.sendRawDapRequest("threads", %*{}).getOrDefault("body")

suite "CTUI-6: the thread selector is blocked on the recorder":

  test "multi-thread selection: MISSING-PREREQ SKIP, by name":
    ## CTUI-6: "switching threads updates frames and source together. If
    ## `threads` is unavailable this reports `MISSING-PREREQ SKIP` naming the
    ## recorder, and the milestone's status records the thread selector as
    ## unverified rather than done."
    ##
    ## Both halves of the skip assert. That the fixture is DECLARED — a fixture
    ## silently dropped from the corpus would make this case pass by having
    ## nothing to skip — and that the refusal is ATTRIBUTED, in a line a reader
    ## of a CI log can grep for.
    skipArmRan = true
    let spec = fixtureSpec(BlockedFixture)
    ck spec.name == BlockedFixture
    ck spec.blockedOn.len > 0
    # The reason names the mechanism, not just the absence: a `blockedOn` that
    # said "unavailable" would be a silence with a field around it.
    ck spec.blockedOn.contains("list_processes")
    ck spec.blockedOn.contains("replay.rs:238")

    let resolution = resolveFixture(BlockedFixture)
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix) and
         BlockedFixture in message
      ck resolution.tracePath.len == 0
      skip()
    else:
      # THE UNBLOCKED ARM. If the fixture ever resolves, this case must not
      # quietly start passing on a single-threaded trace: it asserts what the
      # selector was cut for.
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()
      let threads = threadsFrom(session.threadsBody())
      checkpoint("DAP threads on the unblocked fixture: " & $threads)
      ck threads.len > 1
      ck threads[0].name.len > 0

  test "the blocker is measured on this run, not quoted from a document":
    ## The non-vacuity guard for the skip above, and the tripwire that unblocks
    ## it: a REAL trace, a REAL `replay-server`, and the number the engine
    ## actually reports.
    measuredArmRan = true
    let resolution = resolveFixture(AvailableFixture)
    if resolution.outcome == foMissingPrereq:
      # The suite does NOT skip here. If the one fixture it can measure against
      # is unavailable, the blocker was not re-established on this run and
      # saying nothing would leave a green lane meaning two different things.
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      checkpoint(message)
      ck false
      ck false
      ck false
      ck false
      ck false
      ck false
      ck false
      ck false
      ck false
    else:
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()
      let body = session.threadsBody()
      let threads = threadsFrom(body)
      reportedThreads = threads.len
      echo "CTUI-6 THREAD SURFACE: DAP `threads` on " & AvailableFixture &
           " reports " & $threads.len & " entry(ies): " & $body
      # ONE ENTRY, asserted as an equality. `<= 1` would keep passing on the day
      # the engine answers two, which is the day this milestone's cut deliverable
      # becomes buildable and someone has to be told.
      ck threads.len == 1
      ck threads[0].id == 1
      ck threads[0].name.len > 0
      # …and the shape the front-end sees is the shape the pane renders: one
      # thread, so §3.3.3's "in single-threaded traces, automatically collapses
      # to show the call tree directly" is the only case that exists.
      let frames = framesFromStackTrace(
        session.sendRawDapRequest("stackTrace", %*{
          "threadId": 1, "startFrame": 0, "levels": 64,
        }).getOrDefault("body"))
      ck frames.len >= 1
      let model = callStackModelFor(frames, session.getCurrentFile(),
                                    threads = threads)
      ck model.threadCount == 1
      ck model.threadName == threads[0].name
      # The thread is NAMED in the pane's title — which is all a single-threaded
      # trace can support — and there is no selector row above the frames.
      let title = titleRowText(model, 60)
      checkpoint("pane title: '" & title & "'")
      ck title.contains(threads[0].name)
      ck model.paneRows().len == frames.len
      ck callStackScreen(model, 60, 8).visible.len ==
         min(frames.len, 8 - 1)

  test "assertion count":
    ## Both arms ran, and the tally is derived from that rather than
    ## hand-totalled.
    ck skipArmRan
    ck measuredArmRan
    let expected = ChecksSkipArm + ChecksMeasuredArm + ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected &
               ", threads reported " & $reportedThreads)
    ck countedAssertions == expected
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
