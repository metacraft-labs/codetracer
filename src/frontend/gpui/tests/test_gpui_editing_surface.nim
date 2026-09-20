## test_gpui_editing_surface.nim — PLAT-22. **The GPUI editing surface, graded
## against the ViewModel rather than against an appearance.**
##
## ## WHAT THIS SUITE IS FOR
##
## PLAT-22's second named integration test: *"the execution pointer and per-line
## status come from the ViewModel and are asserted against it, so a rendering
## that drifts from the model fails."*
##
## Every case below therefore does the same three things in the same order:
##
##   1. put a fact into a ViewModel a REAL session built,
##   2. build the surface and render it through the REAL isonim-gpui shim,
##   3. read the answer back out of the RUST-SIDE SHADOW TREE and compare it
##      with the ViewModel.
##
## Step 3 is the one that matters. Reading the `EditorSurface` back would be
## comparing this suite's own fixture with itself (Verification-Harness-Traps
## §4a); reading the rendered attribute makes the binding part of the subject.
## The attributes are the ROW MODEL's own values stringified — never a glyph —
## so a case is about the model and not about how this medium spells an arrow.
##
## ## WHAT THIS SUITE CANNOT DO, STATED HERE RATHER THAN IMPLIED BY ITS ABSENCE
##
## PLAT-22's first named integration test asks for *"a large real source file
## opened, scrolled and stepped through, with the frame budget measured and
## stated with host load"*. **THE FRAME BUDGET IS NOT MEASURED HERE AND CANNOT
## BE, FOR TWO INDEPENDENT REASONS**, and a number that looked like one would be
## the worst thing on this page:
##
##   1. The shim is built WITHOUT `--features gpui-backend`, so `createWindow`
##      opens nothing — isonim-gpui's own `Cargo.toml` says so, and PLAT-20 and
##      PLAT-21 both recorded "no GPUI window has been observed".
##   2. **This host has no display server at all.** `DISPLAY` and
##      `WAYLAND_DISPLAY` are both empty, `XDG_SESSION_TYPE` is `tty`, there is
##      no socket in `/tmp/.X11-unix` and neither `Xvfb` nor `xvfb-run` is on
##      `PATH` — measured 2026-09-16. So even a shim built WITH the backend
##      would have nothing to open a window on, which is a narrowing of the
##      inherited limit rather than a repetition of it: PLAT-20 recorded the
##      cause as the shim's build features, and the host is a second cause that
##      a different build does not remove.
##
## A frame budget is time per painted frame. With no frame there is no budget,
## and this suite measures something else and SAYS which: the wall time to build
## the surface and render it into the shim's element tree. That is a real cost
## on the real path and it is NOT a frame budget; the case that reports it says
## so in its own name.
##
## ## No mocks
##
## There is none to justify. The session is a real `replay-server` child over
## the real DAP stdio transport; the renderer is `isonim-gpui`'s own
## `GpuiRenderer` and the element tree is built by the real Rust shim through
## its `extern "C"` surface; the large file is read back through the PRODUCTION
## `SourceProvider` (`spkCtfsMaterialized`), the same code path a `.ct`
## container's unpacked sources take. The only synthetic thing anywhere is the
## CONTENT of that file, which is the subject rather than the instrument.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## `ck` counts; `expectCount` fails when a case does not reach the number
## written at the end of it. Every number was written LAST, from a run.

