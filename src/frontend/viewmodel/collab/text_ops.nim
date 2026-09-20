## text_ops.nim — PLAT-33: where `editor/collab_text.nim`'s algorithm meets the
## existing `ViewOpEnvelope` stream.
##
## Owns: `Architecture/Editor-ViewModel.md` §12.2a. Nothing here decides how a
## rebase works — that is `editor/collab_text.nim`, which knows nothing about
## envelopes, capabilities or sessions. This module is the translation, and it
## is a separate file so the algorithm can be graded with no session in sight
## and the wire can be graded with no rebase in sight.
##
## =========================================================================
## THE FOUR MEASUREMENTS §12.1 TOOK, AND WHICH OF THEM STILL HOLD — PLAT-33
## =========================================================================
##
## 1. **"The envelope is text-ready and kind-agnostic."** HOLDS, re-measured.
##    Three kinds were added to `ViewOpKind` and `codec.nim` needed no change
##    for them: `parseViewOpKind` iterates the enum and `toJson` writes `$kind`,
##    so the new names are on the wire the moment they exist, and an older peer
##    decodes them as `vokUnknown` + `kindName` and forwards them losslessly.
##
##    What DID need a codec change is the authority version, and that is a
##    different claim — measurement 3 below said so.
##
## 2. **"The merge layer cannot carry them."** HELD, and is why `collab_text`
##    exists rather than a fourth resolver in `reducer.nim`. The reducer's text
##    arms hold a LOG; they do not merge.
##
## 3. **"There is no authority-issued version."** WAS TRUE; there is one now.
##    `ViewOpEnvelope.authorityVersion` is the field, and `lamport` is
##    untouched beside it because the two answer different questions.
##
## 4. **"`SharedEditorViewState` is one field."** WAS TRUE; it is three.
##
## =========================================================================
## WHY THE PAYLOAD CARRIES `"CS1|"` AND NOT A JSON CHANGE SET
## =========================================================================
##
## PLAT-25 built `encodeChangeSet` / `decodeChangeSet` with the note *"because
## PLAT-33 puts change sets on a wire"*, and using it here is what makes
## `LAW-A9` re-runnable **on the wire**: the same round trip, through the real
## envelope codec, where `unknownFields` splatting and `vokUnknown` preservation
## are a SECOND encoding the change set has to survive. A JSON rendering of the
## sections would have been a second encoder to keep in step with the first.
##
## The encoding is length-prefixed and byte-transparent, which matters more
## than it looks: the corpus contains ill-formed UTF-8 by design (class 7), and
## a JSON string cannot carry a bare continuation byte.

import std/json

import ./types
import ./capabilities
import ./reducer
import ../editor/change_set
import ../editor/collab_text

export collab_text.TextUpdate, collab_text.TextAuthority,
       collab_text.Submission, collab_text.AcceptOutcome,
       collab_text.AcceptStatus, collab_text.PeerSession,
       collab_text.CollabTextError

type
  TextOpsError* = object of ValueError
    ## A payload that does not describe a text update. Raised rather than
    ## returned as an empty value: an undecodable change set silently becoming
    ## the identity is a peer that quietly stops converging.

const
  TextDocumentsPath* = "editor.documents"
  TextSelectionsPath* = "editor.remoteSelections"
    ## The capability target paths, named once. A grant is written against
    ## these strings and `requiredCapability` answers with them, so a typo in
    ## either place is a grant that covers nothing — which is why they are
    ## constants rather than two string literals in two files.

# ===========================================================================
# SHARED STATE <-> THE ALGORITHM'S TYPES
# ===========================================================================

proc toTextUpdate*(entry: SharedTextUpdate): TextUpdate =
  ## One log entry, decoded. `decodeChangeSet` raises by name on a malformed
  ## encoding, and that raise is deliberately not caught here.
  TextUpdate(changes: decodeChangeSet(entry.changes),
             producer: entry.producer,
             updateId: entry.opId)

