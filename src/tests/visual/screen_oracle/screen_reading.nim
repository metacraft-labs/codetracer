## PLAT-39 — `ScreenReading[T]`: the three-way outcome of reading a screen.
##
## **THE WHOLE POINT OF THIS MODULE IS THAT THERE ARE THREE OUTCOMES, NOT TWO.**
##
## "I could not read this" is never spelled the same way as "this is empty".
## Collapsing those two is the single defect this campaign has walked into most
## often, in four separate places that were each found independently:
##
## * PLAT-23: *"two empty screens compare equal"* — the pane census moved from
##   `locals=0` to `locals=8` on ONE step, so an unstepped program and a broken
##   reader produced the same answer.
## * `Verification-Harness-Traps.md` §4: a scanner that finds nothing satisfies
##   every "must not contain" check written over it.
## * `PLAT35-VG7` was retired against a run in which BOTH arms answered empty.
##   Two empty answers compared equal, the question agreed with itself, and the
##   retirement case then required the gap to go.
## * PLAT-37's blank control: a "not blank" check with no blank to compare
##   against is a negation with nothing to negate.
##
## An unreadable region must be a LOUD TYPED FAILURE and must never be a value
## that flows into a comparison. That is enforced here rather than documented:
## `==` on two `srUnreadable` values RAISES. It does not return false — a false
## would still let `check a == b` run and merely fail, and a caller that wrote
## `if a != b: gap()` would then file a gap instead of reporting that it could
## not see. The only way to compare unreadable readings is to ask explicitly.
##
## **`UnreadableReason` IS A CLOSED SET AND EVERY MEMBER IS REACHABLE.** That is
## PLAT-36's rule for its own reason set applied here: *a closed set with an
## unreachable member is an open set wearing a type*. `LAW-R6` in the suite
## plants an input per member and asserts each is reached, so a member that
## nothing can emit fails the build rather than sitting as decoration.

import std/[strutils, tables]

type
  UnreadableReason* = enum
    ## The five ways a read can fail. **Closed set — see the module header.**
    ##
    ## Ordered from "no picture" to "picture I could not parse", because that is
    ## the order in which the reader encounters them and a reader that reports a
    ## later reason has necessarily passed the earlier ones.
    urFrameMissing = "frame-missing"
      ## The frame file does not exist or was never captured.
    urFrameBlank = "frame-blank"
      ## No region survives thresholding. This is the DOCUMENTED degeneracy of
      ## Otsu on a unimodal histogram, not an inference: a uniform image has no
      ## between-class variance to maximise, so every threshold is equally good
      ## and the mask is all-or-nothing. A blank frame therefore yields zero
      ## window rectangles, and "zero panes located" MUST classify here and not
      ## as "no panes present" — that is `LAW-R3`.
    urRegionNotLocated = "region-not-located"
      ## The frame has regions, but none matched this pane. Distinct from
      ## `urFrameBlank` because the frame was readable and this pane was not.
    urNoWordAboveFloor = "no-word-above-floor"
      ## The region was located and OCR returned no word at or above the
      ## published confidence floor. A reader that accepts every word accepts
      ## noise; see `pane_grammar.OcrConfidenceFloor`.
    urGrammarMismatch = "grammar-mismatch"
      ## Words were read, and none of them matched the pane's published grammar.
      ## This is the reason that keeps a silent drop from happening: a row the
      ## grammar cannot parse is reported here rather than skipped.

  ScreenReadingKind* = enum
    srRead
    srEmpty
    srUnreadable

  ScreenReading*[T] = object
    ## The outcome of reading one pane out of one frame.
    ##
    ## Deliberately an object variant rather than `Option[T]` plus an error
    ## field: `Option` has exactly the two-way shape this type exists to reject,
    ## and a separate error field permits the state "none, and no reason", which
    ## is the collapsed case again wearing two fields instead of one.
    case kind*: ScreenReadingKind
    of srRead:
      value*: T
    of srEmpty:
      discard
    of srUnreadable:
      reason*: UnreadableReason
      detail*: string
        ## Free text for a human. NEVER parsed, NEVER compared — the machine
        ## meaning lives entirely in `reason`, so that a detail string being
        ## reworded can never change a verdict.

  UnreadableComparison* = object of CatchableError
    ## Raised by `==` when either side is `srUnreadable`. Carries the reasons so
    ## the failure names what could not be read rather than only that something
    ## could not be.

