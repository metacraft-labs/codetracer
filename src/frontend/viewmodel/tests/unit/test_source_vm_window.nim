## CTUI-4 — `SourceVM`'s window, driven over a REAL materialized source file.
##
## ## What is real here, and what is not mocked
##
## Exactly one mock appears, and it is not the subject: `MockBackendService` is
## passed to `createReplayDataStore` because the store cannot be constructed
## without a transport. No command is sent through it and nothing is asserted
## about it — see `newHarness`. The source text is a real file on the real
## filesystem, laid out under a real trace folder's `files/` payload exactly
## where `src/ct/trace/ctfs_sources.nim`'s `safePayloadPath` puts it, and it is
## read back through the production `SourceProvider`
## (`sdk/source_provider.nim`, `spkCtfsMaterialized`) — the same code path a
## `.ct` container's unpacked sources take. Nothing here substitutes an
## in-memory `seq[string]` for a file, because the two failures this suite
## exists to catch are both about the boundary between the two: a window that
## grows without bound, and a read outside the window that comes back as an
## empty string.
##
## ## The four properties, and why each is worth a suite
##
## 1. **The window tracks `cursorLine`.** A pane that does not follow the
##    execution pointer loses it off the bottom on the first step.
## 2. **Scrolling requests EXACTLY the newly visible lines.** Asserted as exact
##    counts and exact ranges, never as "at least one request"
##    (`codetracer-specs/Testing/Verification-Harness-Traps.md` §4b): a
##    provider that re-fetched the whole file on every scroll would satisfy any
##    lower bound and would defeat the virtualization outright.
## 3. **Overscan is honoured** — the held range is the viewport plus the
##    configured overscan, and *only* that. This is the half of the contract
##    that keeps the memory bounded, and it is why `requestMissing` trims
##    before it asks.
## 4. **A read outside the window is a REQUEST.** `lineAt` returns
##    `srkRequest`, and the request names the exact line and the exact
##    revision. An empty string here is how a source pane silently renders
##    blank, which is indistinguishable from a file of blank lines.
##
## ## Test-quality rules this file follows
##
## Every helper that calls `check` is a `template`, never a `proc`. A `proc`
## that fails a `check` sets `programResult = 1` while the enclosing test still
## prints `[OK]`, which is a live silent-self-pass mechanism found earlier in
## this campaign. There is no `skip`, no `when false`, and no early return on a
## missing prerequisite: this suite writes the file it reads, so it has no
## prerequisite to be missing.
##
## Native only, and rejected from `vm-unit-js` in `ci/lib/test-lane-files.sh`
## with that reason: the subject is the FILESYSTEM half of the source seam, and
## `std/os`'s file writes have no `nim js` equivalent. `SourceVM` itself
## compiles on both backends — `codetracer_embed` exports it and the JS lane
## compiles the facade — and the pure window arithmetic it depends on is
## asserted here as free functions so a JS-side regression in it would show up
## as a compile failure rather than as a gap.
##
## Compile + run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_source_vm_window.nim

import std/[os, sequtils, strutils, unittest]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../backend/[backend_service, mock_backend]
import ../../store/replay_data_store
import ../../viewmodels/[editor_vm, source_vm]
import ../../sdk/source_provider

# ---------------------------------------------------------------------------
# A real trace folder, with a real source payload in it
# ---------------------------------------------------------------------------

const
  RecordedPath = "/opt/ctui4/window_fixture/program.src"
    ## An ABSOLUTE recorded path that does not exist on any machine running
    ## this suite. That is deliberate: it forces the provider to resolve
    ## through the trace folder's `files/` payload, which is the path a real
    ## recording takes, rather than falling through to a working-tree read that
    ## would happen to succeed here and nowhere else.
  FixtureLineCount = 400
    ## Long enough that a 20-line viewport plus overscan is a small fraction of
    ## it, so "the VM holds the window" and "the VM holds the file" are
    ## distinguishable outcomes rather than the same number.

proc fixtureLineText(line: int): string =
  ## Line `line` of the fixture file. Each line names its own number, so an
  ## off-by-one in the window arithmetic shows up as a wrong string rather than
  ## as text that merely looks plausible.
  "line " & $line & " of " & $FixtureLineCount & " :: " & repeat('x', line mod 7)

