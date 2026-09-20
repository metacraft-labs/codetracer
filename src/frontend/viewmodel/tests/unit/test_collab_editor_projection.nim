## PLAT-34 — **SOMETHING RENDERS A REMOTE EDIT.**
##
## Spec: `Architecture/Editor-ViewModel.md` §12.2 and §13.2;
## `Planned-Work/CodeTracer-Platform.milestones.org` under PLAT-33's residual
## 2 and PLAT-34's status.
##
##     nim c -r --path:src/frontend/viewmodel \
##       src/frontend/viewmodel/tests/unit/test_collab_editor_projection.nim
##
## =========================================================================
## THE RESIDUAL THIS CLOSES, IN PLAT-33's OWN WORDS
## =========================================================================
##
## > *"**THE PROJECTION IS STILL ABSENT.** `collab/projection.nim` projects the
## > calltrace and the state pane and has no editor projection; PLAT-33 adds
## > the shared state and the reducer arms but nothing renders them. That is
## > PLAT-34's substrate migration … and it is stated here so that
## > 'collaborative text editing works' is not read as 'a user can see
## > somebody else typing'."*
##
## `projection.projectEditorViewState` is the renderer, and this suite is what
## makes it a claim rather than a function. It drives the REAL authority
## (`text_ops.acceptSubmission`), the REAL reducer (`applyViewOp`) and the
## REAL capability grant, and reads the result out of an `EditingDocument` —
## the same value both front-ends' editors derive from, which is the whole
## reason one projection can serve both.
##
## =========================================================================
## WHAT A TEXT ASSIGNMENT WOULD HAVE LOOKED IDENTICAL FOR
## =========================================================================
##
## Three properties distinguish `applyRemoteChange` from writing the folded
## text into the document, and all three are invisible on screen until the
## user does something:
##
##   1. **the remote edit does not enter the local undo history** (§13.2 — it
##      becomes an accumulated MAPPING in both branches instead), so the next
##      `undo` reverses the USER's last edit and not the peer's;
##   2. **it does not consult the local `TransactionFilter`s** (§12.2 — the
##      authority's changes are not negotiable);
##   3. **the local selection is MAPPED through it**, not reset.
##
## Each has a case. A suite that asserted only "the text arrived" would be
## green over an assignment, which is the §4a shape applied to a projection.
##
## =========================================================================
## No mocks
## =========================================================================
##
## The authority is `text_ops.acceptSubmission`, the state machine is
## `reducer.applyViewOp`, the document is a real `SharedSessionDocument` with
## a real capability grant, and the editor is `editing_core.EditingDocument`.

import std/[json, strutils, unittest]

import ../../collab/types
import ../../collab/reducer
import ../../collab/text_ops
import ../../collab/projection
import ../../editing_core
import ../../editor/change_set
import ../../editor/transaction

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 38
  ## Asserted by the last case against the runtime tally. Written LAST, from a
  ## run.

const
  SessionId = "plat34-projection"
  Authority = "authority"
  Peer = "peer-1"
    ## The REMOTE peer — whoever else is typing.
  LocalPeer = "peer-local"
    ## **THIS FRONT-END'S OWN ID, AND IT IS NOT `Peer`.**
    ##
    ## The first version of this suite used one id for both and the undo case
    ## failed with the remote text absent. That is `receiveUpdates` working:
    ## it recognises the peer's OWN updates coming back and CONSUMES them to
    ## confirm the local ones, rather than applying them a second time — which
    ## is `LAW-X2` and is the whole reason a submission carries a producer. A
    ## suite that shared the id was asking the protocol to apply an update it
    ## is specified to swallow.
  DocumentId = "main.py"
  BaseDoc = "def calc(n):\n    total = 0\n    return total\n"

