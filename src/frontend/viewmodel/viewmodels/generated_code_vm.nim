## viewmodels/generated_code_vm.nim
##
## GeneratedCodeVM — the ON-DEMAND, CURSOR-ANCHORED, TAB-SYNCED half of
## `GUI/Debugging-Features/Generated-Code-Listing.md`.
##
## §1, §2 (GCL-D10), §6 (GCL-D14, GCL-D15, GCL-D16), §7, §8's state table,
## §9 (GCL-D18), §14.2 (GCL-D23).
##
## LANE: `vm-unit` AND `vm-unit-js`. No host, no Monaco, no DOM.
##
## ## WHAT THIS ADDS TO A TREE THAT ALREADY HAD THE MODEL
##
## `generated_code_anchors` decides what a mapping claim may say, and
## `noir_anchor_producer` reads a real `nargo compile` artefact into anchors.
## Both are green against a committed compiler artefact. NEITHER HAD A
## PRODUCTION CALLER: `setAnchors`, `syncFromSource`, `syncFromGenerated` and
## `produceAnchors` were reached only from their own suites, which is the
## defect shape `ci/test/frontend-reachability-guard.py` was written for —
## a correct, tested capability no product code reaches, whose user-visible
## face is a feature that looks present and does nothing.
##
## So this module is the operation, and `ui/generated_code.nim` is what reaches
## it. What it adds over the model:
##
##   1. **Nothing is computed until it is asked for.** §1: "the operation is
##      invoked, never permanently displayed."
##   2. **The cursor is the subject** (GCL-D10), and the relationship between
##      the two documents is RENDERED rather than implied (GCL-D12).
##   3. **The listing follows the active source tab**, and a cursor move in a
##      tab the user is not looking at moves nothing.
##
## ## 1. ON DEMAND, AND WHY THAT IS A STRUCTURAL PROPERTY RATHER THAN A HABIT
##
## This surface sits beside panes that have caused re-render storms, and a
## listing recomputed on every cursor move would be the next one. "We only call
## it when needed" is not a property anything can check. So the model is:
##
##   * A closed VM HOLDS NO CURSOR. `noteCursorMoved` on a closed VM writes no
##     signal and returns `false`. It cannot recompute a listing it does not
##     have, and it cannot accumulate a position to replay later.
##   * `openListing` takes the cursor as an ARGUMENT. This is GCL-D16's rule
##     turned into a signature: projection is a pure function of the landing
##     position and depends on nothing that happened on the way there, so the
##     VM never needs a queue of positions it missed while closed, and a
##     deferred projection is EXACT rather than approximate.
##   * `revision` increments only when ROWS ARE REPLACED. A cursor move
##     re-projects and leaves it alone. That is the assertion that separates
##     "re-anchored" from "recompiled", and it is countable: N cursor moves
##     over an open listing must leave `revision` where they found it.
##
## ## 2. THE THREE ANSWERS, NOT TWO (GCL-D12)
##
## The failure ruled out is a surface with two states — *an answer* and
## *nothing* — where the reader cannot tell a broken query from a correct empty
## one. `SyncDecision` already carries the distinction (`soAligned` /
## `soSuspended` / `soDisabled`) and `focusText` is what makes it visible:
## every non-aligned state renders a sentence, and the aligned state renders
## which rows correspond to which line. A correspondence the user cannot see is
## indistinguishable from drift.
##
## `instantiationCount` is stated in ALL cases, including one and zero
## (GCL-D29): otherwise *one instantiation* and *this product has no such
## concept* look the same, and a reader who expected several cannot tell a
## correct answer from a missing feature. It is read from `anchorsFromSource`,
## which returns every anchor the line produced — NOT from the single anchor
## `syncFromSource` picks, which cannot tell one from three.
##
## ## 3. THE TAB IS PART OF THE IDENTITY, NOT AN AMBIENT FACT
##
## A listing describes ONE source file. The editor has many tabs, and each has
## its own cursor. Three rules, and the second is the one an implementation
## reading an ambient "current line" gets wrong:
##
##   * `noteActiveTabChanged` is what moves the listing between files. When the
##     newly active tab is not the file the listing describes, correspondence
##     SUSPENDS with a sentence naming both files — it does not silently keep
##     showing the previous file's anchors against this file's cursor, which is
##     the confidently-wrong answer §5 exists to prevent.
##   * `noteCursorMoved` IGNORES a move whose path is not the active tab.
##     Monaco fires cursor events for background models; a VM that took them
##     would follow a tab the user is not looking at.
##   * Reopening the same target for the same file REUSES the listing and
##     re-projects (§7) rather than rebuilding it — which is the same
##     `revision` assertion as above, reached by the other gesture.
##
## ## 4. STALENESS SUSPENDS; IT DOES NOT CLEAR (GCL-D18)
##
## An edit leaves the rows — they describe a real compilation the reader may
## still want — marks the tab stale, and suspends correspondence, because a
## stale listing that kept synchronising would move the cursor to confidently
## wrong lines. Three effects, and `noteSourceEdited` does all three or none;
## `constraints_vm.editInvalidatesCounts` is the producer's rule about which
## files matter and is reused rather than restated.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./generated_code_anchors
import ./generated_code_operation
import ./constraints_vm

