## history_generator.nim — PLAT-32's stream generator,
## `Editor-Model-Conformance-Suite.md` §4 applied to §3.6's `LAW-H*`.
##
## NOT-A-TEST-LANE-FILE: a generator, not a suite. It imports no `unittest` and
## asserts nothing; every assertion about what it produced lives in
## `../unit/test_editor_history_laws.nim` and
## `../unit/test_editor_history_examples.nim`.
##
## =========================================================================
## THE FOUR STREAM SHAPES, AND WHY `ssLocalOnly` IS ONE OF THEM
## =========================================================================
##
## PLAT-32's counted target names four: **local only**, **local plus remote**,
## **remote-heavy** and **fully interleaved**, and says what the first one is
## for — *"`local only` is the arm that must NOT discriminate, and its presence
## is what makes the other three evidence."* A suite that only ran the
## interleaved shape would be a suite in which every law is about remote edits;
## a suite that only ran the local one would be a single-writer history suite
## with a remote test bolted on, which is the shape this milestone exists to
## avoid.
##
## =========================================================================
## §34 — THE POPULATION THIS MILESTONE IS MOST LIKELY TO SHIP BROKEN
## =========================================================================
##
## Seven milestones running, and the instance here is named in advance because
## it is the one that costs the most: **a stream in which no remote edit ever
## arrives while a local event is still on the branch.** Every law passes on
## such a stream — they pass *harder*, because `addMappingToBranch` is never
## called and `mapEvent` is never reached — and nothing about the verdict says
## the mapping code was not executed.
##
## Two measures are published for the suite to assert, and both are read back
## out of the built stream rather than taken from the label the constructor
## applied:
##
##   * `realisedShape` — `classifyStream` decides the shape from the
##     TRANSACTIONS' own annotations (`history.isRemote`, which is the function
##     the PRODUCT reads), never from `HistoryStream.intended`. §34's third
##     rule: *"the classifier must not be the constructor."*
##   * `interleavedRemotes` — how many remote steps arrive with at least one
##     local step already behind them. That is the count of remote changes that
##     have a local event to be mapped past, and it is **zero for `ssLocalOnly`
##     by construction and must be non-zero for all three others**. The suite
##     asserts it as an EQUALITY over the drawn population, not as "at least
##     one somewhere": §4b's *"a partial set is worse than an empty one, and
##     'at least one' will not catch it"*.
##
## =========================================================================
## `LAW-H4` GETS ITS OWN GENERATOR, BECAUSE THE CASE DOES NOT ARISE BY ACCIDENT
## =========================================================================
##
## The milestone is explicit: *"the stream generator deliberately emits a
## remote change that entirely deletes the range a local event touched, and the
## realised count of dropped events is asserted non-zero. The spec calls this
## clause 'easy to omit and impossible to notice'; a generator that never
## produces it makes that literally true."*
##
## `genDroppedStream` is that generator. It does not hope for a collision: the
## remote change's range is computed FROM the local event's inserted text, so
## the event maps entirely away every time, on every corpus class. The suite
## then asserts the realised drop count per class — which is the difference
## between §4b's "the population is non-empty" and §34's stronger claim that
## each draw realised the class it was drawn for.
##
## =========================================================================
## THE DOCUMENTS ARE THE UNICODE CORPUS, AND THE SELECTOR IS NOT RE-DERIVED
## =========================================================================
##
## `corpusClassIds` and `docsOneNumberPerClass` live in `async_generator.nim`
## because PLAT-29 needed them first. They are imported rather than written
## again: Verification-Harness-Traps §30a's *"the worst instance was a whole
## re-derived module"*, and a second spelling of "one window per corpus class,
## by class id rather than by index" is exactly the shape that lets a corpus
## which grows a tenth class arrive in one suite and be silently cut off at
## nine in the other.

import std/[options, strutils]

import ../../editor/change_set
import ../../editor/history
import ./async_generator
import ./change_generator

export change_generator
export history

