## viewmodels/agent_activity_deepreview_vm.nim
##
## AgentActivityDeepReviewVM — ViewModel for the Agent Activity
## DeepReview pane.
##
## The Agent Activity DeepReview pane is the per-session collapsible
## panel (see ``frontend/ui/agent_activity_deepreview.nim``) that
## overlays DeepReview metrics — coverage summary, test results,
## per-file coverage table, and a recent-notifications feed — onto
## the agent activity stream.  The legacy
## ``AgentActivityDeepReviewComponent`` used a Karax ``method
## render`` to draw the entire panel.  Section §1.74 (mission
## goal #3) replaces the Karax render with an IsoNim view; the
## VM here owns the reactive state the view subscribes to.
##
## Reactive surface:
## - ``coverageSummary``    — ``AgentDeepReviewCoverageSummary`` value
##                            with the aggregate coverage stats.
##                            Updated by ``setCoverageSummary``.
## - ``testResults``        — ``AgentDeepReviewTestResults`` value
##                            with run / pass / fail counts and the
##                            aggregate duration.  Updated by
##                            ``setTestResults``.
## - ``testResultsAvailable`` — whether anything has actually reported
##                            a test run.  False by default and after a
##                            review is entered over a dataset that
##                            carries no tests; ``setTestResults`` flips
##                            it true.  It exists because
##                            ``DeepReviewData``
##                            (``common/common_types/codetracer_features/
##                            deepreview.nim``) has *no* test-result
##                            field at all — no test name, no pass/fail,
##                            no duration — so a CLI-launched review has
##                            nothing to fill this row with.  Rendering
##                            "0 run / 0 passed / all passing" in that
##                            case would read as "every test passed",
##                            which is a fabricated fact; the view paints
##                            an explicit "not available for this
##                            dataset" state instead
##                            (DeepReview-GUI.milestones.org, DR-R3,
##                            "A data gap to record, not to paper over").
## - ``reviewActive``       — true once a review dataset has populated
##                            the pane.  The section is part of the
##                            Agent Activity panel and must stay out of
##                            the way of a normal debugging session, so
##                            it paints only when a review put something
##                            in it (DeepReview-GUI.md §2.1: "The section
##                            is part of the existing Agent Activity
##                            panel").
## - ``selectedFilePath``   — path of the file selected in the per-file
##                            coverage table.  DeepReview-GUI.md §2.1:
##                            "Selecting a file in either the VCS panel
##                            or the per-file coverage table should agree
##                            with the other; they are two views of one
##                            selection."  The selection is expressed as
##                            a *path* rather than an index because the
##                            two tables are independent projections of
##                            the changeset and only the path is common
##                            to both.
## - ``fileCoverage``       — ``seq[AgentDeepReviewFileCoverage]`` —
##                            one row per file the panel knows about.
##                            Updated by ``setFileCoverage``.
## - ``notifications``      — ``seq[AgentDeepReviewNotification]`` —
##                            recent activity feed (most-recent
##                            last).  Bounded by ``MAX_NOTIFICATIONS``
##                            so a long-running session cannot grow
##                            the seq unboundedly; ``appendNotification``
##                            trims the oldest rows once the cap is
##                            reached.
## - ``isExpanded``         — true when the collapsible header is
##                            open.  Mirrors the legacy ``expanded``
##                            bool.  ``toggleExpanded`` flips it;
##                            ``setExpanded`` lets callers force a
##                            specific state (e.g. when the user
##                            clicks the header label).
##
## Derived:
## - ``coveragePercent``    — convenience memo that reports the
##                            ``coverageSummary.coveragePercent``
##                            value; the bridge keeps that float
##                            authoritative so the same number can
##                            be set from a recorded percentage or
##                            recomputed from the line counts.
## - ``hasFailures``        — true when ``testResults.testsFailed``
##                            > 0; the IsoNim view paints the
##                            failures pill warn-coloured when this
##                            memo flips.
## - ``notificationCount``  — len of the notifications seq; used by
##                            tests + the "Recent Activity" header
##                            badge.
## - ``sectionVisible``     — whether the DeepReview section should
##                            paint at all: true once a review is
##                            active or any data (file coverage,
##                            notifications) has arrived.  The view
##                            hides the whole container otherwise, so a
##                            normal debugging session's Agent Activity
##                            panel is unchanged.
## - ``selectedFileIndex``  — index of ``selectedFilePath`` within
##                            ``fileCoverage``, or -1 when the selected
##                            path has no row (an empty selection, or a
##                            file the coverage table does not carry).
##
## Actions:
## - ``setCoverageSummary`` — bulk replace the coverage summary
##                            value.  No throttling — callers are
##                            expected to coalesce upstream when
##                            necessary.
## - ``setTestResults``     — bulk replace the test-result roll-up.
## - ``setFileCoverage``    — bulk replace the per-file coverage
##                            table.  Used by the bridge after a
##                            ``CoverageUpdate`` notification so the
##                            row order matches the legacy
##                            iteration order.
## - ``appendNotification`` — append one row to the notifications
##                            feed; trims to the most-recent
##                            ``MAX_NOTIFICATIONS`` entries so the
##                            seq never grows past the cap.
## - ``clearNotifications`` — drop every notification row.  Used by
##                            the legacy ``resetCommandPalette``
##                            analogue and by the headless tests.
## - ``toggleExpanded``     — flip ``isExpanded``.
## - ``setExpanded``        — force ``isExpanded`` to a specific
##                            value (idempotent — re-setting the
##                            same value is a no-op so subscribers
##                            do not refire pointlessly).
##
## ``string`` / ``int`` / ``float`` / ``bool`` / ``seq`` shapes are
## used throughout so the same value flows through both
## ``test-vm-native`` and ``test-vm-js`` without ``cstring`` /
## ``langstring`` conversion noise.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

