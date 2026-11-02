## sdk/scrub_queue.nim — the scrubber's request queue: which seek to send,
## and when.
##
## Moved here from BlockTracer (`client/src/debugger/scrub_queue.nim`,
## Shared-DOM-Front-Ends D8: "what BlockTracer does well moves upstream"), so
## every front-end that drives a scrubber over a slow engine coalesces its seeks
## by the same rule. It is pure data: no ViewModel, no clock, no transport.
##
## ## Why this is a module and not four fields in a host
##
## Dragging the trace scrubber issues `ct/goto-ticks` while the pointer is
## still down, and the engine cannot answer as fast as a pointer reports:
## measured, the demo recording answers a seek in a median of 46 ms over 127
## seeks while a pointer reports every 8–16 ms, and a real chain capture takes
## about 2.1 s. So the requests have to be **coalesced**, and the rule is that
## at most one is outstanding and a newer target SUPERSEDES the one waiting
## rather than queueing behind it — a throttle clocked by the engine instead of
## by an interval that would have to be guessed and would be wrong on one of
## those two recordings whatever it was.
##
## That rule is four lines of state and it is the single easiest place in this
## feature to be subtly wrong, because being wrong looks exactly like being
## right. The failure is not a dead control: it is a drag that ends on a
## position the visitor merely dragged THROUGH. The handle tracked, the mark
## moved, the panes updated, the session settled — and it settled in the wrong
## place, once, some of the time.
##
## IT SHIPPED IN THE FIRST DRAFT OF THIS FEATURE. A drag released at step 1052
## put 1052 on the wire and then, a moment later, 707; the session finished at
## 707. And the browser-level gate written to catch it could not: reproducing
## it needs a pointer move to land after the in-flight slot is released and
## before the deferred send, a window one microtask drain wide, and across two
## dozen chances in a full journey run no real pointer move landed there. The
## mutation arm SURVIVED. An arm that reproduces its own defect only sometimes
## is a coin, not evidence.
##
## So the logic lives here, where it is ordinary data with no browser, no
## worker and no clock in front of it, and `tests/unit/test_scrub_queue.nim`
## states the orderings directly — including the exact one above, which is six
## lines and cannot be flaky. A host keeps the DOM and the transport and owns
## no part of the decision.

type
  ScrubQueue* = object
    ## At most one seek outstanding, and at most one waiting behind it.
    inFlight*: bool
      ## A request has been sent and its answer has not arrived.
    sent*: int
      ## The step that outstanding request asked for. Kept after it settles, so
      ## `drain` can tell "the visitor wants somewhere new" from "the visitor
      ## wants exactly where we already are".
    pending*: int
      ## The newest step asked for that has NOT been sent, or 0 for none.
      ##
      ## ONE SLOT AND NOT A QUEUE, deliberately: every position between the
      ## last request and the newest one is somewhere the pointer has already
      ## left, and seeking to each in turn would replay the drag at the
      ## engine's speed after the hand had stopped. Superseding is the point —
      ## what a scrub asks for is where the pointer IS.

func request*(q: var ScrubQueue; step: int): int =
  ## The visitor is asking for `step`. Returns the step to SEND NOW, or 0.
  ##
  ## A step of 0 or less is not a position: `positioned` is `step > 0`, so
  ## seeking there would ask the session to report that it has none.
  if step <= 0: return 0
  if q.inFlight:
    # CLEARED, not set, when the ask matches what is already on its way. There
    # is nothing left to do, and leaving it pending would send the same seek
    # twice for a drag that paused on a tick it had already reached.
    #
    # This line is half of the defect described in the module comment, and the
    # half that is easy to miss: with `if step != sent: pending = step` instead,
    # a release that lands on the step already in flight writes NOTHING — so a
    # stale target sitting in the slot survives the commit that was supposed to
    # overwrite it, and is issued after the gesture is over.
    q.pending = (if step == q.sent: 0 else: step)
    return 0
  q.inFlight = true
  q.sent = step
  q.pending = 0
  step

func settled*(q: var ScrubQueue) =
  ## The outstanding request has been answered — or refused, or errored.
  ##
  ## It frees the slot and DECIDES NOTHING. Both outcomes come here, because
  ## this is what releases the slot: a hook that ran only on success would wedge
  ## it closed on the first refusal and leave the rest of a drag painting a
  ## handle the session never followed.
  q.inFlight = false

func drain*(q: var ScrubQueue): int =
  ## What to send now that the slot is free. Returns the step, or 0.
  ##
  ## SEPARATE FROM `settled`, AND THAT SEPARATION IS THE WHOLE MODULE. The send
  ## cannot happen inside the answer's own callback — it would re-enter the
  ## transport mid-settle — so there is unavoidably a gap between freeing the
  ## slot and filling it again, and `hydrate.nim` spends that gap in a
  ## `setTimeout`.
  ##
  ## Anything the visitor does during that gap must WIN. So this reads the
  ## pending slot at the moment it runs and takes no target of its own: the
  ## version that captured one when the answer arrived re-sent it afterwards,
  ## overwriting a newer target that a faster pointer move had already put on
  ## the wire. `test_scrub_queue.nim`'s fourth case is that ordering, and its
  ## MUTATION BITE case is the captured-target variant failing it.
  ## There is deliberately NO "unless it is where we already are" test here.
  ## The first version had one — `nxt != sent` — and mutating it away changed
  ## no behaviour and reddened nothing, because it cannot fire: `pending` is
  ## only ever written by `request` on the branch where it differs from `sent`,
  ## and `sent` only changes on the branch that clears `pending`. So a non-zero
  ## `pending` is never equal to `sent`, and the guard was an untestable claim
  ## about a state the object cannot be in. `test_scrub_queue` asserts the
  ## invariant across a sixty-move drag instead, which is the honest form of
  ## the same statement — and one that fails if the invariant ever stops
  ## holding, which the guard would have quietly covered up.
  if q.inFlight: return 0
  let nxt = q.pending
  q.pending = 0
  if nxt > 0: q.request(nxt) else: 0
