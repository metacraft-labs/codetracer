## Headless tests for next / previous build-error navigation.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_build_error_navigation.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_build_error_navigation.nim
##
## ## What this suite is built against
##
## Before this feature the Problems pane already had a row-click handler that
## called `ErrorsVM.jumpToProblem`, which dispatched `ct/jump-location` — a
## command `backend/dap_dialect.md` §7 records as having **no engine
## implementation at all**. The click therefore did nothing in production and
## was green in tests, because the tests asserted the command was *enqueued*
## on a mock backend. The Build pane meanwhile still applies a
## `build-clickable` class and a `cursor: pointer`, documents
## `click→jumpToLocation` in its own header, and has no `onclick` on any row
## in either renderer arm — and `real-compiler-errors.spec.ts` asserts that
## class **by name**, so it passes over an affordance that does nothing.
##
## So the assertions here are about OUTCOMES, never about a call being made:
## `gotoError` returns an `ErrorNavOutcome` and the host callbacks record what
## they were actually given. A jump that "happened" but carried line 0 or a
## dropped column is a different failure from one that did not happen, and
## both are failures this suite separates.
##
## Every assertion is `counted`, and the count itself is asserted by the last
## case. A guard that returned early, or a loop over a list that turned out
## empty, stops being a silent pass.

import std/[json, unittest]

import isonim/core/[signals, computation, async_compat]

import ../../backend/backend_service
import ../../store/replay_data_store
import ../../store/types
import ../../viewmodels/errors_vm

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 128
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# A real ErrorsVM over a stub backend, plus a recording host.
#
# The VM is the real one — a double would assert that the code calls the procs
# the test thinks it should, which is the same thing said twice. What IS
# doubled is the host, because the host is the thing whose inputs this feature
# is about: the caret it is asked to move to, and whether it was asked at all.
# ---------------------------------------------------------------------------

proc stubStore(): ReplayDataStore =
  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) = resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut
  createReplayDataStore(BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard))

type
  Jump = tuple[path: string; line: int; col: int]

  Host = ref object
    ## What the editor was actually asked to do.
    jumps: seq[Jump]
    reveals: int

proc install(vm: ErrorsVM): Host =
  ## Wire a recording host, the way `ui/errors.nim` wires the real one.
  let host = Host(jumps: @[], reveals: 0)
  vm.onJumpToProblem = proc(path: string; line: int; col: int) =
    host.jumps.add((path: path, line: line, col: col))
  vm.onRevealPanel = proc() =
    host.reveals += 1
  host

proc problem(path: string; line, col: int; severity: BuildLineSeverity;
             message: string = "boom"): BuildProblemLine =
  BuildProblemLine(severity: severity, path: path, line: line, col: col,
                   message: message)

proc fixture(rows: seq[BuildProblemLine]): (ErrorsVM, Host) =
  let vm = createErrorsVM(stubStore())
  let host = vm.install()
  vm.setProblems(rows)
  (vm, host)

# Three errors in two files, with a warning and a note interleaved so that
# "navigation ranges over errors only" is measured against a list where the
# wrong answer is reachable rather than one where it happens to coincide.
proc mixedRows(): seq[BuildProblemLine] =
  @[
    problem("src/main.nr", 3, 41, blsError, "expected u8"),        # master 0
    problem("src/main.nr", 7, 5, blsWarning, "unused variable"),   # master 1
    problem("src/utils.nr", 11, 9, blsError, "type mismatch"),     # master 2
    problem("src/utils.nr", 12, 1, blsInfo, "expected because"),   # master 3
    problem("src/lib.nr", 20, 2, blsError, "unknown symbol"),      # master 4
  ]

