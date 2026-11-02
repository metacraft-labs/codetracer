## The scrubber's coalescing rule, stated as orderings rather than as a race.
##
## Moved with `sdk/scrub_queue.nim` from BlockTracer.
##
## WHY THIS SUITE EXISTS, AND WHY IT IS NOT A BROWSER TEST
## -------------------------------------------------------
## BlockTracer's journey 12 drives a real drag in a real browser and asserts the two things
## that make the control a scrubber: the handle tracks the pointer, and the
## session ends where the pointer was released. It is the right gate for the
## gesture and it cannot be the gate for THIS.
##
## The defect this file is written against is a drag that finishes on a
## position the visitor merely dragged THROUGH — a target decided when an
## earlier seek settled, issued after a newer one had already gone out. It
## shipped in the first draft of the drag: released at step 1052, the wire
## carried 1052 and then 707, and the session finished at 707.
##
## Reproducing it in a browser needs a pointer move to arrive after the
## in-flight slot is released and before the deferred send — a window one
## microtask drain wide. A mutation arm aimed at it SURVIVED a full journey
## run, because across roughly two dozen chances no pointer move happened to
## land there; a later attempt to force the window with injected events
## reproduced the stale request but not the stale RESTING PLACE, because the
## engine's own latency varies by a factor of twenty between the demo
## recording and a real chain capture. An arm that reproduces its own defect
## only sometimes is a coin, not evidence.
##
## `scrub_queue` exists so the rule can be stated as data. Every case below is
## an explicit sequence of calls with no clock in it, so the ordering that took
## two days to catch in a browser is six lines here and cannot be flaky.
##
## COUNTED, AND THE COUNT ASSERTED. Each suite ends by checking how many cases
## it ran, because a `for` that skipped or a `check` that was never reached
## shortens a run without failing it.

import std/unittest

import sdk/scrub_queue

# `std/unittest` has no assertion counter, so a case that returned early — or a
# sequence shorter than its author believed — passes by making FEWER checks
# rather than by failing one. Same device as `test_instruction_listing.nim`:
# every check goes through `ck`, and each suite ends by asserting how many have
# run in total. The numbers are cumulative across suites, in file order.
var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

suite "1 — one request at a time, and the newest wins":
  test "the first ask goes straight out, and the rest coalesce behind it":
    var q: ScrubQueue
    ck q.request(26) == 26        # nothing in flight: send now
    ck q.inFlight
    ck q.request(104) == 0        # in flight: wait
    ck q.request(259) == 0        # and the newer ask REPLACES the waiting one
    ck q.pending == 259
    # Not a queue. 104 is somewhere the pointer has already left, and replaying
    # it later is the behaviour this object exists to prevent.
    q.settled()
    ck q.drain() == 259
    ck q.drain() == 0             # nothing left to want

  test "an ask that matches the request in flight CLEARS the slot":
    ## The other half of the shipped defect, and the half that is easy to miss.
    ## With `if step != sent: pending = step` instead, a release landing on the
    ## step already in flight writes nothing — so a stale target sitting in the
    ## slot survives the commit that was supposed to overwrite it.
    var q: ScrubQueue
    ck q.request(259) == 259
    ck q.request(104) == 0
    ck q.pending == 104           # a stale target is waiting
    ck q.request(259) == 0        # the release commits the step in flight
    ck q.pending == 0             # AND WIPES THE STALE ONE
    q.settled()
    ck q.drain() == 0             # so nothing goes back to 104

  test "a step that is not a position is never asked for":
    var q: ScrubQueue
    ck q.request(0) == 0
    ck q.request(-3) == 0
    ck not q.inFlight

  test "assertion count":
    expectCount(16)

