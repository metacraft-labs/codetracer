## viewmodels/source_vm.nim
##
## `SourceVM` — the ViewModel that owns *the text of the file at the current
## debugger location*.
##
## ## Why this exists
##
## Until CTUI-4 nothing in this layer owned that text. The desktop delegates it
## to Monaco, which loads files itself, and the only source text present in the
## ViewModel layer arrives pre-filled from a caller
## (`VCSDiffFileRow.sourceLines`, `FlowWindow.sourceLines`,
## `OriginChain.sourceText`). A terminal front-end has no Monaco, so the source
## pane it needs was specified against a seam that did not exist
## (`codetracer-specs/Front-Ends/CodeTracer-TUI.md` §5.3).
##
## It lives in the *shared* ViewModel layer rather than inside `tui/` so the
## terminal front-end and the web GUI cannot drift apart on what "the source at
## this stop" means. It is purely additive: no existing ViewModel changes shape,
## and the desktop continues to use Monaco.
##
## ## Three contracts, and each is asserted rather than described
##
## 1. **The window is virtualized.** This VM holds only the visible line range
##    plus a configurable overscan, never a whole file. `requestMissing` trims
##    the held range to that window before it asks for anything, so a scroll
##    asks for exactly the newly visible lines and no more. That is what lets a
##    source pane meet a memory target on a large file.
##
## 2. **A line outside the window is a REQUEST, not an empty string.**
##    `lineAt` returns a `SourceRead` whose kind says which of the two it is. An
##    empty-string default is exactly how a source pane silently renders blank,
##    and a blank pane over a working debugger is indistinguishable from a file
##    of blank lines.
##
## 3. **Identity is the triple `EditorVM` already tracks** — `activeFileName`,
##    `activeSourceGeneration`, `activeSourceDigest`. Held text is tagged with
##    the triple it was fetched for, so a file recorded twice with different
##    contents (live HCR) can never be served from the wrong revision: when the
##    current triple differs from the held one, every line is a request again.
##
## And one non-contract, stated because its absence is load-bearing:
## **`SourceVM` performs no file I/O and sends no request.** It computes *what*
## it needs; `sdk/source_provider.nim` is the only thing that acquires it. That
## is what keeps a front-end's `app/` layer inside the Embed SDK facade, and it
## is why this module compiles unchanged on both the C and the JS backend.
##
## Degradation is deliberately NOT re-invented here: `degradedState` is the
## *same memo object* `EditorVM` exposes, so a provider that cannot honour a
## requested generation surfaces through Page-Descriptions.md §14's existing
## "No verified source" row rather than through a second, parallel message.
##
## Usage:
##   let editor = createEditorVM(store)
##   let vm = createSourceVM(store, editor)
##   vm.setViewport(height = 20, overscan = 5)
##   for request in vm.requestMissing():
##     discard   # hand `request` to a SourceProvider, then call `vm.fulfill(...)`

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/replay_data_store
import editor_vm

