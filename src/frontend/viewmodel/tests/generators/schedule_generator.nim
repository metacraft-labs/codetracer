## NOT-A-TEST-LANE-FILE: a generator, not a suite. It imports no `unittest`
## and asserts nothing. `test_editor_collab_laws.nim` is what runs it.
##
## PLAT-33's POPULATION: delivery schedules over a real multi-peer session,
## and the peers that run them.
##
## `Testing/Editor-Model-Conformance-Suite.md` §4.4 declares five schedule
## classes — in-order, reordered, duplicated, delayed-past-a-local-edit,
## partitioned-and-healed — and requires **each class's realised count to be
## asserted non-zero**, because *"1,000 schedules" cannot be 1,000 in-order
## ones* and in-order delivery is the schedule under which every merge strategy
## converges, including the ones this milestone exists to refuse.
##
## =========================================================================
## THE THREE TRAPS THIS FILE IS BUILT AGAINST, NAMED AS MEASURES
## =========================================================================
##
## **§34 — the classifier is not the constructor.** `Schedule.intended` is what
## the generator meant to build; `classifySchedule` reads the STEP LIST back
## and says what it actually is, mentioning `intended` nowhere. The suite
## compares the two as a per-class EQUALITY at the number DRAWN for that class,
## not as a non-emptiness check: a generator whose classes smear across each
## other produces a plausible histogram and a population that is mostly
## in-order, and only equality can see that.
##
## The five features are made MUTUALLY EXCLUSIVE by construction so the
## comparison is well defined: each constructor produces exactly its own
## distinguishing feature and none of higher precedence. The precedence is
## declared once, in `classifySchedule`, and it is the only place an ordering
## between the features exists.
##
## **§34 again — a generator called twice in one expression draws twice.**
## Every draw below is bound to a name before any part of it is read.
##
## **§30a — the peers share a merge function.** Two peers running one
## `receiveUpdates` agree under ANY mutation to it, so convergence between them
## is invisible to a defect in the thing they share. That is why `runSchedule`
## returns the AUTHORITY'S OWN FOLD alongside the peers' documents, computed by
## `TextAuthority.document` — a different walk over different data — and why
## the law compares each peer against THAT rather than against another peer.
## The claim is armed further by a source scan in the suite.
##
## =========================================================================
## THE PEERS ARE REAL, AND THAT IS THE EXPENSIVE PART
## =========================================================================
##
## A peer here holds a real `SharedSessionDocument` and drives it through the
## real `reducer.applyViewOp` with real `ViewOpEnvelope`s built by
## `collab/text_ops.nim`. Nothing is mocked, and in particular the two things
## a mock would have quietly provided are the two the laws are about:
##
##   * **`opId` dedup is `reducer.hasApplied`**, so `LAW-X2`'s published killer
##     — "disable `opId` dedup" — lands on the product's dedup and not on a
##     `seen` set the harness kept;
##   * **out-of-order arrival is `reducer.committedLog`**, so the reordered
##     class exercises the shipped buffering rather than a sort in the runner.
##
## `receiveUpdates` requires the log in order — that is true of the reference
## too — and what makes the reordered class runnable is that the shared state
## holds an accepted entry in its own version slot until the gap below it
## closes. A peer feeds `receiveUpdates` exactly the newly-committed prefix.

import std/[json, options, tables]

import ../../editor/change_set
import ../../editor/collab_text
import ../../editor/operations
import ../../editor/selection
import ../../collab/types
import ../../collab/reducer
import ../../collab/text_ops
import ./change_generator

export change_generator.Rng, change_generator.initRng, change_generator.rand,
       change_generator.pick, change_generator.GenDoc,
       change_generator.genDocs, change_generator.corpusClusters