suite "2 — the gesture ends where it was released":
  test "THE SHIPPED DEFECT, as an ordering: press, drag, release":
    ## The exact sequence that finished at 707. Read it as the drag it is:
    ## press at 26, drag through 104, an answer lands, the pointer reaches 259,
    ## let go there.
    var q: ScrubQueue
    ck q.request(26) == 26        # press
    ck q.request(104) == 0        # dragged through here
    q.settled()                      # the press seek is answered...
    # ...and BEFORE the deferred send runs, the pointer reaches the end. The
    # slot is free, so this goes out immediately.
    ck q.request(259) == 259
    # Now the deferred send finally runs. It must find nothing to do — 104 was
    # superseded while it was waiting its turn.
    ck q.drain() == 0
    ck q.request(259) == 0        # the release commits the same step
    q.settled()
    ck q.drain() == 0             # and the gesture is over, AT 259
    ck q.sent == 259

  test "MUTATION BITE: a drain handed its target re-sends the dragged-through step":
    ## The defective variant, written out, so the case above is known to be
    ## about something. `capturedDrain` is what `settled` used to do: decide
    ## what to send next AT THE MOMENT THE ANSWER ARRIVED, and send it later.
    var q: ScrubQueue
    func capturedDrain(q: var ScrubQueue): int =
      ## The old `settled` + deferred send, in one call: capture now, send later.
      q.inFlight = false
      let nxt = q.pending
      q.pending = 0
      nxt
    ck q.request(26) == 26
    ck q.request(104) == 0
    let captured = capturedDrain(q)  # decides 104 while the pointer is elsewhere
    ck captured == 104
    ck q.request(259) == 259      # the pointer reaches the end and it goes out
    # And here is the defect: the captured target is issued AFTER 259, so the
    # gesture ends at a position the visitor dragged straight through.
    ck captured != 259
    ck q.request(captured) == 0
    ck q.pending == 104           # queued behind 259, and it will be sent
    q.settled()
    ck q.drain() == 104           # ← the session ends HERE, not at 259
    # The shipping object cannot produce this: `drain` reads the slot when it
    # runs, and by then 104 is gone. That is suite 2's first case.

  test "a refused or errored answer still frees the slot":
    ## `settled` is called on BOTH outcomes. A hook that ran only on success
    ## would wedge the slot closed on the first refusal and leave the rest of a
    ## drag painting a handle the session never followed.
    var q: ScrubQueue
    ck q.request(26) == 26
    ck q.request(104) == 0
    q.settled()                      # the engine refused; the slot is free
    ck q.drain() == 104           # and the drag carries on

  test "a drag that pauses on the step already in flight sends nothing twice":
    var q: ScrubQueue
    ck q.request(100) == 100
    ck q.request(100) == 0
    q.settled()
    ck q.drain() == 0
    ck q.sent == 100

  test "assertion count":
    expectCount(38)

suite "3 — a long drag issues one seek per answer, not one per move":
  test "sixty pointer positions against three answers":
    ## The throttle's whole claim, counted. A pointer reports 60–120 times a
    ## second; the demo recording answers a seek in a median of 46 ms and a real
    ## chain capture in about 2.1 s. What must NOT happen is one request per
    ## move, and what must also not happen is a request for a position the
    ## pointer left long ago.
    var q: ScrubQueue
    var sent: seq[int] = @[]
    var step = 0
    proc ask(s: int) =
      let issued = q.request(s)
      if issued > 0: sent.add issued
    proc answer() =
      q.settled()
      let issued = q.drain()
      if issued > 0: sent.add issued

    # THE INVARIANT `drain` RELIES ON, checked at every point in the drag: a
    # waiting target is never the one already in flight. `drain` used to carry
    # a guard against that case; mutating the guard away reddened nothing,
    # because the object cannot reach the state it guarded. Asserting the
    # invariant is the same claim made falsifiable — if a future edit lets
    # `pending` equal `sent`, this fails here rather than being absorbed by a
    # branch nobody can reach.
    proc invariantHolds(): bool =
      q.pending == 0 or q.pending != q.sent

    for i in 1 .. 60:
      step = i * 10
      ask(step)
      ck invariantHolds()
      if i mod 20 == 0: answer()     # three answers over sixty moves
    # The release: the visitor lets go at the last position reached.
    ask(step)
    answer()

    # EXACTLY four, not "fewer than sixty". The size is knowable — one send
    # per answer plus the press — and where it is knowable a bound is the
    # weaker verb: `<= 5` is satisfied by a queue that sent only the press and
    # dropped the rest of the drag on the floor.
    ck sent.len == 4
    ck sent[0] == 10              # the press went out immediately
    ck sent[^1] == 600            # and the gesture ENDS where it was released
    # Every request is for a position at least as new as the one before it.
    for i in 1 ..< sent.len:
      ck sent[i] > sent[i - 1]

  test "assertion count":
    expectCount(104)
