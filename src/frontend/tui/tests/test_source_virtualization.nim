## test_source_virtualization.nim — CTUI-5, Tier 1, over a real provider.
##
## ## What this suite establishes
##
## CTUI-5: "on a >10,000-line file: asserts the number of lines materialized
## stays within window+overscan across a long scroll, and that RSS does not
## grow monotonically. This is the only test that can catch the memory target
## regressing before CTUI-14 measures it."
##
## Three bounds, all asserted rather than described:
##
##   1. **`SourceVM` holds at most `viewport + 2 * overscan` lines**, at EVERY
##      one of the scroll's stops. `trimToWindow` runs before every request, so
##      this is a property of the seam CTUI-4 built; the assertion here is that
##      the PANE does not defeat it — a pane that accumulated its own copy
##      would still see a trimmed VM.
##   2. **The pane materializes at most one row of source per body row.**
##      `SourcePaneScreen.materializedLines` counts what the frame read out of
##      the model, so a pane that walked the whole file to find the visible
##      part would report a number larger than the pane is tall.
##   3. **The highlighter's cache is bounded.** The cache key includes the
##      WINDOW, so a long scroll produces one entry per window visited; an
##      unbounded cache would make "the pane holds only its window" true of the
##      text and false of the process. `MaxCachedWindows` caps it and this
##      suite asserts the cap holds across 300 windows.
##
## …and then RSS, which is the milestone's own instrument and is reported with
## its limits stated rather than presented as a memory measurement it is not.
##
## ## WHERE THE 12 000-LINE FILE COMES FROM, AND WHY IT IS NOT A FIXTURE
##
## No recorded fixture in this campaign's corpus has a file that long — `calc`
## is 116 lines and `noir_space_ship`'s `main.nr` is 38. So this suite writes
## one, into a trace folder's `files/` payload at the path
## `ct/trace/ctfs_sources.safePayloadPath` puts it, and reads it back through
## the PRODUCTION `SourceProvider` (`spkCtfsMaterialized`) — the same code path
## a `.ct` container's unpacked sources take. The recorded path is absolute and
## does not exist on any machine running this suite, and the provider is built
## with `allowWorkingTree = false`, so the payload is the only thing that can
## answer.
##
## The STORE, the `EditorVM` and the `SourceVM` are a real
## `HeadlessDebugSession` over a real `replay-server` on the `calc` fixture.
## `store.updateDebuggerPosition` — the production call
## `headless_session.updatePositionFromCompleteMove` makes on every
## `ct/complete-move` event — is what points that session's `SourceVM` at the
## large file. Nothing here is mocked: there is no `MockBackendService`, and
## the only synthetic thing in the suite is the CONTENT of a file, which is the
## subject rather than the instrument.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## Same reason as `test_source_stepping_forward_backward.nim`: `app/tests/` is
## walked by `tests/test_tui_facade_boundary.nim`, which forbids
## `viewmodel/headless_session`.
##
## ## Templates, not procs, for anything that calls `check`

