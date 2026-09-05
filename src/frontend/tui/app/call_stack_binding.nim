## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade —
## and never `viewmodel/*` directly.
##
## app/call_stack_binding.nim — CTUI-6. The ONE place that turns a debugger's
## answers into a `CallStackModel`, and a selected frame into the source window
## the pane must show.
##
## ## Why it exists as its own module
##
## The same split, and the same three reasons, as CTUI-5's
## `app/source_binding.nim`: the view stays a pure function of a value, two
## frames stay comparable, and the pane's row count stays a property of a field
## a reader can see. This module reads; `app/views/call_stack.nim` draws.
##
## ## WHAT THE VIEWMODEL LAYER COULD NOT SUPPLY, MEASURED RATHER THAN ASSUMED
##
## Two findings, both established by reading and grepping
## `src/frontend/viewmodel/` on 2026-09-05, and both recorded here because a
## later reader would otherwise re-derive them:
##
## 1. **No ViewModel owns the call stack.** DAP `stackTrace` is in
##    `backend/dap_commands.nim`'s allow-list, and a grep for it over the whole
##    ViewModel layer finds two test files and no ViewModel, no store field and
##    no type: `store/types.nim` has `CallLine` (a CALLTRACE row) and
##    `DebuggerState` (one `Location`), and nothing shaped like a frame. So the
##    frames arrive here as a VALUE — `framesFromStackTrace` converts the
##    engine's own answer — exactly as CTUI-5's breakpoints do, and for the same
##    reason: a pane bound to a ViewModel that nothing fills renders an empty
##    stack on every real session while looking correctly wired.
##
##    `CalltraceVM` is still the right ViewModel for what it actually owns.
##    `inspectionCursorFrom` / `publishInspectionCursor` put the INSPECTION
##    CURSOR in `CalltraceVM.selectedEntry` — a signal whose writer
##    (`selectEntry`) touches no debugger state at all, which is precisely the
##    property CTUI-6's contract needs.
##
## 2. **`SourceVM` cannot be pointed at another file.** Its `revision` is a memo
##    over `EditorVM.activeFileName`, which is itself a memo over
##    `store.debugger.val.location.file` — a DERIVED value with no setter,
##    despite the name. So "the source pane follows the selected frame" cannot
##    be done by re-pointing `SourceVM`: an outer frame in another file needs
##    its own window, fetched for its own revision through the same
##    `SourceProvider` CTUI-4 built. `frameSourceRequest` and
##    `sourcePaneModelForFrame` are that path.
##
## ## THE EXECUTION POINTER IS SUPPRESSED IN A FILE THE DEBUGGER IS NOT IN
##
## This is the defect CTUI-6 names — "conflating the two cursors is the classic
## defect here" — in its most concrete form. `SourceVM.executionLine` is
## `store.debugger.val.location.LINE` and carries no file with it. A pane
## showing `main.nr` while the debugger is stopped at `shield.nr:24` would draw
## `-->` on line 24 OF MAIN.NR: a line the program has never executed, marked as
## the current statement.
##
## So `sourcePaneModelForFrame` sets `executionLine` only when the file on
## screen is the file the debugger reports, and sets `inspectionLine` always.
## `tests/test_call_stack_navigation.nim` asserts both arms on a real trace —
## the cross-file one on `noir_space_ship`, where the outer frame is in another
## file, and the same-file one where both cursors are on screen at once.
##
## ## No mocks
##
## Nothing here constructs a ViewModel, a store or a backend. It takes the ones
## a real session built, and a `SourceFetch` a real provider answered.

import std/[json, options]

import codetracer_embed

import ./source_binding
import ./views/call_stack

export call_stack, source_binding

proc framesFromStackTrace*(body: JsonNode): seq[StackFrame] =
  ## The frames in a DAP `stackTrace` response body, innermost first.
  ##
  ## Defensive at every step and silent at none: a response with no
  ## `stackFrames` array yields an EMPTY sequence, which the pane renders as
  ## "no frames reported" rather than as a stack — an empty pane that looks like
  ## a shallow stack is the failure this shape avoids.
  result = @[]
  if body.isNil or body.kind != JObject:
    return
  let frames = body.getOrDefault("stackFrames")
  if frames.isNil or frames.kind != JArray:
    return
  for i in 0 ..< frames.len:
    let f = frames[i]
    if f.isNil or f.kind != JObject:
      continue
    let source = f.getOrDefault("source")
    var path = ""
    if not source.isNil and source.kind == JObject:
      path = source.getOrDefault("path").getStr("")
    result.add StackFrame(
      index: i,
      id: f.getOrDefault("id").getInt(-1),
      name: f.getOrDefault("name").getStr(""),
      path: path,
      line: f.getOrDefault("line").getInt(0))

