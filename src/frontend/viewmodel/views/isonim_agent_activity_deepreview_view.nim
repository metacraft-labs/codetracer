## views/isonim_agent_activity_deepreview_view.nim
##
## IsoNim DOM-rendering view for the Agent Activity DeepReview pane.
##
## Renders a live, reactive DOM tree driven by
## ``AgentActivityDeepReviewVM`` signals.  Replaces the legacy Karax
## ``method render`` in
## ``frontend/ui/agent_activity_deepreview.nim`` (the IsoNim view is
## the single source of truth for the panel's DOM).
##
## The legacy panel composed several Karax helpers
## (``renderSummaryCards`` / ``renderFileTable`` /
## ``renderTestResults`` / ``renderRecentNotifications``) into a
## collapsible container.  This iteration intentionally renders a
## minimal, dependency-free shell — one ``activity-dr-files-row``
## per file-coverage entry, one ``activity-dr-test-item`` per
## test result row, one ``activity-dr-notif-item`` per notification
## — and reuses the legacy class names so the existing
## ``static/styles/components/activity-dr.styl`` rules keep
## targeting the same selectors.  Per-row icons + per-file
## coverage bars and per-notification rich badges remain a
## follow-up captured in the VM doc-comment.
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy
## ``activity-dr-container`` layout::
##
##   div.component-container.activity-dr-container[.activity-dr-collapsed]
##     div.activity-dr-header
##       span.activity-dr-chevron     (text 'v' or '>')
##       span.activity-dr-header-label  text "DeepReview"
##       span.activity-dr-header-badge  (only when collapsed)
##         text "{coveragePercent:.1f}%"
##     div.activity-dr-body[.hidden]    (only when collapsed)
##       div.activity-dr-summary
##         div.activity-dr-card.activity-dr-card-coverage
##         div.activity-dr-card.activity-dr-card-tests[.activity-dr-card-warn]
##       div.activity-dr-files
##         div.activity-dr-files-header (one row of column labels)
##         div.activity-dr-files-row    (one per AgentDeepReviewFileCoverage)
##         div.activity-dr-files-empty[.hidden]
##       div.activity-dr-tests
##         div.activity-dr-tests-header
##         div.activity-dr-test-item[.activity-dr-test-pass|...-fail]
##         div.activity-dr-tests-empty[.hidden]
##       div.activity-dr-notifs
##         div.activity-dr-notifs-header
##         div.activity-dr-notif-item[.activity-dr-notif-{kind}]
##         div.activity-dr-notifs-empty[.hidden]
##
## Reactive surface:
## - One outer ``createRenderEffect`` rebuilds the per-file coverage
##   table, the test-results list, and the notifications list and
##   toggles the body's hidden modifier + the header badge when the
##   ``isExpanded`` / ``coverageSummary`` / ``testResults`` /
##   ``fileCoverage`` / ``notifications`` signals change.  Mirrors
##   the trace_log / scratchpad / filesystem / command_palette
##   pattern (DSL builds the static shell, imperative renderer ops
##   inside the effect handle the dynamic content).

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/agent_activity_deepreview_vm

# ---------------------------------------------------------------------------
# Class-name constants — name-spaced so they don't collide with the
# Filesystem / CommandPalette / Scratchpad constants in
# isonim_views_test.nim.
# ---------------------------------------------------------------------------

const AgentActivityDeepReviewContainerClass* =
  "component-container activity-dr-container"
  ## Outer wrapper class string.  Mirrors the legacy
  ## Activity DeepReview root class in
  ## ``ui/agent_activity_deepreview.nim``.  The
  ## ``component-container`` prefix matches the convention used by
  ## the other migrated panels (filesystem / scratchpad / command-
  ## palette) so the GoldenLayout chrome lines up.