type
  StreamShape* = enum
    ## §4.1's declared classes for this milestone. The order is the
    ## declaration order and every law runs against every one of them.
    ssLocalOnly
    ssLocalPlusRemote
    ssRemoteHeavy
    ssInterleaved

  StepKind* = enum
    stLocal
    stRemote
    stSelection

  StreamStep* = object
    ## One transaction, already expressed against the document that was there
    ## when it was built. **There is no `kind` field**: the step's kind is
    ## derived from its transaction's annotations by `stepKind`, so a
    ## classifier over a stream reads what the PRODUCT reads rather than a
    ## label the constructor attached (§34).
    tr*: Transaction
    docBefore*, docAfter*: string

  HistoryStream* = object
    docId*: string
    start*: string
    intended*: StreamShape
      ## What the constructor MEANT to build. Compared against
      ## `classifyStream`'s answer by the suite; never read by it.
    steps*: seq[StreamStep]

  RemoteSite* = enum
    ## Where a remote change sits relative to the local edit it must not
    ## disturb. The three "event shapes" of the counted target's
    ## *"6 delivery orders x 3 event shapes"* term.
    rsBefore    ## strictly before the local edit's range
    rsAtEdge    ## at exactly the local edit's start — the side-ambiguous case
    rsAfter     ## strictly after it

const
  StreamShapeCount* = ord(high(StreamShape)) - ord(low(StreamShape)) + 1
  RemoteSiteCount* = ord(high(RemoteSite)) - ord(low(RemoteSite)) + 1
    ## Derived from the enums. §10.4 rule 3: a sweep's multiplier must be an
    ## asserted cardinality, not a round number.

  StreamSteps* = 8
    ## How many transactions a generated stream holds. Chosen so that every
    ## shape below is REALISED at this length, which is a measurement and not
    ## an argument: `ssRemoteHeavy`'s pattern has a period of four and
    ## `ssInterleaved`'s a period of two, and at eight steps all four shapes
    ## come back from `classifyStream` as the shape they were drawn for, on all
    ## nine corpus classes. At a period of three for `ssRemoteHeavy` — the
    ## first spelling — that number was 0 of 9.

  MarkerA* = "<A>"
  MarkerB* = "<B>"
    ## What a local edit inserts. ASCII and bracketed, so a drop generator can
    ## compute the remote change's range from the marker's own length and a
    ## suite can say "the local edit is gone" by a `contains` that cannot be
    ## satisfied by the corpus text itself.

# ---------------------------------------------------------------------------
# Reading a step back
# ---------------------------------------------------------------------------

func stepKind*(s: StreamStep): StepKind =
  ## **DERIVED, NEVER STORED.** `isRemote` is `history.nim`'s own function —
  ## the one `record` branches on — so a stream classified through here is
  ## classified the way the product classifies it.
  if isRemote(s.tr): stRemote
  elif s.tr.changes.isIdentity: stSelection
  else: stLocal

func collapsedKinds*(s: HistoryStream): seq[StepKind] =
  ## The stream's kinds, with a local BURST collapsed to one entry.
  ##
  ## A local step is typed one byte at a time so that the coalescing path is
  ## exercised, and the bytes of one marker carry one timestamp. Every measure
  ## below is about EVENTS rather than about transactions, so every one of them
  ## reads this. It is derived from the transactions — `isRemote` and the
  ## `anTime` annotation, both of which the PRODUCT reads — and never from a
  ## label the constructor attached (§34).
  var lastTime = int64.low
  var lastKind = stSelection
  var first = true
  for st in s.steps:
    let k = st.stepKind
    if k == stLocal:
      let t = timeOf(st.tr)
      if not first and lastKind == stLocal and t == lastTime: continue
      lastTime = t
    lastKind = k
    first = false
    result.add k

func localSteps*(s: HistoryStream): int =
  for k in s.collapsedKinds:
    if k == stLocal: inc result

func remoteSteps*(s: HistoryStream): int =
  for k in s.collapsedKinds:
    if k == stRemote: inc result