proc reportedFrameCount*(body: JsonNode): int =
  ## The `totalFrames` the engine reports, or -1 when it reports none.
  ##
  ## Read SEPARATELY from the array's length so a test can assert the two agree.
  ## An engine that paginated a deep stack would answer fewer frames than it
  ## has, and a pane that trusted the array would silently show a truncated
  ## stack as a complete one.
  if body.isNil or body.kind != JObject:
    return -1
  let total = body.getOrDefault("totalFrames")
  if total.isNil or total.kind != JInt: -1 else: total.getInt(-1)

proc threadsFrom*(body: JsonNode): seq[tuple[id: int; name: string]] =
  ## The threads in a DAP `threads` response body.
  ##
  ## CTUI-6's thread selector is CUT (see `app/views/call_stack.nim`'s
  ## `threadCount` note): no recorder in this workspace produces a recording
  ## whose answer here has more than one entry. This function exists so the pane
  ## can NAME the thread it is showing, and so
  ## `tests/test_multi_thread_selection.nim` measures the limitation on every
  ## run instead of quoting it.
  result = @[]
  if body.isNil or body.kind != JObject:
    return
  let threads = body.getOrDefault("threads")
  if threads.isNil or threads.kind != JArray:
    return
  for t in threads:
    if t.isNil or t.kind != JObject:
      continue
    result.add (id: t.getOrDefault("id").getInt(-1),
                name: t.getOrDefault("name").getStr(""))

proc directoryOf*(path: string): string =
  ## The directory component of a recorded path, splitting on BOTH separators.
  ##
  ## Hand-written rather than `std/os.splitPath` for the reason
  ## `source_pane.pathBaseName` records: a recorded path is whatever a recorder
  ## interned, and a splitter that knows only its own host's separator gets a
  ## Windows recording wrong on Linux. It also keeps `std/os` out of `app/`.
  result = ""
  for i in countdown(path.high, 0):
    if path[i] == '/' or path[i] == '\\':
      return path[0 ..< i]

proc userRootsFor*(entryFile: string): seq[string] =
  ## The directories whose files count as the recorded program's own.
  ##
  ## The ENTRY FILE'S directory, as the backend reported it — a fact about the
  ## recording rather than about this machine. It is deliberately not a list of
  ## magic names (`site-packages`, `/usr/lib`): see
  ## `app/views/frame_item.nim`'s header.
  ##
  ## THE LIMITATION, STATED RATHER THAN LEFT TO BE FOUND: a program whose
  ## sources live in sibling directories of the entry file's — `src/` beside
  ## `lib/` — will have the second directory classified `lib`. The corpus this
  ## campaign has does not exercise that (`noir_space_ship` keeps `main.nr` and
  ## `shield.nr` in one `src/`), so widening the rule would be a change no test
  ## could justify. A host that knows the project root should pass it instead;
  ## the field is a `seq` for exactly that reason.
  let dir = directoryOf(entryFile)
  if dir.len == 0: @[] else: @[dir]

proc callStackModelFor*(frames: seq[StackFrame];
                        entryFile: string;
                        selected = 0;
                        executionFrame = 0;
                        threads: seq[tuple[id: int; name: string]] = @[];
                        expandedGroups: seq[int] = @[];
                        scrollTop = 0): CallStackModel =
  ## The pane's model for the CURRENT stop.
  ##
  ## Everything is read at call time and nothing is retained, so two stops are
  ## two values and the difference between them is exactly the difference on
  ## screen.
  initCallStackModel(
    frames = frames,
    userRoots = userRootsFor(entryFile),
    executionFrame = executionFrame,
    selected = selected,
    expandedGroups = expandedGroups,
    scrollTop = scrollTop,
    threadName = (if threads.len > 0: threads[0].name else: ""),
    threadCount = threads.len)