type
  ScheduleClass* = enum
    ## §4.4's five, in declaration order.
    scInOrder
    scReordered
    scDuplicated
    scDelayedPastLocalEdit
    scPartitionedAndHealed

  StepKind* = enum
    stLocalEdit   ## `peer` types
    stSubmit      ## `peer` sends its unconfirmed work to the authority
    stDeliver     ## `peer` receives accepted log entry `version`
    stPartition   ## `peer` stops receiving
    stHeal        ## `peer` receives everything it missed, in order

  Step* = object
    kind*: StepKind
    peer*: int
    version*: int   ## `stDeliver` only

  Schedule* = object
    intended*: ScheduleClass
      ## What the constructor meant. **Compared against `classifySchedule`'s
      ## answer and never read by it.**
    peers*: int
    steps*: seq[Step]

  PeerRuntime* = object
    ## One peer's whole stack: the shared document the reducer maintains, the
    ## collaborative session, and the editor the user sees.
    id*: int
    principalId*: PrincipalId
    doc*: SharedSessionDocument
    session*: PeerSession
    editor*: EditorState
    partitioned*: bool
    missed*: seq[ViewOpEnvelope]
      ## Accepts that arrived while partitioned, kept in arrival order so
      ## healing replays exactly what the transport held.

  RunResult* = object
    documents*: seq[string]       ## per peer, the editor's document
    authorityFold*: string        ## the authority's own fold — the ORACLE
    authorityVersion*: int
    delivered*: int
    duplicatesSeen*: int
      ## Deliveries the reducer answered `asDuplicate` to. Asserted non-zero
      ## on the duplicated class: a duplicate the transport never produced is
      ## a class that tests nothing.
    refusals*: int
    interleavedDeliveries*: int
      ## Deliveries that landed on a peer **holding unconfirmed local work**.
      ##
      ## That is the state `receiveUpdates`' rebase loop exists for, and a
      ## schedule in which it never happens is one under which every merge
      ## strategy converges — §34's first vacuity. It is measured from the
      ## PEER'S OWN STATE at the moment of delivery rather than guessed from
      ## the step list, because the step list does not know which accept
      ## confirms whose update.
    parkedOutOfOrder*: int
      ## Accepts that applied but could NOT be committed yet, because the
      ## version below them had not arrived.
      ##
      ## **THE VERIFICATION GATE ASKS FOR A COUNT AND NOT A CLAIM ABOUT THE
      ## GENERATOR**, and "the schedule was classified reordered" is a claim
      ## about the generator. This is the runtime fact: the shipped
      ## committed-prefix buffering held an entry in its own slot. A reordered
      ## schedule that somehow never parked anything would exercise nothing,
      ## and the class equality could not tell.
    heldWhilePartitioned*: int
      ## Frames the transport held because the peer was disconnected. The same
      ## rule for the partitioned class: a partition that never held a frame
      ## is a flag nobody set.
    rebasedSubmissions*: int
      ## Submissions the authority accepted at a version BEHIND its own, so
      ## `rebaseUpdates` had a non-empty `over` to walk.
    movedByRebase*: int
      ## Accepted updates whose change set the rebase actually CHANGED.
      ##
      ## This is the honest answer to *"every peer's edits were disjoint, so
      ## convergence was trivial"* — exactly as `LAW-A1` was trivially true on
      ## disjoint change sets. A rebase that is the identity on every update
      ## is a population that proves nothing, and only comparing the submitted
      ## change set against the accepted one can see it.
    quiesced*: bool
      ## Every peer's unconfirmed queue was empty when the documents were
      ## compared. **A convergence assertion over a run that did not quiesce
      ## is asking whether a peer mid-keystroke agrees with the authority, and
      ## the honest answer is no.** Asserted by the suite, so a run that gave
      ## up short of quiescence is a named red rather than a divergence.
    raised*: int
      ## Exceptions caught while running. §36a: a mutation that makes the
      ## runner raise would otherwise kill the harness instead of the suite,
      ## so it is counted and a case asserts the count is zero.

const
  ScheduleClassCount* = ord(high(ScheduleClass)) - ord(low(ScheduleClass)) + 1
    ## Derived from the enum, so the suite's multiplier and the class list
    ## cannot drift apart (Conformance Suite §10.4, rule 3).

  SessionId* = "plat33-session"
  DocumentId* = "plat33-doc"
  AuthorityPrincipal*: PrincipalId = "peer0"
    ## Peer 0 is the session authority. Stated as a constant because both the
    ## runner and the suite's capability cases need to agree about it.

func peerPrincipal*(i: int): PrincipalId = "peer" & $i

# ===========================================================================
# THE CLASSIFIER — reads the steps back, mentions `intended` nowhere
# ===========================================================================