import std/[os, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim_tui

import headless_session
import store/replay_data_store
import viewmodels/source_vm
import sdk/source_provider

import ../app/source_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 27

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  BigFileLines = 12_000
    ## ">10,000-line file", with room to spare. Each line names its own number,
    ## so an off-by-one in the window arithmetic shows up as the wrong string
    ## rather than as text that merely looks plausible.
  RecordedBigPath = "/opt/ctui5/virtualization/huge_module.py"
    ## An ABSOLUTE recorded path that exists on no machine running this suite,
    ## so the provider must resolve through the payload rather than falling
    ## through to a working-tree read that would succeed here and nowhere else.
    ## `.py` so the LEXICAL highlighter runs — the tree-sitter path on a
    ## 12 000-line window would measure the parser rather than the pane.
  PaneWidth = 90
  PaneHeight = 46
    ## The Ultra-wide profile's `editor` rectangle at 200x60, from CTUI-3's
    ## measured table: `editor (40,1 90x46)`. The tallest pane this campaign
    ## produces, so the bound below is asserted at its worst case.
  ViewportLines = PaneHeight - 1
  Overscan = 8
  MaxHeldLines = ViewportLines + 2 * Overscan
    ## `SourceVM`'s contract, spelled out: the viewport plus overscan on each
    ## side. Asserted as an upper bound at every stop of the scroll.
  ScrollStops = 150
  ScrollStride = BigFileLines div ScrollStops
    ## 80 lines per stop, which is larger than the window — so every stop is a
    ## fresh window and a fresh fetch, which is the case that would expose an
    ## accumulating VM. A stride smaller than the window would be served from
    ## the held range and would prove nothing about trimming.
  RssSampleEvery = 15
  RssGrowthCapKb = 24 * 1024
    ## 24 MB. Stated as a CEILING on the growth across the scroll rather than
    ## as the memory target: CTUI-14 owns the < 30 MB steady-state number and
    ## measures it on the APP. What this suite can say is that scrolling a
    ## 12 000-line file twice does not add tens of megabytes, which is what a
    ## pane that stopped virtualizing would do.

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

proc bigLineText(line: int): string =
  ## Line `line` of the synthetic file. Real Python, so the lexical highlighter
  ## has something to classify, and self-describing so a wrong line is visible
  ## as a wrong number rather than as plausible text.
  "    value_" & $line & " = compute(" & $line & ")  # line " & $line &
    " of " & $BigFileLines

proc writeBigPayload(root: string): string =
  ## A trace folder holding the large file, at the payload path the WRITER
  ## chooses. Returns the trace folder.
  let traceDir = root / "trace"
  var text = newStringOfCap(BigFileLines * 64)
  for line in 1 .. BigFileLines:
    text.add bigLineText(line)
    text.add '\n'
  let payload = traceDir / "files" / RecordedBigPath[1 .. ^1]
  createDir(payload.parentDir)
  writeFile(payload, text)
  traceDir

proc residentKb(): int =
  ## This process's resident set size, in KB, from `/proc/self/statm`.
  ##
  ## A DIAGNOSTIC FAILURE rather than a skip when the file is absent: the two
  ## TUI lanes run on Linux, and a run that silently stopped measuring memory
  ## would be a run whose memory assertion passed for free.
  const statm = "/proc/self/statm"
  if not fileExists(statm):
    raise newException(IOError,
      "RSS cannot be measured: " & statm & " does not exist. This suite's " &
      "memory bound is CTUI-5's only guard on the CTUI-14 target, so a host " &
      "without procfs must not run it silently — port `residentKb` or run " &
      "the `tui` lane on Linux.")
  let fields = readFile(statm).splitWhitespace()
  if fields.len < 2:
    raise newException(IOError, statm & " has fewer than two fields")
  parseInt(fields[1]) * 4   # pages -> KB, 4 KiB pages

type VHarness = object
  session: HeadlessDebugSession
  vm: SourceVM
  provider: SourceProvider
  cache: HighlighterCache
  root: string

proc openHarness(tracePath: string): VHarness =
  let root = getTempDir() / ("ctui5-virt-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  let bigTrace = writeBigPayload(root)
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let vm = createSourceVM(session.session.store, session.session.editorVM)
  vm.setViewport(height = ViewportLines, overscan = Overscan)
  VHarness(
    session: session,
    vm: vm,
    provider: newCtfsSourceProvider(bigTrace, allowWorkingTree = false),
    cache: newHighlighterCache(),
    root: root)

proc closeHarness(h: VHarness) =
  h.vm.dispose()
  h.session.close()
  removeDir(h.root)

proc serveOne(h: VHarness; request: SourceLineRequest): SourceFetch =
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillWindow(h: VHarness): int =
  ## Serve everything the window lacks; return how many LINES were fetched.
  for request in h.vm.requestMissing():
    let fetch = h.serveOne(request)
    discard h.session.session.store.applySourceFetch(h.vm, fetch)
    result += fetch.lines.len

proc paneModel(h: VHarness): SourcePaneModel =
  sourcePaneModelFor(
    h.vm, h.session.session.store.degraded.sourceAvailability.val)

proc isStrictlyIncreasing(samples: seq[int]): bool =
  for i in 1 ..< samples.len:
    if samples[i] <= samples[i - 1]:
      return false
  samples.len >= 2

suite "CTUI-5: the source pane stays a window on a 12 000-line file":

  test "a long scroll never materializes more than window + overscan":
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
      let h = openHarness(resolution.tracePath)
      defer: h.closeHarness()

      # ---- point the session's SourceVM at the large file ------------------
      # `updateDebuggerPosition` is the production call `headless_session`
      # makes on every `ct/complete-move` event; nothing here reaches into the
      # VM's own signals.
      h.session.session.store.updateDebuggerPosition(
        rrTicks = 0, file = RecordedBigPath, line = 1)
      ck h.vm.revision.val.path == RecordedBigPath
      ck h.vm.executionLine.val == 1

      # ---- the positive control: the payload really answers ----------------
      let first = h.fillWindow()
      ck first > 0
      ck h.vm.totalLineCount.val == BigFileLines
      ck h.vm.lineAt(1).kind == srkHeld
      ck h.vm.lineAt(1).text == bigLineText(1)
      # …and it is the RECORDING's copy, not this machine's: the provider was
      # built refusing the working tree and the recorded path exists nowhere.
      ck not fileExists(RecordedBigPath)

      # ---- the scroll ------------------------------------------------------
      var maxHeld = 0
      var maxMaterialized = 0
      var maxRows = 0
      var totalFetched = first
      var stops = 0
      var rss: seq[int] = @[]
      var overBound: seq[string] = @[]
      var textWrong = 0

      for direction in [1, -1]:
        for i in 0 ..< ScrollStops:
          let top =
            if direction == 1: 1 + i * ScrollStride
            else: BigFileLines - i * ScrollStride
          h.vm.scrollTo(top)
          totalFetched += h.fillWindow()
          inc stops

          let held = h.vm.heldLines.val.len
          if held > maxHeld: maxHeld = held
          if held > MaxHeldLines:
            overBound.add "top " & $top & ": held " & $held &
              " line(s), bound is " & $MaxHeldLines

          let model = h.paneModel()
          let screen = sourcePaneScreen(model, PaneWidth, PaneHeight, h.cache)
          if screen.materializedLines > maxMaterialized:
            maxMaterialized = screen.materializedLines
          if screen.rows.len > maxRows:
            maxRows = screen.rows.len
          # Every visible held line carries the text that file really has at
          # that number. Counted rather than asserted per line, so the stop
          # count stays the assertion.
          for offset in 0 ..< model.heldLines.len:
            if model.heldLines[offset] !=
               bigLineText(model.firstHeldLine + offset):
              inc textWrong

          if stops mod RssSampleEvery == 0:
            rss.add residentKb()

      # ECHOED, not only checkpointed: `std/unittest` flushes checkpoints from
      # `fail()` alone, and these are the numbers a reader of a GREEN run needs
      # to watch trend. Same reason CTUI-3 echoes its projection timing.
      echo "CTUI-5 VIRTUALIZATION: " & $stops & " stop(s), max held " &
           $maxHeld & " line(s) (bound " & $MaxHeldLines & "), max " &
           "materialized " & $maxMaterialized & " (pane body " &
           $(PaneHeight - 1) & "), " & $totalFetched & " line(s) fetched " &
           "from a " & $BigFileLines & "-line file"
      checkpoint("stops: " & $stops & ", max held: " & $maxHeld &
                 ", max materialized: " & $maxMaterialized &
                 ", total lines fetched: " & $totalFetched)
      ck stops == 2 * ScrollStops
      ck overBound.len == 0
      # THE EXACT BOUND, and the positive twin beside it: the window really was
      # filled (a VM that held nothing would satisfy the upper bound for free).
      ck maxHeld <= MaxHeldLines
      ck maxHeld >= ViewportLines
      ck maxMaterialized <= ViewportLines
      ck maxMaterialized >= 1
      ck maxRows == PaneHeight
      ck textWrong == 0

      # ---- the pane FETCHED a window per stop, not a file per stop ---------
      # 300 stops over a 12 000-line file. Fetching the window each time is
      # about 300 * (viewport + overscan); fetching the file each time would be
      # 300 * 12 000. The bound is stated against the second, with a floor
      # against the first so a provider that answered nothing cannot pass.
      checkpoint("lines fetched across the scroll: " & $totalFetched &
                 " (a window per stop is ~" & $(stops * MaxHeldLines) &
                 ", a file per stop would be " & $(stops * BigFileLines) & ")")
      ck totalFetched <= stops * MaxHeldLines
      ck totalFetched >= stops * ViewportLines

      # ---- the highlighting cache is bounded -------------------------------
      # 300 distinct windows visited; the cache keeps `MaxCachedWindows`.
      checkpoint("highlight cache: " & $h.cache.entries.len & " entrie(s), " &
                 $h.cache.parseCount & " parse(s), " &
                 $h.cache.evictions & " eviction(s)")
      ck h.cache.entries.len <= MaxCachedWindows
      ck h.cache.parseCount > MaxCachedWindows
      ck h.cache.evictions > 0

      # ---- RSS -------------------------------------------------------------
      # WHAT THIS NUMBER IS AND IS NOT. It is the whole process's resident set,
      # which carries a `replay-server` client, an open trace, the Nim runtime
      # and this suite's own 12 000-line string. It cannot attribute a
      # kilobyte to the pane. What it CAN do is fail when the pane stops
      # virtualizing, because that failure is tens of megabytes over 300
      # stops, and that is the regression CTUI-5 asks this suite to catch
      # before CTUI-14 measures the target properly.
      echo "CTUI-5 RSS ACROSS THE SCROLL: " & $rss & " KB (samples every " &
           $RssSampleEvery & " stops)"
      ck rss.len == (2 * ScrollStops) div RssSampleEvery
      ck rss[0] > 0
      # The milestone's own words: "RSS does not grow monotonically".
      ck not isStrictlyIncreasing(rss)
      let growth = rss[^1] - rss[0]
      echo "CTUI-5 RSS GROWTH: " & $growth & " KB across " & $stops &
           " scroll stops (cap " & $RssGrowthCapKb & " KB)"
      ck growth < RssGrowthCapKb

  test "assertion count":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
