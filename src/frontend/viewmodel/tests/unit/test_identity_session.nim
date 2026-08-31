## Headless tests for the identity session — ID1's refresh client and
## revocation transport.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_identity_session.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_identity_session.nim
##
## ## What this suite is actually defending
##
## `token.nim` cannot reach a network because nothing it can see is a network.
## `session.nim` CAN — it holds the transport — so the property stops being
## structural and starts needing evidence. That evidence is a call count.
##
## Every fake transport below increments a counter per operation, and the
## assertions read the counters rather than the return values. A session that
## renewed correctly and *also* polled in the normal band would satisfy every
## status check in this file; only the count catches it, which is the same
## reason `test_platform_wasm_modules.nim`'s fake host records a `HostLog`
## instead of trusting `ok`.
##
## The sharpest case is `the normal band makes no network call at all`. It is
## §3.3.1a's first row — "No network required, no renewal attempted" — and it
## is the sentence that makes a debugger work on a plane for the first
## sixteen days of a thirty-day token. It is asserted as **zero**, not as
## "fewer than the others".

import std/[unittest, strutils]

import ../../platform/outcome
import ../../identity/session

# ---------------------------------------------------------------------------
# Counted assertions.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 106
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Awaiting a facade future. The `onComplete` + `drainPlatformCallbacks` +
# `doAssert settled` shape is the one every async ViewModel suite uses, and the
# `doAssert` matters: a future that never settles must abort the run loudly
# rather than leave the case asserting over a default-constructed value.
# ---------------------------------------------------------------------------
proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  var captured: PlatformOutcome[T]
  var settled = false
  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true
  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true
  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "an identity future never settled"
  captured

# ---------------------------------------------------------------------------
# Fixtures. The issuer is written out by hand, as in test_identity_token.nim,
# so that a parser that stopped reading a field could not make the two agree.
# ---------------------------------------------------------------------------
const
  TestKeyId = "ct-identity-2026-08"
  Subject = "acct_01HQ8Z3K"
  T0 = 1_787_875_200'i64

