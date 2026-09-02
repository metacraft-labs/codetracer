## viewmodels/errors_vm.nim
##
## ErrorsVM — ViewModel for the Errors / Problems panel.
##
## Holds reactive state for:
## - The list of structured ``BuildProblemLine`` rows surfaced to the
##   panel (one row per parsed compiler diagnostic).
## - The active severity filter (``ProblemFilterTag``).
## - The group-by-file toggle.
##
## Derives:
## - ``visibleProblems``: the ``problems`` list filtered by the active
##   ``filter`` value.  The view consumes this so the empty-state
##   overlay renders whenever the filter wipes every row out.
## - ``errorCount`` / ``warningCount``: severity tallies used by the
##   header count badges.
## - ``totalCount``: convenience alias for ``problems.val.len``.
##
## The VM has no auto-load effect: the legacy ``BuildComponent``
## already pushes problems into ``BuildVM.problems`` via
## ``appendProblem`` (and the bulk ``syncLegacyBuildIntoVM`` path); the
## errors module mirrors that signal into ``ErrorsVM.problems`` via the
## ``setProblems`` action.  Mirrors the contract of ``BuildVM`` itself —
## events arrive through the legacy mediator subscriptions; the VM is a
## platform-neutral facade so headless tests under
## ``src/tests/gui/tests/views/isonim_views_test.nim`` can drive the
## full reactive flow without needing the build pipeline.
##
## Usage::
##
##   let vm = createErrorsVM(store)
##   vm.setProblems(@[
##     BuildProblemLine(severity: blsError, path: "main.nim",
##                       line: 1, col: 1, message: "boom")])
##   echo vm.totalCount.val          # 1
##   echo vm.errorCount.val          # 1
##   vm.setFilter(pfWarnings)
##   echo vm.visibleProblems.val.len # 0
##
## When the user clicks a problem row the view calls
## ``vm.jumpToProblem(problem)`` which dispatches a ``ct/jump-location``
## request via the backend.  In production the legacy
## ``ErrorsComponent`` rendered an inline ``onclick = jumpLocation(loc)``
## closure; routing the click through the VM keeps the signal flow
## self-contained for headless tests.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const NO_SELECTED_PROBLEM* = -1
  ## ``selectedIndex`` when no row is selected.  Named rather than bare
  ## ``-1`` for the reason ``trace_log_vm.NO_SELECTED_INDEX`` is:
  ## an out-of-range index and "nothing selected" are different states
  ## and the clamping code has to tell them apart.