type
  SourceLineRequest* = object
    ## What the VM needs and cannot produce itself: a contiguous, inclusive,
    ## 1-based line range of one *revision* of one path.
    ##
    ## The identity triple travels WITH the range rather than being read from
    ## the store by whoever serves it. A provider that re-read the store would
    ## answer a request the debugger has already stepped past, using the new
    ## revision's text for the old revision's line numbers.
    path*: string
    sourceGeneration*: int
    sourceDigest*: string
    firstLine*: int
      ## 1-based, inclusive.
    lastLine*: int
      ## 1-based, inclusive. `lastLine < firstLine` means an empty request and
      ## is never emitted by `requestMissing`.

  SourceReadKind* = enum
    ## Which of the two answers `lineAt` gave. An enum rather than an
    ## empty-string sentinel, for the reason in this module's header.
    srkHeld
      ## The line is inside the window and its text is present.
    srkRequest
      ## The line is not held. `request` says exactly what to fetch; it is
      ## never a silent blank.

  SourceRead* = object
    ## One answer to "what is on line N?".
    line*: int
    case kind*: SourceReadKind
    of srkHeld:
      text*: string
    of srkRequest:
      request*: SourceLineRequest

  SourceRevision* = object
    ## The identity triple, as one value.
    ##
    ## A value rather than three arguments so a call site cannot pass two of
    ## the three — which for this type would mean serving generation 1's text
    ## under generation 0's identity, the exact failure the triple exists to
    ## prevent.
    path*: string
    sourceGeneration*: int
    sourceDigest*: string

  SourceVM* = ref object of ViewModel
    ## A windowed, revision-identified view of the active file.
    ##
    ## Mutable signals (what a caller sets):
    ##   viewportHeight  — how many lines the pane can show
    ##   overscan        — extra lines held above and below the viewport
    ##   viewportTop     — first VISIBLE line (1-based)
    ##
    ## Held state (what a provider filled in):
    ##   heldFirstLine   — 1-based line number of `heldLines[0]`
    ##   heldLines       — the window's text, and nothing outside it
    ##   heldRevision    — the triple `heldLines` was fetched for
    ##   totalLineCount  — the file's length, as the provider reported it
    ##
    ## Derived memos:
    ##   revision / path / sourceGeneration / sourceDigest — the identity
    ##     triple of the CURRENT debugger location
    ##   visibleFirstLine / visibleLastLine — the viewport, clamped
    ##   windowFirstLine  / windowLastLine  — viewport plus overscan, clamped
    ##   degradedState    — the SAME memo `EditorVM` exposes (§14)
    store*: ReplayDataStore
    editor*: EditorVM

    # -- Mutable state --
    viewportHeight*: Signal[int]
    overscan*: Signal[int]
    viewportTop*: Signal[int]

    # -- Held window --
    heldFirstLine*: Signal[int]
    heldLines*: Signal[seq[string]]
    heldRevision*: Signal[SourceRevision]
    totalLineCount*: Signal[int]
    pendingRequests*: Signal[seq[SourceLineRequest]]
      ## The requests the last `requestMissing` emitted, so a view can render
      ## "loading" for exactly the ranges that are in flight rather than for
      ## "anything I cannot see".

    # -- Derived state --
    revision*: Memo[SourceRevision]
    executionLine*: Memo[int]
      ## The line the BACKEND reports for the current stop
      ## (`store.debugger.val.location.line`).
      ##
      ## THIS IS NOT `EditorVM.cursorLine`, AND THE DIFFERENCE WAS MEASURED
      ## RATHER THAN ASSUMED. `cursorLine` is the editor CARET: nothing in the
      ## ViewModel layer writes it from the debugger position — the only writer
      ## is `EditorVM.setCursor` — so a source pane that scrolled by
      ## `followCursor` alone stays on line 1 for the whole session while the
      ## execution pointer walks off the bottom. That is what
      ## `src/tests/gui/tests/source-access/source_access_test.nim` observed on
      ## the `calc` fixture: the debugger reached line 29 with the window still
      ## holding 1..16.
      ##
      ## Both are kept, because they are different questions: `followCursor`
      ## is what a user moving the caret drives, `followExecutionPointer` is
      ## what a stop drives. A front-end binds the second one to its stepping
      ## controls.
    path*: Memo[string]
    sourceGeneration*: Memo[int]
    sourceDigest*: Memo[string]
    visibleFirstLine*: Memo[int]
    visibleLastLine*: Memo[int]
    windowFirstLine*: Memo[int]
    windowLastLine*: Memo[int]
    degradedState*: Memo[PaneDegradation]
      ## Page-Descriptions.md §14's one row this pane renders. This is
      ## `EditorVM.degradedState` itself — the same object, not a second memo
      ## computing the same thing — because §14's rule is "one canonical
      ## treatment rather than being reinvented per page", and a source pane
      ## that resolved its own degradation would be the reinvention.

# ---------------------------------------------------------------------------
# Small helpers over the identity triple
# ---------------------------------------------------------------------------

func `==`*(a, b: SourceRevision): bool =
  ## Identity is all three components. Two revisions of one path differ in
  ## `sourceGeneration`; two builds of one generation differ in `sourceDigest`.
  a.path == b.path and
    a.sourceGeneration == b.sourceGeneration and
    a.sourceDigest == b.sourceDigest

func `$`*(r: SourceRevision): string =
  r.path & "@" & $r.sourceGeneration &
    (if r.sourceDigest.len > 0: "#" & r.sourceDigest else: "")

func isEmpty*(r: SourceRevision): bool =
  ## No path means the debugger has not reported a source location yet.
  r.path.len == 0

func lineCount*(request: SourceLineRequest): int =
  ## How many lines this request covers. Zero for an empty request.
  if request.lastLine < request.firstLine: 0
  else: request.lastLine - request.firstLine + 1

# ---------------------------------------------------------------------------
# Window arithmetic
#
# Free functions over plain integers, so the clamping rules are testable
# without a store, a reactive root or a debugger.
# ---------------------------------------------------------------------------