export generated_code_anchors
export generated_code_operation

type
  ListingState* = enum
    ## §8's state table, which "must not collapse" its rows. Each of these is a
    ## different answer to *why am I not looking at a listing*, and a surface
    ## that renders two of them the same has lost the distinction the model
    ## went to the trouble of encoding.
    lsClosed
      ## Nothing has been requested. No artefact, no rows, no cursor. This is
      ## the state the product boots in and returns to on close, and it is what
      ## "on demand" means structurally.
    lsBuilding
      ## A build is running FOR THIS SURFACE. §8: the tab is open and shows the
      ## build; it does not show a spinner over an empty document.
    lsFailed
      ## The build failed. No listing, and the compiler's own diagnostic.
      ## Never the previous successful build's rows.
    lsReady
      ## Rows are present.

  GeneratedRow* = object
    ## One printed row of the compiler's own listing. `index` IS the row index
    ## the anchors are keyed by — GCL-D6's `row index ≡ opcode index`
    ## invariant, carried here so a consumer that reorders or filters rows
    ## cannot silently shift every anchor by a constant.
    index*: int
    text*: string
    annotation*: string
      ## The compiler's own annotation on this row, where it emitted one —
      ## an assertion's failure message beside the opcode that enforces it,
      ## for instance. §14.3: it is preserved rather than stripped as noise,
      ## because it is what turns a row into a statement about the developer's
      ## program rather than about the circuit.

  GeneratedListing* = object
    ## What a producer hands over. §13.1's four requirements land here: rows as
    ## the compiler prints them, anchors carrying an ordered inlining chain,
    ## and the artefact's own ceiling.
    targetId*: string
    sourcePath*: string
      ## The file this listing describes. Not a display detail: it is what
      ## `noteActiveTabChanged` compares against, and a listing that did not
      ## carry it would have to read the answer from whichever tab happened to
      ## be in front.
    producer*: string
      ## GCL-D23. The surface states it, because a row count cannot
      ## discriminate two producers that agree on every number.
    rows*: seq[GeneratedRow]
    anchors*: seq[MappingAnchor]
    support*: ArtefactSupport
    listingAbsence*: string
      ## Non-empty when the build SUCCEEDED and the producer has anchors and
      ## totals but no rows (§8's fourth state). Totals with no rows is a
      ## different answer from a listing that came back empty, and a surface
      ## that cannot tell a reader which it holds has collapsed them.

  GeneratedCodeVM* = ref object of ViewModel
    # -- Mutable state --
    state*: Signal[ListingState]
    targetId*: Signal[string]
    targetName*: Signal[string]
    producer*: Signal[string]
    listingPath*: Signal[string]
    rows*: Signal[seq[GeneratedRow]]
    revision*: Signal[int]
      ## Increments ONLY when the rows are replaced. A cursor move must leave
      ## it alone; that is how "re-anchored" is told from "recomputed".
    anchors*: Signal[seq[MappingAnchor]]
    listingAbsence*: Signal[string]
    failure*: Signal[string]
    activeTabPath*: Signal[string]
    cursorLine*: Signal[int]
    syncEnabled*: Signal[bool]
    stale*: Signal[bool]

    # -- Derived state --
    isOpen*: Memo[bool]
    describesActiveTab*: Memo[bool]
    focus*: Memo[SyncDecision]
    focusRows*: Memo[(int, int)]
    instantiationCount*: Memo[int]
    focusText*: Memo[string]
    tabTitle*: Memo[string]
    producerLine*: Memo[string]