const MAX_NOTIFICATIONS* = 50
  ## Upper bound for the notifications feed.  Mirrors the legacy
  ## ``MAX_RECENT`` constant in
  ## ``ui/agent_activity_deepreview.nim::handleNotification`` so a
  ## long-running session does not grow the feed unboundedly.

type
  AgentActivityDeepReviewVM* = ref object of ViewModel
    ## Reactive state for the Agent Activity DeepReview pane.
    store*: ReplayDataStore

    # -- Mutable state --
    coverageSummary*: Signal[AgentDeepReviewCoverageSummary]
    testResults*: Signal[AgentDeepReviewTestResults]
    testResultsAvailable*: Signal[bool]
    fileCoverage*: Signal[seq[AgentDeepReviewFileCoverage]]
    notifications*: Signal[seq[AgentDeepReviewNotification]]
    isExpanded*: Signal[bool]
    reviewActive*: Signal[bool]
    selectedFilePath*: Signal[string]

    # -- Derived state --
    coveragePercent*: Memo[float]
    hasFailures*: Memo[bool]
    notificationCount*: Memo[int]
    sectionVisible*: Memo[bool]
    selectedFileIndex*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setCoverageSummary*(vm: AgentActivityDeepReviewVM;
                         summary: AgentDeepReviewCoverageSummary) =
  ## Bulk replace the coverage summary value.  Subscribers fire on
  ## every change because the value compares structurally via the
  ## ``==`` override on the type.
  vm.coverageSummary.val = summary

proc setTestResults*(vm: AgentActivityDeepReviewVM;
                     results: AgentDeepReviewTestResults) =
  ## Bulk replace the test-result roll-up.
  ##
  ## Calling this *is* the statement that test results are known — only a
  ## producer that ran tests has counts to publish — so it flips
  ## ``testResultsAvailable``.  There is deliberately no way to publish
  ## counts while leaving the row marked unavailable: that combination
  ## would be the fabricated zero this flag exists to prevent.
  vm.testResults.val = results
  vm.testResultsAvailable.val = true

proc setTestResultsUnavailable*(vm: AgentActivityDeepReviewVM) =
  ## Declare that nothing has reported test results — the state a review
  ## launched over an exported ``.dr`` dataset is in, because
  ## ``DeepReviewData`` carries no test-result fields.  Resets the counts
  ## too so a stale roll-up cannot show through the unavailable label.
  vm.testResults.val = AgentDeepReviewTestResults()
  vm.testResultsAvailable.val = false

proc setReviewActive*(vm: AgentActivityDeepReviewVM; active: bool) =
  ## Mark the pane as belonging to a live review, which is what makes the
  ## DeepReview section paint inside the Agent Activity panel.
  vm.reviewActive.val = active

proc setSelectedFilePath*(vm: AgentActivityDeepReviewVM; path: string) =
  ## Move the per-file coverage table's selection.  Accepts any path,
  ## including one with no row: ``selectedFileIndex`` then reports -1 and
  ## no row paints as selected, which is the honest rendering of "the
  ## selected file has no coverage row".
  vm.selectedFilePath.val = path

