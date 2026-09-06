## test_event_log_virtualization.nim — CTUI-8, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-8: "a dense log pages rather than loading whole; scrolling requests
## successive pages exactly once." And its risk mitigation: "dense event logs
## exhaust memory / server-side pagination".
##
## Both, against `noir_space_ship`'s real 70-event log through a real
## `ct/event-load`, and the three claims are asserted SEPARATELY because a pane
## can satisfy any two of them and fail the third:
##
##   1. IT PAGES. After the first screen the model holds ONE page, which is
##      strictly fewer rows than the log has, and the seam was called once.
##   2. EACH PAGE IS FETCHED EXACTLY ONCE. `fetchedPageOrder` is the whole
##      history of calls; scrolling to the end and back must leave no page in it
##      twice. A model that re-fetched on every repaint would satisfy claim 1
##      and fail this.
##   3. IT RELEASES. `heldRows` after scrolling to the end is bounded by the
##      window and its neighbours, NOT by how far the reader has travelled. A
##      pane that merely stopped DRAWING would satisfy claims 1 and 2 and hold
##      the entire log — which is exactly the failure the mitigation names.
##
## ## THE PAGING IS COMPARED AGAINST A GROUND TRUTH THE PANE DID NOT PRODUCE
##
## The whole log is fetched ONCE, separately, in a single request, and the paged
## walk is compared against it: every event exactly once, in order, with the same
## ticks and the same content. A paged reader checked against its own paging
## would be comparing a thing with itself.
##
## ## THE SERVER REALLY SLICES, AND THAT IS ASSERTED ON THE WIRE
##
## `Handler::event_load` clamps `start`/`count` against its cached events and
## sends only the window. So the assertion that this is SERVER-side pagination
## and not a client-side filter is that a request for `(start: 40, count: 16)`
## comes back with 16 rows whose FIRST is the whole log's 41st — measured
## against the ground truth above, not against the pane.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## Same reason as CTUI-5's, CTUI-6's and CTUI-7's session-driven suites:
## `tests/test_tui_facade_boundary.nim` forbids `headless_session` under `app/`.
##
## ## No mocks
##
## A real `.ct` trace, a real `replay-server`, and a seam that is one call to
## `ct/event-load` per page.
##
## ## Templates, not procs, for anything that calls `check`

import std/[sequtils, sets, strutils, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]
import viewmodels/[event_log_vm, timeline_vm]

import ../app/timeline_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 62

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "noir_space_ship"
    ## 70 recorded events — the only log in CTUI-1's corpus with an interior.
    ## `calc` and `wide_state` record six each, which one page holds, so paging
    ## could not be observed on them at all.
  PageSize = 16
    ## Five pages of this log, the last of them SHORT (70 = 4x16 + 6). Both
    ## facts are load-bearing: four full pages is enough for "exactly once" to
    ## mean something, and a short last page is how the model discovers the end.
  BodyHeight = 8
    ## Half a page, so a scroll of one body crosses a page boundary every other
    ## step rather than exactly on one — a window that always aligned with a
    ## page would never test the two-page window.
  PaneWidth = 80

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0
  seamCalls = 0
  seamWindows: seq[(int, int)] = @[]

proc countingPagesOver(session: HeadlessDebugSession): EventPages =
  ## The real `ct/event-load` seam, with a counter around it.
  ##
  ## The counter is OUTSIDE the model, so "the model called the seam N times"
  ## and "the model thinks it called the seam N times" are two numbers and the
  ## suite asserts they agree. A model that mis-counted its own fetches would
  ## otherwise report whatever it liked.
  let s = session
  result = proc(offset, limit: int): EventPage =
    inc seamCalls
    seamWindows.add (offset, limit)
    let entries = s.requestAndLoadEventLog(start = offset, count = limit)
    var rows: seq[EventRow] = @[]
    for entry in entries:
      rows.add EventRow(
        index: entry.eventIndex, tick: entry.rrTicks, file: entry.file,
        line: entry.line, content: entry.content,
        category: categoryFor(entry.kind, entry.stdout), kindId: entry.kind)
    EventPage(rows: rows, atEnd: entries.len < limit)