proc settingsOf(vm: GeneratedCodeVM): SyncSettings =
  SyncSettings(enabled: vm.syncEnabled.val)

# ---------------------------------------------------------------------------
# Opening — the only path that computes anything
# ---------------------------------------------------------------------------

proc noteBuildStarted*(vm: GeneratedCodeVM; t: GeneratedCodeTarget;
                       sourcePath: string; cursorLine: int) =
  ## §8: "while the build runs, the tab is open and shows the build." The tab
  ## exists from here, so a reader who asked a question can watch it being
  ## answered instead of looking at a spinner over an empty document.
  ##
  ## THE PREVIOUS ROWS GO. A build that is running describes an artefact that
  ## does not exist yet, and leaving the last successful build's rows on screen
  ## while it runs is the same defect as leaving them after a failure: a
  ## developer reading a listing that does not correspond to the source in
  ## front of them is worse off than one reading nothing.
  vm.state.val = lsBuilding
  vm.targetId.val = t.id
  vm.targetName.val = t.displayName
  vm.producer.val = t.producer
  vm.listingPath.val = sourcePath
  vm.activeTabPath.val = sourcePath
  vm.cursorLine.val = cursorLine
  vm.rows.val = @[]
  vm.anchors.val = @[]
  vm.listingAbsence.val = ""
  vm.failure.val = ""
  vm.stale.val = false

proc noteBuildFailed*(vm: GeneratedCodeVM; diagnostic: string) =
  ## GCL: "a failed build produces no listing and says so." The rows are
  ## cleared rather than kept, which is the OPPOSITE of the staleness rule
  ## below and deliberately so: a stale listing describes a compilation that
  ## really happened, and a failed build describes none.
  vm.state.val = lsFailed
  vm.failure.val =
    if diagnostic.len > 0: diagnostic
    else: "the build failed and produced no diagnostic"
  vm.rows.val = @[]
  vm.anchors.val = @[]

proc openListing*(vm: GeneratedCodeVM; listing: GeneratedListing;
                  cursorLine: int) =
  ## THE ON-DEMAND ENTRY POINT. Everything this surface computes is downstream
  ## of a call to this proc or to `noteBuildStarted`.
  ##
  ## `cursorLine` is an argument rather than something the VM has been
  ## accumulating, and that is GCL-D16 expressed as a signature: correspondence
  ## is computed from the leader's position and the artefact's map, and depends
  ## on nothing that happened on the way there. So a listing opened after a
  ## hundred cursor moves the VM never saw lands exactly where one opened after
  ## none would have.
  ##
  ## REOPENING THE SAME TARGET FOR THE SAME FILE re-projects and does not
  ## rebuild (§7: "re-invoking the same target for the same file reuses its tab
  ## and re-positions it"). `revision` is what says which happened.
  let sameSurface = vm.state.val == lsReady and
    vm.targetId.val == listing.targetId and
    vm.listingPath.val == listing.sourcePath

  vm.state.val = lsReady
  vm.targetId.val = listing.targetId
  vm.producer.val = listing.producer
  vm.listingPath.val = listing.sourcePath
  vm.activeTabPath.val = listing.sourcePath
  vm.listingAbsence.val = listing.listingAbsence
  vm.failure.val = ""
  vm.stale.val = false
  vm.cursorLine.val = cursorLine

  var t: GeneratedCodeTarget
  if targetById(listing.targetId, t):
    vm.targetName.val = t.displayName

  if not sameSurface:
    vm.rows.val = listing.rows
    vm.anchors.val = listing.anchors
    vm.revision.val = vm.revision.val + 1