const AgentActivityDeepReviewCollapsedModifier* = "activity-dr-collapsed"
  ## CSS modifier appended to the outer container when the panel is
  ## collapsed.  Distinct from the generic ``hidden`` modifier other
  ## panels use because the activity-dr panel keeps the header
  ## visible even when the body is hidden — the modifier signals
  ## "body is hidden" without implying "the entire panel is hidden".

const AgentActivityDeepReviewBodyClass* = "activity-dr-body"
  ## Inner body wrapper class.  All collapsible content lives inside
  ## this element so the render effect can flip a single ``hidden``
  ## modifier on the body without rebuilding the rest of the tree.

const AgentActivityDeepReviewHiddenModifier* = "hidden"
  ## CSS modifier class appended to the body / sub-section empty-
  ## state placeholders when they should not be visible.  Same
  ## modifier as the ``CommandPaletteHiddenModifier`` constant —
  ## name-spaced separately so tests can assert on the panel's own
  ## constant.

const AgentActivityDeepReviewSummaryClass* = "activity-dr-summary"
const AgentActivityDeepReviewCardClass* = "activity-dr-card"
const AgentActivityDeepReviewFilesClass* = "activity-dr-files"
const AgentActivityDeepReviewFileRowClass* = "activity-dr-files-row"
const AgentActivityDeepReviewFilesHeaderClass* = "activity-dr-files-header"
const AgentActivityDeepReviewFilesEmptyClass* = "activity-dr-files-empty"
const AgentActivityDeepReviewTestsClass* = "activity-dr-tests"
const AgentActivityDeepReviewTestRowClass* = "activity-dr-test-item"
const AgentActivityDeepReviewTestsHeaderClass* = "activity-dr-tests-header"
const AgentActivityDeepReviewTestsEmptyClass* = "activity-dr-tests-empty"
const AgentActivityDeepReviewNotifsClass* = "activity-dr-notifs"
const AgentActivityDeepReviewNotifRowClass* = "activity-dr-notif-item"
const AgentActivityDeepReviewNotifsHeaderClass* = "activity-dr-notifs-header"
const AgentActivityDeepReviewNotifsEmptyClass* = "activity-dr-notifs-empty"
const AgentActivityDeepReviewHeaderClass* = "activity-dr-header"
const AgentActivityDeepReviewHeaderLabelClass* = "activity-dr-header-label"
const AgentActivityDeepReviewHeaderBadgeClass* = "activity-dr-header-badge"
const AgentActivityDeepReviewChevronClass* = "activity-dr-chevron"

const AgentActivityDeepReviewLabelText* = "DeepReview"
  ## Header label text rendered in the chevron row.  Kept as a
  ## constant so the view, the headless tests, and any future
  ## fixture builder share one source of truth.

const AgentActivityDeepReviewFilesEmptyText* =
  "No files with coverage data yet."
const AgentActivityDeepReviewTestsEmptyText* = "No test results yet."
const AgentActivityDeepReviewNotifsEmptyText* = "No recent notifications."
  ## Placeholder copy for the per-section empty branches.  Mirror
  ## the legacy strings in ``ui/agent_activity_deepreview.nim`` so
  ## the visual surface stays identical.

const AgentActivityDeepReviewTestPassClass* = "activity-dr-test-pass"
const AgentActivityDeepReviewTestFailClass* = "activity-dr-test-fail"

# ---------------------------------------------------------------------------
# Reactive helpers used inside the render effect
# ---------------------------------------------------------------------------

proc containerClass*(isExpanded: bool): string =
  ## Outer container class string — appends the collapsed modifier
  ## when the body is hidden.  Mirrors the legacy
  ## ``classnames("activity-dr-container", "activity-dr-collapsed":
  ## not expanded)`` pattern.  The header label and chevron stay
  ## visible even when collapsed because the panel's "fold up to
  ## just the header" affordance is the only way to re-expand it.
  if isExpanded:
    AgentActivityDeepReviewContainerClass
  else:
    AgentActivityDeepReviewContainerClass & " " &
      AgentActivityDeepReviewCollapsedModifier

