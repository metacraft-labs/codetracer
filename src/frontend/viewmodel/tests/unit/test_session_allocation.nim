## THE ALLOCATION CALL ASKS THE SUBSTRATE AND DECIDES NOTHING — WD7.
##
## `Architecture/Hosted-Session-Allocation.md` §5's three ☐, from the
## consumer's side, for the halves that are checkable in process. §5's first
## and second verifications also have an OBSERVATIONAL half that this file
## cannot carry and does not pretend to: *"the assertion that makes it mean
## anything is the SUBSTRATE'S view, not the browser's"*, which needs a running
## api-server and `sessionctl list`. **NO SUCH GATE EXISTS YET** -- there is
## no `ci/test/` script that observes an allocation from the substrate's
## side, and this comment named one as though there were. What is here is
## the half that says the request leaving this bundle is the right request
## and the answer coming back is not re-decided; the observational half is
## unbuilt, and the campaign's seam register -- kept with the campaign plan
## that owns it, outside this repository -- carries it as open.
##
## ## MOCK JUSTIFICATION — required by the workspace policy, and short
##
## **There is no mock in this file, and the reason is worth stating because the
## obvious design has one.** `session_allocation.nim` performs no I/O: it
## builds a request value and reads a response string. So the suite drives the
## real module with real values and asserts over the real bytes it produces —
## there is no transport to stand in for, no HTTP server to fake and no
## substrate to stub. The response strings below are not a mock substrate;
## they are the substrate's own `toJson(AllocationView)` shape, copied from the
## substrate's own serialiser at the revision recorded with the workspace, used
## as INPUT to a parser. A test for a parser that did not hand it bytes would be
## testing nothing.
##
## That is also why the I/O lives at one call site in the caller rather than
## inside the module: a module that fetched could only be tested through a
## fake, and then the thing under test would be the fake's fidelity.
##
## ## What each case is a control for
##
## Every property here is paired with the defect that would satisfy a weaker
## version of it, and `run-wd7-session-allocation-mutations.py` beside this
## file plants each one and requires the named case to redden:
##
##   | planted defect | the case that must go red |
##   |---|---|
##   | a flavour allow-list in `allocationRequestFor` | `an unknown flavour is still ASKED, not refused here` |
##   | a refusal-reason allow-list in `readAllocationOutcome` | `a reason this build has never heard of survives byte for byte` |
##   | a local concurrency counter | `two descriptors in a row both produce a request` |
##   | a request for a static project | `a static project produces no request at all` |
##   | `product_id` added to the body | `the body carries the runtime contract and NOT the product` |
##   | refusal branched on the HTTP status | `a refusal is decided by ok, not by the status number` |
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node), discovered by
## `ci/lib/test-lane-files.sh`'s `test_*.nim` sweep over this directory.

import std/[json, options, strutils, unittest]

import ../../platform/session_allocation
# THE CLIENT'S PURE HALVES TOO. `ui/session_allocation_client.nim` carries
# the transport, but two of its three exported non-transport symbols decide
# something a user sees, and review found them with NO coverage at all: the
# descriptor route, and the sentence put in front of a person. It imports
# cleanly here because its non-JS branch supplies stubs that report status 0
# rather than a transport, so there is still no mock in this file.
import ../../../ui/session_allocation_client as client

const ExpectedAssertions = 134
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

# ---------------------------------------------------------------------------
# Fixtures. `sessionFor` is the shape `GET /api/v1/apps/:name/deployment.json`
# serves for a project whose record carries a runtime image — built through
# `decodeDescriptor` rather than by assigning fields, so the suite exercises
# the same path the bundle does and a change to the wire shape fails here.
# ---------------------------------------------------------------------------
proc descriptorJson(projectId, kind: string; imageRef = ""; flavour = ""): string =
  var runtime = %*{"kind": kind}
  if kind == "prkSession":
    runtime["imageRef"] = %imageRef
    runtime["flavour"] = %flavour
  $(%*{
    "session": {"traceId": "", "projectId": projectId, "runtime": runtime},
    "connection": {"frontendSocketPort": -1, "frontendSocketParameters": "",
                   "backendSocketPort": -1}})