func classifySchedule*(s: Schedule): ScheduleClass =
  ## **THE PRECEDENCE IS DECLARED HERE AND NOWHERE ELSE.** A schedule can
  ## exhibit more than one feature in principle; the constructors below are
  ## written so that the intended class is always the highest-precedence
  ## feature present, and this ordering is what "highest" means.
  ##
  ## `Verification-Harness-Traps.md` §34's third rule: the classifier must not
  ## be the constructor. Nothing below reads `s.intended`.
  for step in s.steps:
    if step.kind == stPartition:
      return scPartitionedAndHealed

  var seen = initTable[(int, int), int]()
  for step in s.steps:
    if step.kind == stDeliver:
      let key = (step.peer, step.version)
      if seen.hasKeyOrPut(key, 1):
        return scDuplicated

  var highest = initTable[int, int]()
  for step in s.steps:
    if step.kind == stDeliver:
      let prev = highest.getOrDefault(step.peer, -1)
      if step.version < prev:
        return scReordered
      highest[step.peer] = step.version

  # A delivery is "delayed past a local edit" when the peer made a local edit
  # after the update it is now receiving had already been accepted. The
  # runner's `stSubmit` is what makes an update exist, so the test is: a
  # submit, then a local edit by peer p, then a delivery to p of a version at
  # or below the one that submit produced.
  var accepted = 0
  var editedSince = initTable[int, int]()
  for step in s.steps:
    case step.kind
    of stSubmit:
      inc accepted
    of stLocalEdit:
      editedSince[step.peer] = accepted
    of stDeliver:
      if editedSince.hasKey(step.peer) and step.version < editedSince[step.peer]:
        return scDelayedPastLocalEdit
    else: discard

  scInOrder

# ===========================================================================
# THE CONSTRUCTORS — one distinguishing feature each
# ===========================================================================

proc baseSteps(r: var Rng; peers, rounds: int): seq[Step] =
  ## The spine every class starts from.
  ##
  ## **EVERY PEER EDITS BEFORE ANY PEER SUBMITS, AND EVERY PEER SUBMITS BEFORE
  ## ANY DELIVERY.** That ordering is the whole point and it was not the first
  ## one tried: a spine in which one peer edits, submits and is delivered
  ## before the next peer starts produces a population in which no submission
  ## is ever behind the authority and no peer ever holds unconfirmed work when
  ## a remote update lands. Every law was green on it and `rebaseUpdates` was
  ## never entered with a non-empty `over` — the §34 vacuity this milestone is
  ## most exposed to, measured as `rebasedSubmissions == 0`.
  ##
  ## With this spine, peer 1's edit is produced against a version that peer
  ## 0's accept has already moved past, so the authority rebases it; and peer
  ## 1 is holding unconfirmed work when peer 0's accept arrives, so the peer
  ## rebases too. Both sides of §12.2 are exercised every round.
  var version = 0
  for round in 0 ..< rounds:
    for p in 0 ..< peers:
      result.add Step(kind: stLocalEdit, peer: p)
    for p in 0 ..< peers:
      result.add Step(kind: stSubmit, peer: p)
    for v in 0 ..< peers:
      for p in 0 ..< peers:
        result.add Step(kind: stDeliver, peer: p, version: version + v)
    version += peers

proc genSchedule*(r: var Rng; cls: ScheduleClass; peers: int;
                  rounds = 4): Schedule =
  ## One schedule of the requested class.
  ##
  ## Each arm modifies the spine in exactly one way, and the modification is
  ## the feature `classifySchedule` names — never a second feature of higher
  ## precedence, or the class would be unreachable.
  result.intended = cls
  result.peers = peers
  var steps = baseSteps(r, peers, rounds)

  case cls
  of scInOrder:
    discard

  of scReordered:
    # Swap two ADJACENT deliveries to one peer. Adjacent so nothing else can
    # get between them, and to one peer so no other peer's order moves.
    var idx: seq[int] = @[]
    let victim = r.rand(peers - 1)
    for i, s in steps:
      if s.kind == stDeliver and s.peer == victim:
        idx.add i
    if idx.len >= 2:
      let k = r.rand(idx.len - 2)
      let a = idx[k]
      let b = idx[k + 1]
      # Move the later delivery in front of the earlier one, keeping every
      # other step where it was.
      let later = steps[b]
      steps.delete(b)
      steps.insert(later, a)

  of scDuplicated:
    var idx: seq[int] = @[]
    for i, s in steps:
      if s.kind == stDeliver:
        idx.add i
    if idx.len > 0:
      let at = idx[r.rand(idx.len - 1)]
      let repeated = steps[at]
      steps.insert(repeated, at + 1)

  of scDelayedPastLocalEdit:
    # Hold EVERY delivery to one peer from some point on, until after that
    # peer has made a local edit of its own. Holding the whole tail rather
    # than one delivery keeps the order ascending, so the schedule is delayed
    # and not also reordered.
    let victim = r.rand(peers - 1)
    var held: seq[Step] = @[]
    var kept: seq[Step] = @[]
    var holding = false
    var cut = r.rand(max(0, rounds - 2))
    var round = 0
    for s in steps:
      if s.kind == stSubmit:
        inc round
        if round > cut: holding = true
      if holding and s.kind == stDeliver and s.peer == victim:
        held.add s
      else:
        kept.add s
    kept.add Step(kind: stLocalEdit, peer: victim)
    for s in held:
      kept.add s
    steps = kept

  of scPartitionedAndHealed:
    let victim = r.rand(peers - 1)
    var kept: seq[Step] = @[]
    var partitionedYet = false
    var round = 0
    let cut = 1 + r.rand(max(0, rounds - 2))
    for s in steps:
      if s.kind == stSubmit:
        inc round
        if round == cut and not partitionedYet:
          kept.add Step(kind: stPartition, peer: victim)
          partitionedYet = true
      kept.add s
    if not partitionedYet:
      kept.insert(Step(kind: stPartition, peer: victim), 0)
    kept.add Step(kind: stLocalEdit, peer: victim)
    kept.add Step(kind: stHeal, peer: victim)
    kept.add Step(kind: stSubmit, peer: victim)
    steps = kept

  result.steps = steps

