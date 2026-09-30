## The endpoint contract's codec, graded on both backends.
##
## `Architecture/UI-Bundle-And-Endpoints.md` §6 is the contract. This suite is
## about the two things a codec can get wrong that a reader cannot see:
##
##   1. **A frame that cannot be read must raise on BOTH backends.** The JS
##      backend's `parseJson` defers to V8's `JSON.parse`, which throws a
##      `SyntaxError` that no Nim exception type matches — so a narrow
##      `except CatchableError` catches nothing there and the exception escapes
##      into the renderer. This module decodes bytes from a socket, so that is
##      a crash on the backend the renderer ships on. The suite runs in
##      `vm-unit` (C) and `vm-unit-js` (node) for exactly this reason, and the
##      malformed-input cases below are the ones that differ.
##   2. **A refusal must not be readable as a success.** `PlatformErrorKind`'s
##      zero value is `pkNone`, which means *nothing went wrong*, so a failed
##      reply that omitted its kind would decode into a failure whose kind says
##      there was no failure.
##
## Everything here is pure. No socket, no platform, no facade.

import std/[json, strutils, unittest]

import ../../platform/capabilities
import ../../platform/endpoint_protocol
import ../../platform/outcome

const ExpectedAssertions = 93
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

template raisesProtocolError(body: untyped) =
  inc counted
  var raised = false
  try:
    body
  except ProtocolError:
    raised = true
  except CatchableError:
    raised = false
  check raised

suite "version negotiation — §6.5":
  test "inside the range, and at both edges":
    ck negotiate(1, 1, 1) == negOk
    ck negotiate(2, 1, 3) == negOk
    ck negotiate(1, 1, 3) == negOk
    ck negotiate(3, 1, 3) == negOk

  test "outside it, in the direction that says which side is stale":
    # The two are not interchangeable. `negBundleTooOld` is a cached artifact
    # the user can fix by reloading; `negBundleTooNew` is a deployment that has
    # not been updated, which reloading will not fix.
    ck negotiate(0, 1, 3) == negBundleTooOld
    ck negotiate(4, 1, 3) == negBundleTooNew

  test "the refusal names BOTH numbers":
    let tooOld = negotiationMessage(negBundleTooOld, 1, 2, 5)
    ck tooOld.contains("1")
    ck tooOld.contains("2")
    ck tooOld.contains("5")
    ck tooOld.contains("Reload")
    let tooNew = negotiationMessage(negBundleTooNew, 9, 2, 5)
    ck tooNew.contains("9")
    ck tooNew.contains("2-5")
    # Reloading a bundle that is NEWER than the deployment gets the same
    # bundle back, so the message must not suggest it.
    ck not tooNew.contains("Reload")
    ck negotiationMessage(negOk, 1, 1, 1) == ""

  test "this bundle declares a version at all":
    ck EndpointContractVersion >= 1

suite "hello and welcome":
  test "hello round-trips":
    let text = encodeHello(HelloFrame(contractVersion: EndpointContractVersion))
    ck decodeHello(text).contractVersion == EndpointContractVersion
    ck text.contains("\"kind\":\"hello\"")

  test "welcome carries the profile the SERVER serves — §6.3":
    let text = encodeWelcome(WelcomeFrame(
      contractMin: 1, contractMax: 2, profile: containerProfile,
      deployment: %*{"bundle": "/ui.abc123.js"}))
    let got = decodeWelcome(text)
    ck got.contractMin == 1
    ck got.contractMax == 2
    ck got.profile.kind == pkContainer
    ck got.profile.displayName == containerProfile.displayName
    ck got.profile.capabilities == containerProfile.capabilities
    ck got.profile.degradations.len == containerProfile.degradations.len
    ck got.unknownCapabilities.len == 0
    ck got.deployment{"bundle"}.getStr == "/ui.abc123.js"

  test "every profile the product declares survives the wire":
    # A capability set that did not round-trip would present a narrower or
    # wider platform than the deployment serves, which is the whole defect
    # §5.1 measured — so it is asserted over every profile rather than one.
    for kind in allPlatformKinds:
      let p = profileFor(kind)
      var unknown: seq[string]
      let got = decodeProfile(encodeProfile(p), unknown)
      ck got.capabilities == p.capabilities
      ck got.kind == p.kind
      ck unknown.len == 0

  test "a degradation's SENTENCE survives, not just its capability":
    # It is what the user is shown in place of the missing capability. A codec
    # that carried the set and dropped the explanations would leave the client
    # able to say what it cannot do and not why.
    var unknown: seq[string]
    let got = decodeProfile(encodeProfile(webProfile), unknown)
    var checkedOne = false
    for rule in got.degradations:
      ck rule.behaviour.len > 0
      checkedOne = true
      break
    ck checkedOne

  test "an unknown capability is REPORTED, not silently dropped":
    # Within a negotiated version the two ends agree, so a name arriving here
    # means something is wrong upstream. A client that ignored it would serve a
    # narrower platform than the server does, with nothing saying why.
    let node = encodeProfile(containerProfile)
    node["capabilities"].add(%"capTimeTravel")
    var unknown: seq[string]
    let got = decodeProfile(node, unknown)
    ck unknown == @["capTimeTravel"]
    ck got.capabilities == containerProfile.capabilities

  test "an empty contract range is refused":
    raisesProtocolError:
      discard decodeWelcome($(%*{
        "kind": "welcome", "contractMin": 5, "contractMax": 2,
        "profile": encodeProfile(containerProfile)}))

  test "a platform kind this bundle does not know is refused, not defaulted":
    let node = encodeProfile(containerProfile)
    node["kind"] = %"pkHologram"
    raisesProtocolError:
      var unknown: seq[string]
      discard decodeProfile(node, unknown)

