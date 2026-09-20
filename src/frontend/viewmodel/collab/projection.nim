## Projection adapters from SharedSessionViewState into panel ViewModel signals.
##
## =========================================================================
## THE EDITOR PROJECTION — PLAT-33's SECOND RESIDUAL, CLOSED BY PLAT-34
## =========================================================================
##
## PLAT-33 landed the collaborative rebase and recorded, in its own status,
## that nothing rendered it: *"`collab/projection.nim` projects the calltrace
## and the state pane and has no editor projection; PLAT-33 adds the shared
## state and the reducer arms but nothing renders them. … it is stated here so
## that 'collaborative text editing works' is not read as 'a user can see
## somebody else typing'."*
##
## `projectEditorViewState` below is that renderer, and it is one function
## because PLAT-34 made it possible to be one: both front-ends derive their
## editor from the same `EditingDocument`, so a projection that advances THAT
## value is a projection both of them draw. Before this milestone the terminal
## held an `isonim-tui` widget and the GPUI front-end held a string it had
## read off the disk, and a remote edit would have had to be written into two
## places that could disagree.
##
## **IT GOES THROUGH `collab_text.receiveInto`, NOT THROUGH A TEXT
## ASSIGNMENT AND NOT THROUGH A BARE `applyRemoteChange`.** Two separate
## points, and the second was measured rather than reasoned:
##
## Against an assignment: a remote change does not enter the local undo
## history (§13.2 — it becomes an accumulated MAPPING in both branches
## instead), it does not consult the local `TransactionFilter`s (§12.2 — the
## authority's changes are not negotiable), and it maps the local selection
## through itself rather than resetting it. Assigning `doc.state.doc` would
## lose all three and look identical on screen until the user pressed undo.
##
## **Against a bare `applyRemoteChange`: the first version of this projection
## used one, and it raised on its own suite.** A committed change set is
## expressed against the AUTHORITY's document; a front-end with unconfirmed
## local work has a longer one, and `applyRemoteChange` refuses by name rather
## than corrupting it (*"the change is over 44 bytes and the document is 45. A
## remote change that does not meet the document was not rebased past the
## local work."*). Rebasing past the peer's own unconfirmed updates is
## `receiveUpdates`'s job, and `receiveInto` is the routine that exists so a
## caller *"cannot do the second without the first"*. The projection therefore
## holds a `PeerSession` — which is also what makes the peer's own accepted
## updates recognisable when they come back, rather than applied twice.

import std/[options, parseutils, sets]

import isonim/core/signals

import ./[reducer, session_core, text_ops, types]
import ../editing_core
import ../editor/change_set
import ../editor/collab_text
import ../editor/operations
import ../editor/transaction
import ../viewmodels/[calltrace_vm, state_vm]

proc parseInt64Option(value: string): Option[int64] =
  if value.len == 0:
    return none(int64)
  var parsed: int64
  let consumed = parseBiggestInt(value, parsed, 0)
  if consumed == value.len:
    some(parsed)
  else:
    none(int64)

proc parseStateTab(value: string): StateTab =
  case value
  of "stGlobals": stGlobals
  of "stWatches": stWatches
  else: stLocals

proc projectCalltraceViewState*(state: SharedSessionViewState;
                                vm: CalltraceVM) =
  if vm.isNil:
    return
  vm.selectedEntry.val = parseInt64Option(state.calltrace.selectedEntry.value)
  vm.searchQuery.val = state.calltrace.searchQuery.value

  var nodes = initHashSet[int64]()
  for id in visibleExpansionIds(state.calltrace.expandedNodes):
    let parsed = parseInt64Option(id)
    if parsed.isSome:
      nodes.incl(parsed.get)
  vm.expandedNodes.val = nodes

proc projectStateViewState*(state: SharedSessionViewState; vm: StateVM) =
  if vm.isNil:
    return
  vm.activeTab.val = parseStateTab(state.statePane.activeTab.value)
  vm.selectedPath.val = state.statePane.selectedPath.value

  var paths = initHashSet[string]()
  for path in visibleExpansionIds(state.statePane.expandedPaths):
    paths.incl(path)
  vm.expandedPaths.val = paths

  var watches: seq[string] = @[]
  for watch in visibleWatches(state.statePane):
    watches.add watch.expression
  vm.watchExpressions.val = watches

proc installCalltraceProjection*(core: CollaborativeSessionCore;
                                 vm: CalltraceVM) =
  if core.isNil or vm.isNil:
    return
  core.addProjectionCallback(proc(state: SharedSessionViewState) =
    projectCalltraceViewState(state, vm))

proc installStateProjection*(core: CollaborativeSessionCore; vm: StateVM) =
  if core.isNil or vm.isNil:
    return
  core.addProjectionCallback(proc(state: SharedSessionViewState) =
    projectStateViewState(state, vm))

# ===========================================================================
# THE EDITOR — PLAT-34
# ===========================================================================