suite "build error navigation":

  test "the fixture itself contains what the cases below range over":
    # NON-VACUITY FIRST. Every case after this one quantifies over the
    # navigable subset; if that subset were empty they would all pass while
    # measuring nothing. Universal quantification over an empty set is the
    # failure this whole file is shaped against, so the set is sized here.
    let (vm, _) = fixture(mixedRows())
    counted vm.problems.val.len == 5
    counted vm.navigableErrors().len == 3
    counted vm.errorCount.val == 3
    counted vm.warningCount.val == 1

  test "navigation ranges over errors only, and skips warnings and notes":
    let (vm, _) = fixture(mixedRows())
    let nav = vm.navigableErrors()
    counted nav.len == 3
    # By MASTER INDEX, not by position: the whole point of ProblemRef is that
    # the warning at master 1 and the note at master 3 keep their places in
    # the list while being unreachable from the keyboard.
    counted nav[0].index == 0
    counted nav[1].index == 2
    counted nav[2].index == 4
    var severities = 0
    for entry in nav:
      if entry.problem.severity == blsError: inc severities
    counted severities == 3
    counted severities == nav.len

  test "a row with no path or a non-positive line is listed but not navigable":
    # EMT-D20: shown and not navigable, never dropped. The two halves are
    # asserted separately because a implementation that DROPPED them would
    # satisfy the navigability half alone.
    let rows = @[
      problem("", 4, 1, blsError, "no path at all"),
      problem("src/a.nr", 0, 1, blsError, "line zero"),
      problem("src/a.nr", -1, 1, blsError, "negative line"),
      problem("src/a.nr", 6, 3, blsError, "a real one"),
    ]
    let (vm, host) = fixture(rows)
    counted vm.problems.val.len == 4          # listed: none were dropped
    counted vm.errorCount.val == 4            # and all four still count
    counted vm.navigableErrors().len == 1     # but only one is reachable
    counted not problem("", 4, 1, blsError).isNavigable
    counted not problem("src/a.nr", 0, 1, blsError).isNavigable
    counted problem("src/a.nr", 6, 3, blsError).isNavigable
    # And navigating lands on the real one rather than on a corrupted row.
    counted vm.gotoNextError() == enoMoved
    counted host.jumps.len == 1
    counted host.jumps[0].path == "src/a.nr"
    counted host.jumps[0].line == 6

  test "an empty list is a no-op that says so and does not open the panel":
    # EMT-D22.3. Three separate claims, because an implementation that
    # revealed the panel would still return the right outcome.
    let (vm, host) = fixture(@[])
    counted vm.gotoNextError() == enoEmpty
    counted vm.gotoPreviousError() == enoEmpty
    counted host.jumps.len == 0
    counted host.reveals == 0
    counted vm.statusMessage.val == "no errors"
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM

  test "a list of only warnings is empty for navigation purposes":
    # The premise most likely to rot: if `navigableErrors` ever widened to
    # all severities, the empty-list case above would keep passing while this
    # one reddens.
    let (vm, host) = fixture(@[
      problem("src/a.nr", 1, 1, blsWarning),
      problem("src/a.nr", 2, 1, blsInfo)])
    counted vm.problems.val.len == 2
    counted vm.navigableErrors().len == 0
    counted vm.gotoNextError() == enoEmpty
    counted host.jumps.len == 0
    counted vm.statusMessage.val == "no errors"

  test "next moves forward through the errors and reports its position":
    let (vm, host) = fixture(mixedRows())
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 0
    counted vm.statusMessage.val == "error 1 of 3"
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 2
    counted vm.statusMessage.val == "error 2 of 3"
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 4
    counted vm.statusMessage.val == "error 3 of 3"
    counted host.jumps.len == 3

  test "next from the last error wraps to the first, and announces it":
    # EMT-D22.2. The announcement is asserted BY CONTENT, not merely as
    # non-empty: a silent wrap and a wrap announced as "error 1 of 3" are
    # both wrong and are different wrongs.
    let (vm, host) = fixture(mixedRows())
    discard vm.gotoNextError()
    discard vm.gotoNextError()
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 4
    counted vm.gotoNextError() == enoWrapped
    counted vm.selectedIndex.val == 0
    counted vm.statusMessage.val == "wrapped to first error"
    counted host.jumps.len == 4
    counted host.jumps[3].path == "src/main.nr"
    counted host.jumps[3].line == 3

  test "previous from the first error wraps to the last, and announces it":
    let (vm, host) = fixture(mixedRows())
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 0
    counted vm.gotoPreviousError() == enoWrapped
    counted vm.selectedIndex.val == 4
    counted vm.statusMessage.val == "wrapped to last error"
    counted host.jumps.len == 2
    counted host.jumps[1].line == 20

  test "previous with no selection starts from the last error":
    let (vm, _) = fixture(mixedRows())
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM
    counted vm.gotoPreviousError() == enoMoved
    counted vm.selectedIndex.val == 4

  test "previous moves backward":
    let (vm, _) = fixture(mixedRows())
    discard vm.gotoPreviousError()          # -> master 4
    counted vm.gotoPreviousError() == enoMoved
    counted vm.selectedIndex.val == 2
    counted vm.gotoPreviousError() == enoMoved
    counted vm.selectedIndex.val == 0

  test "a single error wraps onto itself rather than reporting movement":
    # A one-error list is where "wrap or stop" is most visible. Reporting
    # `enoMoved` here would tell the user they had advanced when they had
    # not.
    let (vm, host) = fixture(@[problem("src/only.nr", 9, 4, blsError)])
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 0
    counted vm.gotoNextError() == enoWrapped
    counted vm.selectedIndex.val == 0
    counted vm.gotoPreviousError() == enoWrapped
    counted vm.selectedIndex.val == 0
    counted host.jumps.len == 3

  test "navigating carries the column, not just the line":
    # The field most likely to be silently dropped, and the one that makes
    # the difference between landing on a line and landing on the token. A
    # corrupted `col = -1` row is the specific false pass this checks for.
    let (vm, host) = fixture(mixedRows())
    discard vm.gotoNextError()
    counted host.jumps.len == 1
    counted host.jumps[0].col == 41
    discard vm.gotoNextError()
    counted host.jumps[1].col == 9
    discard vm.gotoNextError()
    counted host.jumps[2].col == 2
    var positiveCols = 0
    for jump in host.jumps:
      if jump.col > 0: inc positiveCols
    counted positiveCols == 3
    counted positiveCols == host.jumps.len

  test "navigation reveals the panel every time, including when already open":
    # EMT-D22.4: navigation works whether or not the panel is visible and
    # reveals it. The host is asked unconditionally; deciding that the panel
    # is already open is the host's business, not the VM's, and a VM that
    # tried to remember would be a second copy of the layout state.
    let (vm, host) = fixture(mixedRows())
    discard vm.gotoNextError()
    counted host.reveals == 1
    discard vm.gotoNextError()
    counted host.reveals == 2

  test "selecting a row does not move the caret and does not reveal":
    # The load-bearing distinction of EMT-D21: selecting is not focusing.
    let (vm, host) = fixture(mixedRows())
    vm.selectProblemIndex(2)
    counted vm.selectedIndex.val == 2
    counted host.jumps.len == 0
    counted host.reveals == 0

  test "an out-of-range selection clears rather than storing a bad index":
    let (vm, _) = fixture(mixedRows())
    vm.selectProblemIndex(99)
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM
    vm.selectProblemIndex(-5)
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM

  test "a failed build highlights the first error without moving focus":
    # The "Build fails" row of EMT-D21's table, which is the one the whole
    # focus decision turns on.
    let (vm, host) = fixture(mixedRows())
    counted vm.highlightFirstError()
    counted vm.selectedIndex.val == 0
    counted host.jumps.len == 0        # the caret did NOT move
    counted host.reveals == 0          # and nothing was focused
    # And it gives `next error` an origin: the following next goes to the
    # SECOND error, not back to the first.
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 2

  test "highlighting reports honestly when there is nothing to highlight":
    let (vm, _) = fixture(@[problem("src/a.nr", 1, 1, blsWarning)])
    counted not vm.highlightFirstError()
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM

  test "a new build clears the list and resets the cursor":
    # EMT-D22.7. Asserted through BOTH entry points, because the desktop
    # path bulk-replaces via `setProblems` and the clear button goes through
    # `clearProblems`, and a fix to one would not fix the other.
    let (vm, _) = fixture(mixedRows())
    discard vm.gotoNextError()
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 2
    vm.clearProblems()
    counted vm.problems.val.len == 0
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM
    counted vm.statusMessage.val == ""

    vm.setProblems(mixedRows())
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 0
    vm.setProblems(mixedRows())
    counted vm.selectedIndex.val == NO_SELECTED_PROBLEM
    # And navigation after a reset starts from the beginning again, rather
    # than from a remembered position into a list that has been replaced.
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 0

  test "the selection is an index into the master list, so a filter change keeps it":
    # Selection recorded against the FILTERED list would silently point at a
    # different diagnostic the moment the user pressed the Errors filter.
    let (vm, _) = fixture(mixedRows())
    discard vm.gotoNextError()
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 2
    vm.setFilter(pfErrors)
    counted vm.selectedIndex.val == 2
    counted vm.visibleProblems.val.len == 3
    counted vm.problems.val[vm.selectedIndex.val].message == "type mismatch"
    vm.setFilter(pfAll)
    counted vm.problems.val[vm.selectedIndex.val].message == "type mismatch"
    # And navigation is unaffected by the filter: the user's view of the
    # panel must not change which diagnostics the keyboard reaches.
    vm.setFilter(pfWarnings)
    counted vm.navigableErrors().len == 3
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 4

  test "visibleRefs carries master indices so a row can identify itself":
    # Two diagnostics identical by value must still highlight separately,
    # which is why the view is given indices rather than values.
    let (vm, _) = fixture(@[
      problem("src/a.nr", 5, 5, blsError, "same"),
      problem("src/a.nr", 5, 5, blsError, "same")])
    let refs = vm.visibleRefs.val
    counted refs.len == 2
    counted refs[0].index == 0
    counted refs[1].index == 1
    counted refs[0].problem == refs[1].problem   # equal as values
    counted refs[0].index != refs[1].index       # distinct as rows
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 0
    discard vm.gotoNextError()
    counted vm.selectedIndex.val == 1

  test "visibleRefs agrees with visibleProblems under every filter":
    # Two derivations of the same fact drift. This is the check that says so.
    let (vm, _) = fixture(mixedRows())
    var compared = 0
    for tag in [pfAll, pfErrors, pfWarnings]:
      vm.setFilter(tag)
      let refs = vm.visibleRefs.val
      let rows = vm.visibleProblems.val
      counted refs.len == rows.len
      for i in 0 ..< rows.len:
        counted refs[i].problem == rows[i]
        inc compared
    counted compared == 5 + 3 + 1

  test "a VM with no host falls back without crashing":
    # The historical behaviour, kept so the mock-backend view tests that
    # assert the `ct/jump-location` dispatch keep measuring what they always
    # did. This is NOT a working jump and is not asserted to be one.
    let vm = createErrorsVM(stubStore())
    vm.setProblems(mixedRows())
    counted vm.onJumpToProblem.isNil
    counted vm.gotoNextError() == enoMoved
    counted vm.selectedIndex.val == 0

  test "build_error_navigation_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