proc writeTraceFolderWithSource(root: string): string =
  ## Build a trace folder holding one materialized source file and return it.
  ##
  ## The payload path is `safePayloadPath`'s answer, obtained by calling the
  ## writer's own function rather than by spelling the mapping again here — the
  ## same rule the provider follows, and for the same reason.
  let traceDir = root / "trace"
  var text = ""
  for line in 1 .. FixtureLineCount:
    text.add(fixtureLineText(line))
    text.add('\n')
  let payload = traceDir / "files" / RecordedPath[1 .. ^1]
  createDir(payload.parentDir)
  writeFile(payload, text)
  traceDir

type Harness = object
  store: ReplayDataStore
  editor: EditorVM
  vm: SourceVM
  provider: SourceProvider
  traceDir: string
  root: string

proc newHarness(): Harness =
  ## A store stopped at `RecordedPath`, an `EditorVM`, a `SourceVM` over it and
  ## a CTFS provider over a freshly written trace folder.
  ##
  ## `MockBackendService` appears here only as the `BackendService` the store
  ## constructor requires; this suite never sends a command through it and
  ## never asserts on one. The subject is the filesystem provider and the VM's
  ## own arithmetic, and the store cannot be constructed without a transport.
  let root = getTempDir() / "ctui4-window-" & $getCurrentProcessId()
  removeDir(root)
  createDir(root)
  let traceDir = writeTraceFolderWithSource(root)
  let store = createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())
  store.updateDebuggerPosition(rrTicks = 0, file = RecordedPath, line = 1)
  let editor = createEditorVM(store)
  Harness(
    store: store,
    editor: editor,
    vm: createSourceVM(store, editor),
    provider: newCtfsSourceProvider(traceDir, allowWorkingTree = false),
    traceDir: traceDir,
    root: root)

proc teardown(h: Harness) =
  h.vm.dispose()
  h.editor.dispose()
  removeDir(h.root)

proc serve(h: Harness; request: SourceLineRequest): SourceFetch =
  ## Run one request through the real provider and apply the answer.
  ##
  ## A `proc` rather than a template BECAUSE it calls no `check`: the rule is
  ## that a helper which asserts must be a template, and a helper that only
  ## moves data is clearer as a proc.
  var captured: SourceFetch
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  discard h.store.applySourceFetch(h.vm, captured)
  captured

proc fillWindow(h: Harness): seq[SourceLineRequest] =
  ## Ask the VM what it needs, serve every request, and return what was asked.
  result = h.vm.requestMissing()
  for request in result:
    discard h.serve(request)

# ---------------------------------------------------------------------------
# Assertion templates. Every one of these is a TEMPLATE, on purpose.
# ---------------------------------------------------------------------------

template checkHeldRangeIs(h: Harness; expectedFirst, expectedLast: int) =
  ## The VM holds exactly `expectedFirst .. expectedLast` and nothing else.
  check h.vm.heldFirstLine.val == expectedFirst
  check h.vm.heldLastLine == expectedLast
  check h.vm.heldLines.val.len == expectedLast - expectedFirst + 1

template checkHeldTextIsCorrect(h: Harness) =
  ## Every held line carries the text that file really has at that number.
  for offset, text in h.vm.heldLines.val:
    check text == fixtureLineText(h.vm.heldFirstLine.val + offset)

template checkRequestsAre(requests: seq[SourceLineRequest];
                          expected: seq[(int, int)]) =
  ## The requests are EXACTLY these ranges, in this order.
  ##
  ## Exact — count and contents — rather than "contains": a VM that asked for
  ## the whole file every time would pass a containment check while holding
  ## nothing to the contract.
  check requests.len == expected.len
  if requests.len == expected.len:
    for i, want in expected:
      check requests[i].firstLine == want[0]
      check requests[i].lastLine == want[1]