type
  EditorProjection* = ref object
    ## **THE DOCUMENT A FRONT-END IS DRAWING, PLUS HOW MUCH OF THE AUTHORITY'S
    ## LOG HAS REACHED IT.**
    ##
    ## A `ref` and not a value, unlike `EditingDocument` itself, because a
    ## projection is installed as a CALLBACK and a callback has to write
    ## somewhere the caller can still see. The document inside it stays a
    ## value, so two front-ends' documents remain two comparable values —
    ## which is what `DIFF-1` rests on.
    documentId*: string
    doc*: EditingDocument
    session*: PeerSession
      ## **THE PEER'S OWN SESSION, AND IT IS WHAT MAKES THIS CORRECT RATHER
      ## THAN JUST SHORT.** It carries the unconfirmed local updates the
      ## arriving batch has to be rebased past, and it recognises this peer's
      ## own updates coming back so they confirm rather than apply twice.
      ## `session.version` is the cursor into the committed log; there is no
      ## second counter here, for the reason `SharedTextDocument` has none.
    peerId*: string

proc newEditorProjection*(documentId: string; doc: EditingDocument;
                          peerId: string;
                          atVersion = 0): EditorProjection =
  EditorProjection(documentId: documentId, doc: doc, peerId: peerId,
                   session: initPeerSession(peerId, atVersion))

func appliedVersion*(p: EditorProjection): int =
  ## How far into the authority's committed log this front-end has been
  ## brought. Read off the session rather than tracked beside it.
  if p.isNil: 0 else: p.session.version

proc projectEditorViewState*(state: SharedSessionViewState;
                             p: EditorProjection): int =
  ## Advance `p.doc` over every committed entry it has not seen. Answers how
  ## many entries were applied, so a caller can tell "nothing arrived" from
  ## "nothing was rendered".
  ##
  ## **THE CURSOR IS THE DEDUP**, and it is the same argument `hasApplied`
  ## makes one layer down: the reducer already refuses a duplicate ENVELOPE,
  ## and this refuses a duplicate APPLICATION — a projection callback fires on
  ## every state change, including ones that touched another pane entirely, so
  ## without the cursor every calltrace selection would re-apply the whole
  ## text log.
  if p.isNil or p.documentId.len == 0:
    return 0
  if not state.hasTextDocument(p.documentId):
    return 0
  let log = state.textDocument(p.documentId).committedLog
  let firstUnseen = p.session.version
  if firstUnseen >= log.len:
    return 0
  # ONE BATCH, NOT ONE CALL PER ENTRY. `receiveUpdates` walks the arriving
  # updates in order and advances the running remote change past each local
  # update in turn; feeding it one entry at a time would rebase every entry
  # against the same unconfirmed work rather than against the work as it
  # stands after the previous one. The integration suite's `drain` batches for
  # the same reason and this is the same routine.
  var batch: seq[TextUpdate] = @[]
  for i in firstUnseen ..< log.len:
    batch.add log[i].toTextUpdate
  # A CHANGE THAT DOES NOT MEET THE DOCUMENT RAISES BY NAME RATHER THAN BEING
  # CLAMPED (§36a) — `applyRemoteChange` does that inside `receiveInto`, and
  # the session's version is not advanced past a batch that did not apply, so
  # the failure is sticky rather than skipped.
  p.doc.state = p.session.receiveInto(p.doc.state, batch)
  p.session.version - firstUnseen

proc commitLocalChange*(p: EditorProjection; cs: ChangeSet;
                        updateId: string; nowMs: int64): bool =
  ## A LOCAL edit: applied to the document **and** recorded as unconfirmed
  ## work on the session, in one call.
  ##
  ## **BOTH HALVES OR NEITHER, AND THE REASON IS A FAILURE THIS SUITE SAW.**
  ## The first version of the projection's own suite edited the document
  ## directly and did not record — at which point the document was one byte
  ## longer than the session believed, the next arriving batch was rebased
  ## past nothing, and `applyRemoteChange` refused by name. That refusal is
  ## the model working, and the lesson is that the two writes are one
  ## operation: a front-end that can do the first without the second has a
  ## document its own session cannot describe.
  ##
  ## `commitChange` is the local path — it enters the undo history, consults
  ## the local `TransactionFilter`s, and maps the marks — and `recordLocal` is
  ## what makes the edit sendable. Answers whether anything was recorded; an
  ## identity change is not an edit on either side.
  if p.isNil or cs.isIdentity:
    return false
  # **THE LOCAL GUARDS ARE CONSULTED, AND THIS LINE IS WHY THE CASE EXISTS.**
  # `operations.commitChange` is the document-moving primitive and it does NOT
  # check the filters — `applyTransaction` does, one layer up, which is where
  # every one of the 224 operations goes through. A local path that reached
  # `commitChange` directly therefore bypassed a read-only buffer entirely;
  # the suite's `tfReadOnly` case caught it on the first run. §12.2's asymmetry
  # is that the LOCAL path calls `refusedBy` and the remote path does not call
  # it at all, and a projection that offered a third path had to pick a side.
  if p.doc.state.filters.refusedBy(cs):
    return false
  p.doc.state = commitChange(p.doc.state, cs, nowMs = nowMs)
  p.session.recordLocal(cs, updateId)
  true

proc installEditorProjection*(core: CollaborativeSessionCore;
                              p: EditorProjection) =
  ## Render every remote edit into `p.doc` as it is committed.
  ##
  ## The same shape as `installCalltraceProjection` and
  ## `installStateProjection` above — one `addProjectionCallback`, no second
  ## channel — because a front-end that had to poll for text while it
  ## subscribed for everything else would be a front-end with two liveness
  ## models.
  if core.isNil or p.isNil:
    return
  core.addProjectionCallback(proc(state: SharedSessionViewState) =
    discard projectEditorViewState(state, p))