proc bodyClass*(isExpanded: bool): string =
  ## Inner body wrapper class string — appends the ``hidden``
  ## modifier when the panel is collapsed so the tree under the
  ## body element does not paint in the closed state.  Distinct
  ## from ``containerClass`` because tests assert on each modifier
  ## independently.
  if isExpanded:
    AgentActivityDeepReviewBodyClass
  else:
    AgentActivityDeepReviewBodyClass & " " &
      AgentActivityDeepReviewHiddenModifier

proc chevronChar*(isExpanded: bool): string =
  ## Single-character chevron rendered in the header.  Mirrors the
  ## legacy ``"v"`` / ``">"`` glyphs.  Returned as a Nim string so
  ## the IsoNim DSL ``text`` node renders it verbatim across both
  ## renderers.
  if isExpanded:
    "v"
  else:
    ">"

proc formatPercent*(value: float): string =
  ## Format a coverage percentage with one decimal place plus the
  ## trailing ``%`` glyph.  Matches the ``fmt"{summary.coveragePercent:
  ## .1f}%"`` calls in the legacy ``renderSummaryCards`` /
  ## header-badge code paths.  Implemented manually so the same
  ## helper compiles on both ``test-vm-native`` and ``test-vm-js``
  ## without dragging in ``std/strformat`` (which is fine but
  ## adds compilation surface for headless tests).
  let scaled = (value * 10.0).int
  let whole = scaled div 10
  var frac = scaled mod 10
  if frac < 0:
    frac = -frac
  result = $whole & "." & $frac & "%"

proc coverageBadgeText*(summary: AgentDeepReviewCoverageSummary): string =
  ## Header-badge text shown when the panel is collapsed.  Renders
  ## the coverage percentage with a single decimal place.  Returns
  ## an empty string when the summary is at its default value AND
  ## no test runs have been recorded — mirrors the legacy "show a
  ## compact coverage percentage" behaviour while suppressing the
  ## badge before any data has arrived.
  if summary.coveragePercent <= 0.0 and
     summary.totalLinesCovered == 0 and
     summary.totalLinesUncovered == 0:
    return ""
  formatPercent(summary.coveragePercent)

proc headerBadgeText*(isExpanded: bool;
                      summary: AgentDeepReviewCoverageSummary): string =
  ## Header badge is present as a stable span; it carries text only
  ## when collapsed and coverage data has arrived.
  if isExpanded:
    ""
  else:
    coverageBadgeText(summary)

proc coverageDetailText*(summary: AgentDeepReviewCoverageSummary): string =
  ## "X covered / Y uncovered" detail row in the coverage card.
  ## Mirrors the legacy ``fmt"{summary.totalLinesCovered} covered /
  ## {summary.totalLinesUncovered} uncovered"`` string.
  $summary.totalLinesCovered & " covered / " &
    $summary.totalLinesUncovered & " uncovered"

proc testsValueText*(results: AgentDeepReviewTestResults): string =
  ## "<passed>/<run>" value text for the tests card.  Mirrors the
  ## legacy ``fmt"{summary.testsPassed}/{summary.testsRun}"``
  ## string.
  $results.testsPassed & "/" & $results.testsRun

proc testsDetailText*(results: AgentDeepReviewTestResults): string =
  ## Tests-card detail label.  When at least one test failed it
  ## reports ``"<n> failed"``; otherwise it reports the legacy
  ## ``"all passing"`` string.  When no tests have been run at all
  ## the legacy view rendered the ``all passing`` branch — keep
  ## that behaviour so an empty panel does not flicker the warn
  ## modifier on first paint.
  if results.testsFailed > 0:
    $results.testsFailed & " failed"
  else:
    "all passing"

proc testsDetailClass*(results: AgentDeepReviewTestResults): string =
  if results.testsFailed > 0:
    "activity-dr-card-detail activity-dr-card-warn"
  else:
    "activity-dr-card-detail"