proc closeListing*(vm: GeneratedCodeVM) =
  ## §7: "the tab is closable like any other tab, and closing it is how the
  ## operation is undone. There is no separate dismissal."
  ##
  ## Back to holding nothing, including the cursor: a closed VM that remembered
  ## a position would start accumulating again the moment it reopened, and
  ## GCL-D16's equivalence would stop being true.
  vm.state.val = lsClosed
  vm.targetId.val = ""
  vm.targetName.val = ""
  vm.producer.val = ""
  vm.listingPath.val = ""
  vm.activeTabPath.val = ""
  vm.rows.val = @[]
  vm.anchors.val = @[]
  vm.listingAbsence.val = ""
  vm.failure.val = ""
  vm.cursorLine.val = 0
  vm.stale.val = false

# ---------------------------------------------------------------------------
# The cursor leads
# ---------------------------------------------------------------------------

proc noteCursorMoved*(vm: GeneratedCodeVM; path: string; line: int): bool
    {.discardable.} =
  ## The cursor moved in `path`. Returns whether it was taken.
  ##
  ## THREE REFUSALS, and each is a separate defect if it is missing:
  ##
  ##   * **Closed.** Nothing is written and nothing is computed. This is what
  ##     makes the surface on-demand structurally rather than by convention —
  ##     a closed VM cannot storm, because it holds nothing to recompute.
  ##   * **Not the active tab.** Monaco fires cursor events for models that are
  ##     not on screen. A VM that took them would follow a tab the user is not
  ##     looking at, and the listing would move for a reason nothing visible
  ##     explains.
  ##   * **Same line.** `onDidChangeCursorPosition` fires for column moves too,
  ##     and this surface is line-granular (`SourceRegion` is). Writing the
  ##     signal for a value that did not change re-runs every memo and the
  ##     render effect for nothing — the same guard, and the same reason, as
  ##     `constraints_vm.markStale`'s.
  ##
  ## What it does NOT do is rebuild anything. `revision` is untouched here, and
  ## that is the assertion: the listing is re-anchored, never recomputed.
  if vm.state.val == lsClosed:
    return false
  if path != vm.activeTabPath.val:
    return false
  if line == vm.cursorLine.val:
    return false
  vm.cursorLine.val = line
  true

proc noteActiveTabChanged*(vm: GeneratedCodeVM; path: string; line: int): bool
    {.discardable.} =
  ## The user switched source tabs. Returns whether it was taken.
  ##
  ## The listing follows the ACTIVE tab, which is the whole of "synced tabs".
  ## When the new tab is a different file from the one the listing describes,
  ## the correspondence suspends and says so — `describesActiveTab` is what
  ## carries it, and `focus` reads it. It does not keep projecting the old
  ## file's anchors against the new file's cursor, which would produce a
  ## plausible row range that means nothing.
  ##
  ## The cursor arrives WITH the tab rather than being asked for afterwards:
  ## each tab has its own, and a VM that switched tabs and then waited for a
  ## cursor event would spend the interval showing the previous tab's line
  ## under the new tab's name.
  if vm.state.val == lsClosed:
    return false
  if path == vm.activeTabPath.val and line == vm.cursorLine.val:
    return false
  vm.activeTabPath.val = path
  vm.cursorLine.val = line
  true

proc setSyncEnabled*(vm: GeneratedCodeVM; enabled: bool) =
  ## GCL-D15's toggle. *Off* and *suspended* are different states and render
  ## differently; this sets the first, and the mapping running out is what
  ## produces the second.
  if vm.syncEnabled.val != enabled:
    vm.syncEnabled.val = enabled