proc authorityOf*(doc: SharedTextDocument): TextAuthority =
  ## Rebuild the authority from shared state, over the COMMITTED prefix.
  ##
  ## An entry parked beyond a gap is not part of the document yet
  ## (`reducer.committedLog`), so it is not part of the authority either — a
  ## version the authority claims to hold but cannot fold would make
  ## `accept`'s length check answer about a document nobody has.
  result = initTextAuthority(doc.baseLength)
  for entry in doc.committedLog:
    let outcome = result.accept(
      Submission(updates: @[entry.toTextUpdate], atVersion: result.version))
    if outcome.status == asRefused:
      raise newException(TextOpsError,
        "authorityOf: log entry " & $entry.version & " of document " &
        doc.id & " does not fold: " & outcome.reason)

proc textDocument*(state: SharedSessionViewState;
                   documentId: string): SharedTextDocument =
  for doc in state.editor.documents:
    if doc.id == documentId:
      return doc
  raise newException(TextOpsError,
    "textDocument: no document '" & documentId & "' in the shared state")

proc hasTextDocument*(state: SharedSessionViewState;
                      documentId: string): bool =
  for doc in state.editor.documents:
    if doc.id == documentId:
      return true
  false

# ===========================================================================
# BUILDING ENVELOPES
# ===========================================================================

proc textUpdatePayload*(documentId: string; update: TextUpdate;
                        baseLength = 0): JsonNode =
  ## One accepted log entry. The authority emits exactly one of these per
  ## entry, so this shape is singular and stays so.
  %*{
    "documentId": documentId,
    "baseLength": baseLength,
    "producer": update.producer,
    "updateId": update.updateId,
    "changes": encodeChangeSet(update.changes),
  }

proc submissionPayload*(documentId: string; updates: openArray[TextUpdate];
                        baseLength = 0): JsonNode =
  ## **A SUBMISSION CARRIES THE WHOLE UNCONFIRMED LIST, AND IT HAS TO.**
  ##
  ## §12.2: *"the peer submits its unconfirmed updates tagged with its synced
  ## version"* — plural, one version for the list. Splitting the list into one
  ## envelope per update with `atVersion + k` looks equivalent and is not:
  ## update 1 is expressed against the document the peer's own update 0
  ## produced, and by the time the authority has accepted update 0 it has
  ## REBASED it, so the accepted update 0 is not the one update 1 was written
  ## after. `rebaseUpdates` exists to walk the whole list carrying the
  ## accumulated change forward between members, and it cannot do that if it
  ## is handed one member at a time.
  ##
  ## Measured rather than reasoned: the first runner submitted singly and
  ## `LAW-X1` failed on every class with two peers holding unconfirmed work.
  var items = newJArray()
  for update in updates:
    items.add %*{
      "producer": update.producer,
      "updateId": update.updateId,
      "changes": encodeChangeSet(update.changes),
    }
  %*{
    "documentId": documentId,
    "baseLength": baseLength,
    "updates": items,
  }

proc submitTextUpdateOp*(sessionId: string; principalId: PrincipalId;
                         actorId: ActorId; replicaId: SessionReplicaId;
                         opId: ViewOpId; lamport: uint64;
                         documentId: string; updates: openArray[TextUpdate];
                         atVersion: int; baseLength = 0;
                         capabilityIds: seq[CapabilityGrantId] = @[]):
                        ViewOpEnvelope =
  ## A peer's submission: **all** its unconfirmed updates under ONE version.
  ## `authorityVersion` is what the peer had seen, which is the field the
  ## rebase needs and the one `lamport` is not.
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: sessionId,
    principalId: principalId,
    actorId: actorId,
    replicaId: replicaId,
    opId: opId,
    lamport: lamport,
    authorityVersion: atVersion,
    capabilityIds: capabilityIds,
    targetPath: TextDocumentsPath,
    kind: vokSubmitTextUpdate,
    payload: submissionPayload(documentId, updates, baseLength),
    unknownFields: newJObject(),
  )