func read*[T](value: T): ScreenReading[T] =
  ScreenReading[T](kind: srRead, value: value)

func empty*[T](): ScreenReading[T] =
  ScreenReading[T](kind: srEmpty)

func unreadable*[T](reason: UnreadableReason,
                    detail = ""): ScreenReading[T] =
  ScreenReading[T](kind: srUnreadable, reason: reason, detail: detail)

func isRead*[T](r: ScreenReading[T]): bool = r.kind == srRead
func isEmpty*[T](r: ScreenReading[T]): bool = r.kind == srEmpty
func isUnreadable*[T](r: ScreenReading[T]): bool = r.kind == srUnreadable

func describe*[T](r: ScreenReading[T]): string =
  ## A human-facing rendering. Used in failure messages only.
  case r.kind
  of srRead: "read"
  of srEmpty: "empty"
  of srUnreadable:
    "unreadable(" & $r.reason & (if r.detail.len > 0: ": " & r.detail else: "") & ")"

proc `==`*[T](a, b: ScreenReading[T]): bool =
  ## **RAISES when either side is unreadable — this is `LAW-R2`.**
  ##
  ## The killer for `LAW-R2` is to make this return `true` for two
  ## `srUnreadable` values, which is precisely the `PLAT35-VG7` retirement:
  ## two empty answers compared equal, so the question agreed with itself and
  ## a gap was retired against a run that had measured nothing.
  ##
  ## Returning `false` would not be enough either, and the distinction matters:
  ## `false` keeps the comparison RUNNABLE, so `a != b` becomes a true statement
  ## about two things neither of which was seen, and a caller that files a gap
  ## on inequality files a gap it cannot justify. The only honest answer to
  ## "are these two equal" when one was not read is to refuse the question.
  if a.kind == srUnreadable or b.kind == srUnreadable:
    var parts: seq[string]
    if a.kind == srUnreadable: parts.add "left=" & describe(a)
    if b.kind == srUnreadable: parts.add "right=" & describe(b)
    raise newException(UnreadableComparison,
      "refusing to compare an unreadable screen reading: " & parts.join(", ") &
      ". An unreadable reading is not a value; ask isUnreadable() instead.")
  if a.kind != b.kind: return false
  case a.kind
  of srRead: a.value == b.value
  of srEmpty: true
  of srUnreadable: false  # unreachable: guarded above

func sameUnreadable*[T](a, b: ScreenReading[T]): bool =
  ## The EXPLICIT way to ask whether two readings failed the same way.
  ##
  ## This exists so that `==` can refuse without making the question
  ## unaskable. It is deliberately not spelled `==`: a caller has to say that
  ## it means to compare failures, which is the whole difference between
  ## observing "both unreadable" and asserting "both equal".
  a.kind == srUnreadable and b.kind == srUnreadable and a.reason == b.reason

type
  PaneOutcomeCounts* = object
    ## The three-way tally used by `LAW-R1`'s partition.
    read*: int
    empty*: int
    unreadable*: int

func total*(c: PaneOutcomeCounts): int = c.read + c.empty + c.unreadable

func tally*[T](readings: openArray[ScreenReading[T]]): PaneOutcomeCounts =
  for r in readings:
    case r.kind
    of srRead: inc result.read
    of srEmpty: inc result.empty
    of srUnreadable: inc result.unreadable

func reasonHistogram*[T](readings: openArray[ScreenReading[T]]):
    Table[UnreadableReason, int] =
  ## Which reasons were actually emitted. `LAW-R6` asserts this covers the
  ## whole enum across the planted corpus — an unreached reason is an untested
  ## reason.
  result = initTable[UnreadableReason, int]()
  for r in readings:
    if r.kind == srUnreadable:
      result.mgetOrPut(r.reason, 0) += 1

const AllUnreadableReasons* = [
  urFrameMissing, urFrameBlank, urRegionNotLocated,
  urNoWordAboveFloor, urGrammarMismatch]
  ## Spelled out rather than derived with `..`, so that adding a member to the
  ## enum without deciding how it is reached fails to compile here. The suite
  ## asserts `AllUnreadableReasons.len == UnreadableReason.high.ord + 1`, which
  ## catches the opposite mistake — a member added to the enum and to this list
  ## but never planted.