proc noteSourceEdited*(vm: GeneratedCodeVM; path: string) =
  ## GCL-D18. An edit to a file the producer names as invalidating marks the
  ## tab stale AND suspends correspondence AND leaves the rows. All three or
  ## none — an implementation doing the first two blanks a surface that still
  ## holds a correct answer, and one doing only the first keeps moving the
  ## cursor to lines the map no longer addresses.
  ##
  ## `editInvalidatesCounts` is the Noir producer's rule about which files
  ## matter (`.nr` sources and `Nargo.toml`, deliberately not `Prover.toml`),
  ## and it is CALLED rather than restated: two copies of that rule is how the
  ## label comes to appear on edits that cannot have invalidated anything,
  ## which costs the credibility the whole mechanism is for.
  if vm.state.val == lsClosed:
    return
  if not editInvalidatesCounts(path):
    return
  if not vm.stale.val:
    vm.stale.val = true

# ---------------------------------------------------------------------------
# Reading — what the view renders
# ---------------------------------------------------------------------------

# `rowsFor` / `sourcesFor` wrappers over `counterpartRows` /
# `counterpartSources` WERE HERE AND ARE DELETED. Nothing outside this module
# called them: the row range a view needs is already the `focusRows` memo, and
# the wrappers existed for a renderer that has not been written. An exported
# convenience with no consumer is the shape
# `ci/test/frontend-reachability-guard.py` exists to find, and writing one
# while adding that guard's sibling would have been a poor joke. When a view
# needs the sources of an aligned decision it can call `counterpartSources`,
# which this module re-exports.