suite "call and reply":
  test "a call round-trips with its arguments":
    let text = encodeCall(CallFrame(
      id: 7, verb: "fs.readText", args: %*{"path": "/a/b.nim"}))
    let got = decodeCall(text)
    ck got.id == 7
    ck got.verb == "fs.readText"
    ck got.args{"path"}.getStr == "/a/b.nim"

  test "an undotted verb is refused — §6.2":
    raisesProtocolError:
      discard decodeCall($(%*{"kind": "call", "id": 1, "verb": "readText",
                              "args": %*{}}))

  test "a successful reply round-trips its payload":
    let got = decodeReply(encodeReply(ReplyFrame(
      id: 7, ok: true, payload: %*{"text": "hello"})))
    ck got.id == 7
    ck got.ok
    ck got.payload{"text"}.getStr == "hello"

  test "a refused reply round-trips its KIND, by name — §6.4":
    for kind in [pkNotFound, pkAccessDenied, pkNotSupported, pkTransport,
                 pkQuotaExceeded, pkCancelled]:
      let got = decodeReply(encodeReply(ReplyFrame(
        id: 1, ok: false, errorKind: kind, errorMessage: "because")))
      ck got.errorKind == kind
      ck not got.ok
    ck decodeReply(encodeReply(ReplyFrame(
      id: 1, ok: false, errorKind: pkNotFound,
      errorMessage: "because"))).errorMessage == "because"

  test "a refusal with NO kind decodes as pkFailed, never as pkNone":
    let got = decodeReply($(%*{"kind": "reply", "id": 1, "ok": false}))
    ck not got.ok
    ck got.errorKind == pkFailed
    ck got.errorKind != pkNone

  test "a refusal naming a kind this bundle does not know is still a refusal":
    let got = decodeReply($(%*{"kind": "reply", "id": 1, "ok": false,
                               "errorKind": "pkSupernova",
                               "errorMessage": "m"}))
    ck not got.ok
    ck got.errorKind == pkFailed
    ck got.errorMessage == "m"

  test "a reply with no 'ok' is refused rather than read as one":
    raisesProtocolError:
      discard decodeReply($(%*{"kind": "reply", "id": 1}))

suite "events — the subscription half of §6.1":
  test "an event round-trips against the handle that subscribed":
    let got = decodeEvent(encodeEvent(EventFrame(
      handle: "watch-3", event: "changed", payload: %*{"path": "/x"})))
    ck got.handle == "watch-3"
    ck got.event == "changed"
    ck got.payload{"path"}.getStr == "/x"

  test "an event with no handle is refused — it would reach no subscriber":
    raisesProtocolError:
      discard decodeEvent($(%*{"kind": "event", "event": "changed"}))

suite "malformed input raises on BOTH backends":
  # These are the cases where the two backends differ, and the reason this
  # suite is in `vm-unit` AND `vm-unit-js`. Under a narrow
  # `except CatchableError` the JS arm would not raise here at all — the
  # `SyntaxError` would escape.
  test "text that is not JSON":
    raisesProtocolError: discard decodeHello("{not json")
    raisesProtocolError: discard decodeWelcome("")
    raisesProtocolError: discard decodeCall("]")
    raisesProtocolError: discard decodeReply("undefined")
    raisesProtocolError: discard decodeEvent("{\"kind\":")

  test "JSON that is not an object":
    raisesProtocolError: discard decodeHello("[1,2,3]")
    raisesProtocolError: discard decodeCall("\"call\"")
    raisesProtocolError: discard decodeReply("42")

  test "a frame of the wrong kind":
    raisesProtocolError:
      discard decodeReply(encodeCall(CallFrame(id: 1, verb: "fs.readText")))
    raisesProtocolError:
      discard decodeWelcome(encodeHello(HelloFrame(contractVersion: 1)))

  test "a frame missing a field it needs":
    raisesProtocolError: discard decodeHello($(%*{"kind": "hello"}))
    raisesProtocolError: discard decodeCall($(%*{"kind": "call", "id": 1}))
    raisesProtocolError:
      discard decodeWelcome($(%*{"kind": "welcome", "contractMin": 1,
                                 "contractMax": 1}))

suite "frameKind tolerates a shared socket — §6.1":
  test "it names a frame":
    ck frameKind(encodeHello(HelloFrame(contractVersion: 1))) == "hello"
    ck frameKind(encodeEvent(EventFrame(handle: "h", event: "e"))) == "event"

  test "and answers empty for anything else, rather than raising":
    # The facade shares one connection with the existing index IPC surface, so
    # a dispatcher sees traffic that is not a frame at all. Raising there would
    # make every unrelated message an error.
    ck frameKind("{not json") == ""
    ck frameKind("[1,2]") == ""
    ck frameKind($(%*{"no": "kind"})) == ""
    ck frameKind($(%*{"kind": 7})) == ""

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