func clampTop*(top, viewportHeight, totalLineCount: int): int =
  ## The first visible line, clamped so the viewport never runs off either end.
  ##
  ## `totalLineCount == 0` means the provider has not reported a length yet;
  ## the top stays where the caller put it (but never above line 1) rather than
  ## collapsing to 1, so a scroll issued before the first fulfilment is not
  ## silently discarded.
  if top < 1:
    1
  elif totalLineCount <= 0:
    top
  elif viewportHeight >= totalLineCount:
    1
  elif top > totalLineCount - viewportHeight + 1:
    totalLineCount - viewportHeight + 1
  else:
    top

func topFollowingCursor*(currentTop, cursorLine, viewportHeight,
                         totalLineCount: int): int =
  ## The smallest scroll that brings `cursorLine` inside the viewport.
  ##
  ## "Smallest" is the point: a source pane that re-centred on every step would
  ## make a single-line step look like a jump, and a pane that never scrolled
  ## would lose the execution pointer off the bottom.
  if viewportHeight <= 0 or cursorLine <= 0:
    return clampTop(currentTop, viewportHeight, totalLineCount)
  let bottom = currentTop + viewportHeight - 1
  if cursorLine < currentTop:
    clampTop(cursorLine, viewportHeight, totalLineCount)
  elif cursorLine > bottom:
    clampTop(cursorLine - viewportHeight + 1, viewportHeight, totalLineCount)
  else:
    clampTop(currentTop, viewportHeight, totalLineCount)

# ---------------------------------------------------------------------------
# Reading the window
# ---------------------------------------------------------------------------

proc heldLastLine*(vm: SourceVM): int =
  ## 1-based line number of the last held line; `heldFirstLine - 1` (i.e. an
  ## empty range) when nothing is held.
  vm.heldFirstLine.val + vm.heldLines.val.len - 1

proc holdsCurrentRevision*(vm: SourceVM): bool =
  ## Whether the held text belongs to the revision the debugger is stopped in.
  ##
  ## False after the debugger moves to another file, and false after a live-HCR
  ## patch bumps `sourceGeneration` for the SAME path — which is the case that
  ## would otherwise show correct-looking source for the wrong build.
  not vm.revision.val.isEmpty and vm.heldRevision.val == vm.revision.val

proc requestFor*(vm: SourceVM; firstLine, lastLine: int): SourceLineRequest =
  ## A request for `firstLine .. lastLine` of the CURRENT revision.
  let rev = vm.revision.val
  SourceLineRequest(
    path: rev.path,
    sourceGeneration: rev.sourceGeneration,
    sourceDigest: rev.sourceDigest,
    firstLine: firstLine,
    lastLine: lastLine)

proc lineAt*(vm: SourceVM; line: int): SourceRead =
  ## The text of `line`, or the request that would obtain it.
  ##
  ## NEVER returns held text for a revision other than the current one, and
  ## never returns an empty string to mean "not loaded" — see contract 2 in
  ## this module's header.
  if line >= 1 and vm.holdsCurrentRevision and
      line >= vm.heldFirstLine.val and line <= vm.heldLastLine:
    SourceRead(line: line, kind: srkHeld,
               text: vm.heldLines.val[line - vm.heldFirstLine.val])
  else:
    SourceRead(line: line, kind: srkRequest,
               request: vm.requestFor(line, line))

proc visibleReads*(vm: SourceVM): seq[SourceRead] =
  ## One `SourceRead` per visible line, in order. A view iterates this and
  ## renders each answer for what it is.
  result = @[]
  for line in vm.visibleFirstLine.val .. vm.visibleLastLine.val:
    result.add(vm.lineAt(line))

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setViewport*(vm: SourceVM; height: int; overscan: int = -1) =
  ## Set the pane's height in lines, and optionally the overscan.
  ##
  ## A negative or zero height is clamped to 1: a viewport of zero lines would
  ## make every window empty and every read a request, which reads exactly like
  ## a provider that never answers.
  vm.viewportHeight.val = max(1, height)
  if overscan >= 0:
    vm.overscan.val = overscan
  vm.viewportTop.val = clampTop(vm.viewportTop.val, vm.viewportHeight.val,
                                vm.totalLineCount.val)

proc scrollTo*(vm: SourceVM; top: int) =
  ## Put `top` at the top of the viewport, clamped to the file.
  vm.viewportTop.val = clampTop(top, vm.viewportHeight.val,
                                vm.totalLineCount.val)

proc scrollBy*(vm: SourceVM; delta: int) =
  ## Scroll by `delta` lines (negative scrolls up).
  vm.scrollTo(vm.viewportTop.val + delta)

