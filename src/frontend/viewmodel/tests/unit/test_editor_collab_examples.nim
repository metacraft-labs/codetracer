## PLAT-33 — the wire, the capability, the merge table, and the receive path.
##
## Spec: `Architecture/Editor-ViewModel.md` §12.1a (the normative merge table,
## which this file parses as an ORACLE), §12.2 (the receive path's three
## properties) and §12.2a (how text meets the ViewOp stream);
## `Testing/Editor-Model-Conformance-Suite.md` §7.1 (the two-way count) and
## §7.2 (the oracle register).
##
##     nim c -r --path:src/frontend/viewmodel \
##       src/frontend/viewmodel/tests/unit/test_editor_collab_examples.nim
##
## =========================================================================
## WHY THE ORACLE IS `staticRead` AND A MISSING CHECKOUT FAILS BY NAME
## =========================================================================
##
## `std/os`'s `readFile` does not exist on the JS backend and this suite is
## compiled by three lanes. So the published table is read at COMPILE time out
## of the sibling checkout, exactly as `test_editor_vocabulary_oracle.nim`
## reads §2.2 — and a missing sibling is then a compile error naming the path,
## which is louder than a run-time failure and is the opposite of a skip
## (`Testing/Silent-Self-Pass-Audit-2026-08-23.md`).
##
## **The expected value is never produced by the code under test.** A
## transcribed copy of the table would have been written from the same reading
## that produced `mergeFamilyOf`, and the two would agree about a misreading.

import std/[json, strutils, tables]
import unittest

import ../../editor/change_set
import ../../editor/collab_text
import ../../editor/operations
import ../../editor/selection
import ../../editor/transaction
import ../../collab/types
import ../../collab/codec
import ../../collab/reducer
import ../../collab/text_ops
import ../generators/change_generator

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 138

const
  SpecRelativePath = "codetracer-specs/Architecture/Editor-ViewModel.md"
  SpecSource = staticRead(
    "../../../../../../codetracer-specs/Architecture/Editor-ViewModel.md")
  SectionStart = "### 12.1a The normative merge table"
  SectionEnd = "### 12.2 The algorithm"

  WorkflowSource = staticRead(
    "../../../../../.github/workflows/codetracer.yml")
  JustfileSource = staticRead("../../../../../justfile")
  LaneFilesSource = staticRead("../../../../../ci/lib/test-lane-files.sh")

proc specSection(): string =
  let a = SpecSource.find(SectionStart)
  if a < 0: return ""
  let b = SpecSource.find(SectionEnd, a)
  if b < 0: SpecSource[a .. ^1] else: SpecSource[a ..< b]

proc publishedFamilies(): seq[string] =
  ## Every `` `MF-…` `` id in the first column of the section's table.
  ##
  ## One rule per column, and a DUPLICATE CHECK, because *"every family
  ## appears in the table"* is satisfiable with one fewer distinct name than
  ## the count claims (§7.3).
  for line in specSection().splitLines:
    let row = line.strip()
    if not row.startsWith("|"): continue
    let cells = row.split('|')
    if cells.len < 3: continue
    let first = cells[1].strip()
    if not (first.startsWith("`MF-") or first.startsWith("**`MF-")): continue
    let open = first.find('`')
    let close = first.find('`', open + 1)
    if open < 0 or close <= open: continue
    result.add first[open + 1 ..< close]

proc rowCells(id: string): seq[string] =
  for line in specSection().splitLines:
    let row = line.strip()
    if not row.startsWith("|"): continue
    if not row.contains("`" & id & "`"): continue
    for cell in row.split('|'):
      result.add cell.strip()
    return