# ===========================================================================
# THE RUNNER — real envelopes, real reducer, real editor states
# ===========================================================================

proc localChangeSet*(st: EditorState; r: var Rng; marker: string): ChangeSet =
  ## A peer's edit: insert a real cluster run from the corpus at a real
  ## cluster boundary, with a unique marker so the oracle can find it.
  ##
  ## **THE OFFSET IS A CLUSTER BOUNDARY AND THE MILESTONE'S HARDEST INPUT IS
  ## ALSO REACHABLE.** PLAT-33 names *"two concurrent inserts at the same
  ## offset inside a ZWJ sequence"* as the input that distinguishes a rebase
  ## that maps positions from one that maps byte offsets. Drawing from
  ## `clusterBoundaries` puts the offsets ON boundaries; the interesting
  ## coincidence — two peers choosing the SAME boundary — happens because the
  ## boundary set is small and both peers draw from it, and its realised count
  ## is asserted rather than hoped for.
  let bs = clusterBoundaries(st.doc)
  if bs.len < 2:
    return changeSet(st.doc.len, 0, 0, marker)
  let at = bs[r.rand(bs.len - 1)]
  changeSet(st.doc.len, at, at, marker & corpusClusters(r, 1))

proc initPeer*(i: int; base: string): PeerRuntime =
  PeerRuntime(
    id: i,
    principalId: peerPrincipal(i),
    doc: initSharedSessionDocument(
      sessionId = SessionId,
      authorityPrincipalId = AuthorityPrincipal,
      backendOwnerId = AuthorityPrincipal),
    session: initPeerSession(peerPrincipal(i)),
    editor: initEditorState(base),
    partitioned: false,
    missed: @[])

proc grantTextCapability*(p: var PeerRuntime; subject: PrincipalId;
                          lamport: uint64) =
  ## The authority grants `subject` the text capability, through a real
  ## `vokGrantCapabilities` envelope. Peer 0 is the authority and needs no
  ## grant — `hasLiveCapability` short-circuits for it — so this is what makes
  ## every OTHER peer able to edit, and withholding it is the ungated-op arm.
  let op = ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: SessionId,
    principalId: AuthorityPrincipal,
    actorId: AuthorityPrincipal,
    opId: "grant-" & subject,
    lamport: lamport,
    kind: vokGrantCapabilities,
    targetPath: "capabilityGrants",
    payload: %*{
      "grantId": "grant-" & subject,
      "subject": subject,
      "issuer": AuthorityPrincipal,
      "capabilities": [$capEditSharedText, $capPublishAwareness],
      "targetPaths": [TextDocumentsPath, TextSelectionsPath],
    },
    unknownFields: newJObject())
  discard p.doc.applyViewOp(op)

proc drain(p: var PeerRuntime): int =
  ## Feed the peer's editor everything the reducer has newly COMMITTED.
  ##
  ## `session.version` is how far `receiveUpdates` has been taken; the
  ## reducer's `committedLog` is how far the shared state can be folded. The
  ## difference is exactly what has not been applied yet, and it is never
  ## negative because the log only grows.
  if not p.doc.state.hasTextDocument(DocumentId):
    return 0
  let committed = p.doc.state.textDocument(DocumentId).committedLog
  if committed.len <= p.session.version:
    return 0
  var batch: seq[TextUpdate] = @[]
  for i in p.session.version ..< committed.len:
    batch.add committed[i].toTextUpdate
  p.editor = p.session.receiveInto(p.editor, batch)
  batch.len