proc followCursor*(vm: SourceVM) =
  ## Scroll the least amount that brings `EditorVM.cursorLine` — the editor
  ## CARET — into view.
  vm.viewportTop.val = topFollowingCursor(
    vm.viewportTop.val, vm.editor.cursorLine.val,
    vm.viewportHeight.val, vm.totalLineCount.val)

proc followExecutionPointer*(vm: SourceVM) =
  ## Scroll the least amount that brings the line the BACKEND reports for the
  ## current stop into view.
  ##
  ## This is the one a stepping front-end calls after every stop. See
  ## `executionLine` for why it is not the same call as `followCursor`.
  vm.viewportTop.val = topFollowingCursor(
    vm.viewportTop.val, vm.executionLine.val,
    vm.viewportHeight.val, vm.totalLineCount.val)

proc trimToWindow*(vm: SourceVM) =
  ## Drop every held line outside the window (viewport plus overscan).
  ##
  ## THIS IS THE VIRTUALIZATION, and it runs before requesting rather than
  ## after: without it the held range only ever grows, `requestMissing` asks
  ## only for lines beyond the high-water mark, and the VM ends up holding the
  ## whole file while every test about "requests exactly the newly visible
  ## lines" still passes.
  if not vm.holdsCurrentRevision:
    vm.heldLines.val = @[]
    vm.heldFirstLine.val = 1
    return
  let first = vm.windowFirstLine.val
  let last = vm.windowLastLine.val
  let heldFirst = vm.heldFirstLine.val
  let heldLast = vm.heldLastLine
  if heldLast < heldFirst:
    return
  if last < first or heldLast < first or heldFirst > last:
    vm.heldLines.val = @[]
    vm.heldFirstLine.val = first
    return
  let keepFirst = max(first, heldFirst)
  let keepLast = min(last, heldLast)
  if keepFirst == heldFirst and keepLast == heldLast:
    return
  vm.heldLines.val = vm.heldLines.val[keepFirst - heldFirst .. keepLast - heldFirst]
  vm.heldFirstLine.val = keepFirst

proc requestMissing*(vm: SourceVM): seq[SourceLineRequest] =
  ## Trim to the window, then return the ranges the window still lacks.
  ##
  ## At most two requests, and each is contiguous: the gap above the held range
  ## and the gap below it. A caller hands each to a `SourceProvider` and feeds
  ## the answer back through `fulfill`.
  ##
  ## Returns an empty seq when the window is fully held — which is what makes
  ## "scrolling requests exactly the newly visible lines and no more" an exact
  ## assertion rather than an upper bound.
  result = @[]
  if vm.revision.val.isEmpty:
    vm.pendingRequests.val = result
    return
  vm.trimToWindow()
  let first = vm.windowFirstLine.val
  let last = vm.windowLastLine.val
  if last < first:
    vm.pendingRequests.val = result
    return
  let heldFirst = vm.heldFirstLine.val
  let heldLast = vm.heldLastLine
  if heldLast < heldFirst:
    result.add(vm.requestFor(first, last))
  else:
    if first < heldFirst:
      result.add(vm.requestFor(first, heldFirst - 1))
    if last > heldLast:
      result.add(vm.requestFor(heldLast + 1, last))
  vm.pendingRequests.val = result

proc fulfill*(vm: SourceVM; revision: SourceRevision; firstLine: int;
              lines: seq[string]; totalLineCount: int): bool =
  ## Adopt `lines` as the text of `firstLine ..` for `revision`.
  ##
  ## Returns FALSE, and changes nothing, when `revision` is not the revision
  ## the debugger is currently stopped in. That refusal is the point: an answer
  ## that arrives after the debugger has stepped into another file — or after a
  ## live-HCR patch bumped the generation — describes a file the pane is no
  ## longer showing, and adopting it would render the wrong build's text under
  ## the right build's line numbers.
  ##
  ## Also returns false for a non-contiguous fill: a fill that neither touches
  ## nor overlaps the held range would leave a hole the window arithmetic
  ## cannot represent, and silently accepting it would put unrelated text at
  ## the line numbers between.
  if revision.isEmpty or revision != vm.revision.val:
    return false
  if firstLine < 1:
    return false
  if totalLineCount >= 0:
    vm.totalLineCount.val = totalLineCount

  if not vm.holdsCurrentRevision or vm.heldLines.val.len == 0:
    vm.heldRevision.val = revision
    vm.heldFirstLine.val = firstLine
    vm.heldLines.val = lines
    vm.trimToWindow()
    return true

  let heldFirst = vm.heldFirstLine.val
  let heldLast = vm.heldLastLine
  let newLast = firstLine + lines.len - 1
  if firstLine > heldLast + 1 or newLast < heldFirst - 1:
    return false

  var merged: seq[string] = @[]
  let mergedFirst = min(heldFirst, firstLine)
  let mergedLast = max(heldLast, newLast)
  for line in mergedFirst .. mergedLast:
    if line >= firstLine and line <= newLast:
      # The incoming fill wins on overlap: it is the fresher read of the same
      # revision, and a stale cached line is exactly what this VM must not
      # serve.
      merged.add(lines[line - firstLine])
    else:
      merged.add(vm.heldLines.val[line - heldFirst])
  vm.heldFirstLine.val = mergedFirst
  vm.heldLines.val = merged
  vm.trimToWindow()
  true