let baseDoc = block:
  var d = ""
  for doc in genDocs(0x33c0de00'u32):
    if doc.id.startsWith("c1-zwj"):
      d = doc.text
      break
  if d.len == 0: d = genDocs(0x33c0de00'u32)[0].text
  d

proc envelope(kind: ViewOpKind; principal: PrincipalId; opId: string;
              targetPath = ""; payload: JsonNode = newJObject();
              authorityVersion = 0; lamport = 1'u64): ViewOpEnvelope =
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: "ex-session", principalId: principal, actorId: principal,
    replicaId: principal, opId: opId, lamport: lamport,
    authorityVersion: authorityVersion, targetPath: targetPath,
    kind: kind, payload: payload, unknownFields: newJObject())

proc freshDocument(): SharedSessionDocument =
  initSharedSessionDocument(
    sessionId = "ex-session", authorityPrincipalId = "owner",
    backendOwnerId = "owner")

proc grant(doc: var SharedSessionDocument; subject: PrincipalId;
           caps: openArray[CapabilityKind]; paths: openArray[string];
           opId: string) =
  var capNames = newJArray()
  for c in caps: capNames.add %($c)
  var pathNames = newJArray()
  for p in paths: pathNames.add %p
  discard doc.applyViewOp(envelope(
    vokGrantCapabilities, "owner", opId, "capabilityGrants",
    %*{"grantId": opId, "subject": subject, "issuer": "owner",
       "capabilities": capNames, "targetPaths": pathNames}))

proc sampleUpdate(producer: string; at: int; text: string): TextUpdate =
  TextUpdate(changes: changeSet(baseDoc.len, at, at, text),
             producer: producer, updateId: "u-" & producer & "-" & $at)

# ===========================================================================
suite "PLAT-33 — the normative merge table is an oracle (§7.1, both directions)":
# ===========================================================================

  test "the section was found and parsed":
    counted specSection().len > 0
    checkpoint("parsed out of " & SpecRelativePath)
    counted publishedFamilies().len == PublishedMergeFamilyCount

  test "no family id is published twice":
    # §7.3: without a duplicate check, "every family appears" is satisfiable
    # with one fewer distinct name than the count claims.
    var seen = initCountTable[string]()
    for id in publishedFamilies(): seen.inc id
    for id, n in seen:
      checkpoint(id & " appears " & $n & " time(s)")
      counted n == 1
    counted seen.len == PublishedMergeFamilyCount

  test "every PUBLISHED family is implemented":
    let published = publishedFamilies()
    var implemented: seq[string] = @[]
    for f in MergeFamily:
      if MergeFamilyIds[f].len > 0: implemented.add MergeFamilyIds[f]
    for id in published:
      checkpoint("published: " & id)
      counted id in implemented

  test "every IMPLEMENTED family is published":
    let published = publishedFamilies()
    for f in MergeFamily:
      if MergeFamilyIds[f].len == 0: continue
      checkpoint("implemented: " & MergeFamilyIds[f])
      counted MergeFamilyIds[f] in published

  test "and neither set is empty, which is the line usually omitted":
    var implemented = 0
    for f in MergeFamily:
      if MergeFamilyIds[f].len > 0: inc implemented
    counted publishedFamilies().len == PublishedMergeFamilyCount
    counted implemented == PublishedMergeFamilyCount

  test "every published row states HOW a conflict is resolved":
    # A row whose third cell is empty is a family nobody defined, and the
    # table would still have four ids.
    for id in publishedFamilies():
      let cells = rowCells(id)
      checkpoint(id & " row has " & $cells.len & " cells")
      counted cells.len >= 5
      counted cells[3].len > 20

  test "`MF-TextRebase` is the one that does not DISCARD":
    # The operational difference §12.1a asks a reader to take from the table,
    # asserted rather than left to be read: the three older families resolve
    # by choosing, and this one resolves by moving.
    let textRow = rowCells("MF-TextRebase")
    counted textRow.len >= 5
    counted textRow[3].contains("rebased over")
    counted textRow[3].contains("Neither side is discarded")
    let lwwRow = rowCells("MF-LWW")
    counted lwwRow.len >= 5
    counted lwwRow[3].contains("discarded")

  test "every op kind belongs to exactly one family, and the text kinds to the fourth":
    # The dispatch is exhaustive, so this cannot silently miss a kind; what it
    # adds is that the three text kinds land where the table says.
    counted mergeFamilyOf(vokAcceptTextUpdate) == mfTextRebase
    counted mergeFamilyOf(vokSetTextSelection) == mfTextRebase
    counted mergeFamilyOf(vokSubmitTextUpdate) == mfNone
    counted mergeFamilyOf(vokSetRegister) == mfLww
    counted mergeFamilyOf(vokAddWatch) == mfAddWins
    counted mergeFamilyOf(vokRequestDriver) == mfOwnerEpoch
    # And no OTHER kind claims the text family, which is the direction that
    # catches a watch op quietly being reclassified.
    var textKinds = 0
    for k in ViewOpKind:
      if mergeFamilyOf(k) == mfTextRebase: inc textKinds
    counted textKinds == 2

# ===========================================================================
suite "PLAT-33 — capability gating, including the planted omission":
# ===========================================================================

  test "a peer WITHOUT the text capability is refused":
    var doc = freshDocument()
    let op = envelope(vokSubmitTextUpdate, "guest", "s1", TextDocumentsPath,
                      submissionPayload("d", [sampleUpdate("guest", 0, "X")]))
    let outcome = doc.applyViewOp(op)
    counted outcome.status == asRejected
    counted outcome.reason.contains("capability")

  test "a peer WITH the text capability is accepted":
    var doc = freshDocument()
    doc.grant("guest", [capEditSharedText], [TextDocumentsPath], "g1")
    let op = envelope(vokSubmitTextUpdate, "guest", "s2", TextDocumentsPath,
                      submissionPayload("d", [sampleUpdate("guest", 0, "X")]))
    let outcome = doc.applyViewOp(op)
    counted outcome.status != asRejected
    counted canEditSharedText(doc.state, "guest")

  test "the text capability is NOT capMutateSharedViewState":
    # The whole reason it is a capability of its own: a reviewer who may move
    # the focus and expand a tree must not thereby be able to type into the
    # buffer being debugged.
    var doc = freshDocument()
    doc.grant("viewer", [capMutateSharedViewState], ["*"], "g2")
    counted not canEditSharedText(doc.state, "viewer")
    let op = envelope(vokSubmitTextUpdate, "viewer", "s3", TextDocumentsPath,
                      submissionPayload("d", [sampleUpdate("viewer", 0, "X")]))
    counted doc.applyViewOp(op).status == asRejected

  test "a caret is AWARENESS and is gated separately":
    # Two-sided: the same principal is refused the edit and allowed the caret.
    var doc = freshDocument()
    doc.grant("watcher", [capPublishAwareness], [TextSelectionsPath], "g3")
    let caret = setTextSelectionOp(
      "ex-session", "watcher", "watcher", "watcher", "c1", 3'u64,
      "d", [SharedCaretAnchor(pos: 0, sideAfter: true)], 0)
    counted doc.applyViewOp(caret).status == asApplied
    let edit = envelope(vokSubmitTextUpdate, "watcher", "s4",
                        TextDocumentsPath,
                        submissionPayload("d", [sampleUpdate("watcher", 0, "X")]))
    counted doc.applyViewOp(edit).status == asRejected

  test "only the session authority may APPEND to the log":
    var doc = freshDocument()
    doc.grant("guest", [capEditSharedText], [TextDocumentsPath], "g4")
    let op = acceptTextUpdateOp(
      "ex-session", "guest", "guest", "guest", "a1", 4'u64,
      "d", baseDoc.len, sampleUpdate("guest", 0, "X"), 0)
    let outcome = doc.applyViewOp(op)
    counted outcome.status == asRejected
    counted outcome.reason.contains("authority")

  test "THE PLANTED OMISSION — requiredCapability's `else` is gone":
    # `Editor-ViewModel.md` §12.1's hazard: a text kind added to the enum and
    # to the exhaustive reducer but NOT to `requiredCapability` compiled, ran
    # and was **ungated**, because the `else` answered `(false, capObserve,
    # "")` and `hasRequiredCapability` reads `not needed` as "allowed".
    #
    # The arm that performs the omission restores the `else` and removes the
    # text arms; this case and the two above then go green-to-red, because an
    # ungated text op from a principal with NO grant at all is accepted.
    const ReducerSource = staticRead("../../collab/reducer.nim")
    var body = ""
    let at = ReducerSource.find("proc requiredCapability(")
    if at >= 0:
      let stop = ReducerSource.find("\nproc hasRequiredCapability", at)
      body = ReducerSource[at ..< (if stop < 0: ReducerSource.len else: stop)]
    counted body.len > 0
    # The `case` must name the text kinds and must carry no `else`.
    counted body.contains("of vokSubmitTextUpdate, vokAcceptTextUpdate:")
    counted body.contains("of vokSetTextSelection:")
    counted not body.contains("\n  else:")
    # And the behavioural half, which is what the arm actually reddens.
    var doc = freshDocument()
    let ungated = envelope(vokSubmitTextUpdate, "nobody", "s5",
                           TextDocumentsPath,
                           submissionPayload("d", [sampleUpdate("nobody", 0, "X")]))
    counted doc.applyViewOp(ungated).status == asRejected

  test "the authority itself needs no grant":
    # `hasLiveCapability` short-circuits for the session authority, which is
    # why the runner grants every OTHER peer and not peer 0. Asserted so the
    # short-circuit is a decision somebody watched hold.
    var doc = freshDocument()
    counted canEditSharedText(doc.state, "owner")
    let op = envelope(vokSubmitTextUpdate, "owner", "s6", TextDocumentsPath,
                      submissionPayload("d", [sampleUpdate("owner", 0, "X")]))
    counted doc.applyViewOp(op).status != asRejected

  test "A REMOTE CARET IS MAPPED THROUGH THE LOG, NOT READ BACK RAW":
    # §12.2a: *"a remote collaborator's caret is an anchor mapped through
    # arriving change sets — not an LWW register, which would make two
    # people's carets fight."* **The MAPPING is the substance of that
    # sentence**, and without this case "mapped anchors" is a type name: the
    # reducer would store an offset and a reader would hand it back, and a
    # caret published five edits ago would name a byte in the middle of a
    # word.
    var doc = freshDocument()
    doc.grant("watcher", [capPublishAwareness], [TextSelectionsPath], "g6")
    doc.grant("other", [capPublishAwareness], [TextSelectionsPath], "g7")

    # Two accepted log entries, each inserting three bytes at offset 0.
    let first = TextUpdate(changes: changeSet(baseDoc.len, 0, 0, "AAA"),
                           producer: "owner", updateId: "a0")
    counted doc.applyViewOp(acceptTextUpdateOp(
      "ex-session", "owner", "owner", "owner", "acc0", 10'u64,
      "d", baseDoc.len, first, 0)).status == asApplied
    let second = TextUpdate(changes: changeSet(baseDoc.len + 3, 0, 0, "BBB"),
                            producer: "owner", updateId: "a1")
    counted doc.applyViewOp(acceptTextUpdateOp(
      "ex-session", "owner", "owner", "owner", "acc1", 11'u64,
      "d", baseDoc.len, second, 1)).status == asApplied
    counted doc.state.textDocument("d").committedVersion == 2

    # A caret published against version 0 — before either insert.
    counted doc.applyViewOp(setTextSelectionOp(
      "ex-session", "watcher", "watcher", "watcher", "c-old", 12'u64,
      "d", [SharedCaretAnchor(pos: 10, sideAfter: true)], 0)).status == asApplied
    let mapped = mappedAnchors(doc.state, "watcher", "d")
    counted mapped.len == 1
    # Six bytes inserted before it, so it has moved by exactly six. A
    # register would answer 10.
    counted mapped[0].pos == 16
    counted mapped[0].pos != 10

    # A caret published against the CURRENT version is returned unchanged,
    # which is the other half: a mapping that always moves a caret is not a
    # mapping either.
    counted doc.applyViewOp(setTextSelectionOp(
      "ex-session", "other", "other", "other", "c-new", 13'u64,
      "d", [SharedCaretAnchor(pos: 10, sideAfter: true)], 2)).status == asApplied
    let fresh = mappedAnchors(doc.state, "other", "d")
    counted fresh.len == 1
    counted fresh[0].pos == 10

    # **AND THE TWO CARETS COEXIST**, which is what "never an LWW register"
    # buys: a register keyed by document would have let the second write
    # overwrite the first, and the two people would fight over one value.
    counted doc.state.editor.remoteSelections.len == 2
    counted mappedAnchors(doc.state, "watcher", "d")[0].pos == 16

  test "a caret published against a version this replica has not folded is WITHHELD":
    # The honest answer when a peer is ahead of us. Answering with the raw
    # offset would place the caret by an accident of timing, which is the
    # failure an LWW register makes unavoidable and a mapped anchor makes
    # merely possible — so it is refused here rather than guessed.
    var doc = freshDocument()
    doc.grant("ahead", [capPublishAwareness], [TextSelectionsPath], "g8")
    let first = TextUpdate(changes: changeSet(baseDoc.len, 0, 0, "AAA"),
                           producer: "owner", updateId: "b0")
    counted doc.applyViewOp(acceptTextUpdateOp(
      "ex-session", "owner", "owner", "owner", "bcc0", 20'u64,
      "d", baseDoc.len, first, 0)).status == asApplied
    counted doc.applyViewOp(setTextSelectionOp(
      "ex-session", "ahead", "ahead", "ahead", "c-ahead", 21'u64,
      "d", [SharedCaretAnchor(pos: 4, sideAfter: true)], 9)).status == asApplied
    counted mappedAnchors(doc.state, "ahead", "d").len == 0
    # And it is not lost — the moment the log catches up it resolves.
    counted doc.state.editor.remoteSelections.len == 1

  test "a revoked grant stops working":
    var doc = freshDocument()
    doc.grant("guest", [capEditSharedText], [TextDocumentsPath], "g5")
    counted canEditSharedText(doc.state, "guest")
    discard doc.applyViewOp(envelope(
      vokRevokeCapabilities, "owner", "r1", "capabilityGrants",
      %*{"grantId": "g5"}))
    counted not canEditSharedText(doc.state, "guest")

# ===========================================================================
suite "PLAT-33 — the envelope and the codec, with LAW-A9 re-run ON THE WIRE":
# ===========================================================================

  test "the authority version survives the round trip":
    let op = envelope(vokAcceptTextUpdate, "owner", "a2", TextDocumentsPath,
                      %*{"documentId": "d"}, authorityVersion = 17)
    let back = parseViewOpEnvelope(op.toJson)
    counted back.authorityVersion == 17
    counted back.kind == vokAcceptTextUpdate
    counted back.opId == "a2"

  test "`authorityVersion` is a KNOWN field and therefore not also an unknown":
    # The two halves of `KnownEnvelopeFields` are the same list read in
    # opposite directions. A field decoded into a typed slot and left off the
    # list would ALSO be preserved as an unknown, emitted twice, and shadow
    # itself on the next round trip.
    let op = envelope(vokAcceptTextUpdate, "owner", "a3", "", newJObject(),
                      authorityVersion = 5)
    let back = parseViewOpEnvelope(op.toJson)
    counted back.unknownFields.kind == JObject
    counted not back.unknownFields.hasKey("authorityVersion")
    counted back.authorityVersion == 5

  test "an unknown envelope field still round-trips beside it":
    var raw = envelope(vokAcceptTextUpdate, "owner", "a4", "", newJObject(),
                       authorityVersion = 9).toJson
    raw["futureThing"] = %"kept"
    let back = parseViewOpEnvelope(raw)
    counted back.unknownFields.hasKey("futureThing")
    counted back.authorityVersion == 9
    counted back.toJson{"futureThing"}.getStr("") == "kept"

  test "LAW-A9 on the wire — a change set survives the SECOND encoding":
    # PLAT-25's `LAW-A9` is the serialisation round trip through
    # `encodeChangeSet`. Here it is re-run through the real `ViewOpEnvelope`
    # codec, because the envelope's JSON is a second encoding the change set
    # has to survive — and the corpus contains ill-formed UTF-8 by design,
    # which a JSON string cannot carry unescaped.
    var r = initRng(0xa9a9'u32)
    for cls in ShapeClass:
      let doc = genDocs(0xa9a9'u32)[0]
      let pair = genPair(doc, r, cls)
      let update = TextUpdate(changes: pair.a, producer: "p", updateId: "w")
      let op = acceptTextUpdateOp(
        "ex-session", "owner", "owner", "owner", "w-" & $cls, 1'u64,
        "d", doc.text.len, update, 0)
      let back = parseViewOpEnvelope(op.toJson)
      let decoded = decodeChangeSet(back.payload{"changes"}.getStr(""))
      checkpoint($cls)
      counted decoded == pair.a
      counted decoded.apply(doc.text) == pair.a.apply(doc.text)

  test "an unknown KIND is preserved rather than coerced":
    var raw = envelope(vokAcceptTextUpdate, "owner", "a5", "", newJObject()).toJson
    raw["kind"] = %"vokSomethingFromTheFuture"
    let back = parseViewOpEnvelope(raw)
    counted back.kind == vokUnknown
    counted back.kindName == "vokSomethingFromTheFuture"
    counted back.toJson{"kind"}.getStr("") == "vokSomethingFromTheFuture"

  test "the three new kinds are on the wire by NAME, with no codec arm":
    # §12.1's first measurement, re-measured: adding a kind needs an enum
    # member, a capability arm and a reducer arm — and no codec change.
    for kind in [vokSubmitTextUpdate, vokAcceptTextUpdate, vokSetTextSelection]:
      let op = envelope(kind, "owner", "k-" & $kind)
      let back = parseViewOpEnvelope(op.toJson)
      checkpoint($kind)
      counted back.kind == kind
      counted back.kindName.len == 0

# ===========================================================================
suite "PLAT-33 — the receive path's three properties, two scenarios each":
# ===========================================================================

  # §12.2 calls the three "not incidental". Each is asserted under TWO
  # scenarios — a remote insert BEFORE the caret and one AFTER it — because a
  # property that holds only when the edit is far from the cursor is a
  # property about the population.

  for scenario in ["remote edit BEFORE the caret", "remote edit AFTER the caret"]:

    test "no history event — " & scenario:
      var st = initEditorState(baseDoc)
      st.selection = singleSelection(10, 14)
      st = commitChange(st, changeSet(baseDoc.len, 0, 0, "[L]"))
      let depth = st.history.done.len
      let at = if scenario.contains("BEFORE"): 0 else: st.doc.len
      let after = st.applyRemoteChange(
        changeSet(st.doc.len, at, at, "[R]"), "peerX")
      counted after.history.done.len == depth
      counted after.doc.contains("[R]")
      counted after.doc.contains("[L]")

    test "the filters are bypassed — " & scenario:
      var st = initEditorState(baseDoc)
      st.filters = @[TransactionFilter(kind: tfProtectedRange,
                                       protectedFrom: 0,
                                       protectedTo: baseDoc.len)]
      let at = if scenario.contains("BEFORE"): 1 else: baseDoc.len - 1
      # The local edit is refused by the guard...
      let local = commitChange(st, changeSet(baseDoc.len, at, at, "[L]"))
      counted local.doc == st.doc
      # ...and the remote one is not.
      let remote = st.applyRemoteChange(
        changeSet(baseDoc.len, at, at, "[R]"), "peerX")
      counted remote.doc != st.doc
      counted remote.doc.contains("[R]")

    test "the selection is MAPPED, never set — " & scenario:
      var st = initEditorState(baseDoc)
      st.selection = singleSelection(10, 14)
      let before = st.selection
      let at = if scenario.contains("BEFORE"): 0 else: baseDoc.len
      let cs = changeSet(baseDoc.len, at, at, "[R]")
      let after = st.applyRemoteChange(cs, "peerX")
      counted after.selection == mapSelection(before, cs)
      if scenario.contains("BEFORE"):
        # An insert before the selection moves it by exactly the inserted
        # length — the ordinary §7 rule, and nothing special-cased.
        counted after.selection.mainRange.head == before.mainRange.head + 3
      else:
        counted after.selection == before

# ===========================================================================
suite "PLAT-33 — the two lanes are reached by a workflow":
# ===========================================================================

  # **THE CASE WITHOUT WHICH EVERY OTHER CASE IN THIS MILESTONE IS WORTH
  # NOTHING.** `vm-collab-units` and `vm-collab-integration` were defined in
  # `ci/lib/test-lane-files.sh` and invoked from the justfile and named by NO
  # workflow, so fourteen suites and 4,688 lines were graded by nothing. A
  # milestone that adds tests to a lane no pipeline executes has added
  # nothing.
  #
  # This is asserted against the WORKFLOW FILE rather than against a local
  # run, because a local run says nothing about what CI does.

  test "both lanes are declared, have recipes, and are named by a workflow":
    for lane in ["vm-collab-units", "vm-collab-integration"]:
      checkpoint(lane)
      counted LaneFilesSource.contains(lane & ")")
      counted JustfileSource.contains("test-" & lane & ":")
      counted JustfileSource.contains("run-nim-test-lane.sh " & lane)
      counted WorkflowSource.contains("just test-" & lane)

  test "the workflow step that names them cannot be short-circuited away":
    # Every lane step in `viewmodel-tests` carries `if: ${{ !cancelled() }}`
    # so that a failure in an earlier step does not hide this one's status —
    # the job would otherwise stop at the first red and report these two as
    # skipped, which reads as "not broken".
    for lane in ["vm-collab-units", "vm-collab-integration"]:
      let at = WorkflowSource.find("just test-" & lane)
      counted at > 0
      let window = WorkflowSource[max(0, at - 400) ..< at]
      checkpoint(lane & " step window")
      counted window.contains("!cancelled()")

# ===========================================================================
suite "PLAT-33 — the tally":
# ===========================================================================

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