proc grantText(doc: var SharedSessionDocument; subject: PrincipalId) =
  ## The real grant, through the real reducer. Without it every submission is
  ## refused and the suite would be measuring the capability layer rather than
  ## the projection.
  discard doc.applyViewOp(ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: SessionId, principalId: Authority, actorId: Authority,
    opId: "grant-" & subject, lamport: 10,
    kind: vokGrantCapabilities, targetPath: "capabilityGrants",
    payload: %*{
      "grantId": "grant-" & subject, "subject": subject, "issuer": Authority,
      "capabilities": [$capEditSharedText, $capPublishAwareness],
      "targetPaths": [TextDocumentsPath, TextSelectionsPath]},
    unknownFields: newJObject()))

proc newDoc(): SharedSessionDocument =
  result = initSharedSessionDocument(
    sessionId = SessionId, authorityPrincipalId = Authority,
    backendOwnerId = Authority)
  result.grantText(Peer)

proc commitRemote(doc: var SharedSessionDocument; cs: ChangeSet;
                  updateId: string; atVersion: int; lamport: uint64): int =
  ## One peer edit, submitted, accepted and committed. Answers how many
  ## accept envelopes the reducer applied.
  let submission = submitTextUpdateOp(
    sessionId = SessionId, principalId = Peer, actorId = Peer,
    replicaId = Peer, opId = "sub-" & updateId, lamport = lamport,
    documentId = DocumentId,
    updates = [TextUpdate(changes: cs, producer: Peer, updateId: updateId)],
    atVersion = atVersion, baseLength = BaseDoc.len)
  let accept = doc.state.acceptSubmission(submission, Authority, Authority,
                                          Authority, lamport + 1)
  if accept.refused.len > 0:
    return 0
  for op in accept.ops:
    if doc.applyViewOp(op).status != asApplied:
      return 0
    inc result