func maxSameKindRun*(s: HistoryStream): int =
  var run = 0
  var prev = stSelection
  var first = true
  for k in s.collapsedKinds:
    if first or k != prev:
      run = 1
      first = false
    else:
      inc run
    prev = k
    if run > result: result = run

func interleavedRemotes*(s: HistoryStream): int =
  ## **THE MEASURE §34 IS ABOUT.** How many remote steps arrive with at least
  ## one local event already behind them — which is how many remote changes
  ## have a local event on the branch to be mapped past. Zero means `mapEvent`
  ## was never reached and every law about "undo mine, not theirs" was asserted
  ## over a stream with no theirs in it.
  var seenLocal = false
  for k in s.collapsedKinds:
    case k
    of stLocal: seenLocal = true
    of stRemote:
      if seenLocal: inc result
    of stSelection: discard

func classifyStream*(s: HistoryStream): StreamShape =
  ## What the stream IS, read back from its transactions.
  let local = s.localSteps
  let remote = s.remoteSteps
  if remote == 0: return ssLocalOnly
  if local > 0 and s.maxSameKindRun == 1: return ssInterleaved
  if remote >= 2 * local: return ssRemoteHeavy
  ssLocalPlusRemote

# ---------------------------------------------------------------------------
# Building transactions
# ---------------------------------------------------------------------------

proc localTransaction*(doc: string; fromPos, toPos: int; insert: string;
                       userEvent = ueInput; timeMs: int64 = 0;
                       selection = none(EditorSelection)): Transaction =
  transaction(changeSet(doc.len, fromPos, toPos, insert), selection, @[],
              @[Annotation(kind: anUserEvent, userEvent: userEvent),
                Annotation(kind: anTime, timeMs: timeMs)])

proc remoteTransaction*(doc: string; fromPos, toPos: int; insert: string;
                        peer = "peer-1"): Transaction =
  ## **THE REMOTE STREAM IS SYNTHETIC TRANSACTIONS, NOT PLAT-33's TRANSPORT**,
  ## and the milestone says why: *"deliberately, so this milestone's gate does
  ## not wait on the collaboration milestone that depends on it."* What makes a
  ## transaction remote is the annotation the collaboration layer already sets,
  ## so when the transport arrives it produces exactly this.
  transaction(changeSet(doc.len, fromPos, toPos, insert), none(EditorSelection),
              @[], @[Annotation(kind: anRemote, peer: peer)])

func markerSpans*(doc: string): seq[(int, int)] =
  ## Every `<A>n` / `<B>n` occurrence in `doc`, as half-open byte ranges.
  ##
  ## This exists so a generated position can be kept OUT of a marker. Without
  ## it a remote insertion drawn at a cluster boundary of the ORIGINAL window
  ## can land in the middle of a marker a previous step inserted, and the
  ## suite's oracle — *"the final document minus the markers of the undone
  ## events"* — stops being exact for a reason that has nothing to do with the
  ## history.
  var i = 0
  while i + 2 < doc.len:
    if doc[i] == '<' and (doc[i + 1] == 'A' or doc[i + 1] == 'B') and
       doc[i + 2] == '>':
      var j = i + 3
      while j < doc.len and doc[j] in {'0' .. '9'}: inc j
      result.add (i, j)
      i = j
    else:
      inc i

func safePosition*(doc: string; at: int): int =
  ## `at`, moved out of any marker it landed inside. A position at a marker's
  ## start or end is left alone: those are legitimate, and the at-edge case is
  ## the one `LAW-H6` is about.
  result = min(max(at, 0), doc.len)
  for (a, b) in markerSpans(doc):
    if result > a and result < b: return b

func insertedText*(cs: ChangeSet): string =
  ## Everything a change set inserts, concatenated. Used to read a local
  ## step's marker back out of its transaction rather than storing it beside
  ## the transaction, where the two could disagree.
  for r in changedRanges(cs, individual = true):
    result.add r.inserted