type
  ProblemRef* = tuple[index: int; problem: BuildProblemLine]
    ## A problem together with its position in the **master** ``problems``
    ## list.  Navigation ranges over a filtered subset but selection is
    ## recorded against the master list, so a selected row survives a
    ## change of ``filter`` instead of silently pointing at a different
    ## diagnostic.

  ErrorNavStep* = enum
    ## Direction for ``gotoError``.
    ensNext
    ensPrevious

  ErrorNavOutcome* = enum
    ## What a navigation command actually did.  Returned rather than
    ## discarded so a test can distinguish "moved" from "wrapped" from
    ## "there was nothing to move to" — three outcomes that a `bool`
    ## collapses and that have different specified behaviour
    ## (Edit-Mode-Toolbar.md EMT-D22).
    enoEmpty     ## No navigable error. A no-op; the panel is not opened.
    enoMoved     ## Selection advanced within the list.
    enoWrapped   ## Selection advanced past an end and wrapped around.

  ErrorsVM* = ref object of ViewModel
    ## Reactive state for the Errors / Problems panel.
    ##
    ## Mutable signals:
    ##   problems       — every problem row produced by the build pipeline.
    ##   filter         — the active severity filter.
    ##   groupByFile    — whether the view should group rows by file path.
    ##   selectedIndex  — index into ``problems`` of the selected row, or
    ##                    ``NO_SELECTED_PROBLEM``.
    ##   statusMessage  — the last thing navigation announced.
    ##
    ## Derived memos:
    ##   visibleProblems — ``problems`` filtered by ``filter``.
    ##   errorCount      — number of ``blsError`` rows in ``problems``.
    ##   warningCount    — number of ``blsWarning`` rows in ``problems``.
    ##   totalCount      — convenience: ``problems.val.len``.
    ##   visibleRefs     — ``visibleProblems`` carrying master indices, so a
    ##                     row can tell whether it is the selected one
    ##                     without comparing structurally (two diagnostics
    ##                     on the same line of the same file are equal by
    ##                     value and must still be distinguishable).
    store*: ReplayDataStore

    # -- Mutable state --
    problems*: Signal[seq[BuildProblemLine]]
    filter*: Signal[ProblemFilterTag]
    groupByFile*: Signal[bool]
    selectedIndex*: Signal[int]
    statusMessage*: Signal[string]

    # -- Derived state --
    visibleProblems*: Memo[seq[BuildProblemLine]]
    errorCount*: Memo[int]
    warningCount*: Memo[int]
    totalCount*: Memo[int]
    visibleRefs*: Memo[seq[ProblemRef]]

    # -- Callbacks wired by the host (ui/errors.nim) after VM creation --
    onJumpToProblem*: proc(path: string; line: int; col: int)
      ## Move the editor caret to a diagnostic and focus the editor.
      ##
      ## The pair of ``SearchResultsVM.onJumpToResult``, and added for the
      ## same reason it was: the jump used to fall back to
      ## ``ct/jump-location``, a command **no backend in this repo
      ## implements** (`backend/dap_dialect.md` §7 lists it among nine such).
      ## That fallback is gone — see ``jumpToProblem`` — so this callback is
      ## now the only way the Problems pane navigates. A host that installs it
      ## owns the jump; a host that does not gets an explicit no-op.
    onRevealPanel*: proc()
      ## Reveal the Problems pane without focusing it.  Navigation works
      ## whether or not the pane is on screen (EMT-D22.4), so the command
      ## must be able to bring it up.

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setProblems*(vm: ErrorsVM; problems: seq[BuildProblemLine]) =
  ## Replace the problem list wholesale.  Used by the legacy build
  ## pipeline's ``syncLegacyErrorsIntoVM`` after a bulk update; per-row
  ## updates flow through ``appendProblem`` instead.
  ##
  ## Resets the navigation cursor for ``clearProblems``' reason: the indices
  ## the cursor holds are positions in the list being replaced.
  vm.problems.val = problems
  vm.selectedIndex.val = NO_SELECTED_PROBLEM

proc appendProblem*(vm: ErrorsVM; problem: BuildProblemLine) =
  ## Append a single problem row.  Called by the legacy build pipeline
  ## whenever ``parseBuildLocation`` emits a structured diagnostic so
  ## the ``ErrorsVM`` mirrors the same data ``BuildVM.problems``
  ## carries without coupling the two view-models.
  var entries = vm.problems.val
  entries.add(problem)
  vm.problems.val = entries

proc clearProblems*(vm: ErrorsVM) =
  ## Reset the problem list.  The view re-displays the
  ## ``"No problems detected."`` empty-state overlay.
  ##
  ## EMT-D22.7: a new build clears the list **and resets the navigation
  ## cursor**.  Keeping the cursor would leave `next error` counting from a
  ## row that no longer exists, and stale diagnostics point at lines that
  ## have moved.
  vm.problems.val = @[]
  vm.selectedIndex.val = NO_SELECTED_PROBLEM
  vm.statusMessage.val = ""

proc setFilter*(vm: ErrorsVM; filter: ProblemFilterTag) =
  ## Set the active severity filter.  Memoed signals (``visibleProblems``)
  ## recompute automatically.
  vm.filter.val = filter

proc setGroupByFile*(vm: ErrorsVM; on: bool) =
  ## Toggle the group-by-file rendering mode.
  vm.groupByFile.val = on

proc toggleGroupByFile*(vm: ErrorsVM) =
  ## Flip the group-by-file rendering mode.
  vm.groupByFile.val = not vm.groupByFile.val

proc isNavigable*(problem: BuildProblemLine): bool =
  ## Whether a diagnostic can be navigated to.
  ##
  ## EMT-D20: a diagnostic whose path does not resolve is **shown and not
  ## navigable**, carrying its raw path, rather than dropped.  The VM cannot
  ## resolve a path against the workspace — that is the host's job — so the
  ## test here is the one the VM *can* make honestly: a row with no path, or
  ## with a non-positive line, names no location.  A row that names a
  ## location the host later fails to open stays in the list and reports the
  ## failure; it is not silently skipped, because a diagnostic that vanishes
  ## is worse than one that cannot be opened.
  problem.path.len > 0 and problem.line > 0