proc sessionFor(projectId, imageRef, flavour: string): SessionDescriptor =
  decodeDescriptor(descriptorJson(projectId, "prkSession", imageRef, flavour))

proc staticFor(projectId: string): SessionDescriptor =
  decodeDescriptor(descriptorJson(projectId, "prkStatic"))

# The substrate's own answer shape (`toJson(AllocationView)`).
proc allocationJson(ok: bool; reason = ""; message = ""; sessionId = "";
                    instance = ""; origin = ""; flavour = "";
                    hostname = ""): string =
  $(%*{"ok": ok, "reason": reason, "message": message,
       "session_id": sessionId, "instance": instance, "origin": origin,
       "flavour": flavour, "hostname": hostname,
       "starting_message": "", "waited_ms": 0})

# ---------------------------------------------------------------------------
suite "test_noir_studio_allocates_nothing (the construction half)":
  # §5's second ☐. The OBSERVATIONAL half — the substrate seeing no request —
  # is the integration gate's; this is the reason it will see none, and it is
  # the half a reader of the code can check.

  test "a static project produces no request at all":
    # The positive control is in the same test and the same reader, which is
    # exactly what §5 demands of this one: "a run in which neither arm sees a
    # request is a broken observer reporting a pass".
    let noir = staticFor("noir-studio")
    ck allocationRequestFor(noir).isNone

    let ide = sessionFor("acme-web", "codetracer/host:259138424e8a", "s2")
    ck allocationRequestFor(ide).isSome
    # Said as a comparison rather than as two separate claims, so a change
    # that made BOTH answer `none` cannot satisfy this case.
    ck allocationRequestFor(noir).isSome != allocationRequestFor(ide).isSome

  test "static is the zero value, so a descriptor that says nothing allocates nothing":
    # The whole corpus of projects written before the field existed decodes
    # this way, and that is what keeps the anonymous path untouched.
    let bare = decodeDescriptor("""{"session":{"projectId":"legacy"}}""")
    ck bare.session.runtime.kind == prkStatic
    ck allocationRequestFor(bare).isNone

  test "an absent session group allocates nothing either":
    let empty = decodeDescriptor("{}")
    ck empty.session.runtime.kind == prkStatic
    ck allocationRequestFor(empty).isNone

# ---------------------------------------------------------------------------
suite "the request is the substrate's own surface, and names four of five":
  # §3.1's runtime contract plus the tenancy tuple. The fifth value,
  # `product_id`, is deliberately absent — D-S13.

  let req = allocationRequestFor(
    sessionFor("acme-web", "codetracer/host:259138424e8a", "s2")).get()

  test "it is a POST to the substrate's allocation route for THIS project":
    ck req.verb == "POST"
    ck req.path == "/api/v1/projects/acme-web/sessions"
    # Built from the parts rather than compared to a second hand-written
    # string, so the route cannot drift in one place only.
    ck req.path == AllocationPathPrefix & "acme-web" & AllocationPathSuffix
    ck req.verb == AllocationVerb
    # A GET would be actioned by link prefetch and by every crawler that
    # followed a dashboard, which is the substrate's own stated reason.
    ck req.verb != "GET"

  test "the login cookie travels, because the cookie IS the principal":
    # §3.1's `customer_id`. Without it `requireViewer` answers 401, and the
    # bundle has no principal id to send instead — nor should it.
    ck req.sameOriginCredentials

  test "the body carries the runtime contract and NOT the product":
    let body = parseJson(req.body)
    ck body.kind == JObject
    ck body{"flavour"} != nil
    ck body{"flavour"}.getStr == "s2"
    ck body{"image"} != nil
    ck body{"image"}.getStr == "codetracer/host:259138424e8a"
    # D-S13. Asserted over the KEYS, four spellings, because a body that
    # carried any of them would let this consumer pick which grant it spends
    # against — the cross-subsidy shape `(customer, product)` keying exists to
    # prevent.
    for spelling in ["product_id", "productId", "product", "productID"]:
      ck body{spelling} == nil
    ck not req.body.contains("product")
    # Exactly two fields. A third that crept in would be a request dimension
    # nobody decided; `slot` in particular is a caller's statement that only a
    # caller with several panes open can make.
    ck body.len == 2
    ck body{"slot"} == nil

  test "the pair is READ from the descriptor and not re-derived":
    # §3.1a and WD4's own note: "what it must not add is a second place the
    # front door looks". Two different descriptors must produce two different
    # bodies, and the values must be the descriptor's — a module that
    # defaulted either would pass a single-fixture test.
    let a = allocationRequestFor(sessionFor("p1", "img-a", "s1")).get()
    let b = allocationRequestFor(sessionFor("p2", "img-b", "h4")).get()
    ck parseJson(a.body){"image"}.getStr == "img-a"
    ck parseJson(a.body){"flavour"}.getStr == "s1"
    ck parseJson(b.body){"image"}.getStr == "img-b"
    ck parseJson(b.body){"flavour"}.getStr == "h4"
    ck a.path != b.path
    ck a.body != b.body

  test "a session runtime with no project id is refused before it is sent":
    # `/api/v1/projects//sessions` splits to an empty `parts[4]` at the
    # substrate and addresses a project named "". The same argument
    # `decodeRuntime` makes about an empty image reference: the failure
    # presented as a working request is the expensive one.
    var d = sessionFor("placeholder", "img", "s1")
    d.session.projectId = ""
    expect DescriptorError:
      discard allocationRequestFor(d)