proc acceptTextUpdateOp*(sessionId: string; authorityPrincipalId: PrincipalId;
                         actorId: ActorId; replicaId: SessionReplicaId;
                         opId: ViewOpId; lamport: uint64;
                         documentId: string; baseLength: int;
                         update: TextUpdate; version: int): ViewOpEnvelope =
  ## The authority's canonical log entry going out. `authorityVersion` here is
  ## the INDEX this entry occupies — not what anyone had seen. The two uses of
  ## one field are distinguished by the KIND, which is the reason the two kinds
  ## are separate rather than one with a direction flag.
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: sessionId,
    principalId: authorityPrincipalId,
    actorId: actorId,
    replicaId: replicaId,
    opId: opId,
    lamport: lamport,
    authorityVersion: version,
    targetPath: TextDocumentsPath,
    kind: vokAcceptTextUpdate,
    payload: textUpdatePayload(documentId, update, baseLength),
    unknownFields: newJObject(),
  )

proc setTextSelectionOp*(sessionId: string; principalId: PrincipalId;
                         actorId: ActorId; replicaId: SessionReplicaId;
                         opId: ViewOpId; lamport: uint64;
                         documentId: string;
                         anchors: openArray[SharedCaretAnchor];
                         atVersion: int): ViewOpEnvelope =
  var items = newJArray()
  for a in anchors:
    items.add %*{"pos": a.pos, "sideAfter": a.sideAfter}
  ViewOpEnvelope(
    protocolVersion: CurrentCollabProtocolVersion,
    sessionId: sessionId,
    principalId: principalId,
    actorId: actorId,
    replicaId: replicaId,
    opId: opId,
    lamport: lamport,
    authorityVersion: atVersion,
    targetPath: TextSelectionsPath,
    kind: vokSetTextSelection,
    payload: %*{"documentId": documentId, "anchors": items},
    unknownFields: newJObject(),
  )

# ===========================================================================
# THE AUTHORITY SIDE — turning one submission into its accepts
# ===========================================================================

type
  AcceptedOps* = object
    ## What the authority broadcasts in response to a submission.
    ops*: seq[ViewOpEnvelope]
    version*: int
    refused*: string
      ## Empty when accepted. **A REFUSAL IS A STRING AND NOT AN EMPTY `ops`**:
      ## a submission of zero updates is also an empty `ops`, and the two must
      ## be distinguishable or the offline path cannot tell "nothing to do"
      ## from "your version is ahead of mine".

proc acceptSubmission*(state: SharedSessionViewState;
                       submission: ViewOpEnvelope;
                       authorityPrincipalId: PrincipalId;
                       authorityActorId: ActorId;
                       authorityReplicaId: SessionReplicaId;
                       lamport: uint64): AcceptedOps =
  ## Run §12.2's authority half over one `vokSubmitTextUpdate` envelope.
  ##
  ## The `opId`s minted for the accepts are derived from the submission's own
  ## `opId` and the position within it, so **a resubmitted envelope produces
  ## the same accept ids** and the reducer's `hasApplied` dedup recognises
  ## them. A random id per accept would make a retry look like new work, which
  ## is `LAW-X2` failing through the authority rather than through the peer.
  if submission.kind != vokSubmitTextUpdate:
    raise newException(TextOpsError,
      "acceptSubmission: expected vokSubmitTextUpdate, got " &
      $submission.kind)
  let documentId = submission.payload{"documentId"}.getStr("")
  if documentId.len == 0:
    return AcceptedOps(refused: "submission names no document")

  let doc = if state.hasTextDocument(documentId): state.textDocument(documentId)
            else: SharedTextDocument(
              id: documentId,
              baseLength: submission.payload{"baseLength"}.getInt(0),
              log: @[])
  var authority = doc.authorityOf
  let startVersion = authority.version

  var updates: seq[TextUpdate] = @[]
  for item in submission.payload{"updates"}.getElems(@[]):
    updates.add TextUpdate(
      changes: decodeChangeSet(item{"changes"}.getStr("")),
      producer: item{"producer"}.getStr(submission.principalId),
      updateId: item{"updateId"}.getStr(submission.opId))
  if updates.len == 0:
    return AcceptedOps(version: startVersion, refused: "submission carries no updates")

  let outcome = authority.accept(
    Submission(updates: updates, atVersion: submission.authorityVersion))
  if outcome.status == asRefused:
    return AcceptedOps(version: startVersion, refused: outcome.reason)

  result.version = outcome.version
  for i, accepted in outcome.accepted:
    result.ops.add acceptTextUpdateOp(
      sessionId = submission.sessionId,
      authorityPrincipalId = authorityPrincipalId,
      actorId = authorityActorId,
      replicaId = authorityReplicaId,
      opId = submission.opId & "#a" & $i,
      lamport = lamport + uint64(i),
      documentId = documentId,
      baseLength = doc.baseLength,
      update = accepted,
      version = startVersion + i)