proc fileBasename*(path: string): string =
  ## Extract the basename from a path.  Mirrors the legacy
  ## ``fileBasename`` helper in ``ui/agent_activity_deepreview.nim``
  ## but operates on a Nim string (the VM stores ``path`` as
  ## ``string``, not ``cstring``, so the same helper works on both
  ## backends).
  let idx = path.rfind('/')
  if idx >= 0:
    path[idx + 1 .. ^1]
  else:
    path

proc fileRowCoverageText*(entry: AgentDeepReviewFileCoverage): string =
  ## "<covered>/<total>" coverage ratio text for the per-file row.
  ## Mirrors the legacy ``fmt"{entry.coveredLines}/{entry.totalLines}"``
  ## string.
  $entry.coveredLines & "/" & $entry.totalLines

proc fileRowFlowText*(entry: AgentDeepReviewFileCoverage): string =
  ## "yes" / "--" flow indicator for the per-file row.  Mirrors the
  ## legacy ``if entry.hasFlow: text "yes" else: text "--"`` branch.
  if entry.hasFlow:
    "yes"
  else:
    "--"

proc testRowClass*(passed: bool): string =
  ## Compose the class string for a test-result row.  Adds the
  ## pass / fail modifier so the stylesheet can colour-code the
  ## row.  Returns the base class for the unknown-state branch so
  ## the row never paints with a stray "test-pass"/"test-fail"
  ## modifier when the data is incomplete.
  if passed:
    AgentActivityDeepReviewTestRowClass & " " &
      AgentActivityDeepReviewTestPassClass
  else:
    AgentActivityDeepReviewTestRowClass & " " &
      AgentActivityDeepReviewTestFailClass

proc notificationKindClass*(kind: AgentDeepReviewNotificationKind): string =
  ## Map the notification kind to its CSS modifier.  Mirrors the
  ## legacy ``notificationCssClass`` proc; the test-pass/fail
  ## variants are folded together because the per-pass/fail tint
  ## is owned by the row class string above.
  case kind
  of adrnkCoverageUpdate: "activity-dr-notif-coverage"
  of adrnkFlowTraceUpdate: "activity-dr-notif-flow"
  of adrnkTestComplete: "activity-dr-notif-test"
  of adrnkCollectionComplete: "activity-dr-notif-complete"

proc notificationRowClass*(notif: AgentDeepReviewNotification): string =
  ## Compose the class string for a notification row.  Adds the
  ## per-kind modifier and a pass/fail tint for ``TestComplete``
  ## rows so the row's colour matches the legacy view.
  var parts = @[AgentActivityDeepReviewNotifRowClass,
                notificationKindClass(notif.kind)]
  if notif.kind == adrnkTestComplete:
    if notif.passed:
      parts.add AgentActivityDeepReviewTestPassClass
      parts.add "activity-dr-notif-test-pass"
    else:
      parts.add AgentActivityDeepReviewTestFailClass
      parts.add "activity-dr-notif-test-fail"
  parts.join(" ")

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderMockFileRow(r: MockRenderer;
                       entry: AgentDeepReviewFileCoverage): MockNode =
  ## Render a single file-coverage row in the headless DOM.  Mirrors
  ## the legacy ``activity-dr-files-row`` markup with three
  ## column spans (basename / coverage ratio / flow indicator).
  let base = fileBasename(entry.path)
  let coverageText = fileRowCoverageText(entry)
  let flowText = fileRowFlowText(entry)
  let row = ui(r):
    tdiv(class = AgentActivityDeepReviewFileRowClass):
      span(class = "activity-dr-files-col-name"):
        text base
      span(class = "activity-dr-files-col-coverage"):
        text coverageText
      span(class = "activity-dr-files-col-flow"):
        text flowText
  row

proc renderMockTestRow(r: MockRenderer;
                       notif: AgentDeepReviewNotification): MockNode =
  ## Render a single test-result row.  ``notif.label`` already
  ## carries the legacy ``"Test PASS: name (123ms)"`` label so the
  ## row body is just the label string.
  let cls = testRowClass(notif.passed)
  let label = notif.label
  let row = ui(r):
    tdiv(class = cls):
      text label
  row