# ---------------------------------------------------------------------------
suite "test_a_refusal_is_surfaced_not_re-derived — nothing is decided here":
  # §5's third ☐, and §3.2's "CodeTracer surfaces the reason; it does not
  # re-derive the decision".

  test "all six of §3.2's reasons survive byte for byte, with their status":
    for reason in ["concurrency", "budget", "flavour_not_allowed",
                   "snapshot_expired", "not_entitled", "unknown_image"]:
      let o = readAllocationOutcome(
        402, allocationJson(false, reason, "the substrate said " & reason))
      ck o.status == asRefused
      ck o.reason == reason
      ck o.message == "the substrate said " & reason
      # WD4 passes refusals through WITH their status; the two halves have to
      # agree about what the status was.
      ck o.httpStatus == 402
      # And the text a person reads carries the substrate's words, not a
      # translation of them.
      ck allocationFailureText(o).contains(reason)

  test "a reason this build has never heard of survives byte for byte":
    # THE CASE AN ALLOW-LIST FAILS. Every assertion above is satisfied by a
    # module carrying a list of the six; this one is not. The nonce is
    # deliberately not a word that appears honestly anywhere in the tree.
    const invented = "wd7q_reason_7f3a1c"
    let o = readAllocationOutcome(402, allocationJson(false, invented, "x"))
    ck o.status == asRefused
    ck o.reason == invented
    ck allocationFailureText(o).contains(invented)
    # Not collapsed into a generic word either.
    ck not allocationFailureText(o).contains("unavailable")
    ck not allocationFailureText(o).contains("unknown refusal")

  test "an unknown flavour is still ASKED, not refused here":
    # A CodeTracer-side flavour allow-list is one of the three admission checks
    # §3.2 names, and `admit` is what refuses a flavour this principal is not
    # entitled to. So a flavour no catalogue row mentions must still produce a
    # request.
    for flavour in ["h99", "", "s2048", "wd7q_flavour_5d20ab"]:
      let d = sessionFor("acme-web", "codetracer/host:abc", flavour)
      let r = allocationRequestFor(d)
      ck r.isSome
      ck parseJson(r.get().body){"flavour"}.getStr == flavour

  test "an image reference that looks unpublished is still ASKED":
    # `unknown_image` is the substrate's refusal and the producer pipeline's
    # tell. Guessing it here is how "the image was never published" becomes an
    # hour of debugging the substrate.
    for image in ["nope:does-not-exist", "wd7q_image_9b41ef", "   "]:
      let d = sessionFor("acme-web", image, "s2")
      let r = allocationRequestFor(d)
      ck r.isSome
      ck parseJson(r.get().body){"image"}.getStr == image

  test "two descriptors in a row both produce a request":
    # A local concurrency counter is the second of §3.2's three, and it would
    # pass every single-request case above. `session.concurrent` is the
    # substrate's grant, enforced per `(customer_id, product_id)`.
    #
    # TWO THOUSAND, and the number is load-bearing rather than enthusiastic.
    # A lease counter is global state, so a counter with a small limit would
    # trip on whichever case happened to ask first and this arm would grade a
    # case it does not name — which is what
    # `run-wd7-session-allocation-mutations.py` reports as MISDIRECTED, and
    # what it did report while this loop asked five times. The arm's limit is
    # set above anything the rest of this file does and below this loop, so
    # the arm is THIS case's and the suite may grow without re-tuning it.
    # Counted rather than checked per iteration, so the tally stays a constant.
    var asked = 0
    let d = sessionFor("acme-web", "codetracer/host:abc", "s2")
    for i in 0 ..< 2000:
      if allocationRequestFor(d).isSome: inc asked
    ck asked == 2000
    # And two DIFFERENT projects, in case a counter were keyed per project.
    ck allocationRequestFor(sessionFor("p1", "i", "s1")).isSome
    ck allocationRequestFor(sessionFor("p2", "i", "s1")).isSome

  test "an entitlement verdict is never produced locally":
    # The third of §3.2's three. `not_entitled` must only ever arrive from the
    # substrate, so the module must have no way to emit it: the only outcome
    # reachable without a substrate answer is `asUnreachable`, which carries
    # no reason at all.
    let o = readAllocationOutcome(0, "")
    ck o.status == asUnreachable
    ck o.reason.len == 0
    ck not allocationFailureText(o).contains("not_entitled")
    ck not allocationFailureText(o).contains("budget")

  test "a refusal is decided by ok, not by the status number":
    # A module that branched on the status would read a second refusal status
    # the substrate learns to send as a SUCCESS with an empty session id.
    let refusedAt200 = readAllocationOutcome(
      200, allocationJson(false, "budget", "out of budget"))
    ck refusedAt200.status == asRefused
    ck refusedAt200.reason == "budget"
    let refusedAt409 = readAllocationOutcome(
      409, allocationJson(false, "concurrency", "two already"))
    ck refusedAt409.status == asRefused
    ck refusedAt409.reason == "concurrency"
    let allocatedAt402 = readAllocationOutcome(
      402, allocationJson(true, "", "", "s-1", "i-1", "new", "s2"))
    ck allocatedAt402.status == asAllocated