suite "PLAT-34: a remote edit reaches the document both front-ends draw":

  test "a committed remote change lands in the EditingDocument":
    var shared = newDoc()
    var p = newEditorProjection(DocumentId,
                                initEditingDocument(DocumentId, BaseDoc), LocalPeer)
    counted p.doc.text == BaseDoc
    # The peer inserts at the top of the body.
    let at = BaseDoc.find("    total")
    counted at > 0
    let cs = changeSet(BaseDoc.len, at, at, "    # hello\n")
    counted commitRemote(shared, cs, "u1", 0, 100) == 1
    let applied = projectEditorViewState(shared.state, p)
    checkpoint("applied " & $applied & " entries; doc is now:\n" & p.doc.text)
    counted applied == 1
    counted p.doc.text != BaseDoc
    counted "# hello" in p.doc.text
    counted p.appliedVersion == 1

  test "the cursor DEDUPS: projecting again applies nothing":
    # A projection callback fires on every state change, including ones that
    # touched another pane entirely. Without the cursor the whole text log
    # would be re-applied on every calltrace selection, and the document would
    # grow a copy of every remote edit per unrelated event.
    var shared = newDoc()
    var p = newEditorProjection(DocumentId,
                                initEditingDocument(DocumentId, BaseDoc), LocalPeer)
    let at = BaseDoc.find("    total")
    counted commitRemote(shared, changeSet(BaseDoc.len, at, at, "X"),
                         "u1", 0, 100) == 1
    counted projectEditorViewState(shared.state, p) == 1
    let once = p.doc.text
    counted projectEditorViewState(shared.state, p) == 0
    counted p.doc.text == once
    counted projectEditorViewState(shared.state, p) == 0
    counted p.doc.text == once

  test "the remote edit does NOT become the user's next undo (§13.2)":
    # **THE PROPERTY A TEXT ASSIGNMENT WOULD LOOK IDENTICAL FOR.** The user
    # types, a peer types, the user presses undo: what comes back must be the
    # USER's edit. Under an assignment the peer's insertion is either
    # un-undoable or the user's own history is gone; under
    # `applyRemoteChange` the remote change is an accumulated MAPPING in both
    # branches and the user's event is rebased through it.
    var shared = newDoc()
    var p = newEditorProjection(DocumentId,
                                initEditingDocument(DocumentId, BaseDoc), LocalPeer)
    # THE LOCAL EDIT GOES THROUGH `commitLocalChange`, WHICH IS THE POINT.
    # A front-end that wrote the document without recording the change on its
    # session would have a document its own session cannot describe, and the
    # next arriving batch would be rebased past nothing — measured: the first
    # version of this case did exactly that and `applyRemoteChange` refused by
    # name, which is the model working.
    counted p.commitLocalChange(changeSet(BaseDoc.len, 0, 0, "L"),
                                "local-1", 1_000)
    let afterLocal = p.doc.text
    counted afterLocal.startsWith("L")

    let at = BaseDoc.find("    return")
    counted at > 0
    counted commitRemote(shared, changeSet(BaseDoc.len, at, at, "R"),
                         "u1", 0, 100) == 1
    counted projectEditorViewState(shared.state, p) == 1
    let afterRemote = p.doc.text
    counted "R" in afterRemote
    counted afterRemote.startsWith("L")

    discard p.doc.applyNamed("undo", OpArgs(), 2_000)
    checkpoint("after undo:\n" & p.doc.text)
    # THE USER'S EDIT IS GONE AND THE PEER'S IS STILL THERE. Both halves,
    # because either alone is satisfied by the wrong implementation: an undo
    # that reverted everything satisfies the first, and an undo that did
    # nothing satisfies the second.
    counted not p.doc.text.startsWith("L")
    counted p.doc.text != afterRemote
    counted p.doc.text.contains("    R" & "return") or "R" in p.doc.text

  test "a LOCAL FILTER does not refuse the authority's change (§12.2)":
    # A read-only buffer refuses the user's keystrokes and must not refuse a
    # peer's committed edit: a guard that suppressed part of an authority
    # change would break convergence silently. `applyRemoteChange` is the path
    # that does not call `refusedBy`, and this is what makes that observable.
    var shared = newDoc()
    var doc = initEditingDocument(DocumentId, BaseDoc)
    doc.state.filters = @[TransactionFilter(kind: tfReadOnly)]
    var p = newEditorProjection(DocumentId, doc, LocalPeer)
    # The local guard bites: the user cannot type.
    # The local guard bites through the SAME entry point the undo case uses.
    counted not p.commitLocalChange(changeSet(BaseDoc.len, 0, 0, "L"),
                                    "local-1", 1_000)
    counted p.doc.text == BaseDoc
    # The authority's does not.
    let at = BaseDoc.find("    total")
    counted commitRemote(shared, changeSet(BaseDoc.len, at, at, "R"),
                         "u1", 0, 100) == 1
    counted projectEditorViewState(shared.state, p) == 1
    counted p.doc.text != BaseDoc
    counted "R" in p.doc.text

  test "the local SELECTION is mapped through the remote change, not reset":
    var shared = newDoc()
    var p = newEditorProjection(DocumentId,
                                initEditingDocument(DocumentId, BaseDoc), LocalPeer)
    let caretAt = BaseDoc.find("return")
    counted caretAt > 0
    p.doc.state.selection = caretSelection(caretAt)
    counted p.doc.state.primaryHead == caretAt
    # A remote insertion BEFORE the caret moves it by the inserted length; a
    # reset would move it to 0 and a no-op would leave it where the text no
    # longer is.
    let at = BaseDoc.find("    total")
    counted at < caretAt
    counted commitRemote(shared, changeSet(BaseDoc.len, at, at, "RRRR"),
                         "u1", 0, 100) == 1
    counted projectEditorViewState(shared.state, p) == 1
    checkpoint("caret " & $caretAt & " -> " & $p.doc.state.primaryHead)
    counted p.doc.state.primaryHead == caretAt + 4

  test "a projection with no document, and one whose document is absent":
    # Two real states rather than defensiveness: a session that has not opened
    # a text document, and a front-end that has not been told which document
    # it is drawing. Both answer zero, and neither raises.
    var shared = newDoc()
    var p = newEditorProjection("", initEditingDocument("x", BaseDoc),
                                LocalPeer)
    counted projectEditorViewState(shared.state, p) == 0
    var q = newEditorProjection("no-such-document",
                                initEditingDocument("x", BaseDoc), LocalPeer)
    counted projectEditorViewState(shared.state, q) == 0
    counted q.doc.text == BaseDoc

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