proc setFileCoverage*(vm: AgentActivityDeepReviewVM;
                      entries: openArray[AgentDeepReviewFileCoverage]) =
  ## Bulk replace the per-file coverage table.  Stored as a seq so
  ## the IsoNim view can iterate without re-allocating on each
  ## render-effect tick.
  vm.fileCoverage.val = @entries

proc appendNotification*(vm: AgentActivityDeepReviewVM;
                         notif: AgentDeepReviewNotification) =
  ## Append ``notif`` to the notifications feed and trim the seq to
  ## the most-recent ``MAX_NOTIFICATIONS`` rows so the feed cannot
  ## grow unboundedly.  Mirrors the legacy
  ## ``handleNotification`` trim logic.
  var current = vm.notifications.val
  current.add(notif)
  if current.len > MAX_NOTIFICATIONS:
    let start = current.len - MAX_NOTIFICATIONS
    current = current[start .. ^1]
  vm.notifications.val = current

proc clearNotifications*(vm: AgentActivityDeepReviewVM) =
  ## Drop every notification row.  The coverage / test / file
  ## coverage signals are intentionally untouched so the panel's
  ## summary surface stays populated across notification resets.
  vm.notifications.val = @[]

proc toggleExpanded*(vm: AgentActivityDeepReviewVM) =
  ## Flip ``isExpanded``.  Mirrors the legacy header onclick handler.
  vm.isExpanded.val = not vm.isExpanded.val

proc setExpanded*(vm: AgentActivityDeepReviewVM; expanded: bool) =
  ## Force ``isExpanded`` to ``expanded``.  Idempotent — re-setting
  ## the same value is a no-op so subscribers do not refire
  ## pointlessly (matches the ``open`` no-op pattern in
  ## ``CommandPaletteVM``).
  if vm.isExpanded.val == expanded:
    return
  vm.isExpanded.val = expanded

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createAgentActivityDeepReviewVM*(
    store: ReplayDataStore): AgentActivityDeepReviewVM =
  ## Create an ``AgentActivityDeepReviewVM`` inside a reactive root
  ## owned by ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty default so
  ## the view paints the closed/empty branch on first render.  The
  ## panel starts collapsed (``isExpanded = false``) to match the
  ## legacy ``expanded: false`` initial value in
  ## ``utils.nim::makeAgentActivityDeepReviewComponent``.
  withViewModel proc(dispose: proc()): AgentActivityDeepReviewVM =
    let coverageSummary = createSignal(AgentDeepReviewCoverageSummary())
    let testResults = createSignal(AgentDeepReviewTestResults())
    let testResultsAvailable = createSignal(false)
    let fileCoverage = createSignal(newSeq[AgentDeepReviewFileCoverage]())
    let notifications = createSignal(newSeq[AgentDeepReviewNotification]())
    let isExpanded = createSignal(false)
    let reviewActive = createSignal(false)
    let selectedFilePath = createSignal("")

    let coveragePercent = createMemo[float] proc(): float =
      coverageSummary.val.coveragePercent

    let hasFailures = createMemo[bool] proc(): bool =
      testResults.val.testsFailed > 0

    let notificationCount = createMemo[int] proc(): int =
      notifications.val.len

    let sectionVisible = createMemo[bool] proc(): bool =
      reviewActive.val or fileCoverage.val.len > 0 or notifications.val.len > 0

    let selectedFileIndex = createMemo[int] proc(): int =
      let wanted = selectedFilePath.val
      if wanted.len == 0:
        return -1
      let rows = fileCoverage.val
      for i in 0 ..< rows.len:
        if rows[i].path == wanted:
          return i
      -1

    AgentActivityDeepReviewVM(
      store: store,
      coverageSummary: coverageSummary,
      testResults: testResults,
      testResultsAvailable: testResultsAvailable,
      fileCoverage: fileCoverage,
      notifications: notifications,
      isExpanded: isExpanded,
      reviewActive: reviewActive,
      selectedFilePath: selectedFilePath,
      coveragePercent: coveragePercent,
      hasFailures: hasFailures,
      notificationCount: notificationCount,
      sectionVisible: sectionVisible,
      selectedFileIndex: selectedFileIndex,
      disposeProc: dispose,
    )