proc jumpToProblem*(vm: ErrorsVM; problem: BuildProblemLine) =
  ## Move the editor to a diagnostic.
  ##
  ## The jump belongs to the host: ``onJumpToProblem`` is installed by
  ## ``ui/errors.nim`` and calls ``data.openLocation``, the same path the
  ## editor uses for every other file navigation.
  ##
  ## There is deliberately **no backend fallback**. This used to dispatch
  ## ``ct/jump-location`` when no host was installed — a command
  ## `backend/dap_dialect.md` §7 records as having no engine implementation
  ## anywhere: absent from ``VALID_DAP_COMMANDS``, from
  ## ``EVENT_KIND_TO_DAP_MAPPING``, and from both Rust dispatch tables in
  ## ``dap_server.rs``. It never jumped. What it did do was make a VM with no
  ## host *look* like it had acted, which is exactly what kept the row-click
  ## tests green over a control that did nothing.
  ##
  ## Nor is some other DAP command the right fallback. A build diagnostic can
  ## name a file the recording never executed, so moving the *debugger* — what
  ## ``ct/source-line-jump`` does — is a different action, not a substitute for
  ## editor navigation.
  ##
  ## With no host installed this is a no-op, and is now honestly shaped like
  ## one instead of dispatching into the void.
  if vm.onJumpToProblem.isNil:
    return
  vm.onJumpToProblem(problem.path, problem.line, problem.col)

proc navigableErrors*(vm: ErrorsVM): seq[ProblemRef] =
  ## The rows ``gotoError`` ranges over, with their master indices.
  ##
  ## EMT-D22.1: navigation ranges over the Problems list **filtered to
  ## ``blsError``**.  Warnings and notes are listed and are not navigated.
  ## Deliberately independent of ``filter``: the user's chosen *view* of the
  ## panel must not silently change which diagnostics the keyboard can
  ## reach, or `next error` would mean different things depending on a
  ## button pressed minutes ago.
  for index, problem in vm.problems.val:
    if problem.severity == blsError and problem.isNavigable:
      result.add((index: index, problem: problem))

proc selectProblemIndex*(vm: ErrorsVM; masterIndex: int) =
  ## Select the row at ``masterIndex`` in the master list, or clear the
  ## selection when the index is out of range.  Selecting a row does **not**
  ## move the caret and does **not** focus anything (EMT-D21).
  if masterIndex < 0 or masterIndex >= vm.problems.val.len:
    vm.selectedIndex.val = NO_SELECTED_PROBLEM
  else:
    vm.selectedIndex.val = masterIndex

proc announce*(vm: ErrorsVM; message: string) =
  ## Record a navigation announcement.
  ##
  ## The repo has no status bar — `grep` for one finds only the LSP's
  ## private `setStatus`.  Rather than invent a surface this feature cannot
  ## test, the announcement is a signal the Problems pane header paints, so
  ## EMT-D22.2's "the wrap is announced" is observable in the same place and
  ## the same way as everything else this pane claims.
  vm.statusMessage.val = message

proc gotoError*(vm: ErrorsVM; step: ErrorNavStep): ErrorNavOutcome =
  ## Move the selection to the next / previous navigable error, move the
  ## editor caret there, and reveal the pane.  Returns what it did.
  ##
  ## EMT-D22, point by point:
  ##  2. wraps at both ends, and announces the wrap;
  ##  3. an empty list is a no-op that says "no errors" and does **not**
  ##     open the panel;
  ##  4. works whether or not the panel is visible, and reveals it;
  ##  5. selects the row *and* moves the caret to (line, col);
  ##  6. the editor is focused afterwards — that is the host's half of
  ##     ``onJumpToProblem``.
  let nav = vm.navigableErrors()
  if nav.len == 0:
    # NOT `enoMoved` with a no-op jump: an empty list is its own outcome.
    # A caller that treated "nothing happened" as success is exactly how a
    # navigation command that never worked would look like one that did.
    vm.announce("no errors")
    return enoEmpty

  # Where the current selection sits *within the navigable subset*. The
  # selection may be a warning, or a filtered-out row, or gone entirely
  # after a rebuild — all of which read as "not in the list" and start
  # navigation from the appropriate end rather than from nowhere.
  var current = -1
  let selected = vm.selectedIndex.val
  for position, entry in nav:
    if entry.index == selected:
      current = position
      break

  var wrapped = false
  var target = 0
  case step
  of ensNext:
    if current < 0:
      target = 0
    elif current + 1 >= nav.len:
      target = 0
      wrapped = true
    else:
      target = current + 1
  of ensPrevious:
    if current < 0:
      target = nav.high
    elif current - 1 < 0:
      target = nav.high
      wrapped = true
    else:
      target = current - 1

  let entry = nav[target]
  vm.selectedIndex.val = entry.index
  if not vm.onRevealPanel.isNil:
    vm.onRevealPanel()
  vm.jumpToProblem(entry.problem)

  if wrapped:
    vm.announce(
      if step == ensNext: "wrapped to first error" else: "wrapped to last error")
    enoWrapped
  else:
    vm.announce("error " & $(target + 1) & " of " & $nav.len)
    enoMoved