func localMarkers*(s: HistoryStream): seq[string] =
  ## The text each local EVENT inserted, oldest first — one entry per event,
  ## not one per transaction.
  ##
  ## A local step is typed one byte at a time inside the grouping window, so
  ## consecutive local transactions carrying the same timestamp are the bytes
  ## of one marker and belong to one event. **The grouping key read here is the
  ## TIMESTAMP the generator stamped, not a re-derivation of `history.mayGroup`**
  ## (§30): the suite asserts that the product produced exactly this many
  ## events, which is a claim about the product rather than a copy of it.
  var current = ""
  var currentTime = int64.low
  for st in s.steps:
    if st.stepKind != stLocal:
      continue
    let t = timeOf(st.tr)
    if t != currentTime:
      if current.len > 0: result.add current
      current = ""
      currentTime = t
    current.add insertedText(st.tr.changes)
  if current.len > 0: result.add current

func localEvents*(s: HistoryStream): int =
  ## How many EVENTS the local transactions are expected to produce.
  s.localMarkers.len

func remoteMarkers*(s: HistoryStream): seq[string] =
  for st in s.steps:
    if st.stepKind == stRemote: result.add insertedText(st.tr.changes)

proc clusterAt*(d: GenDoc; i: int): int =
  ## A cluster boundary of the generated document, by index, wrapped. Every
  ## position this generator uses is one of these — §4.2: *"a fuzzer over ASCII
  ## cannot produce the cluster boundary that is the interesting input."*
  d.boundaries[i mod d.boundaries.len]

# ---------------------------------------------------------------------------
# The four shapes
# ---------------------------------------------------------------------------

proc after0(tr: Transaction; doc: string): string = tr.changes.apply(doc)

proc kindPattern(shape: StreamShape; n: int): seq[StepKind] =
  ## The kind of each step, as a pattern rather than as a draw.
  ##
  ## **WRITTEN OUT AND NOT DRAWN**, which is what makes the suite's histogram
  ## an EQUALITY: the number of streams that realise a shape is the number
  ## drawn for it, and a constructor that produced the wrong shape some of the
  ## time would show up as an inequality rather than as a plausible spread
  ## (§34).
  result = @[]
  case shape
  of ssLocalOnly:
    for i in 0 ..< n: result.add stLocal
  of ssLocalPlusRemote:
    # A block of locals, then a block of remotes: the run length is > 1, so it
    # is not interleaved, and remote < 2 * local, so it is not remote-heavy.
    let locals = (n * 2) div 3
    for i in 0 ..< n:
      result.add(if i < locals: stLocal else: stRemote)
  of ssRemoteHeavy:
    # L R R R L R R R … — THREE remote changes per local edit.
    #
    # **THE PERIOD IS FOUR AND IT WAS MEASURED, NOT CHOSEN.** A period of
    # three (`L R R`) gives five remote steps to three local ones at
    # `StreamSteps = 8`, and `classifyStream` reads that back as
    # `ssLocalPlusRemote` because `5 >= 2 * 3` is false — so the shape
    # realised 0 of 9 on the first run, with every law green. That is §34's
    # defect in this generator's own constructor, caught by the per-class
    # equality rather than by any property. A period of four gives 2 local to
    # 6 remote, which the classifier agrees with.
    for i in 0 ..< n:
      result.add(if i mod 4 == 0: stLocal else: stRemote)
  of ssInterleaved:
    for i in 0 ..< n:
      result.add(if i mod 2 == 0: stLocal else: stRemote)