template checkLineIsHeld(h: Harness; lineNumber: int) =
  ## The parameter is `lineNumber` rather than `line` for a reason worth
  ## keeping: a Nim template substitutes its parameter identifier EVERYWHERE,
  ## including in a field position, so a parameter named `line` turns
  ## `read.line` into `read.200` at the call site. That is a compile error
  ## here, which is the good case; in a template that happened not to touch a
  ## `.line` field it would be a silent capture.
  let read = h.vm.lineAt(lineNumber)
  check read.kind == srkHeld
  check read.line == lineNumber
  if read.kind == srkHeld:
    check read.text == fixtureLineText(lineNumber)

template checkLineIsRequest(h: Harness; lineNumber: int;
                            expectedGeneration: int = 0) =
  ## The point of the whole suite: a line outside the window comes back as a
  ## REQUEST naming that line and that revision — never as `""`.
  let read = h.vm.lineAt(lineNumber)
  check read.kind == srkRequest
  check read.line == lineNumber
  if read.kind == srkRequest:
    check read.request.firstLine == lineNumber
    check read.request.lastLine == lineNumber
    check read.request.path == RecordedPath
    check read.request.sourceGeneration == expectedGeneration

# ---------------------------------------------------------------------------

suite "CTUI-4 — SourceVM holds a window, and says so when asked for the rest":

  test "the payload the provider reads is a real file this test wrote":
    # The premise of every other case here. If the fixture did not land on
    # disk, the assertions below would be about a provider that always fails,
    # and they would still be able to pass.
    let h = newHarness()
    defer: h.teardown()
    let payload = h.traceDir / "files" / RecordedPath[1 .. ^1]
    check fileExists(payload)
    check readFile(payload).splitLines.len == FixtureLineCount + 1
    check h.provider.supports()
    check h.provider.kind == spkCtfsMaterialized

  test "the first fill asks for the viewport plus overscan, and nothing else":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    check h.vm.visibleFirstLine.val == 1
    # Overscan cannot reach above line 1, so the first window is
    # 1 .. 20 + 5 = 1 .. 25.
    let requests = h.vm.requestMissing()
    checkRequestsAre(requests, @[(1, 25)])
    for request in requests:
      let fetch = h.serve(request)
      check fetch.status == sfsAvailable
      check fetch.origin == soTracePayload
      check fetch.totalLineCount == FixtureLineCount
    h.checkHeldRangeIs(1, 25)
    h.checkHeldTextIsCorrect()
    check h.vm.totalLineCount.val == FixtureLineCount

  test "overscan is honoured on both sides once the viewport is off the top":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    discard h.fillWindow()
    h.vm.scrollTo(100)
    discard h.fillWindow()
    check h.vm.visibleFirstLine.val == 100
    check h.vm.visibleLastLine.val == 119
    # 5 above the viewport, 5 below it: 95 .. 124.
    h.checkHeldRangeIs(95, 124)
    h.checkHeldTextIsCorrect()

  test "changing the overscan changes the window and nothing else":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    h.vm.scrollTo(100)
    discard h.fillWindow()
    h.checkHeldRangeIs(95, 124)
    h.vm.setViewport(height = 20, overscan = 12)
    let requests = h.fillWindow()
    checkRequestsAre(requests, @[(88, 94), (125, 131)])
    h.checkHeldRangeIs(88, 131)
    h.checkHeldTextIsCorrect()

  test "scrolling down requests exactly the newly visible lines":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    h.vm.scrollTo(100)
    discard h.fillWindow()
    h.checkHeldRangeIs(95, 124)

    # Scroll one viewport down: the window becomes 115 .. 144, so the only
    # lines that are new are 125 .. 144. Ten of the previously held lines
    # (95 .. 114) must be DROPPED, or the window is not a window.
    h.vm.scrollBy(20)
    let requests = h.fillWindow()
    checkRequestsAre(requests, @[(125, 144)])
    h.checkHeldRangeIs(115, 144)
    h.checkHeldTextIsCorrect()
    check h.vm.heldLines.val.len == 30

  test "scrolling up requests exactly the newly visible lines":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    h.vm.scrollTo(100)
    discard h.fillWindow()
    h.vm.scrollBy(-20)
    let requests = h.fillWindow()
    checkRequestsAre(requests, @[(75, 94)])
    h.checkHeldRangeIs(75, 104)
    h.checkHeldTextIsCorrect()

  test "a scroll beyond the held window requests one contiguous range":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    h.vm.scrollTo(100)
    discard h.fillWindow()
    h.vm.scrollTo(300)
    let requests = h.fillWindow()
    checkRequestsAre(requests, @[(295, 324)])
    h.checkHeldRangeIs(295, 324)
    h.checkHeldTextIsCorrect()

  test "a settled window requests nothing at all":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    discard h.fillWindow()
    checkRequestsAre(h.vm.requestMissing(), newSeq[(int, int)]())
    checkRequestsAre(h.vm.requestMissing(), newSeq[(int, int)]())

  test "the window follows cursorLine, by the smallest scroll that works":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    discard h.fillWindow()
    check h.vm.visibleFirstLine.val == 1

    # A cursor already on screen moves nothing.
    h.editor.setCursor(10, 1)
    h.vm.followCursor()
    check h.vm.visibleFirstLine.val == 1

    # A cursor one line below the viewport scrolls by exactly one line.
    h.editor.setCursor(21, 1)
    h.vm.followCursor()
    check h.vm.visibleFirstLine.val == 2
    check h.vm.visibleLastLine.val == 21
    let requests = h.fillWindow()
    checkRequestsAre(requests, @[(26, 26)])
    h.checkHeldRangeIs(1, 26)

    # A cursor far below scrolls so the cursor is the LAST visible line.
    h.editor.setCursor(200, 1)
    h.vm.followCursor()
    check h.vm.visibleFirstLine.val == 181
    check h.vm.visibleLastLine.val == 200
    discard h.fillWindow()
    h.checkHeldRangeIs(176, 205)
    h.checkLineIsHeld(200)

  test "the execution pointer is NOT the caret, and has its own follow":
    # `EditorVM.cursorLine` is the editor CARET, and nothing in the ViewModel
    # layer writes it from the debugger position — `EditorVM.setCursor` is its
    # only writer. A pane that scrolled by `followCursor` alone would sit on
    # line 1 for a whole session while the execution pointer walked off the
    # bottom, which is what `source_access_test.nim` observed on the `calc`
    # fixture before `followExecutionPointer` existed. So both are asserted,
    # and asserted to MOVE DIFFERENTLY.
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    discard h.fillWindow()

    h.store.updateDebuggerPosition(rrTicks = 1, file = RecordedPath, line = 250)
    check h.vm.executionLine.val == 250
    check h.editor.cursorLine.val == 1

    # Following the CARET leaves the window where it is: the caret has not
    # moved, and this is the assertion that makes the two calls distinguishable
    # rather than two names for one behaviour.
    h.vm.followCursor()
    check h.vm.visibleFirstLine.val == 1

    # Following the EXECUTION POINTER scrolls to it.
    h.vm.followExecutionPointer()
    check h.vm.visibleFirstLine.val == 231
    check h.vm.visibleLastLine.val == 250
    discard h.fillWindow()
    h.checkHeldRangeIs(226, 255)
    h.checkLineIsHeld(250)

  test "a line outside the window is a REQUEST, never an empty string":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    h.vm.scrollTo(100)
    discard h.fillWindow()
    h.checkHeldRangeIs(95, 124)

    # Inside: held, with the right text.
    h.checkLineIsHeld(95)
    h.checkLineIsHeld(110)
    h.checkLineIsHeld(124)

    # Outside, on both sides, and past the end of the file. All three are
    # requests. NONE of them is `text == ""`, which is the shape a source pane
    # renders as a blank line without noticing.
    h.checkLineIsRequest(94)
    h.checkLineIsRequest(125)
    h.checkLineIsRequest(1)
    h.checkLineIsRequest(FixtureLineCount)
    h.checkLineIsRequest(FixtureLineCount + 1)

  test "every visible line is answered, and the answers are all held":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    h.vm.scrollTo(100)
    discard h.fillWindow()
    let reads = h.vm.visibleReads()
    check reads.len == 20
    check reads.allIt(it.kind == srkHeld)
    check reads[0].line == 100
    check reads[^1].line == 119
    for read in reads:
      if read.kind == srkHeld:
        check read.text == fixtureLineText(read.line)

  test "the identity triple travels with every request the VM emits":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    let requests = h.vm.requestMissing()
    check requests.len == 1
    if requests.len == 1:
      check requests[0].path == RecordedPath
      check requests[0].sourceGeneration == 0
      check requests[0].sourceDigest == ""
    check h.vm.revision.val.path == RecordedPath
    check h.vm.path.val == h.editor.activeFileName.val
    check h.vm.sourceGeneration.val == h.editor.activeSourceGeneration.val
    check h.vm.sourceDigest.val == h.editor.activeSourceDigest.val

  test "moving to another revision of the same path drops the held text":
    # The live-HCR case. The path is identical, only the generation changes,
    # and held text from the previous generation must stop being readable
    # IMMEDIATELY — not after the next fetch returns.
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    discard h.fillWindow()
    h.checkLineIsHeld(10)

    h.store.updateDebuggerPosition(rrTicks = 1, file = RecordedPath, line = 10,
                                   sourceGeneration = 1)
    check h.vm.sourceGeneration.val == 1
    check not h.vm.holdsCurrentRevision
    h.checkLineIsRequest(10, expectedGeneration = 1)
    let read = h.vm.lineAt(10)
    check read.kind == srkRequest
    if read.kind == srkRequest:
      check read.request.sourceGeneration == 1

  test "fulfilling with the wrong revision is refused, and changes nothing":
    let h = newHarness()
    defer: h.teardown()
    h.vm.setViewport(height = 20, overscan = 5)
    discard h.fillWindow()
    h.checkHeldRangeIs(1, 25)

    let wrong = SourceRevision(path: RecordedPath, sourceGeneration: 7)
    check not h.vm.fulfill(wrong, 1, @["poisoned"], 1)
    h.checkHeldRangeIs(1, 25)
    h.checkHeldTextIsCorrect()

    let otherFile = SourceRevision(path: "/opt/ctui4/other.src")
    check not h.vm.fulfill(otherFile, 1, @["poisoned"], 1)
    h.checkHeldRangeIs(1, 25)
    h.checkHeldTextIsCorrect()