proc inspectionCursorFrom*(vm: CalltraceVM): int =
  ## The inspection cursor `CalltraceVM` currently holds, or -1.
  ##
  ## `selectedEntry` is an `Option[int64]` of a CALLTRACE line index in the
  ## desktop's use of it, and a FRAME index in this one. The two are different
  ## coordinate systems over the same signal, which is a wart and is written
  ## down rather than hidden: the TUI has no calltrace pane, so nothing else
  ## reads this signal in a TUI session, and the alternative — a second
  ## selection signal — would give a future calltrace pane two cursors that
  ## could disagree.
  if vm.isNil or vm.selectedEntry.val.isNone: -1
  else: int(vm.selectedEntry.val.get)

proc publishInspectionCursor*(vm: CalltraceVM; frame: int) =
  ## Put the inspection cursor where the pane put it.
  ##
  ## `CalltraceVM.selectEntry` writes `selectedEntry` and NOTHING ELSE — no
  ## backend command, no debugger state, no navigation. That is what makes it
  ## the right home for a cursor whose defining property is that moving it does
  ## not move the program.
  if not vm.isNil:
    vm.selectEntry(some(int64(frame)))

# ---------------------------------------------------------------------------
# Following the selected frame in the source pane
# ---------------------------------------------------------------------------

proc frameViewportTop*(line, viewportHeight, totalLineCount: int): int =
  ## Where the source viewport sits when it jumps to a frame.
  ##
  ## CENTRED, unlike a step. `source_vm.topFollowingCursor` deliberately makes
  ## the SMALLEST scroll that brings the line into view, because a pane that
  ## re-centred on every step would make one step look like a jump. Selecting a
  ## frame IS a jump — usually to another function and often to another file —
  ## and landing the call site in the middle of the pane with its callers above
  ## it is what a reader needs to see next.
  clampTop(max(1, line - viewportHeight div 2), viewportHeight, totalLineCount)

proc frameSourceRequest*(frame: StackFrame; viewportHeight: int;
                         overscan = 0): SourceLineRequest =
  ## What to fetch so the pane can show `frame`.
  ##
  ## A FULL VIEWPORT WIDER THAN THE VIEWPORT ON EACH SIDE, deliberately: the
  ## final top depends on `totalLineCount`, which is part of the answer and not
  ## available when the question is asked. Requesting `line ± (height +
  ## overscan)` covers every top the clamp can produce, so a frame near the end
  ## of a file cannot land on a window the fetch did not cover — which would
  ## render as `⋯ loading` rows under a correct-looking title.
  SourceLineRequest(
    path: frame.path,
    sourceGeneration: 0,
    sourceDigest: "",
    firstLine: max(1, frame.line - viewportHeight - overscan),
    lastLine: frame.line + viewportHeight + overscan)

proc sourcePaneModelForFrame*(frame: StackFrame;
                              fetch: SourceFetch;
                              availability: SourceAvailability;
                              debuggerPath: string;
                              debuggerLine: int;
                              viewportHeight: int;
                              points: seq[SourcePoint] = @[];
                              variables: seq[Variable] = @[]): SourcePaneModel =
  ## The source pane's model while `frame` is the inspected frame.
  ##
  ## See this module's header for the one decision that matters here: the
  ## execution pointer is drawn ONLY when the file on screen is the file the
  ## debugger reports.
  ##
  ## THE VALUES ARE DROPPED IN A FILE THE DEBUGGER IS NOT IN, for the same
  ## reason as the pointer: `StateVM.currentVariables` are the locals of the
  ## CURRENT frame, and printing them beside another function's source would
  ## attribute one frame's values to another. CTUI-7 owns per-frame variables —
  ## `StackFrame.id` is carried for exactly that request — and until it exists,
  ## silence is the honest rendering.
  let showsExecution = frame.path.len > 0 and frame.path == debuggerPath
  let total = fetch.totalLineCount
  let top = frameViewportTop(frame.line, viewportHeight, total)
  result = initSourcePaneModel(
    path = frame.path,
    revisionLabel = "",
    provenance = provenanceFor(availability),
    firstHeldLine = fetch.firstLine,
    heldLines = fetch.lines,
    totalLineCount = total,
    viewportTop = top,
    executionLine = (if showsExecution: debuggerLine else: 0),
    marks = marksForFile(points, frame.path),
    values = (if showsExecution: annotationsFrom(variables)
              else: @[]),
    inspectionLine = frame.line)

proc selectedFrame*(model: CallStackModel): StackFrame =
  ## The frame the inspection cursor is on.
  model.frameAt(model.selected)