proc genStream*(d: GenDoc; r: var Rng; shape: StreamShape;
                n = StreamSteps): HistoryStream =
  ## A stream of `n` transactions over a window of a corpus document.
  ##
  ## Positions are cluster boundaries of that window and inserted text is
  ## whole clusters taken from the corpus, so nothing here can produce a
  ## boundary the store would refuse for a reason that is about the generator
  ## rather than about the law.
  result = HistoryStream(docId: d.id, start: d.text, intended: shape, steps: @[])
  var doc = d.text
  var t: int64 = 0
  var k = 0
  for kind in kindPattern(shape, n):
    # The window shrinks and grows as the stream runs, so every position is
    # taken modulo the CURRENT length rather than from the original boundary
    # list — a boundary of the first document is not a boundary of the fifth.
    let anchorIdx = r.rand(d.boundaries.len - 1)
    let at = safePosition(doc, clusterAt(d, anchorIdx))
    case kind
    of stLocal:
      t += NewGroupDelayMs * 2      # each local STEP is its own event
      let marker = MarkerA & $k
      # **A LOCAL STEP IS TYPED, ONE BYTE AT A TIME, INSIDE THE GROUPING
      # WINDOW.** Every byte is its own transaction and they all coalesce into
      # ONE event, so a generated stream exercises the coalescing path — which
      # it did not on the first run, and `LAW-H1`'s published killer (*"coalesce
      # two events without composing their inversions"*) came back MISDIRECTED
      # because the only cells that grouped were `LAW-H5`'s.
      #
      # The marker's bytes are inserted CONTIGUOUSLY, so the group's total
      # inserted text is exactly the marker and the suite's oracle — remove the
      # marker — is unchanged by the burst.
      for bi in 0 ..< marker.len:
        let pos = at + bi
        let caretAfter = caretSelection(pos + 1)
        let tr = localTransaction(doc, pos, pos, $marker[bi], ueInput, t,
                                  some(caretAfter))
        let after = tr.changes.apply(doc)
        result.steps.add StreamStep(tr: tr, docBefore: doc, docAfter: after)
        doc = after
    of stRemote:
      let tr = remoteTransaction(doc, at, at, MarkerB & $k)
      let after = tr.changes.apply(doc)
      result.steps.add StreamStep(tr: tr, docBefore: doc, docAfter: after)
      doc = after
    of stSelection:
      t += NewGroupDelayMs * 2
      let tr = transaction(identityChangeSet(doc.len), some(caretSelection(at)),
                           @[], @[Annotation(kind: anUserEvent,
                                             userEvent: ueSelect),
                                  Annotation(kind: anTime, timeMs: t)])
      result.steps.add StreamStep(tr: tr, docBefore: doc, docAfter: after0(tr, doc))
      doc = tr.changes.apply(doc)
    inc k

# ---------------------------------------------------------------------------
# `LAW-H4`'s own generator — the dropped event
# ---------------------------------------------------------------------------

proc genDroppedStream*(d: GenDoc; r: var Rng): HistoryStream =
  ## Two local events, then a remote change that **entirely deletes the range
  ## the top local event inserted**.
  ##
  ## The remote range is computed from the marker's own length rather than
  ## drawn, so the event maps entirely away on every corpus class rather than
  ## on the classes where a draw happened to line up. That is the whole
  ## difference between a generator for `LAW-H4` and a generator that occasionally
  ## produces `LAW-H4`.
  result = HistoryStream(docId: d.id, start: d.text, intended: ssLocalPlusRemote,
                         steps: @[])
  var doc = d.text
  let lower = clusterAt(d, r.rand(d.boundaries.len div 2))
  let first = localTransaction(doc, lower, lower, MarkerA, ueInput, 0)
  var after = first.changes.apply(doc)
  result.steps.add StreamStep(tr: first, docBefore: doc, docAfter: after)
  doc = after

  # The second local edit, above the first, at a position past it.
  # At least one byte PAST the first marker, so the byte the remote change
  # reaches beneath `MarkerB` is a byte of the document rather than a byte of
  # `MarkerA`.
  let upper = min(lower + MarkerA.len + 1 + (clusterAt(d, 3) mod 4), doc.len)
  let second = localTransaction(doc, upper, upper, MarkerB, ueInput,
                                NewGroupDelayMs * 4)
  after = second.changes.apply(doc)
  result.steps.add StreamStep(tr: second, docBefore: doc, docAfter: after)
  doc = after

  # **THE REMOTE CHANGE DELETES THE MARKER AND ONE BYTE BENEATH IT**, and the
  # extra byte is the whole reason `LAW-H4`'s published killer can land.
  #
  # A remote change confined to the text the top event INSERTED projects to the
  # IDENTITY in the coordinates below that event, so the mapping it leaves
  # behind is the identity and "inherit it" and "discard it" are the same
  # thing. The first spelling of this generator did exactly that, and the arm
  # that discards the mapping came back MISDIRECTED with every drop assertion
  # green. Reaching one byte past the marker makes the inherited mapping a real
  # deletion, which the event beneath must be rebased through.
  let kill = remoteTransaction(doc, upper - 1, upper + MarkerB.len, "")
  after = kill.changes.apply(doc)
  result.steps.add StreamStep(tr: kill, docBefore: doc, docAfter: after)