proc renderMockNotifRow(r: MockRenderer;
                        notif: AgentDeepReviewNotification): MockNode =
  ## Render a single notification row in the recent-activity feed.
  let cls = notificationRowClass(notif)
  let label = notif.label
  let row = ui(r):
    tdiv(class = cls):
      text label
  row

proc renderAgentActivityDeepReviewPanel*(r: MockRenderer;
    vm: AgentActivityDeepReviewVM): MockNode =
  ## Render the Agent Activity DeepReview pane for the Mock
  ## renderer.  Single ``ui()`` block builds the static shell;
  ## ``createRenderEffect`` blocks rebuild the dynamic content
  ## whenever any source signal changes.
  var outerContainer: MockNode
  var headerChevron: MockNode
  var headerBadge: MockNode
  var bodyContainer: MockNode
  var summaryContainer: MockNode
  var coverageValue: MockNode
  var coverageDetail: MockNode
  var testsValue: MockNode
  var testsDetail: MockNode
  var filesContainer: MockNode
  var filesEmpty: MockNode
  var testsContainer: MockNode
  var testsEmpty: MockNode
  var notifsContainer: MockNode
  var notifsEmpty: MockNode

  let panel = ui(r):
    tdiv(ref = outerContainer,
         class = AgentActivityDeepReviewContainerClass):
      tdiv(class = AgentActivityDeepReviewHeaderClass,
           onclick = proc() = vm.toggleExpanded()):
        span(ref = headerChevron,
             class = AgentActivityDeepReviewChevronClass):
          text ">"
        span(class = AgentActivityDeepReviewHeaderLabelClass):
          text AgentActivityDeepReviewLabelText
        span(ref = headerBadge,
             class = AgentActivityDeepReviewHeaderBadgeClass):
          text ""
      tdiv(ref = bodyContainer, class = AgentActivityDeepReviewBodyClass):
        tdiv(ref = summaryContainer,
             class = AgentActivityDeepReviewSummaryClass):
          tdiv(class = AgentActivityDeepReviewCardClass &
                       " activity-dr-card-coverage"):
            tdiv(class = "activity-dr-card-label"):
              text "Coverage"
            tdiv(ref = coverageValue, class = "activity-dr-card-value"):
              text ""
            tdiv(ref = coverageDetail, class = "activity-dr-card-detail"):
              text ""
          tdiv(class = AgentActivityDeepReviewCardClass &
                       " activity-dr-card-tests"):
            tdiv(class = "activity-dr-card-label"):
              text "Tests"
            tdiv(ref = testsValue, class = "activity-dr-card-value"):
              text ""
            tdiv(ref = testsDetail, class = "activity-dr-card-detail"):
              text ""
        tdiv(ref = filesContainer,
             class = AgentActivityDeepReviewFilesClass):
          tdiv(class = AgentActivityDeepReviewFilesHeaderClass):
            span(class = "activity-dr-files-col-name"):
              text "File"
            span(class = "activity-dr-files-col-coverage"):
              text "Coverage"
            span(class = "activity-dr-files-col-flow"):
              text "Flow"
          tdiv(ref = filesEmpty,
               class = AgentActivityDeepReviewFilesEmptyClass):
            text AgentActivityDeepReviewFilesEmptyText
        tdiv(ref = testsContainer,
             class = AgentActivityDeepReviewTestsClass):
          tdiv(class = AgentActivityDeepReviewTestsHeaderClass):
            text "Test Results"
          tdiv(ref = testsEmpty,
               class = AgentActivityDeepReviewTestsEmptyClass):
            text AgentActivityDeepReviewTestsEmptyText
        tdiv(ref = notifsContainer,
             class = AgentActivityDeepReviewNotifsClass):
          tdiv(class = AgentActivityDeepReviewNotifsHeaderClass):
            text "Recent Activity"
          tdiv(ref = notifsEmpty,
               class = AgentActivityDeepReviewNotifsEmptyClass):
            text AgentActivityDeepReviewNotifsEmptyText

  # ----- Outer collapsed/expanded toggle ---------------------------
  createRenderEffect proc() =
    let expanded = vm.isExpanded.val
    r.setAttribute(outerContainer, "class", containerClass(expanded))
    r.setAttribute(bodyContainer, "class", bodyClass(expanded))
    # Chevron flips between '>' (collapsed) and 'v' (expanded).
    r.clearChildren(headerChevron)
    let glyph = chevronChar(expanded)
    let glyphNode = ui(r):
      text glyph
    r.appendChild(headerChevron, glyphNode)
    # Header badge — visible only when collapsed AND the summary
    # has at least one data point.
    r.clearChildren(headerBadge)
    if not expanded:
      let badge = coverageBadgeText(vm.coverageSummary.val)
      if badge.len > 0:
        let badgeNode = ui(r):
          text badge
        r.appendChild(headerBadge, badgeNode)

  # ----- Coverage / tests cards ------------------------------------
  createRenderEffect proc() =
    let summary = vm.coverageSummary.val
    let results = vm.testResults.val
    # Coverage card
    r.clearChildren(coverageValue)
    let coverageVal = formatPercent(summary.coveragePercent)
    let coverageValNode = ui(r):
      text coverageVal
    r.appendChild(coverageValue, coverageValNode)
    r.clearChildren(coverageDetail)
    let coverageDetailVal = coverageDetailText(summary)
    let coverageDetailNode = ui(r):
      text coverageDetailVal
    r.appendChild(coverageDetail, coverageDetailNode)
    # Tests card
    r.clearChildren(testsValue)
    let testsVal = testsValueText(results)
    let testsValNode = ui(r):
      text testsVal
    r.appendChild(testsValue, testsValNode)
    r.clearChildren(testsDetail)
    let testsDetailVal = testsDetailText(results)
    let testsDetailNode = ui(r):
      text testsDetailVal
    r.appendChild(testsDetail, testsDetailNode)
    # Failures pill — flip the warn modifier on the tests card detail.
    if results.testsFailed > 0:
      r.setAttribute(testsDetail, "class",
                     "activity-dr-card-detail activity-dr-card-warn")
    else:
      r.setAttribute(testsDetail, "class", "activity-dr-card-detail")

  # ----- Per-file coverage table -----------------------------------
  createRenderEffect proc() =
    let entries = vm.fileCoverage.val
    # Wipe rows from the previous tick (preserve header + empty
    # placeholder which sit at the start).  Cheaper to clear and
    # rebuild because the legacy view always emits the table in
    # one shot anyway.
    r.clearChildren(filesContainer)
    let header = ui(r):
      tdiv(class = AgentActivityDeepReviewFilesHeaderClass):
        span(class = "activity-dr-files-col-name"):
          text "File"
        span(class = "activity-dr-files-col-coverage"):
          text "Coverage"
        span(class = "activity-dr-files-col-flow"):
          text "Flow"
    r.appendChild(filesContainer, header)
    if entries.len == 0:
      let empty = ui(r):
        tdiv(class = AgentActivityDeepReviewFilesEmptyClass):
          text AgentActivityDeepReviewFilesEmptyText
      r.appendChild(filesContainer, empty)
    else:
      for entry in entries:
        let row = renderMockFileRow(r, entry)
        r.appendChild(filesContainer, row)

  # ----- Test results list -----------------------------------------
  createRenderEffect proc() =
    let allNotifs = vm.notifications.val
    # Filter for ``TestComplete`` notifications — the legacy
    # ``testResults`` seq stored exactly those.  Keeping the filter
    # local to the view means the VM does not need to maintain a
    # parallel "tests only" signal.
    var tests: seq[AgentDeepReviewNotification] = @[]
    for n in allNotifs:
      if n.kind == adrnkTestComplete:
        tests.add(n)
    r.clearChildren(testsContainer)
    let header = ui(r):
      tdiv(class = AgentActivityDeepReviewTestsHeaderClass):
        text "Test Results"
    r.appendChild(testsContainer, header)
    if tests.len == 0:
      let empty = ui(r):
        tdiv(class = AgentActivityDeepReviewTestsEmptyClass):
          text AgentActivityDeepReviewTestsEmptyText
      r.appendChild(testsContainer, empty)
    else:
      for n in tests:
        let row = renderMockTestRow(r, n)
        r.appendChild(testsContainer, row)

  # ----- Notifications feed ----------------------------------------
  createRenderEffect proc() =
    let notifs = vm.notifications.val
    r.clearChildren(notifsContainer)
    let header = ui(r):
      tdiv(class = AgentActivityDeepReviewNotifsHeaderClass):
        text "Recent Activity"
    r.appendChild(notifsContainer, header)
    if notifs.len == 0:
      let empty = ui(r):
        tdiv(class = AgentActivityDeepReviewNotifsEmptyClass):
          text AgentActivityDeepReviewNotifsEmptyText
      r.appendChild(notifsContainer, empty)
    else:
      # Render most-recent first to match the legacy ``while i
      # >= startIdx`` loop in ``renderRecentNotifications``.
      var i = notifs.len - 1
      while i >= 0:
        let row = renderMockNotifRow(r, notifs[i])
        r.appendChild(notifsContainer, row)
        i -= 1

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc renderWebFileRow(r: WebRenderer; entry: AgentDeepReviewFileCoverage):
      isonim_dom.Element =
    ui(r):
      tdiv(class = AgentActivityDeepReviewFileRowClass):
        span(class = "activity-dr-files-col-name"):
          text fileBasename(entry.path)
        span(class = "activity-dr-files-col-coverage"):
          text fileRowCoverageText(entry)
        span(class = "activity-dr-files-col-flow"):
          text fileRowFlowText(entry)

  proc renderWebTestRow(r: WebRenderer; notif: AgentDeepReviewNotification):
      isonim_dom.Element =
    ui(r):
      tdiv(class = testRowClass(notif.passed)):
        text notif.label

  proc renderWebNotifRow(r: WebRenderer; notif: AgentDeepReviewNotification):
      isonim_dom.Element =
    ui(r):
      tdiv(class = notificationRowClass(notif)):
        text notif.label

  proc renderAgentActivityDeepReviewPanel*(r: WebRenderer;
      vm: AgentActivityDeepReviewVM): isonim_dom.Element =
    ## Render the Agent Activity DeepReview pane for the real DOM.
    ## Same dispatch shape as the Mock variant.
    var filesContainer: isonim_dom.Element
    var testsContainer: isonim_dom.Element
    var notifsContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = containerClass(vm.isExpanded.val)):
        tdiv(class = AgentActivityDeepReviewHeaderClass,
             onclick = proc() = vm.toggleExpanded()):
          span(class = AgentActivityDeepReviewChevronClass):
            text chevronChar(vm.isExpanded.val)
          span(class = AgentActivityDeepReviewHeaderLabelClass):
            text AgentActivityDeepReviewLabelText
          span(class = AgentActivityDeepReviewHeaderBadgeClass):
            text headerBadgeText(vm.isExpanded.val, vm.coverageSummary.val)
        tdiv(class = bodyClass(vm.isExpanded.val)):
          tdiv(class = AgentActivityDeepReviewSummaryClass):
            tdiv(class = AgentActivityDeepReviewCardClass &
                         " activity-dr-card-coverage"):
              tdiv(class = "activity-dr-card-label"):
                text "Coverage"
              tdiv(class = "activity-dr-card-value"):
                text formatPercent(vm.coverageSummary.val.coveragePercent)
              tdiv(class = "activity-dr-card-detail"):
                text coverageDetailText(vm.coverageSummary.val)
            tdiv(class = AgentActivityDeepReviewCardClass &
                         " activity-dr-card-tests"):
              tdiv(class = "activity-dr-card-label"):
                text "Tests"
              tdiv(class = "activity-dr-card-value"):
                text testsValueText(vm.testResults.val)
              tdiv(class = testsDetailClass(vm.testResults.val)):
                text testsDetailText(vm.testResults.val)
          tdiv(ref = filesContainer,
               class = AgentActivityDeepReviewFilesClass):
            discard
          tdiv(ref = testsContainer,
               class = AgentActivityDeepReviewTestsClass):
            discard
          tdiv(ref = notifsContainer,
               class = AgentActivityDeepReviewNotifsClass):
            discard

    # ----- Per-file coverage table -----------------------------------
    createRenderEffect proc() =
      let entries = vm.fileCoverage.val
      # Dynamic list host: clear the stable section and append DSL-built
      # header/row branches for the latest VM snapshot.
      r.clearChildren(filesContainer)
      let header = ui(r):
        tdiv(class = AgentActivityDeepReviewFilesHeaderClass):
          span(class = "activity-dr-files-col-name"):
            text "File"
          span(class = "activity-dr-files-col-coverage"):
            text "Coverage"
          span(class = "activity-dr-files-col-flow"):
            text "Flow"
      r.appendChild(filesContainer, header)
      if entries.len == 0:
        let empty = ui(r):
          tdiv(class = AgentActivityDeepReviewFilesEmptyClass):
            text AgentActivityDeepReviewFilesEmptyText
        r.appendChild(filesContainer, empty)
      else:
        for entry in entries:
          r.appendChild(filesContainer, renderWebFileRow(r, entry))

    # ----- Test results list -----------------------------------------
    createRenderEffect proc() =
      let allNotifs = vm.notifications.val
      var tests: seq[AgentDeepReviewNotification] = @[]
      for n in allNotifs:
        if n.kind == adrnkTestComplete:
          tests.add(n)
      # Dynamic list host; rows are rebuilt rather than patched because
      # the legacy panel emitted these sections in one pass.
      r.clearChildren(testsContainer)
      let header = ui(r):
        tdiv(class = AgentActivityDeepReviewTestsHeaderClass):
          text "Test Results"
      r.appendChild(testsContainer, header)
      if tests.len == 0:
        let empty = ui(r):
          tdiv(class = AgentActivityDeepReviewTestsEmptyClass):
            text AgentActivityDeepReviewTestsEmptyText
        r.appendChild(testsContainer, empty)
      else:
        for n in tests:
          r.appendChild(testsContainer, renderWebTestRow(r, n))

    # ----- Notifications feed ----------------------------------------
    createRenderEffect proc() =
      let notifs = vm.notifications.val
      # Dynamic list host; most-recent-first ordering mirrors the legacy
      # notification feed.
      r.clearChildren(notifsContainer)
      let header = ui(r):
        tdiv(class = AgentActivityDeepReviewNotifsHeaderClass):
          text "Recent Activity"
      r.appendChild(notifsContainer, header)
      if notifs.len == 0:
        let empty = ui(r):
          tdiv(class = AgentActivityDeepReviewNotifsEmptyClass):
            text AgentActivityDeepReviewNotifsEmptyText
        r.appendChild(notifsContainer, empty)
      else:
        var i = notifs.len - 1
        while i >= 0:
          r.appendChild(notifsContainer, renderWebNotifRow(r, notifs[i]))
          i -= 1

    panel

  proc mountIsoNimAgentActivityDeepReviewPanel*(
      container: isonim_dom.Element;
      vm: AgentActivityDeepReviewVM) =
    ## Mount the IsoNim Agent Activity DeepReview pane as a child of
    ## ``container``.  Reactive effects handle every subsequent
    ## update — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderAgentActivityDeepReviewPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
