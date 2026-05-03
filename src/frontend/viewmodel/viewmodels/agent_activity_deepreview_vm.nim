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
    fileCoverage*: Signal[seq[AgentDeepReviewFileCoverage]]
    notifications*: Signal[seq[AgentDeepReviewNotification]]
    isExpanded*: Signal[bool]

    # -- Derived state --
    coveragePercent*: Memo[float]
    hasFailures*: Memo[bool]
    notificationCount*: Memo[int]

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
  vm.testResults.val = results

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
    let fileCoverage = createSignal(newSeq[AgentDeepReviewFileCoverage]())
    let notifications = createSignal(newSeq[AgentDeepReviewNotification]())
    let isExpanded = createSignal(false)

    let coveragePercent = createMemo[float] proc(): float =
      coverageSummary.val.coveragePercent

    let hasFailures = createMemo[bool] proc(): bool =
      testResults.val.testsFailed > 0

    let notificationCount = createMemo[int] proc(): int =
      notifications.val.len

    AgentActivityDeepReviewVM(
      store: store,
      coverageSummary: coverageSummary,
      testResults: testResults,
      fileCoverage: fileCoverage,
      notifications: notifications,
      isExpanded: isExpanded,
      coveragePercent: coveragePercent,
      hasFailures: hasFailures,
      notificationCount: notificationCount,
      disposeProc: dispose,
    )