# ===========================================================================
# REMOTE CARETS — MAPPED, NEVER MERGED
# ===========================================================================

proc mappedAnchors*(state: SharedSessionViewState;
                    actorId: ActorId; documentId: string):
                   seq[SharedCaretAnchor] =
  ## One actor's carets, brought from the version they were published against
  ## up to the document's committed version, **by mapping them through the
  ## intervening change sets**.
  ##
  ## This is the function that makes "an anchor, not a register" mean
  ## something. A register would answer with whatever was last written and a
  ## caret published five edits ago would name a byte offset that is now in
  ## the middle of a word. `change_set.mapPosOr` is the same call
  ## `anchor.landingOf` is defined as, and `sideAfter` on the anchor chooses
  ## the same `Side` a local caret's association chooses.
  if not state.hasTextDocument(documentId):
    return @[]
  let doc = state.textDocument(documentId)
  var stored: seq[SharedCaretAnchor] = @[]
  var atVersion = -1
  for sel in state.editor.remoteSelections:
    if sel.actorId == actorId and sel.documentId == documentId:
      stored = sel.anchors
      atVersion = sel.atVersion
      break
  if atVersion < 0:
    return @[]
  let committed = doc.committedLog
  if atVersion > committed.len:
    # Published against a version this replica has not folded yet. Answering
    # with the raw offsets would place the caret by an accident of timing, so
    # the honest answer is that we do not know where it is yet.
    return @[]
  result = stored
  for i in atVersion ..< committed.len:
    let cs = decodeChangeSet(committed[i].changes)
    for a in result.mitems:
      a.pos = cs.mapPosOr(a.pos, if a.sideAfter: sideAfter else: sideBefore)

# ===========================================================================
# FOLDING THE SHARED LOG INTO A DOCUMENT
# ===========================================================================

proc foldDocument*(state: SharedSessionViewState;
                   documentId: string; base: string): string =
  ## What every peer must agree on — `LAW-X1`'s right-hand side.
  let doc = state.textDocument(documentId)
  if base.len != doc.baseLength:
    raise newException(TextOpsError,
      "foldDocument: document '" & documentId & "' is over " &
      $doc.baseLength & " bytes and the base is " & $base.len)
  result = base
  for entry in doc.committedLog:
    result = decodeChangeSet(entry.changes).apply(result)

proc canEditSharedText*(state: SharedSessionViewState;
                        principalId: PrincipalId): bool =
  ## Exported so a front-end can grey out an editor rather than letting a
  ## user type into a buffer whose every keystroke the authority will refuse.
  ## It calls the same predicate the reducer gates on, rather than restating
  ## the rule (`Verification-Harness-Traps.md` §30).
  state.hasLiveCapability(principalId, capEditSharedText, TextDocumentsPath)