proc discardHeldText*(vm: SourceVM) =
  ## Forget the held window. Called when a provider reports that the requested
  ## revision is unavailable, so the pane shows §14's row rather than the last
  ## revision's text under the new revision's identity.
  vm.heldLines.val = @[]
  vm.heldFirstLine.val = 1
  vm.heldRevision.val = SourceRevision()
  vm.totalLineCount.val = 0
  vm.pendingRequests.val = @[]

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

const
  DefaultSourceViewportHeight* = 24
    ## A conventional terminal pane height. Named so a test can assert the
    ## default rather than restate it.
  DefaultSourceOverscan* = 8
    ## Lines held beyond each edge of the viewport. Large enough that a
    ## keyboard scroll of a few lines is served from memory, small enough that
    ## the window stays a window.

proc createSourceVM*(store: ReplayDataStore; editor: EditorVM): SourceVM =
  ## Create a `SourceVM` inside a reactive root owned by `withViewModel`.
  ##
  ## `editor` supplies both the cursor the window follows and the identity
  ## triple, so the two ViewModels cannot disagree about which revision is on
  ## screen. It also supplies `degradedState`, which is re-exposed as the same
  ## memo rather than recomputed.
  withViewModel proc(dispose: proc()): SourceVM =
    let viewportHeight = createSignal(DefaultSourceViewportHeight)
    let overscan = createSignal(DefaultSourceOverscan)
    let viewportTop = createSignal(1)
    let heldFirstLine = createSignal(1)
    let heldLines = createSignal(newSeq[string]())
    let heldRevision = createSignal(SourceRevision())
    let totalLineCount = createSignal(0)
    let pendingRequests = createSignal(newSeq[SourceLineRequest]())

    let revision = createMemo[SourceRevision] proc(): SourceRevision =
      SourceRevision(
        path: editor.activeFileName.val,
        sourceGeneration: editor.activeSourceGeneration.val,
        sourceDigest: editor.activeSourceDigest.val)

    let executionLine = createMemo[int] proc(): int =
      store.debugger.val.location.line

    let path = createMemo[string] proc(): string =
      editor.activeFileName.val

    let sourceGeneration = createMemo[int] proc(): int =
      editor.activeSourceGeneration.val

    let sourceDigest = createMemo[string] proc(): string =
      editor.activeSourceDigest.val

    let visibleFirstLine = createMemo[int] proc(): int =
      clampTop(viewportTop.val, viewportHeight.val, totalLineCount.val)

    let visibleLastLine = createMemo[int] proc(): int =
      let first = clampTop(viewportTop.val, viewportHeight.val,
                           totalLineCount.val)
      let last = first + viewportHeight.val - 1
      if totalLineCount.val > 0: min(last, totalLineCount.val) else: last

    let windowFirstLine = createMemo[int] proc(): int =
      max(1, clampTop(viewportTop.val, viewportHeight.val,
                      totalLineCount.val) - overscan.val)

    let windowLastLine = createMemo[int] proc(): int =
      let first = clampTop(viewportTop.val, viewportHeight.val,
                           totalLineCount.val)
      let last = first + viewportHeight.val - 1 + overscan.val
      if totalLineCount.val > 0: min(last, totalLineCount.val) else: last

    SourceVM(
      store: store,
      editor: editor,
      viewportHeight: viewportHeight,
      overscan: overscan,
      viewportTop: viewportTop,
      heldFirstLine: heldFirstLine,
      heldLines: heldLines,
      heldRevision: heldRevision,
      totalLineCount: totalLineCount,
      pendingRequests: pendingRequests,
      revision: revision,
      executionLine: executionLine,
      path: path,
      sourceGeneration: sourceGeneration,
      sourceDigest: sourceDigest,
      visibleFirstLine: visibleFirstLine,
      visibleLastLine: visibleLastLine,
      windowFirstLine: windowFirstLine,
      windowLastLine: windowLastLine,
      degradedState: editor.degradedState,
      disposeProc: dispose,
    )