proc gotoNextError*(vm: ErrorsVM): ErrorNavOutcome =
  ## ``gotoError(ensNext)``.  The action behind ``aGotoNextError``.
  vm.gotoError(ensNext)

proc gotoPreviousError*(vm: ErrorsVM): ErrorNavOutcome =
  ## ``gotoError(ensPrevious)``.  The action behind ``aGotoPreviousError``.
  vm.gotoError(ensPrevious)

proc highlightFirstError*(vm: ErrorsVM): bool =
  ## Select the first navigable error **without moving the caret and
  ## without focusing anything**.  Returns whether there was one.
  ##
  ## This is the load-bearing distinction in EMT-D21's table: on a failed
  ## build the first row is *highlighted but not focused*, so that
  ## `next error` has an origin and the user can see where they will land,
  ## while the keyboard stays wherever it was.  It is deliberately NOT
  ## ``gotoError`` — calling that here is precisely the "steals focus on
  ## every build" behaviour the decision rules out.
  let nav = vm.navigableErrors()
  if nav.len == 0:
    return false
  vm.selectedIndex.val = nav[0].index
  true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc severityCount(rows: seq[BuildProblemLine];
                   severity: BuildLineSeverity): int =
  ## Count the rows whose severity matches ``severity``.  Pulled out so
  ## both the ``errorCount`` / ``warningCount`` memos can share the
  ## traversal.
  for r in rows:
    if r.severity == severity:
      inc result

proc filterRows(rows: seq[BuildProblemLine];
                filter: ProblemFilterTag): seq[BuildProblemLine] =
  ## Return only the rows matching the active ``filter``.  Mirrors the
  ## legacy ``filterProblems`` proc.
  case filter
  of pfAll:
    return rows
  of pfErrors:
    for r in rows:
      if r.severity == blsError:
        result.add(r)
  of pfWarnings:
    for r in rows:
      if r.severity == blsWarning:
        result.add(r)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createErrorsVM*(store: ReplayDataStore): ErrorsVM =
  ## Create an ErrorsVM inside a reactive root owned by ``withViewModel``.
  ## The reactive root is disposed via ``vm.dispose()``.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults (no problems, ``pfAll``
  ##    filter, group-by-file off).
  ## 2. Derived memos for ``visibleProblems`` / ``errorCount`` /
  ##    ``warningCount`` / ``totalCount``.
  withViewModel proc(dispose: proc()): ErrorsVM =
    let problems = createSignal(newSeq[BuildProblemLine]())
    let filter = createSignal(pfAll)
    let groupByFile = createSignal(false)
    let selectedIndex = createSignal(NO_SELECTED_PROBLEM)
    let statusMessage = createSignal("")

    let visibleProblems = createMemo[seq[BuildProblemLine]] proc(): seq[BuildProblemLine] =
      filterRows(problems.val, filter.val)

    # The visible rows carrying their master indices, so a row can compare
    # identity rather than value against ``selectedIndex``.  Two diagnostics
    # at the same file:line are equal as values and must still highlight
    # separately.
    let visibleRefs = createMemo[seq[ProblemRef]] proc(): seq[ProblemRef] =
      let active = filter.val
      for index, problem in problems.val:
        let keep =
          case active
          of pfAll: true
          of pfErrors: problem.severity == blsError
          of pfWarnings: problem.severity == blsWarning
        if keep:
          result.add((index: index, problem: problem))

    let errorCount = createMemo[int] proc(): int =
      severityCount(problems.val, blsError)

    let warningCount = createMemo[int] proc(): int =
      severityCount(problems.val, blsWarning)

    let totalCount = createMemo[int] proc(): int =
      problems.val.len

    ErrorsVM(
      store: store,
      problems: problems,
      filter: filter,
      groupByFile: groupByFile,
      selectedIndex: selectedIndex,
      statusMessage: statusMessage,
      visibleProblems: visibleProblems,
      errorCount: errorCount,
      warningCount: warningCount,
      totalCount: totalCount,
      visibleRefs: visibleRefs,
      disposeProc: dispose,
    )