proc runSchedule*(s: Schedule; base: string; seed: uint32): RunResult =
  ## Run one schedule to completion and report every peer's document, the
  ## authority's own fold, and the realised delivery counts.
  var r = initRng(seed)
  var peers: seq[PeerRuntime] = @[]
  for i in 0 ..< s.peers:
    peers.add initPeer(i, base)
  for i in 0 ..< s.peers:
    for j in 1 ..< s.peers:
      peers[i].grantTextCapability(peerPrincipal(j), uint64(100 + j))

  # The authority's own view. Peer 0 holds it; every accept is minted from
  # peer 0's shared state, which is what makes ONE log rather than n.
  var broadcast: seq[ViewOpEnvelope] = @[]
  var lamport = 1000'u64
  var editNo = 0

  # `deliverTo` takes the tally by `var` rather than capturing `result`: a
  # closure over `result` does not compile (it would outlive the frame), and
  # the parameter is the honest shape anyway — the accounting is an output of
  # the delivery, not an ambient.
  proc deliverTo(p: var PeerRuntime; op: ViewOpEnvelope; tally: var RunResult) =
    if p.partitioned:
      p.missed.add op
      inc tally.heldWhilePartitioned
      return
    let hadUnconfirmed = p.session.unconfirmed.len > 0
    let committedBefore =
      if p.doc.state.hasTextDocument(DocumentId):
        p.doc.state.textDocument(DocumentId).committedVersion
      else: 0
    let outcome = p.doc.applyViewOp(op)
    case outcome.status
    of asDuplicate: inc tally.duplicatesSeen
    of asRejected: inc tally.refusals
    else: discard
    inc tally.delivered
    let applied = p.drain()
    if hadUnconfirmed and applied > 0:
      inc tally.interleavedDeliveries
    if outcome.status == asApplied:
      let committedAfter =
        if p.doc.state.hasTextDocument(DocumentId):
          p.doc.state.textDocument(DocumentId).committedVersion
        else: 0
      if committedAfter == committedBefore:
        inc tally.parkedOutOfOrder

  for step in s.steps:
    if step.peer < 0 or step.peer >= peers.len:
      continue
    try:
      case step.kind
      of stLocalEdit:
        inc editNo
        let marker = "<" & $step.peer & ":" & $editNo & ">"
        let cs = localChangeSet(peers[step.peer].editor, r, marker)
        peers[step.peer].editor =
          commitChange(peers[step.peer].editor, cs)
        peers[step.peer].session.recordLocal(cs, marker)

      of stSubmit:
        let sendable = peers[step.peer].session.sendable
        if sendable.updates.len == 0:
          continue
        var idTail = ""
        for update in sendable.updates: idTail.add update.updateId
        let submission = submitTextUpdateOp(
          sessionId = SessionId,
          principalId = peers[step.peer].principalId,
          actorId = peers[step.peer].principalId,
          replicaId = peers[step.peer].principalId,
          opId = "sub-" & $step.peer & "-" & idTail,
          lamport = lamport,
          documentId = DocumentId,
          updates = sendable.updates,
          atVersion = sendable.atVersion,
          baseLength = base.len)
        lamport += 1
        let authorityVersionBefore =
          if peers[0].doc.state.hasTextDocument(DocumentId):
            peers[0].doc.state.textDocument(DocumentId).committedVersion
          else: 0
        if sendable.atVersion < authorityVersionBefore:
          inc result.rebasedSubmissions
        let accepted = peers[0].doc.state.acceptSubmission(
          submission, AuthorityPrincipal, AuthorityPrincipal,
          AuthorityPrincipal, lamport)
        lamport += uint64(max(1, accepted.ops.len))
        if accepted.refused.len > 0:
          inc result.refusals
          continue
        for k, op in accepted.ops:
          # Did the rebase actually MOVE this update? Compared against what
          # the peer submitted, which is the only comparison that can tell a
          # real merge from a population of disjoint edits.
          let acceptedCs = decodeChangeSet(op.payload{"changes"}.getStr(""))
          if k < sendable.updates.len and
              acceptedCs != sendable.updates[k].changes:
            inc result.movedByRebase
          # The authority applies its own accept first — it is a peer too, and
          # its shared state is where the next submission is rebased against.
          discard peers[0].doc.applyViewOp(op)
          broadcast.add op
        # The submitter's own work is confirmed by the accepts coming back,
        # which happens through `stDeliver` like everybody else's.
        discard peers[0].drain()

      of stDeliver:
        if step.version >= 0 and step.version < broadcast.len:
          deliverTo(peers[step.peer], broadcast[step.version], result)

      of stPartition:
        peers[step.peer].partitioned = true

      of stHeal:
        peers[step.peer].partitioned = false
        let held = peers[step.peer].missed
        peers[step.peer].missed = @[]
        for op in held:
          deliverTo(peers[step.peer], op, result)
    except CatchableError:
      inc result.raised

  # =======================================================================
  # QUIESCENCE, AND IT IS TWO THINGS RATHER THAN ONE
  # =======================================================================
  #
  # **CONVERGENCE IS A CLAIM ABOUT A QUIESCED SYSTEM AND THE FIRST VERSION OF
  # THIS RUNNER DID NOT REACH ONE.** It healed every partition and delivered
  # every accept, and then compared — and `scDelayedPastLocalEdit` failed on
  # every draw, 200 of 1,000 in `FUZZ-9`, at every peer count.
  #
  # The failure was correct and the law was wrong. That class ends with a
  # local edit the peer never submits, so the peer's document legitimately
  # holds a byte the authority's log has never seen. *"Every peer's document
  # equals the authority's fold"* is a claim about state that has been
  # confirmed, not about a peer mid-keystroke, and a runner that stops before
  # the last submission is asking the wrong question.
  #
  # So quiescence is reached in two steps, and BOTH are asserted:
  #
  #   1. every peer is un-partitioned and given every accept;
  #   2. every peer submits whatever it still holds unconfirmed, and the
  #      resulting accepts are delivered to everybody — repeated until no peer
  #      has unconfirmed work left.
  #
  # The loop is bounded and `quiesced` records whether the bound was enough;
  # a run that gave up short of quiescence would otherwise compare documents
  # that were never supposed to be equal and blame the merge.
  for i in 0 ..< peers.len:
    peers[i].partitioned = false
    for op in broadcast:
      discard peers[i].doc.applyViewOp(op)
      discard peers[i].drain()

  const MaxQuiesceRounds = 8
  var round = 0
  while round < MaxQuiesceRounds:
    var pending = false
    for i in 0 ..< peers.len:
      let sendable = peers[i].session.sendable
      if sendable.updates.len == 0:
        continue
      pending = true
      var idTail = ""
      for update in sendable.updates: idTail.add update.updateId
      let submission = submitTextUpdateOp(
        sessionId = SessionId,
        principalId = peers[i].principalId,
        actorId = peers[i].principalId,
        replicaId = peers[i].principalId,
        opId = "q" & $round & "-" & $i & "-" & idTail,
        lamport = lamport,
        documentId = DocumentId,
        updates = sendable.updates,
        atVersion = sendable.atVersion,
        baseLength = base.len)
      lamport += 1
      let accepted = peers[0].doc.state.acceptSubmission(
        submission, AuthorityPrincipal, AuthorityPrincipal,
        AuthorityPrincipal, lamport)
      lamport += uint64(max(1, accepted.ops.len))
      if accepted.refused.len > 0:
        inc result.refusals
        continue
      for op in accepted.ops:
        broadcast.add op
      for j in 0 ..< peers.len:
        for op in accepted.ops:
          discard peers[j].doc.applyViewOp(op)
          discard peers[j].drain()
    if not pending:
      break
    inc round

  result.quiesced = true
  for i in 0 ..< peers.len:
    if peers[i].session.unconfirmed.len > 0:
      result.quiesced = false

  for i in 0 ..< peers.len:
    result.documents.add peers[i].editor.doc

  # ---------------------------------------------------------------------
  # THE ORACLE — the authority's own fold, and it is a DIFFERENT WALK
  # ---------------------------------------------------------------------
  # §30a: two peers that share `receiveUpdates` agree under any mutation to
  # it. This side folds the shared log directly with `apply`, touching no
  # `PeerSession`, no `receiveUpdates` and no rebase.
  if peers[0].doc.state.hasTextDocument(DocumentId):
    result.authorityFold =
      peers[0].doc.state.foldDocument(DocumentId, base)
    result.authorityVersion =
      peers[0].doc.state.textDocument(DocumentId).committedVersion
  else:
    result.authorityFold = base
    result.authorityVersion = 0
