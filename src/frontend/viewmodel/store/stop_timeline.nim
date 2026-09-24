## store/stop_timeline.nim — PLAT-29: the DAP payloads that feed the locals
## and the inline values name the STOP they were requested at, and are
## reconciled against the stop the store is at when they arrive.
##
## Editor-ViewModel.md §11 lists *"the DAP data that feeds inline values"*
## among the producers that sit outside, compute against a version, and are
## reconciled or discarded when stale. For that producer the "document" that
## can move under a result is not text the user types — it is the DEBUGGER'S
## POSITION. A `ct/load-locals` answer is about the program at the stop it was
## asked at; drawn at another stop it is `x: 42` beside a line where `x` is now
## 7, which reads exactly like the truth. `editor_surface.inlineValuesOf`'s
## header says *"a stale inline value is worse than none"*; this is where
## "stale" stops being a sentence and becomes a version.
##
## ## The model, stated so it can be checked
##
## A `StopTimeline` is a `VersionedDocument` whose text is the stop's
## IDENTITY — the tick, the file, the line and column, and the source
## revision (HCR generation, digest). Each stop the debugger moves to is a new
## version, reached by a change that REPLACES the whole identity. A payload is
## a `ProducerResult` of `pkInlineValues` (`srAnchorLive`) anchored at a point
## INSIDE the identity it was requested at — so the same stop is `roApplied`,
## and a move, having replaced every byte of the old identity, leaves the
## anchor nowhere: `drEvidenceDeleted`. The decision is `reconcile`'s, through
## its table, not a comparison written here; that is what keeps this producer
## on the one boundary with the highlighter and the file worker.
##
## ## Observed, not only notified
##
## The timeline advances when `ReplayDataStore.updateDebuggerPosition` — the
## one bridge every host's move completion goes through — reports a stop, AND
## whenever it is asked for a stamp or a verdict it first observes
## `store.debugger` itself. The second is what makes it total: a host that
## writes `store.debugger` directly (a collaboration replica, a snapshot
## restore) cannot leave the timeline behind, because nothing reads the
## timeline without looking at the position first. An identity that did not
## change is NOT a new version, so a host mirroring one move twice (the web
## renderer does) does not make its own request stale.
##
## One consequence is stated rather than hidden: two consecutive stops with
## the SAME identity — the same tick, file, line and column — are one version.
## On a record-replay trace that is the same machine state, so a value about
## one is true of the other. A materialized trace reports tick 0 for every
## position, and two consecutive stops on the same line and column there are
## indistinguishable to every field the stop carries; no field exists to tell
## them apart, and inventing one here would be a clock.

import ../editor/change_set
import ../editor/document_version
import ../editor/reconcile
import ./types

type
  StopStamp* = object
    ## What a DAP request names: the stop's version when it was SENT, and the
    ## length of that stop's identity (the anchor's document length).
    version*: DocumentVersion
    identityLen*: int

  StopTimeline* = object
    vd: VersionedDocument
    report*: StalenessReport
      ## Every DAP payload that ARRIVED and was reconciled — applied, or
      ## dropped because the debugger had moved. A DRAW is counted elsewhere
      ## (`inline_value_timeline.InlineValueGate.report`, through
      ## `reconcileStamp` with its own report), so this figure is arrivals and
      ## nothing else.

const
  StopTimelineDepth* = 64
    ## Stops remembered. A payload requested more than this many moves ago is
    ## `drVersionForgotten` — counted, and dropped, like any other stale one.
  AnchorOffset = 1
    ## The anchor's position inside the identity. Strictly inside, so that
    ## replacing the whole identity deletes it and an identity that did not
    ## move keeps it.

func stopIdentityOf*(d: DebuggerState): string =
  ## Never shorter than two bytes, so a point strictly inside it exists.
  "\x01" & $d.rrTicks & "\0" & d.location.file & "\0" & $d.location.line &
    "\0" & $d.location.column & "\0" & $d.location.sourceGeneration & "\0" &
    d.location.sourceDigest

proc initStopTimeline*(): StopTimeline =
  StopTimeline(vd: initVersionedDocument(""))

proc observe*(tl: var StopTimeline; d: DebuggerState) =
  ## The debugger is at `d`. A stop with a different identity is a new
  ## version, reached by replacing the whole identity.
  let identity = stopIdentityOf(d)
  let old = tl.vd.text
  if old == identity:
    return
  discard tl.vd.applyChanges(changeSet(old.len, 0, old.len, identity))
  tl.vd.keepRecent(StopTimelineDepth)

func stamp*(tl: StopTimeline): StopStamp =
  ## The stop a request is being sent at.
  StopStamp(version: tl.vd.version, identityLen: tl.vd.text.len)

proc reconcileStamp*(tl: StopTimeline; s: StopStamp;
                     rep: var StalenessReport): ReconcileOutcome =
  ## `reconcile`'s verdict on a payload requested at `s`, counted in `rep`.
  if not tl.vd.knows(s.version):
    rep.record(pkInlineValues, roDropped, drVersionForgotten)
    return roDropped
  if s.identityLen <= AnchorOffset:
    # No stop had been observed when the request was sent: there is nothing
    # to anchor it in, and a value about no stop is not a value about this one.
    rep.record(pkInlineValues, roDropped, drEvidenceDeleted)
    return roDropped
  let pr = producerResult(pkInlineValues, s.version, s.identityLen,
                          AnchorOffset, AnchorOffset)
  reconcile(tl.vd, pr, rep).outcome

proc admit*(tl: var StopTimeline; s: StopStamp): bool =
  ## Whether a payload that just ARRIVED, requested at `s`, may be applied.
  ## Counted in `report`.
  var rep = tl.report
  result = tl.reconcileStamp(s, rep) != roDropped
  tl.report = rep

proc dropUnvouched*(tl: var StopTimeline) =
  ## A payload ARRIVED naming a request no stop can be found for — never
  ## recorded, or recorded so long ago it was forgotten. It is dropped, and
  ## counted like a payload whose stop was forgotten, because that is what it
  ## is: evidence about a stop this timeline can no longer name.
  tl.report.record(pkInlineValues, roDropped, drVersionForgotten)