import std/[algorithm, monotimes, os, osproc, strutils, times, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings

import codetracer_embed

import ../app/leaves
import ../host/gpui_host
import ../../view_vocabulary/pane_views
import ../../../common/view_vocabulary

var asserted = 0
var countedAssertions = 0
  ## TWO COUNTERS AND NOT ONE. `asserted` is per CASE and `resetCount` clears
  ## it; `countedAssertions` is the file's total and nothing clears it. One
  ## counter serving both reports the LAST case's number as the file's, which
  ## is what the first run of this file did — `CHECKS: 7` over a file that had
  ## just made 122 assertions. That is §4b's partial set arriving in the
  ## instrument that exists to detect partial sets.

template ck(condition: untyped) =
  inc asserted
  inc countedAssertions
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template resetCount() =
  asserted = 0

const
  BigFileLines = 40_000
    ## **A LARGE FILE, and the number is chosen against what it has to
    ## demonstrate rather than against a README.**
    ##
    ## PLAT-22 quotes gpui-kit's claim of 200,000 lines. That claim is about a
    ## library this binary does not link (see the milestone's status), so
    ## matching its number would be theatre. What this suite has to show is that
    ## the editor's cost does not scale with the FILE — that the window is what
    ## is held and what is drawn — and 40,000 lines is three times CTUI-5's own
    ## 12,000 and four orders of magnitude above the viewport, which is enough
    ## for a linear cost to be unmissable. The bound asserted is `viewport +
    ## 2 * overscan`, a constant, so a file ten times larger cannot change it.
  RecordedBigPath = "/opt/plat22/editing/huge_module.py"
    ## An ABSOLUTE path that exists on no machine running this suite, so the
    ## trace payload is the only thing that can answer and a provider quietly
    ## falling back to the working tree would read nothing rather than reading
    ## something plausible.
  BigViewportLines = 40
  BigOverscan = 6
  MaxHeldLines = BigViewportLines + 2 * BigOverscan
  ScrollStops = 60
  ScrollStride = BigFileLines div ScrollStops

  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  GpuiEntrypoint = "src/frontend/gpui/main.nim"
    ## The Tier-2 case compiles THIS, into a temporary path, and runs what it
    ## compiled. It deliberately does NOT read `build/bin/codetracer-gpui`: see
    ## the case for the measurement that forced the distinction.

proc bigLineText(line: int): string =
  "value_" & $line & " = compute(" & $line & ")  # line " & $line &
    " of " & $BigFileLines

proc writeBigPayload(root: string): string =
  ## A trace folder holding the large file at the payload path the writer
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
  ## This process's resident set size, in KB.
  ##
  ## A DIAGNOSTIC FAILURE rather than a skip when procfs is absent: a run that
  ## silently stopped measuring memory would be a run whose memory assertion
  ## passed for free, which is the whole subject of the Silent-Self-Pass audit.
  const statm = "/proc/self/statm"
  if not fileExists(statm):
    raise newException(IOError,
      "RSS cannot be measured: " & statm & " does not exist, and this suite's " &
      "memory bound is the only guard here on the editor's window being a " &
      "window. Port `residentKb` or run this lane on Linux.")
  let fields = readFile(statm).splitWhitespace()
  if fields.len < 2:
    raise newException(IOError, statm & " has fewer than two fields")
  parseInt(fields[1]) * 4

proc fixtureAvailable(): bool =
  dirExists(CalcFixture)

proc requireFixture(): string =
  ## The recording, or a FAILURE naming what to run.
  ##
  ## Loud rather than skipped. A suite whose subject is "the editor draws the
  ## recording's source" and which quietly passes with no recording has stopped
  ## being about anything.
  if not fixtureAvailable():
    raise newException(IOError,
      "the `calc` fixture is absent at " & CalcFixture & ". It is recorded on " &
      "demand by the tui lane's fixture provider; run `just test-tui` once, " &
      "or point this suite at another recording. It is NOT skipped, because a " &
      "green run over no recording is worth less than a red one.")
  CalcFixture

# ---------------------------------------------------------------------------
# Reading the RENDERED tree back
# ---------------------------------------------------------------------------

proc editorRowNodes(root: GpuiElement): seq[GpuiElement] =
  ## Every element carrying a row attribute, in tree order.
  ##
  ## Read out of the SHADOW TREE — the Rust-side attribute store — and not out
  ## of the surface, because the surface is this suite's input. PLAT-20
  ## measured that the render PLAN carries no attribute map at all, so the plan
  ## is the wrong reader for this and `planLeafTexts` is the right one for text.
  result = @[]
  if root.isNil: return
  var stack = @[root]
  while stack.len > 0:
    let n = stack.pop()
    if n.isNil: continue
    if getAttribute(n, EditorRowAttribute).len > 0:
      result.add n
    let count = childCount(n)
    for i in countdown(count - 1, 0):
      let c = nthChild(n, i)
      if not c.isNil: stack.add c
  result.reverse()

proc renderedRow(root: GpuiElement; line: int): GpuiElement =
  ## The rendered element for `line`, or nil.
  ##
  ## NIL-SAFE BY CONSTRUCTION and read through accessors below, for
  ## Verification-Harness-Traps §1a's reason: a case that dereferences a value
  ## a mutation can null takes the test binary down, `unittest` prints no
  ## verdict line for it, and a harness folds that into `SURVIVED`.
  for n in editorRowNodes(root):
    if getAttribute(n, EditorRowAttribute) == $line:
      return n
  nil

proc renderedPointer(root: GpuiElement; line: int): string =
  let n = renderedRow(root, line)
  if n.isNil: "<no such row>" else: getAttribute(n, EditorPointerAttribute)

proc renderedMark(root: GpuiElement; line: int): string =
  let n = renderedRow(root, line)
  if n.isNil: "<no such row>" else: getAttribute(n, EditorMarkAttribute)

proc renderedHeld(root: GpuiElement; line: int): string =
  let n = renderedRow(root, line)
  if n.isNil: "<no such row>" else: getAttribute(n, EditorHeldAttribute)

proc renderedText(root: GpuiElement; line: int): string =
  let n = renderedRow(root, line)
  if n.isNil: return "<no such row>"
  # The CODE span is the second child: gutter, code, and an annotation only
  # when there is one. Read positionally rather than by attribute because the
  # spans carry none, and asserted through `childCount` so a shape change is a
  # failure rather than a wrong answer.
  if childCount(n) < 2: return "<row has no code span>"
  let code = nthChild(n, 1)
  if code.isNil: return "<row has no code span>"
  textContent(code)

proc exactTextNodes(root: GpuiElement; want: string): int =
  ## How many elements in the rendered tree carry EXACTLY this text.
  ##
  ## **`want in textContent(root)` IS NOT THIS, AND THE DIFFERENCE COST AN ARM.**
  ## Verification-Harness-Traps §4d: a scan that matches vocabulary rather than
  ## syntax is satisfied by prose that is ABOUT the thing. The edit-mode
  ## surface's read-only NOTICE quotes the source statement verbatim — *"this is
  ## the working tree, read-only: …"* — so the containment check written to
  ## assert *"the pane states which mode's source it is showing, ALWAYS"* was
  ## green over a renderer that had stopped drawing the statement entirely.
  ## Measured on 2026-09-16 by an undeclared arm that disabled exactly that
  ## branch of `renderEditor` and killed nothing. An EXACT match on an element
  ## of its own is what only the statement's own `div` can satisfy.
  ## **LEAVES ONLY**, and that is not a detail: the shim's `textContent`
  ## CONCATENATES a subtree (PLAT-21's verification found the same reader doing
  ## the same thing), so an element wrapping one text node reports exactly what
  ## the text node reports and every such pair would be counted twice. Counting
  ## nodes with no children asks the question this case means — *"is there a
  ## piece of text that IS the statement"* — rather than *"is there a subtree
  ## whose concatenation happens to be"*.
  if root.isNil: return 0
  var stack = @[root]
  while stack.len > 0:
    let n = stack.pop()
    if n.isNil: continue
    let kids = childCount(n)
    if kids == 0 and textContent(n) == want: inc result
    for i in countdown(kids - 1, 0):
      let c = nthChild(n, i)
      if not c.isNil: stack.add c

proc renderSurface(s: EditorSurface): GpuiElement =
  ## Render a surface into a fresh tree and answer the container.
  gpui_reset_tree()
  resetCallbacks()
  var r: GpuiRenderer
  let parent = r.createElement("div")
  discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root, s)
  parent