proc fakeSign(message: openArray[byte]): seq[byte] =
  result = newSeq[byte](SignatureLen)
  var acc: uint32 = 0x9E37_79B9'u32
  for b in message:
    acc = (acc xor uint32(b)) * 16_777_619'u32
  for i in 0 ..< SignatureLen:
    acc = (acc xor uint32(i)) * 16_777_619'u32
    result[i] = byte((acc shr 13) and 0xFF'u32)

proc encodeToken(payload: string; corruptSignature = false): seq[byte] =
  result = @[]
  for c in IdentityMagic:
    result.add byte(c)
  let declared = uint32(payload.len)
  result.add byte(declared and 0xFF'u32)
  result.add byte((declared shr 8) and 0xFF'u32)
  result.add byte((declared shr 16) and 0xFF'u32)
  result.add byte((declared shr 24) and 0xFF'u32)
  for c in payload:
    result.add byte(c)
  var sig = fakeSign(result)
  if corruptSignature:
    sig[0] = byte((uint32(sig[0]) + 1'u32) and 0xFF'u32)
  result.add sig

proc tokenPayload(expiresAt = T0 + DefaultLicensePeriod;
                  issuedAt = T0; keyId = TestKeyId;
                  subject = Subject): string =
  let renewAfter = expiresAt - DefaultRenewLead
  let warnAfter = expiresAt - DefaultWarnLead
  "{\"sub\":\"" & subject & "\",\"key_id\":\"" & keyId &
    "\",\"issued_at\":" & $issuedAt &
    ",\"renew_after\":" & $renewAfter &
    ",\"warn_after\":" & $warnAfter &
    ",\"expires_at\":" & $expiresAt &
    ",\"entitlements\":[\"replay:unlimited\"]}"

proc goodToken(expiresAt = T0 + DefaultLicensePeriod): seq[byte] =
  encodeToken(tokenPayload(expiresAt = expiresAt))

proc renewedTokenAt(now: int64): seq[byte] =
  ## A token the issuer would mint AT `now` — issued then, expiring one full
  ## LICENSE_PERIOD later.
  ##
  ## Written because the first version of this fixture handed the refresh a
  ## token that kept the ORIGINAL `issued_at` and pushed `expires_at` out, so
  ## its period was 46 days against a published default of 30. `admit` refused
  ## it as an unrecorded per-account exception — correctly — and the case read
  ## as a missing signature check. The fixture was wrong and the rule was
  ## right, which is the only reason this comment exists: a renewal is a NEW
  ## token, not the old one with a later expiry.
  encodeToken(tokenPayload(issuedAt = now, expiresAt = now + DefaultLicensePeriod))

type
  TransportLog = ref object
    ## What the session actually ASKED for. Assertions read this rather than
    ## the outcomes: a session that renewed correctly and also polled in the
    ## normal band satisfies every status check and fails only on a count.
    tokenFetches: int
    revocationFetches: int
    signatureChecks: int
    keyIdsSeen: seq[string]

proc fakeTransport(log: TransportLog; knownKey = TestKeyId;
                   issuedToken: seq[byte] = @[];
                   revoked: seq[string] = @[];
                   revocationsAt = T0;
                   tokenFetchFails = false): IdentityTransport =
  IdentityTransport(
    fetchToken: proc(): auto =
      log.tokenFetches = log.tokenFetches + 1
      if tokenFetchFails:
        resolvedErr[seq[byte]](pkTransport, "no network")
      else:
        resolvedOk(issuedToken),
    fetchRevocations: proc(): auto =
      log.revocationFetches = log.revocationFetches + 1
      resolvedOk(RevocationList(subjects: revoked, obtainedAt: revocationsAt)),
    verifySignature: proc(keyId: string; message: seq[byte];
                          signature: seq[byte]): auto =
      log.signatureChecks = log.signatureChecks + 1
      log.keyIdsSeen.add keyId
      let expected = fakeSign(message)
      var ok = keyId == knownKey and expected.len == signature.len
      if ok:
        for i in 0 ..< expected.len:
          if expected[i] != signature[i]:
            ok = false
      resolvedOk(ok))

proc newSession(log: TransportLog; pinned: seq[string] = @[TestKeyId];
                knownKey = TestKeyId; issuedToken: seq[byte] = @[];
                revoked: seq[string] = @[];
                tokenFetchFails = false): IdentitySession =
  newIdentitySession(
    fakeTransport(log, knownKey = knownKey, issuedToken = issuedToken,
                  revoked = revoked, tokenFetchFails = tokenFetchFails),
    pinned, defaultWindowPolicy())

suite "identity session (ID1)":

  # -------------------------------------------------------------------------
  test "admission checks the signature exactly once, and only after inspection":
    let log = TransportLog()
    let s = newSession(log)
    counted s.tokenFetches == 0
    counted s.signatureChecks == 0
    counted not s.hasToken()

    let outcome = awaitOutcome(s.admit(goodToken(), T0))
    counted outcome.isOk
    counted outcome.value.kind == dkAccepted
    counted outcome.value.band == ibNormal
    counted outcome.value.claims.subject == Subject
    counted s.hasToken()
    # Exactly one signature check, and it named the token's key.
    counted log.signatureChecks == 1
    counted log.keyIdsSeen.len == 1
    counted log.keyIdsSeen[0] == TestKeyId
    # Admission is not a token fetch. A session handed a token must not go and
    # ask for another one.
    counted log.tokenFetches == 0
    counted log.revocationFetches == 0

    # The paired REJECTION over the same bytes.
    let log2 = TransportLog()
    let s2 = newSession(log2)
    let bad = awaitOutcome(s2.admit(encodeToken(tokenPayload(),
                                                corruptSignature = true), T0))
    counted bad.isOk
    counted bad.value.kind == dkBadSignature
    counted bad.value.claims.subject.len == 0
    counted not s2.hasToken()
    counted log2.signatureChecks == 1

  # -------------------------------------------------------------------------
  test "a token that fails inspection never becomes a network event":
    ## A malformed container is answerable without asking anybody, and spending
    ## a signature check on it would make attacker-shaped input a way to drive
    ## traffic through the transport.
    let log = TransportLog()
    let s = newSession(log)

    let junk = awaitOutcome(s.admit(@[byte(1), 2, 3], T0))
    counted junk.isOk
    counted junk.value.kind == dkMalformed
    counted log.signatureChecks == 0

    let notJson = awaitOutcome(s.admit(encodeToken("not json at all {{"), T0))
    counted notJson.value.kind == dkMalformed
    counted log.signatureChecks == 0

    # An unknown key id is likewise answerable locally: the build knows which
    # keys it pins without asking.
    let rotated = awaitOutcome(
      s.admit(encodeToken(tokenPayload(keyId = "ct-identity-2026-11")), T0))
    counted rotated.value.kind == dkUnknownKeyId
    counted rotated.value.detail.contains("ct-identity-2026-11")
    counted log.signatureChecks == 0
    counted log.tokenFetches == 0
    counted not s.hasToken()

    # The positive twin: the same session, a good token, DOES reach the
    # transport. Without it, "signatureChecks == 0" would also be satisfied by
    # a transport that was never wired up.
    counted awaitOutcome(s.admit(goodToken(), T0)).value.kind == dkAccepted
    counted log.signatureChecks == 1

  # -------------------------------------------------------------------------
  test "the normal band makes no network call at all":
    ## §3.3.1a row 1: "Normal operation. No network required, no renewal
    ## attempted." Asserted as ZERO, not as "fewer than the others".
    let log = TransportLog()
    let s = newSession(log, issuedToken = goodToken())
    discard awaitOutcome(s.admit(goodToken(), T0))
    let baseline = log.signatureChecks
    counted baseline == 1

    counted s.plan(T0) == raNone
    let r = awaitOutcome(s.refresh(T0))
    counted r.isOk
    counted r.value == raNone
    counted log.tokenFetches == 0
    counted log.revocationFetches == 0
    counted log.signatureChecks == baseline
    counted s.tokenFetches == 0

    # Ten refreshes across the whole normal band, still zero.
    var sampled = 0
    let renewAfter = T0 + DefaultLicensePeriod - DefaultRenewLead
    for i in 0 ..< 10:
      inc sampled
      let at = T0 + ((renewAfter - T0) * i.int64) div 10
      counted awaitOutcome(s.refresh(at)).value == raNone
    counted sampled == 10
    counted log.tokenFetches == 0

    # And `decide` is pure: a hundred entitlement questions, no calls.
    var decisions = 0
    for i in 0 ..< 100:
      inc decisions
      discard s.decide(T0 + i.int64)
    counted decisions == 100
    counted log.tokenFetches == 0
    counted log.signatureChecks == baseline

  # -------------------------------------------------------------------------
  test "the renewing band refreshes silently and the warning band visibly":
    let expiresAt = T0 + DefaultLicensePeriod
    let renewAfter = expiresAt - DefaultRenewLead
    let warnAfter = expiresAt - DefaultWarnLead

    block silent:
      let log = TransportLog()
      let s = newSession(log, issuedToken = renewedTokenAt(renewAfter + 1))
      discard awaitOutcome(s.admit(goodToken(expiresAt = expiresAt), T0))
      counted s.plan(renewAfter + 1) == raSilent
      let r = awaitOutcome(s.refresh(renewAfter + 1))
      counted r.isOk
      counted r.value == raSilent
      counted log.tokenFetches == 1
      # It renewed: a second signature check, on the token it was handed.
      counted log.signatureChecks == 2

    block visible:
      let log = TransportLog()
      let s = newSession(log, issuedToken = renewedTokenAt(warnAfter + 1))
      discard awaitOutcome(s.admit(goodToken(expiresAt = expiresAt), T0))
      counted s.plan(warnAfter + 1) == raVisible
      counted awaitOutcome(s.refresh(warnAfter + 1)).value == raVisible
      counted log.tokenFetches == 1

    block prompt:
      let log = TransportLog()
      let s = newSession(log, issuedToken = renewedTokenAt(expiresAt))
      discard awaitOutcome(s.admit(goodToken(expiresAt = expiresAt), T0))
      counted s.plan(expiresAt) == raPrompt
      counted awaitOutcome(s.refresh(expiresAt)).value == raPrompt
      counted log.tokenFetches == 1

    # The mapping is total and each band has its own action — a merged pair
    # would make two different behaviours indistinguishable.
    counted refreshActionFor(ibNormal) == raNone
    counted refreshActionFor(ibRenewing) == raSilent
    counted refreshActionFor(ibWarning) == raVisible
    counted refreshActionFor(ibExpired) == raPrompt
    counted refreshActionFor(ibRenewing) != refreshActionFor(ibWarning)

  # -------------------------------------------------------------------------
  test "a refresh that cannot reach the network leaves the session usable":
    ## The offline case, which is the whole reason for the grace bands: a
    ## renewal that fails must not cost the user the token they already hold.
    let expiresAt = T0 + DefaultLicensePeriod
    let renewAfter = expiresAt - DefaultRenewLead
    let log = TransportLog()
    let s = newSession(log, tokenFetchFails = true)
    discard awaitOutcome(s.admit(goodToken(expiresAt = expiresAt), T0))
    counted s.hasToken()

    let r = awaitOutcome(s.refresh(renewAfter + 1))
    counted r.isErr
    counted log.tokenFetches == 1
    # STILL USABLE. The failing direction is asserted by `isErr`, never by
    # comparing against a fallback value — outcome.nim's `valueOr` doc says
    # why, and this is the case it warns about.
    counted s.hasToken()
    let d = s.decide(renewAfter + 1)
    counted d.kind == dkAccepted
    counted d.band == ibRenewing
    counted d.entitlementsAreInForce()

  # -------------------------------------------------------------------------
  test "revocation arrives over the transport and takes effect":
    let log = TransportLog()
    let s = newSession(log, revoked = @[Subject])
    discard awaitOutcome(s.admit(goodToken(), T0))
    counted s.decide(T0).kind == dkAccepted
    counted s.revocations().subjects.len == 0
    counted log.revocationFetches == 0

    let r = awaitOutcome(s.refreshRevocations())
    counted r.isOk
    counted log.revocationFetches == 1
    counted s.revocations().subjects.len == 1
    counted s.decide(T0).kind == dkRevoked
    counted not s.decide(T0).entitlementsAreInForce()

    # A list naming somebody else does not revoke this subject.
    let log2 = TransportLog()
    let s2 = newSession(log2, revoked = @["acct_SOMEONE_ELSE"])
    discard awaitOutcome(s2.admit(goodToken(), T0))
    discard awaitOutcome(s2.refreshRevocations())
    counted log2.revocationFetches == 1
    counted s2.decide(T0).kind == dkAccepted

  # -------------------------------------------------------------------------
  test "revocation staleness is the renew lead, not a number of its own":
    ## §3.3.1a ties revocation to renewal, so the list is stale exactly when
    ## the client would have contacted the issuer anyway. A shorter interval
    ## would promise a latency the model does not deliver.
    let log = TransportLog()
    let s = newSession(log, revoked = @[])
    counted s.revocationsAreStale(T0)
      # never fetched — stale by definition, not fresh by default
    discard awaitOutcome(s.refreshRevocations())
    counted not s.revocationsAreStale(T0)
    counted not s.revocationsAreStale(T0 + DefaultRenewLead)
    counted s.revocationsAreStale(T0 + DefaultRenewLead + 1)
    counted DefaultRenewLead == 14 * 86_400

  # -------------------------------------------------------------------------
  test "a session with no token is refused, and says so":
    let log = TransportLog()
    let s = newSession(log)
    let d = s.decide(T0)
    counted d.kind == dkMalformed
    counted not d.entitlementsAreInForce()
    counted d.claims.subject.len == 0
    counted d.detail.contains("no token")
    counted s.plan(T0) == raPrompt
    counted s.bandOf(T0) == ibExpired
    # And asking for a decision made no call.
    counted log.tokenFetches == 0
    counted log.signatureChecks == 0

  # -------------------------------------------------------------------------
  test "a decision cannot be forged through the exported constructor":
    ## `rejectedDecision` is the only exported way to build a decision, and it
    ## coerces `dkAccepted` to `dkMalformed`, so the session layer can report an
    ## inspection failure without gaining the ability to manufacture an
    ## identity. ID1: claims are read, never authored.
    let forged = rejectedDecision(dkAccepted, "let me in")
    counted forged.kind == dkMalformed
    counted forged.kind != dkAccepted
    counted not forged.entitlementsAreInForce()
    counted forged.claims.subject.len == 0
    counted forged.claims.entitlements.len == 0
    # It CAN express a genuine refusal, which is what it is for.
    counted rejectedDecision(dkRevoked, "gone").kind == dkRevoked
    counted rejectedDecision(dkBadSignature, "nope").kind == dkBadSignature

  # -------------------------------------------------------------------------
  test "assertion count":
    check countedAssertions == ExpectedAssertions