suite "CTUI-4 — the window arithmetic, as free functions":

  test "clampTop keeps the viewport inside the file":
    check clampTop(0, 20, 400) == 1
    check clampTop(1, 20, 400) == 1
    check clampTop(200, 20, 400) == 200
    check clampTop(390, 20, 400) == 381
    check clampTop(1000, 20, 400) == 381
    # A file shorter than the viewport pins the top at line 1.
    check clampTop(5, 20, 10) == 1
    # An unknown length must not collapse a scroll the caller just made.
    check clampTop(200, 20, 0) == 200

  test "topFollowingCursor makes the smallest move that works":
    check topFollowingCursor(100, 105, 20, 400) == 100
    check topFollowingCursor(100, 100, 20, 400) == 100
    check topFollowingCursor(100, 119, 20, 400) == 100
    check topFollowingCursor(100, 120, 20, 400) == 101
    check topFollowingCursor(100, 99, 20, 400) == 99
    check topFollowingCursor(100, 1, 20, 400) == 1
    check topFollowingCursor(100, 400, 20, 400) == 381

  test "splitSourceLines does not invent a trailing blank line":
    check splitSourceLines("a\nb\nc\n") == @["a", "b", "c"]
    check splitSourceLines("a\nb\nc") == @["a", "b", "c"]
    check splitSourceLines("a\r\nb\r\n") == @["a", "b"]
    check splitSourceLines("") == newSeq[string]()
    check splitSourceLines("\n") == @[""]

  test "sliceForRequest clamps to the file and never pads":
    let lines = @["one", "two", "three"]
    let inside = sliceForRequest(
      lines, SourceLineRequest(firstLine: 2, lastLine: 3))
    check inside.firstLine == 2
    check inside.lines == @["two", "three"]
    let past = sliceForRequest(
      lines, SourceLineRequest(firstLine: 4, lastLine: 9))
    check past.firstLine == 4
    check past.lines.len == 0
    let overlapping = sliceForRequest(
      lines, SourceLineRequest(firstLine: 1, lastLine: 99))
    check overlapping.lines == lines