# ---------------------------------------------------------------------------
suite "an allocation is carried, and reuse is not a second case":
  test "the substrate's identifiers arrive unaltered":
    let o = readAllocationOutcome(200, allocationJson(
      true, "", "", "sess-7f3a", "wd7q-instance", "new", "s2",
      "sess-7f3a.sessions.example.test"))
    ck o.status == asAllocated
    ck o.sessionId == "sess-7f3a"
    ck o.instance == "wd7q-instance"
    ck o.origin == "new"
    ck o.hostname == "sess-7f3a.sessions.example.test"
    ck allocationFailureText(o).len == 0

  test "reuse is an allocation, and the substrate says which it was":
    # "Opening a project twice must not start two containers and must not bill
    # two leases." A consumer that treated `existing` as a different case
    # would be re-deciding something already decided.
    let o = readAllocationOutcome(200, allocationJson(
      true, "", "", "sess-7f3a", "wd7q-instance", "existing", "s2"))
    ck o.status == asAllocated
    ck o.origin == "existing"

  test "the ALLOCATED flavour is the substrate's to state":
    # It need not be what was asked for.
    let o = readAllocationOutcome(200, allocationJson(
      true, "", "", "s", "i", "new", "s1"))
    ck o.flavour == "s1"

# ---------------------------------------------------------------------------
suite "unreachable is not a refusal":
  test "a body that will not parse carries no reason":
    for body in ["<html>502 Bad Gateway</html>", "", "   ", "not json at all"]:
      let o = readAllocationOutcome(502, body)
      ck o.status == asUnreachable
      ck o.reason.len == 0
      ck allocationFailureText(o).contains("did not answer")

  test "JSON that is not an allocation verdict is unreachable, not refused":
    # A proxy's own JSON error, or a route that answered something else. There
    # is no reason to surface, so inventing one would be the defect.
    let o = readAllocationOutcome(500, """{"error":"upstream"}""")
    ck o.status == asUnreachable
    ck o.reason.len == 0

  test "a JSON array is not an allocation verdict":
    let o = readAllocationOutcome(200, "[]")
    ck o.status == asUnreachable

  test "the status seen is reported, so the two halves can agree":
    let o = readAllocationOutcome(503, "")
    ck o.httpStatus == 503
    ck allocationFailureText(o).contains("503")