proc createGeneratedCodeVM*(): GeneratedCodeVM =
  withViewModel proc(dispose: proc()): GeneratedCodeVM =
    let state = createSignal(lsClosed)
    let targetId = createSignal("")
    let targetName = createSignal("")
    let producer = createSignal("")
    let listingPath = createSignal("")
    let rows = createSignal(newSeq[GeneratedRow]())
    let revision = createSignal(0)
    let anchors = createSignal(newSeq[MappingAnchor]())
    let listingAbsence = createSignal("")
    let failure = createSignal("")
    let activeTabPath = createSignal("")
    let cursorLine = createSignal(0)
    let syncEnabled = createSignal(DefaultSyncSettings.enabled)
    let stale = createSignal(false)

    let isOpen = createMemo[bool] proc(): bool =
      state.val != lsClosed

    let describesActiveTab = createMemo[bool] proc(): bool =
      state.val != lsClosed and listingPath.val.len > 0 and
        listingPath.val == activeTabPath.val

    let focus = createMemo[SyncDecision] proc(): SyncDecision =
      ## The three answers, decided in the order that keeps them distinct.
      ##
      ## `soDisabled` is checked FIRST because GCL-D15 requires *you turned it
      ## off* to survive every other condition: a suspension reported while the
      ## toggle is off would tell the reader the mapping ran out when in fact
      ## nothing was asked of it.
      let settings = SyncSettings(enabled: syncEnabled.val)
      if not settings.enabled:
        return SyncDecision(outcome: soDisabled, anchorIndex: NoAnchor,
          reason: "synchronisation is off")
      if state.val == lsClosed:
        return SyncDecision(outcome: soSuspended, anchorIndex: NoAnchor,
          reason: "no generated-code listing is open")
      if state.val == lsBuilding:
        return SyncDecision(outcome: soSuspended, anchorIndex: NoAnchor,
          reason: "the build is still running, so there is nothing to " &
            "correspond to yet")
      if state.val == lsFailed:
        return SyncDecision(outcome: soSuspended, anchorIndex: NoAnchor,
          reason: "the build failed, so this listing is from no artefact")
      if stale.val:
        # GCL-D18's second effect. The rows are still on screen; the
        # correspondence is not, because line 40 of the edited file is not the
        # line 40 the map was built against.
        return SyncDecision(outcome: soSuspended, anchorIndex: NoAnchor,
          reason: "the source has been edited since this listing was built, " &
            "so its line numbers no longer address the text on screen")
      if listingPath.val != activeTabPath.val:
        return SyncDecision(outcome: soSuspended, anchorIndex: NoAnchor,
          reason: "this listing describes " & listingPath.val &
            "; the active tab is " &
            (if activeTabPath.val.len > 0: activeTabPath.val else: "no file"))
      syncFromSource(anchors.val, listingPath.val, cursorLine.val, settings)

    let focusRows = createMemo[(int, int)] proc(): (int, int) =
      counterpartRows(anchors.val, focus.val)

    let instantiationCount = createMemo[int] proc(): int =
      ## Stated in ALL cases, including zero and one (GCL-D29). Read from
      ## `anchorsFromSource`, which returns every anchor the line produced —
      ## `focus` above picks one and cannot tell one from three.
      if state.val != lsReady or stale.val or
          listingPath.val != activeTabPath.val:
        return 0
      anchorsFromSource(anchors.val, listingPath.val, cursorLine.val).len

    let focusText = createMemo[string] proc(): string =
      ## THE RELATIONSHIP, RENDERED. §6: the two documents move together, and a
      ## correspondence the reader cannot see is indistinguishable from drift.
      ##
      ## The aligned sentence names BOTH ENDS — the source line and the row
      ## range — because naming only one leaves the reader to infer the link
      ## from two numbers that happen to have moved together, which is the
      ## inference this document refuses to delegate everywhere else.
      let d = focus.val
      case d.outcome
      of soDisabled:
        d.reason
      of soSuspended:
        d.reason
      of soAligned:
        let (first, last) = counterpartRows(anchors.val, d)
        let count = anchorsFromSource(anchors.val, listingPath.val,
          cursorLine.val).len
        var s = listingPath.val & ":" & $cursorLine.val & " → rows " &
          $first & (if last != first: "–" & $last else: "")
        # The count is part of the sentence rather than a separate chrome,
        # because GCL-D29 requires it stated even where the picker's chrome is
        # absent: otherwise one instantiation and "this product has no such
        # concept" look the same.
        s.add ", " & $count &
          (if count == 1: " instantiation" else: " instantiations")
        s
    let tabTitle = createMemo[string] proc(): string =
      ## §7: "a tab carries the identity of what it shows: the file, the
      ## target's display name". A tab titled only *Assembly* cannot be told
      ## from another file's. The `(stale)` suffix is GCL-D18's first effect,
      ## and it is the same spelling `constraints_vm.headlineFor` uses.
      if state.val == lsClosed:
        return ""
      var s = listingPath.val
      if targetName.val.len > 0:
        s.add " — " & targetName.val
      if stale.val:
        s.add " (stale)"
      s

    let producerLine = createMemo[string] proc(): string =
      ## GCL-D23: the producer is named ON THE SURFACE. A reader who sees two
      ## different answers over a session must be able to tell which is which
      ## without counting rows — and a row count cannot discriminate them,
      ## because the two producers agree on every number.
      if state.val == lsClosed or producer.val.len == 0:
        return ""
      "listing produced by " & producer.val

    GeneratedCodeVM(
      state: state,
      targetId: targetId,
      targetName: targetName,
      producer: producer,
      listingPath: listingPath,
      rows: rows,
      revision: revision,
      anchors: anchors,
      listingAbsence: listingAbsence,
      failure: failure,
      activeTabPath: activeTabPath,
      cursorLine: cursorLine,
      syncEnabled: syncEnabled,
      stale: stale,
      isOpen: isOpen,
      describesActiveTab: describesActiveTab,
      focus: focus,
      focusRows: focusRows,
      instantiationCount: instantiationCount,
      focusText: focusText,
      tabTitle: tabTitle,
      producerLine: producerLine,
      disposeProc: dispose,
    )