suite "CTUI-8: the event log pages, fetches each page once, and releases":

  test "noir_space_ship: a dense log pages rather than loading whole":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()

      # ---- THE GROUND TRUTH, fetched once and not through the pane ---------
      let truth = session.requestAndLoadEventLog(start = 0, count = 1_000_000)
      let expectedPages = (truth.len + PageSize - 1) div PageSize
      echo "CTUI-8 VIRTUALIZATION: ", truth.len, " recorded event(s), page ",
           PageSize, " -> ", expectedPages, " page(s), last one holds ",
           truth.len - (expectedPages - 1) * PageSize
      # THE ONE NUMBER WRITTEN DOWN ABOUT THIS FIXTURE, and it is asserted
      # rather than assumed: a re-recording that changed the log's size would
      # make every count below mean something else, and this line says so on the
      # spot instead of leaving a suite that still passes for the wrong reason.
      # Every OTHER count in this file is derived from `truth.len`.
      ck truth.len == 70
      ck expectedPages == 5
      # The last page is SHORT, which is how the end is discovered.
      ck truth.len mod PageSize != 0

      seamCalls = 0
      seamWindows = @[]
      var model = eventLogModelFor(countingPagesOver(session),
                                   currentTick = session.getCurrentRRTicks(),
                                   pageSize = PageSize)

      # ---- CLAIM 1: IT PAGES ----------------------------------------------
      model.ensureWindow(0, BodyHeight)
      ck seamCalls == 1
      ck model.fetchCount == seamCalls
      ck model.heldPages == 1
      ck model.heldRows == PageSize
      ck model.heldRows < truth.len
      ck seamWindows == @[(0, PageSize)]
      # The total is NOT yet known, because the first page came back full. A
      # model that claimed a total here would have had to fetch the whole log.
      ck model.knownTotal == -1
      ck not model.atEndKnown

      # ---- THE SERVER REALLY SLICED ---------------------------------------
      # A page from the middle, compared against the ground truth's own rows.
      let midPage = 2
      model.ensureWindow(midPage * PageSize, PageSize)
      let (foundMid, midRow) = model.rowAt(midPage * PageSize)
      ck foundMid
      ck midRow.tick == truth[midPage * PageSize].rrTicks
      ck midRow.content == truth[midPage * PageSize].content
      ck midRow.index == midPage * PageSize
      ck seamWindows[^1] == (midPage * PageSize, PageSize)

      # ---- CLAIM 2: EACH PAGE EXACTLY ONCE, scrolling to the end ----------
      # A body-at-a-time walk from the top, which crosses every page boundary.
      var seen = initHashSet[int]()
      var walked: seq[uint64] = @[]
      var top = 0
      while true:
        model.ensureWindow(top, BodyHeight)
        for row in model.paneRows(top, BodyHeight):
          if row.kind == elrEvent and row.index notin seen:
            seen.incl row.index
            walked.add row.event.tick
        if model.knownTotal >= 0 and top + BodyHeight >= model.knownTotal:
          break
        top += BodyHeight
      echo "CTUI-8 VIRTUALIZATION: walked ", walked.len, " row(s) in ",
           seamCalls, " fetch(es) of ", PageSize, "; page order ",
           model.fetchedPageOrder
      ck model.knownTotal == truth.len
      ck model.atEndKnown
      ck walked.len == truth.len
      # EXACTLY ONCE PER PAGE. The order is the whole call history, so a
      # duplicate anywhere in it fails here.
      ck model.fetchedPageOrder.len == expectedPages
      ck model.fetchedPageOrder.deduplicate().len == expectedPages
      ck seamCalls == expectedPages
      ck model.fetchCount == seamCalls
      for page in 0 ..< expectedPages:
        ck model.fetchesFor(page) == 1

      # ---- …AND THE ROWS ARE THE RECORDING'S, IN ORDER --------------------
      var mismatches = 0
      for i in 0 ..< truth.len:
        if walked[i] != truth[i].rrTicks:
          inc mismatches
      ck mismatches == 0
      ck walked[0] == truth[0].rrTicks
      ck walked[^1] == truth[^1].rrTicks

  test "scrolling back re-reads nothing, and the model releases what it left":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()
      let truth = session.requestAndLoadEventLog(start = 0, count = 1_000_000)
      let expectedPages = (truth.len + PageSize - 1) div PageSize

      seamCalls = 0
      seamWindows = @[]
      var model = eventLogModelFor(countingPagesOver(session),
                                   currentTick = session.getCurrentRRTicks(),
                                   pageSize = PageSize)

      # Walk to the end WITHOUT releasing, so every page is held…
      var top = 0
      while true:
        model.ensureWindow(top, BodyHeight)
        if model.knownTotal >= 0 and top + BodyHeight >= model.knownTotal:
          break
        top += BodyHeight
      let heldAtEnd = model.heldRows
      ck model.heldPages == expectedPages
      ck heldAtEnd == truth.len
      let fetchesAfterWalk = seamCalls
      ck fetchesAfterWalk == expectedPages

      # ---- CLAIM 3: IT RELEASES -------------------------------------------
      # `releaseOutside` drops every page more than one away from the window.
      # RELEASED MEANS RELEASED: `heldRows` counts objects, not rows drawn.
      let lastTop = max(0, model.knownTotal - BodyHeight)
      model.releaseOutside(lastTop, BodyHeight)
      echo "CTUI-8 VIRTUALIZATION RELEASE: held ", heldAtEnd, " row(s) of ",
           truth.len, " at the end of the walk; ", model.heldRows,
           " after releasing outside the window"
      ck model.heldRows < heldAtEnd
      # The window's page and its two neighbours — `keepPages = 1`. A bound,
      # not a count, because the window's own page may be the first or the last.
      ck model.heldPages <= 3
      ck model.heldPages >= 1
      # Nothing was re-fetched by releasing.
      ck seamCalls == fetchesAfterWalk

      # ---- SCROLLING BACK OVER A HELD PAGE RE-READS NOTHING ---------------
      let neighbourTop = max(0, lastTop - BodyHeight)
      model.ensureWindow(neighbourTop, BodyHeight)
      ck seamCalls == fetchesAfterWalk
      # …and scrolling back to a RELEASED page re-fetches it, exactly once, so
      # "held" and "released" are distinguishable rather than both silent.
      model.ensureWindow(0, BodyHeight)
      ck seamCalls == fetchesAfterWalk + 1
      ck model.fetchesFor(0) == 2
      let (foundFirst, firstRow) = model.rowAt(0)
      ck foundFirst
      ck firstRow.tick == truth[0].rrTicks

      # A window past the end asks for nothing: the model knows where the log
      # stops and does not go on requesting empty pages.
      let before = seamCalls
      model.ensureWindow(truth.len + 100, BodyHeight)
      ck seamCalls == before
      ck model.paneRows(truth.len, BodyHeight).len == 0

  test "a painted pane holds a page, not a log":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()
      let truth = session.requestAndLoadEventLog(start = 0, count = 1_000_000)

      seamCalls = 0
      seamWindows = @[]
      var model = eventLogModelFor(countingPagesOver(session),
                                   currentTick = session.getCurrentRRTicks(),
                                   pageSize = PageSize)
      model.ensureWindow(0, BodyHeight)
      let screen = eventLogScreen(model, PaneWidth, BodyHeight + 1)

      # PAINTING DOES NOT FETCH. The one entry point is `ensureWindow`, and this
      # is what makes the pane a pure function of what is held.
      ck seamCalls == 1
      ck screen.eventRows == BodyHeight
      ck screen.pendingRows == 0
      ck screen.bodyHeight == BodyHeight
      let titleText = rowText(screen.rows[0])
      checkpoint("event log title: '" & titleText & "'")
      ck titleText.contains(EventLogTitle)
      # The title says `16+`, because the end has not been found. A pane that
      # printed a total here would be printing one it did not have.
      ck titleText.contains($model.heldRows & "+")
      ck not titleText.contains($truth.len & " event(s)")

      # A row of the pane carries the recording's own tick and content.
      let firstBody = rowText(screen.rows[1])
      checkpoint("first event row: '" & firstBody & "'")
      ck firstBody.contains($truth[0].rrTicks)
      ck firstBody.contains(truth[0].content.strip())
      ck firstBody.contains(categoryLabel(ecOutput).strip())

      # A WINDOW WHOSE PAGE IS NOT HELD PAINTS A HOLE, NOT A SHORTER LIST.
      # The placeholder is what makes a forgotten `ensureWindow` visible.
      model.scrollTop = 3 * PageSize
      let unfetched = eventLogScreen(model, PaneWidth, BodyHeight + 1)
      ck seamCalls == 1
      ck unfetched.pendingRows == BodyHeight
      ck unfetched.eventRows == 0
      ck rowText(unfetched.rows[1]).strip() == PendingText

  test "assertion count":
    echo "CTUI-8 VIRTUALIZATION: examined ", examinedFixtures,
         " fixture case(s), ", verifiedFixtures, " verified, ",
         skippedFixtures, " skipped"
    ck examinedFixtures == 3
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures > 0
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