# ---------------------------------------------------------------------------
suite "the request path's own pure halves (review: these had no coverage)":
  # `startSessionForProject` sequences two calls and is transport; these two are
  # not, and both decide something observable. Neither was asserted anywhere
  # before this suite -- the 118 assertions above are all on the module, and a
  # typo in either of these fails SILENTLY, which is the worse half.

  test "the descriptor route is WD4's, built from its two named parts":
    # A typo here means the descriptor never arrives, and a descriptor that does
    # not arrive is reported as `asked: false` -- indistinguishable from a static
    # project. So nothing allocates and nothing says why.
    ck client.descriptorPathFor("acme-web") ==
      "/api/v1/apps/acme-web/deployment.json"
    ck client.descriptorPathFor("acme-web") ==
      client.DescriptorPathPrefix & "acme-web" & client.DescriptorPathSuffix
    # Same-origin and absolute-from-root, like the allocation route: the front
    # door routes `/api/v1` to `API_ORIGIN`, so the bundle names no host.
    ck client.descriptorPathFor("p").startsWith("/api/v1/")
    ck not client.descriptorPathFor("p").contains("://")
    ck not allocationPathFor("p").contains("://")

  test "a project that was never asked is told nothing":
    # `asked: false` is a static project, a descriptor that did not arrive, and
    # a descriptor this build cannot read. None of them is a refusal, so none of
    # them may produce a sentence -- least of all one about entitlement.
    var s: client.SessionStart
    ck not s.asked
    ck client.sessionStartFailureText(s).len == 0

  test "an allocation says nothing either":
    let s = client.SessionStart(asked: true, outcome: readAllocationOutcome(
      200, allocationJson(true, "", "", "s-1", "i-1", "new", "s2")))
    ck s.outcome.status == asAllocated
    ck client.sessionStartFailureText(s).len == 0

  test "a refusal reaches the person in the SUBSTRATE'S words":
    # §5's third verification, at the one place a person actually reads it. The
    # reason and the message must both survive into the sentence; a `case` over
    # reasons here would be the second vocabulary §3.2 forbids.
    let s = client.SessionStart(asked: true, outcome: readAllocationOutcome(
      402, allocationJson(false, "unknown_image",
                          "no image 'codetracer/host:259138424e8a'")))
    let text = client.sessionStartFailureText(s)
    ck text.contains("unknown_image")
    ck text.contains("no image 'codetracer/host:259138424e8a'")
    # And a reason this build has never heard of, for the same reason the module
    # is tested with one: an allow-list anywhere on this path would collapse it.
    let q = client.SessionStart(asked: true, outcome: readAllocationOutcome(
      402, allocationJson(false, "wd7q_reason_7f3a1c", "a reason from the future")))
    ck client.sessionStartFailureText(q).contains("wd7q_reason_7f3a1c")

  test "an unreachable substrate is never reported as a refusal to the person":
    # The sentence a developer on a machine without the substrate sees must not
    # say their plan is exhausted.
    let s = client.SessionStart(asked: true, outcome: readAllocationOutcome(0, ""))
    let text = client.sessionStartFailureText(s)
    ck s.outcome.status == asUnreachable
    ck text.contains("did not answer")
    ck not text.contains("not_entitled")
    ck not text.contains("budget")

# ---------------------------------------------------------------------------
suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