# ---------------------------------------------------------------------------
# A live session
# ---------------------------------------------------------------------------

type LiveEditor = object
  session: HeadlessDebugSession
  service: GpuiSourceService
  root: string
  bigTrace: string

proc openLive(viewportHeight: int; big: bool): LiveEditor =
  let trace = requireFixture()
  let session = openLocalTrace(trace)
  var root = ""
  var bigTrace = ""
  if big:
    root = getTempDir() / ("plat22-editing-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    bigTrace = writeBigPayload(root)
  let service = newGpuiSourceService(session, (if big: bigTrace else: trace),
                                     viewportHeight)
  # THE VALUES IN SCOPE, through the PRODUCTION request — the same call
  # `main.runOpen` makes and the same one `tui_session.refresh` makes. Without
  # it `StateVM.currentVariables` is empty on every session, and three of this
  # file's assertions about inline values become universal quantifications over
  # an empty set: `if row.values.len > 0` never fires, so a surface that
  # attached every value to every line satisfies them (§4a). Measured — the
  # arms that found it are U3, E3 and E8, all three of which SURVIVED before
  # this line existed.
  try:
    session.requestAndLoadLocals()
  except CatchableError:
    discard
  LiveEditor(session: session, service: service, root: root, bigTrace: bigTrace)

proc closeLive(h: LiveEditor) =
  h.service.close()
  h.session.close()
  if h.root.len > 0:
    removeDir(h.root)

proc surfaceOf(h: LiveEditor; points: openArray[EditorPoint] = []): EditorSurface =
  ## The surface for the session's CURRENT position, through the production
  ## derivation. `serveWindow` is the production serve, so the text in the rows
  ## came off the real provider.
  h.service.serveWindow()
  editorSurfaceFor(
    source = h.service.vm,
    editor = h.session.session.editorVM,
    state = h.session.session.stateVM,
    flow = h.session.session.flowVM,
    availability = h.service.availability(),
    budget = gpuiRowBudget(),
    medium = GpuiMedium,
    points = points)

proc stepUntilInlineValueShape(h: LiveEditor; budget = 60): int =
  ## Step the REAL debugger until the stop has the shape the inline-value rule
  ## is ABOUT, and answer how many steps it took. Zero means it never did.
  ##
  ## The shape is: at least one VISIBLE, HELD line that is NOT the execution
  ## line mentions a variable that is IN SCOPE. That is the only state in which
  ## "values appear on the execution line ONLY" can be distinguished from
  ## "values appear wherever they are mentioned", and reaching it is what the
  ## case needs rather than a detail of how it is written.
  ##
  ## **IT IS A PRECONDITION, AND IT WAS FOUND BY AN ARM.** The entry stop of
  ## `calc` reports NO locals at all, and the first stop that reports any
  ## reports eight module dunders — `__builtins__`, `__file__`, `__name__` and
  ## the rest — which no line of the program mentions. So a case that stepped
  ## only until `currentVariables` was non-empty still quantified over an empty
  ## set, and arm U3 (values attached to every held line, not only the
  ## execution line) SURVIVED it TWICE: once against the entry stop, and once
  ## against the dunder stop.
  ##
  ## Bounded rather than `while true`: a recording that never reaches the shape
  ## must make the case go RED with a number in it, not hang. On `calc` this
  ## answers 3 — the stop where `add` is bound and lines 19 and 29 name it.
  for i in 1 .. budget:
    h.session.stepForward()
    try:
      h.session.requestAndLoadLocals()
    except CatchableError:
      discard
    h.service.serveWindow()
    let exec = h.service.vm.executionLine.val
    for v in h.session.session.stateVM.currentVariables.val:
      if v.name.len == 0: continue
      for r in h.service.vm.visibleReads():
        if r.kind == srkHeld and r.line != exec and mentionsWord(r.text, v.name):
          return i
  0

proc pointAt(h: LiveEditor; line: int; path = "") =
  ## Move the debugger, through the SAME call `headless_session
  ## .updatePositionFromCompleteMove` makes on every `ct/complete-move` event.
  ## Not a setter this suite invented: the production writer.
  h.session.session.store.updateDebuggerPosition(
    rrTicks = uint64(line),
    file = (if path.len > 0: path else: h.service.vm.path.val),
    line = line)

suite "PLAT-22: the GPUI editing surface":

  test "PLAT-22's four concerns are four, and the filed register agrees with a RUN":
    resetCount()
    # The criteria are a VALUE, so "the overlays are in the evaluation criteria
    # before adoption" is checkable rather than a sentence in a milestone.
    ck EditorConcerns.card == 4
    ck ecExecutionPointer in EditorConcerns
    ck ecLineStatus in EditorConcerns
    ck ecInlineValues in EditorConcerns
    ck ecFlowOverlay in EditorConcerns

    # BOTH DIRECTIONS, which is PLAT-21's escape census pointed at the
    # overlays: a concern this front-end degrades with no filed gap fails, and
    # a filed gap nothing degrades for fails too.
    let surface = editorSurfaceForProject(
      path = "a.py", text = "x = 1\ny = 2\n", medium = GpuiMedium,
      mutableHere = false)
    let reported = surface.reportedConcerns()
    let filed = concernsWithFiledGap()
    ck ecFlowOverlay in filed
    ck ecLineStatus in filed
    ck ecInlineValues in filed
    ck ecExecutionPointer notin filed
    # Every concern this EDIT-mode surface DEGRADES is filed, and the count is
    # asserted rather than the loop, so a run in which nothing degrades cannot
    # satisfy a universal quantification for free (§4b: when the membership is
    # knowable, assert the COUNT).
    var degraded: set[EditorConcern] = {}
    for c in EditorConcern:
      if surface.support[c] == esDegraded:
        degraded.incl c
    ck degraded == {ecLineStatus}
    ck degraded <= filed
    ck ecLineStatus in reported
    ck surface.support[ecExecutionPointer] == esAbsent
    ck surface.support[ecInlineValues] == esAbsent
    ck filedGap(pgFlowHasNoPerLineFact).concern == ecFlowOverlay
    ck filedGap(pgMarksHaveNoProducer).concern == ecLineStatus
    ck filedGap(pgInlineValuesDiverge).concern == ecInlineValues
    ck filedGap(pgFlowHasNoPerLineFact).measurement.len > 0
    ck filedGap(pgFlowHasNoPerLineFact).remedy.len > 0

    # **THE FLOW OVERLAY SAYS ONLY WHAT IT CAN, and this is asserted over the
    # RULE rather than over a rendering**, because `EditorVM.showFlowOverlay`
    # defaults false and a case that only built surfaces would never reach
    # `flowStateOf` at all. Arm E4 — which makes every line answer `efsTaken` —
    # SURVIVED against a suite that did exactly that.
    #
    # A loop with `first = 10, last = 20, registeredLine = 10`, focused. What
    # the extent can justify: inside is `efsTaken`, and everything else is
    # `efsUnknown` — NOT `efsNotTaken`, because "this line did not run" is a
    # claim `FlowVM` carries no fact for.
    let loops = @[FlowLoopInfo(first: 10, last: 20, registeredLine: 10,
                               rrTicksForIterations: @[])]
    ck flowStateOf(loops, 0, 15) == efsTaken
    ck flowStateOf(loops, 0, 10) == efsTaken
    ck flowStateOf(loops, 0, 20) == efsTaken
    ck flowStateOf(loops, 0, 9) == efsUnknown
    ck flowStateOf(loops, 0, 21) == efsUnknown
    # No focused loop, and no loops at all: both are `efsUnknown` everywhere,
    # which is the answer that does not overclaim.
    ck flowStateOf(loops, -1, 15) == efsUnknown
    ck flowStateOf(@[], 0, 15) == efsUnknown
    expectCount(26)

  test "an escape naming ANOTHER front-end is refused, and the refusal names both":
    resetCount()
    # `nativeEscape`'s own doc comment says it is built so that a caller has
    # said which front-end it is for, and until PLAT-22 nothing read the
    # answer — an arm that hardcoded it to "terminal" survived PLAT-21's whole
    # suite. This is the production reader.
    gpui_reset_tree()
    resetCallbacks()
    var r: GpuiRenderer
    let good = editorSurfaceForProject(path = "a.py", text = "x = 1\n",
                                       medium = GpuiMedium, mutableHere = false)
    let parentGood = r.createElement("div")
    ck renderEditor(r, parentGood, sourcePaneView(GpuiMedium).root, good)
    ck getAttribute(parentGood, EditorMediumAttribute) == GpuiMedium

    # The SURFACE names another medium.
    let foreign = editorSurfaceForProject(path = "a.py", text = "x = 1\n",
                                          medium = "terminal",
                                          mutableHere = false)
    let parentForeign = r.createElement("div")
    ck not renderEditor(r, parentForeign, sourcePaneView(GpuiMedium).root,
                        foreign)
    ck "terminal" in textContent(parentForeign)
    ck editorRowNodes(parentForeign).len == 0

    # The ESCAPE names another medium, with a correct surface. This is the arm
    # PLAT-21's verification planted and nothing could see.
    let parentEscape = r.createElement("div")
    ck not renderEditor(r, parentEscape, sourcePaneView("terminal").root, good)
    ck editorRowNodes(parentEscape).len == 0
    ck sourcePaneView(GpuiMedium).root.nativeMedium == GpuiMedium
    ck sourcePaneView("terminal").root.nativeMedium == "terminal"
    expectCount(9)

  test "PROVENANCE reaches the rendered tree, and the three availabilities are three":
    resetCount()
    # CTUI-5, quoted verbatim in `editor_rows.EditorProvenance`'s own header:
    # *"a file served `savUnverified` must not look identical to one served
    # `savVerified`. CTUI-4 fought hard for this distinction; do not render it
    # away."*
    #
    # **NOTHING IN THIS SUITE ASSERTED IT UNTIL NOW.** An undeclared arm on
    # 2026-09-16 made `provenanceOf` answer `epVerified` for `savUnverified` —
    # the editor certifying bytes nobody recorded — and all ten cases and 307
    # assertions stayed green. That is Verification-Harness-Traps §7a in its
    # exact shape: a claim argued carefully in a doc comment, with nothing in
    # the suite that could tell it from its opposite. Arm E13 is that mutation.
    #
    # The THREE-WAY distinctness is the assertion that kills it. An equality
    # against `provenanceOf` would be a self-comparison — both sides out of the
    # function under test (§4a) — so what is required here is that the three
    # availabilities reach the rendered tree as three DIFFERENT answers, which
    # a mapping that has collapsed any two of them cannot satisfy.
    let h = openLive(24, big = false)
    try:
      h.service.serveWindow()
      var seen: seq[string] = @[]
      for availability in [savVerified, savUnverified, savAbsent]:
        # ONE TREE AT A TIME. `renderSurface` calls `gpui_reset_tree()`, which
        # destroys the shim's entire element store, so a handle held across two
        # calls answers "" for everything.
        let s = editorSurfaceFor(
          source = h.service.vm,
          editor = h.session.session.editorVM,
          state = h.session.session.stateVM,
          flow = h.session.session.flowVM,
          availability = availability,
          budget = gpuiRowBudget(),
          medium = GpuiMedium)
        let root = renderSurface(s)
        let drawn = getAttribute(root, EditorProvenanceAttribute)
        ck drawn.len > 0
        ck drawn == $s.provenance
        # §2's Requirement on the DEBUG side, in an element of its own — the
        # half `exactTextNodes` exists for, and the half no case had.
        ck exactTextNodes(root, sourceContractFor(pmDebug).statement) == 1
        seen.add drawn
      ck seen.len == 3
      ck seen[0] != seen[1]        # verified vs UNVERIFIED — CTUI-5's own line
      ck seen[1] != seen[2]        # unverified vs absent
      ck seen[0] != seen[2]
    finally:
      closeLive(h)
    expectCount(13)

  test "the EXECUTION POINTER comes from the ViewModel and the rendering follows it":
    resetCount()
    let h = openLive(24, big = false)
    try:
      # Three positions, driven through the production position writer, and the
      # RENDERED attribute compared with the ViewModel at each.
      for target in [3, 11, 24]:
        h.pointAt(target)
        let s = h.surfaceOf()
        ck s.executionLine == h.service.vm.executionLine.val
        let root = renderSurface(s)
        ck renderedPointer(root, target) == $eptExecution
        # A NEGATIVE TWIN OVER THE SAME READER: the pointer is on exactly one
        # line. Without this the case is satisfied by a renderer that marks
        # every row, which is §4a's emptied subject in its usual costume.
        var pointing = 0
        for n in editorRowNodes(root):
          if getAttribute(n, EditorPointerAttribute) == $eptExecution:
            inc pointing
        ck pointing == 1
      expectCount(9)
    finally:
      closeLive(h)

  test "PER-LINE STATUS comes from the points, and a breakpoint beats a tracepoint":
    resetCount()
    let h = openLive(24, big = false)
    try:
      h.pointAt(5)
      let path = h.service.vm.path.val
      let points = @[
        EditorPoint(path: path, line: 7, kind: epkTracepoint, enabled: true),
        EditorPoint(path: path, line: 9, kind: epkBreakpoint, enabled: true),
        EditorPoint(path: path, line: 11, kind: epkBreakpoint, enabled: false),
        # BOTH on one line: the line stops, so it must show the breakpoint.
        EditorPoint(path: path, line: 13, kind: epkTracepoint, enabled: true),
        EditorPoint(path: path, line: 13, kind: epkBreakpoint, enabled: true),
        # Another FILE's point must not appear on this one.
        EditorPoint(path: "/elsewhere/other.py", line: 8,
                    kind: epkBreakpoint, enabled: true)]
      let s = h.surfaceOf(points)
      let root = renderSurface(s)
      ck renderedMark(root, 7) == $emTracepoint
      ck renderedMark(root, 9) == $emBreakpoint
      ck renderedMark(root, 11) == $emBreakpointDisabled
      ck renderedMark(root, 13) == $emBreakpoint
      ck renderedMark(root, 8) == $emNone
      # The rendering agrees with the shared rule, asked independently.
      for line in 6 .. 14:
        ck renderedMark(root, line) == $markFor(points, path, line)
      # And the concern is NOT degraded when points are supplied, which is the
      # half that tells "no producer" from "the medium cannot draw it".
      ck s.support[ecLineStatus] == esRendered
      ck surfaceOf(h).support[ecLineStatus] == esDegraded
      expectCount(16)
    finally:
      closeLive(h)

  test "a line the window does not hold renders a PLACEHOLDER, never a blank":
    resetCount()
    let h = openLive(16, big = true)
    try:
      # **ONE TREE AT A TIME.** `renderSurface` calls `gpui_reset_tree()`, which
      # destroys the shim's whole element store — so two `renderSurface` calls
      # with the first tree's handle still held reads a tree that no longer
      # exists, and every `getAttribute` on it answers "". Measured as four
      # failing assertions on the first attempt at this case, all of them about
      # a tree that had been perfectly correct a line earlier. Each half below
      # therefore renders, reads, and is finished with its tree before the next
      # one starts.

      # HALF ONE — the SERVED window: every visible line is held and carries
      # its own text.
      h.pointAt(20_000, RecordedBigPath)
      let served = h.surfaceOf()
      var held = 0
      block servedHalf:
        let root = renderSurface(served)
        for n in editorRowNodes(root):
          let line = parseInt(getAttribute(n, EditorRowAttribute))
          ck renderedText(root, line) == bigLineText(line)
          inc held
        ck held > 0
        ck renderedHeld(root, 20_000) == "true"

      # HALF TWO — the window MOVED and NOT served, which is the only state in
      # which a row is legitimately not held.
      #
      # It exists because `surfaceOf` calls `serveWindow`, which fills every
      # visible line: on a served surface the not-held branch has NO MEMBERS and
      # asserts nothing at all. That is §4a's emptied subject — the row count
      # never moved and the variety inside it was gone — and arm E7, which makes
      # the renderer discard `held` and draw `row.text` for every row, SURVIVED
      # against the served half alone.
      var unheld = 0
      block unservedHalf:
        h.pointAt(35_000, RecordedBigPath)
        h.service.vm.followExecutionPointer()   # move the window, serve nothing
        let unserved = editorSurfaceFor(
          source = h.service.vm,
          editor = h.session.session.editorVM,
          state = h.session.session.stateVM,
          flow = h.session.session.flowVM,
          availability = h.service.availability(),
          budget = gpuiRowBudget(),
          medium = GpuiMedium)
        let root = renderSurface(unserved)
        for row in unserved.rows:
          if not row.held:
            inc unheld
            ck renderedText(root, row.line) == EditorLoadingText
            ck renderedHeld(root, row.line) == "false"
        # THE NON-VACUITY FLOOR (§4): without it the loop is a universal
        # quantification over an empty set and passes for free — which is
        # exactly the state this case was in before.
        ck unheld > 0
        # NOTHING RENDERS AS AN EMPTY STRING, which is the whole of `SourceVM`'s
        # second contract surviving to the last step.
        for row in unserved.rows:
          ck renderedText(root, row.line).len > 0
      expectCount(held + 2 + 3 * unheld + 1)
    finally:
      closeLive(h)

  test "a LARGE file, scrolled: the window stays bounded and the cost is stated":
    resetCount()
    let h = openLive(BigViewportLines, big = true)
    try:
      h.service.vm.setViewport(height = BigViewportLines, overscan = BigOverscan)
      h.pointAt(1, RecordedBigPath)
      discard h.surfaceOf()

      let rssStart = residentKb()
      var worstHeld = 0
      var worstRss = rssStart
      var totalRenderNs = 0'i64
      var frames = 0
      for stop in 0 ..< ScrollStops:
        let line = 1 + stop * ScrollStride
        h.pointAt(line, RecordedBigPath)
        let t0 = getMonoTime()
        let s = h.surfaceOf()
        let root = renderSurface(s)
        totalRenderNs += (getMonoTime() - t0).inNanoseconds
        inc frames
        worstHeld = max(worstHeld, h.service.vm.heldLines.val.len)
        worstRss = max(worstRss, residentKb())
        # The pointer follows the stop at every one of the stops, so this is a
        # scroll rather than sixty renderings of one window.
        ck renderedPointer(root, line) == $eptExecution
        ck editorRowNodes(root).len <= BigViewportLines

      # BOUND 1: the VM holds at most viewport + 2 * overscan, at every stop.
      # A constant, so a file ten times larger cannot move it.
      ck worstHeld <= MaxHeldLines
      ck worstHeld > 0
      # BOUND 2: RSS does not grow with the file. The bound is generous on
      # purpose — this is a process-wide number and the assertion is about
      # ORDER OF MAGNITUDE, not about allocation. 40,000 lines of ~50 bytes is
      # ~2 MB of text; a renderer holding the file would show it.
      ck worstRss - rssStart < 64 * 1024

      # THE COST, AND IT IS NOT A FRAME BUDGET. See this module's header: there
      # is no window on this host and none was opened, so what follows is the
      # wall time to DERIVE the surface and BUILD the shim's element tree, per
      # stop. It is reported rather than asserted against a constant, because
      # an absolute timing bound on a single measurement is
      # Verification-Harness-Traps §12a's coin flip with one side hidden — and
      # this host is shared.
      let perFrameUs = float(totalRenderNs) / float(frames) / 1000.0
      # `echo` AND NOT `checkpoint`: `unittest.checkpoint` prints only when a
      # case FAILS, so a number reported through it is a number no green run
      # ever shows — and a measurement quoted in a status block that its own
      # passing suite does not print is a claim rather than evidence
      # (Verification-Harness-Traps §14c's closing rule). The host load is on
      # the same line because §12b says to name every input a measurement
      # depends on, and this host is shared.
      echo "PLAT22-COST NOT-A-FRAME-BUDGET surface-build+shim-element-tree" &
           " stops=" & $frames & " file_lines=" & $BigFileLines &
           " us_per_stop=" & $perFrameUs &
           " rss_start_kb=" & $rssStart & " rss_worst_kb=" & $worstRss &
           " held_worst=" & $worstHeld & " held_bound=" & $MaxHeldLines &
           " loadavg1=" & readFile("/proc/loadavg").splitWhitespace()[0]
      # The only thing asserted about the clock is that it RAN, which is the
      # non-vacuity floor (§4): a loop that did nothing would report zero.
      ck totalRenderNs > 0
      ck frames == ScrollStops
      expectCount(2 * ScrollStops + 5)
    finally:
      closeLive(h)

  test "INLINE VALUES are presented at the GPUI ROW budget, on the execution line only":
    resetCount()
    # `gpuiRowBudget()` is the budget `main.nim` passes and `inlineValuesOf`
    # is what spends it. PLAT-21 recorded that the function had NO production
    # caller — four grep hits, its definition and three assertions in its own
    # suite — and said PLAT-22 is where it gains one or goes. It gained one.
    ck gpuiRowBudget().name == "gpui-row"
    ck gpuiRowBudget().lines == 1
    let h = openLive(24, big = false)
    try:
      # STEP INTO A FRAME THAT HAS VARIABLES. See `stepUntilLocals`: the entry
      # stop of this recording has none, and three arms survived against a case
      # that quantified over that empty set.
      let steps = stepUntilInlineValueShape(h)
      ck steps > 0
      let execLine = h.service.vm.executionLine.val
      ck execLine > 0
      let s = h.surfaceOf()
      let root = renderSurface(s)
      # Whatever the recording reports at this stop, an inline value may appear
      # ONLY on the execution line. That is the rule, and it is asserted over
      # every row rather than over the one this run happened to produce.
      for row in s.rows:
        if row.values.len > 0:
          ck row.pointer == eptExecution
      ck s.rowAt(execLine).pointer == eptExecution
      # `rowAt` answers a zero row for a line outside the surface rather than
      # raising, which is what keeps a mutation from taking the binary down.
      ck s.rowAt(-1).line == 0
      ck s.rowAt(-1).values.len == 0

      # **THE THREE RULES INLINE VALUES OBEY, ASSERTED OVER THE RULE ITSELF**,
      # because what the recording reports at a given stop is not this file's
      # to decide — and three arms that changed the rules (E3, E8, U3) all
      # SURVIVED against the loop above, which is true of a surface that
      # attached every value to every line under a substring match rendered at
      # somebody else's budget.
      #
      # 1. WHOLE WORD, not substring. `sum` must not be pulled onto a line
      #    mentioning `summary`.
      let vals = @[EditorValue(name: "sum", value: "7"),
                   EditorValue(name: "n", value: "3")]
      ck valuesForLine("total = sum + n", vals).len == 2
      ck valuesForLine("summary = 1", vals).len == 0
      ck valuesForLine("nn = 1", vals).len == 0
      ck valuesForLine("x = 1", vals).len == 0
      ck mentionsWord("a sum here", "sum")
      ck not mentionsWord("a summary here", "sum")
      # 2. THE PRESENTER'S ANSWER AT THIS FRONT-END'S BUDGET. Every value the
      #    surface carries is `presentText(v.presented, gpuiRowBudget())` — not
      #    `Variable.value`, which is one rendering at `tuiValueBudget`, and
      #    which is the "two spellings of one value in one pane" PLAT-2's own
      #    risk names. Compared against the presenter, independently.
      var compared = 0
      for v in h.session.session.stateVM.currentVariables.val:
        if v.presented.isNil or v.name.len == 0: continue
        let want = presentText(v.presented, gpuiRowBudget()).strip()
        if want.len == 0: continue
        inc compared
        var found = ""
        for got in inlineValuesOf(h.session.session.stateVM, gpuiRowBudget()):
          if got.name == v.name: found = got.value
        ck found == want
      # 3. ON THE EXECUTION LINE ONLY — and the loop at the top of this case is
      #    NOT ENOUGH to say so. `for row in s.rows: if row.values.len > 0: ck
      #    row.pointer == eptExecution` is satisfied by a surface that attaches
      #    values to every line, PROVIDED no other visible line happens to
      #    mention an in-scope name. Arm U3 makes exactly that change and
      #    SURVIVED the loop twice.
      #
      #    The assertion that can see it names the row the rule is about: a
      #    line that is NOT the execution line and DOES mention a variable in
      #    scope must carry no value. Without a floor under that set the
      #    assertion is a universal quantification over nothing, which is the
      #    same defect one level down (§4).
      let scopeNames = inlineValuesOf(h.session.session.stateVM,
                                      gpuiRowBudget())
      var mentioningElsewhere = 0
      for row in s.rows:
        if not row.held or row.pointer == eptExecution: continue
        var mentions = false
        for v in scopeNames:
          if mentionsWord(row.text, v.name): mentions = true
        if mentions:
          inc mentioningElsewhere
          ck row.values.len == 0
      ck mentioningElsewhere > 0
      ck scopeNames.len > 0
      ck compared > 0
      var annotated = 0
      for row in s.rows:
        if row.values.len > 0: inc annotated
      expectCount(16 + annotated + compared + mentioningElsewhere)
    finally:
      closeLive(h)

  test "EDIT mode reaches this front-end, reads the CORE's contract, and says what it cannot do":
    resetCount()
    # PLAT-22: "PLAT-16's edit mode reachable as `ct --ui=gpui edit .`, since
    # edit mode is a product mode and not a front-end feature." The contract is
    # READ rather than re-decided, which is the deliverable's substance.
    let contract = sourceContractFor(pmEdit)
    ck contract.origin == soWorkingTree
    ck contract.mutable
    ck not contract.windowed          # §2.1: "Edit mode does not use SourceVM"

    let s = editorSurfaceForProject(
      path = "src/a.py", text = "def f():\n    return 1\n\nf()\n",
      medium = GpuiMedium, mutableHere = false)
    ck s.productMode == pmEdit
    ck s.sourceStatement == contract.statement
    ck s.sourceStatement == "the working tree"
    # THE DISAGREEMENT IS REPORTED, not rounded. The contract says mutable and
    # this front-end is not, so `mutable` is false AND the surface says why.
    ck not s.mutable
    # The NOTICE accompanies the rows; it does not replace them. `report` is
    # the field that replaces them and it is empty here, which is the whole of
    # the §5a split this milestone had to make in its own diff.
    ck "read-only" in s.notice
    ck GpuiMedium in s.notice
    ck s.report.len == 0
    # The working tree is never the recording's copy, so it is never verified.
    ck s.provenance == epUnverified
    # **FOUR ROWS, UNCHANGED BY PLAT-34, AND THE REASON IS NOW A NAMED
    # POLICY RATHER THAN A `splitLines` IN THIS FUNCTION.** This document ends
    # in a terminator, so it holds five line POSITIONS and four lines of text,
    # and PLAT-28's `TrailingLinePolicy` is the enum that says which is being
    # asked for. `editorSurfaceForProject` is handed a STRING — a file — so it
    # passes `tlpDropFinalEmpty` and `showCaret = false`, which is exactly the
    # answer it has always given. What changed is that the policy is applied
    # by `row_projection.projectionLinesFor` rather than by a third splitter
    # of this module's own; the case below asserts the BUFFER entry point's
    # different answer beside it.
    ck s.totalLineCount == 4
    ck s.rowAt(2).text == "    return 1"
    ck s.rowAt(2).pointer == eptNone
    # A FILE HAS NO CURSOR. The caret in the document `editorSurfaceForProject`
    # opens is an artefact of the delegation, not a fact about the bytes.
    ck s.rowAt(1).pointer == eptNone

    # **THE BUFFER ENTRY POINT ANSWERS THE OTHER QUESTION, AND THAT IS WHAT
    # THE GPUI FRONT-END ACTUALLY CALLS.** `main.editSurfaceFor` opens a
    # document and derives from it (PLAT-34), so what this front-end draws is
    # the five line positions the model has and a caret on the row the model's
    # caret is on. A read-only editor that does not re-render is not a
    # consumer (PLAT-28), and text alone would only move when the document
    # moved — every motion in the 224-operation vocabulary would be invisible
    # to this medium.
    let buffer = editorSurfaceForDocument(
      initEditingDocument("src/a.py", "def f():\n    return 1\n\nf()\n"),
      GpuiMedium, mutableHere = false)
    ck buffer.totalLineCount == 5
    ck buffer.rowAt(1).pointer == eptInspection

    # A DEBUG-mode surface answers the OTHER row of the same table, from the
    # same function, so the two modes cannot be read as one.
    ck sourceContractFor(pmDebug).origin == soTracePayload
    ck not sourceContractFor(pmDebug).mutable
    ck sourceContractFor(pmDebug).windowed

    let root = renderSurface(s)
    ck editorRowNodes(root).len == 4
    ck renderedText(root, 2) == "    return 1"
    # §2's Requirement: the pane states which mode's source it is showing,
    # ALWAYS. Asserted on the RENDERED tree, so a medium that carried the
    # statement in the value and drew nothing fails.
    ck contract.statement in textContent(root)
    ck s.notice in textContent(root)
    # **AND IN AN ELEMENT OF ITS OWN.** The containment check above is
    # satisfied by the NOTICE, which quotes the statement verbatim, so it was
    # green over a renderer that had stopped drawing the statement — measured
    # by an undeclared arm on 2026-09-16 (§4d). Arm E14 is that mutation and
    # this is the only line that reddens.
    ck exactTextNodes(root, contract.statement) == 1
    expectCount(25)

  test "THE SHIPPED BINARY draws the editor — Tier 2, through --report-plan":
    resetCount()
    # Verification-Harness-Traps §7b: a suite that hand-builds its subject
    # never has to ask whether the PRODUCT can reach that state. `main.nim` is
    # compiled by no suite in this repository — which is exactly how PLAT-16's
    # F1 survived a green Tier-1 run — so this case drives the binary.
    #
    # It is also the only thing that grades the `adopt` repair: before it, this
    # binary reported every pane as "waiting for the session to launch" on a
    # real recording, and every Tier-1 case in this file was green.
    #
    # **THE BINARY IS COMPILED HERE, FROM SOURCE, AND THAT IS NOT A
    # CONVENIENCE.** Reading `build/bin/codetracer-gpui` off the disk grades
    # WHATEVER WAS BUILT LAST, which on a mutation run is the tree as it stood
    # before the arm was applied — so a source mutation cannot reach this case
    # at all. Measured: arms E9, E12 and U2 all scored SURVIVED against a
    # prebuilt binary, and all three kill once the case builds what it runs.
    # A Tier-2 case that runs a stale artefact is a Tier-1 case with a process
    # spawn in it, which is the more expensive way of learning nothing.
    let built = getTempDir() / ("plat22-gpui-" & $getCurrentProcessId())
    let buildCmd = "nim c --hints:off --warnings:off " &
      "--path:src/frontend/viewmodel " &
      "--nimcache:" & built & ".cache -o:" & built & " " &
      GpuiEntrypoint
    let (buildOut, buildCode) = execCmdEx(buildCmd)
    if buildCode != 0:
      raise newException(IOError,
        "codetracer-gpui did not compile, so this case could not run: " &
        buildOut.splitLines()[^min(3, buildOut.splitLines().len) .. ^1].join(" "))
    defer:
      removeFile(built)
      removeDir(built & ".cache")
    let trace = requireFixture()
    let (output, code) = execCmdEx(built & " --report-plan " & trace)
    ck code == 0
    ck output.len > 0
    # THE PANES ARE LIVE. The negative is the load-bearing half: this exact
    # string is what the binary printed for all five panes before the repair.
    ck "waiting for the session to launch" notin output
    # The editor drew the recording's own source, not a title.
    ck "Editor" in output
    ck "calc" in output or "#!/usr/bin/env python3" in output
    # The execution pointer reached the plan's TEXT, which is the reader that
    # works across the FFI boundary — the plan carries no attribute map.
    ck ExecutionPointerGlyph in output
    # The state pane rendered its vocabulary tree rather than its name.
    ck "Locals" in output
    expectCount(7)

# ---------------------------------------------------------------------------
# The assertion count, declared for the lane
# ---------------------------------------------------------------------------
#
# Verification-Harness-Traps §7: `std/unittest` prints one `[OK]` per test
# BLOCK that did not fail, never one per `check`, so a file of empty cases
# scores a full pass. `CHECKS:` is what makes a case count stop being read as
# an assertion count. The number is written LAST, from a run; two of this
# file's per-case counts were wrong on the first attempt (16 against 19 and 22
# against 21) and §4c's counter is what said so.
#
# 307 -> 321 on 2026-09-16: thirteen assertions for the provenance case and one
# for the edit-mode statement, both added by the verification pass after two
# undeclared arms survived the 307.

const ExpectedAssertions = 324

suite "PLAT-22: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