# ---------------------------------------------------------------------------
# The delivery-order family — 6 orders x 3 event shapes
# ---------------------------------------------------------------------------

type DeliveryOrder* = object
  ## One interleaving of two remote changes into a two-step local sequence.
  ## The six are every way of placing `R1` and `R2`, in order, among `L1` and
  ## `L2`, in order — `C(4,2) = 6`, which is a cardinality rather than a
  ## round number.
  id*: string
  slots*: seq[StepKind]

proc deliveryOrders*(): seq[DeliveryOrder] =
  ## Written out, and its length is compared against `C(4,2)` by the suite so
  ## a missing row is a red rather than a smaller sweep.
  result = @[]
  const names = ["RRLL", "RLRL", "RLLR", "LRRL", "LRLR", "LLRR"]
  for n in names:
    var slots: seq[StepKind] = @[]
    for c in n:
      slots.add(if c == 'R': stRemote else: stLocal)
    result.add DeliveryOrder(id: n, slots: slots)

proc remotePosition*(doc: string; localAt: int; site: RemoteSite;
                     width: int): int =
  ## Where a remote change lands relative to a local edit at `localAt`.
  case site
  of rsBefore: max(0, localAt - width)
  of rsAtEdge: localAt
  of rsAfter: min(doc.len, localAt + width)

# ---------------------------------------------------------------------------
# Running a stream
# ---------------------------------------------------------------------------

type StreamRun* = object
  ## The result of pushing a stream through a real `HistorySession`.
  session*: HistorySession
  droppedEvents*: int
    ## How many events `addMappingToBranch` removed. Measured as a fall in the
    ## branch's depth across a REMOTE step, which is the only step that can
    ## remove an event without popping one.
  mappedSteps*: int
    ## How many remote steps arrived with a non-empty done branch — the count
    ## of times `mapEvent` was actually reached.
  events*: int
    ## The branch depth at the end. Compared by the suite against
    ## `localMarkers.len`, which is how many events the generator's own
    ## timestamps say there should be — an assertion about the PRODUCT's
    ## grouping rather than a copy of it.

proc runStream*(s: HistoryStream): StreamRun =
  ## No mocks: a real document, real change sets, real inversions.
  result.session = initSession(s.start)
  for st in s.steps:
    let before = result.session.history.done.len
    let hadEvents = before > 0
    result.session.applyTransaction(st.tr)
    if st.stepKind == stRemote:
      if hadEvents: inc result.mappedSteps
      let fall = before - result.session.history.done.len
      if fall > 0: result.droppedEvents += fall
  result.events = result.session.history.undoDepth

func visitedDocuments*(run: StreamRun): seq[string] =
  run.session.visited

func describe*(s: HistoryStream): string =
  var kinds = ""
  for k in s.collapsedKinds:
    kinds.add(case k
              of stLocal: "L"
              of stRemote: "R"
              of stSelection: "S")
  s.docId & " " & $s.intended & " [" & kinds & "] interleaved=" &
    $s.interleavedRemotes

proc streamDocs*(seed: uint32): seq[GenDoc] =
  ## One generated document per corpus class, in class order — imported, not
  ## re-derived. See the header.
  docsOneNumberPerClass(seed)

proc streamCorpusClassCount*(): int =
  corpusClassIds().len
