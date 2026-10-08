## Headless tests for the identity session — admission, refresh, revocation.
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
## renewed correctly and *also* polled when it had a fresh token would satisfy
## every status check in this file; only the count catches it, which is the same
## reason `test_platform_wasm_modules.nim`'s fake host records a `HostLog`
## instead of trusting `ok`.
##
## The sharpest case is `a valid, un-aged token makes no network call at all`,
## and it is asserted as **zero**, not as "fewer than the others".
##
## ## What this suite used to claim, and no longer does
##
## That case used to cite `CodeTracer-End-User-Licensing.md` §3.3.1a and say it
## made a debugger work on a plane for the first sixteen days of a thirty-day
## token. That was licensing's property, borrowed along with its container and
## its windows. An ID token lives about an hour; identity cannot promise offline
## weeks and no longer pretends to. Offline entitlement is licensing's, through
## its own file, which this layer does not touch.
##
## Two cases went with the borrowing. `revocation arrives over the transport and
## takes effect` and `revocation staleness is the renew lead, not a number of
## its own` both tested a revocation LIST fetched over its own channel and
## thresholded on licensing's renew lead. OIDC has no such channel: revocation
## arrives as a refusal to renew, and the replacement case asserts that.

import std/[base64, strutils, unittest]

import ../../platform/outcome
import ../../identity/session

# ---------------------------------------------------------------------------
# Counted assertions.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 259
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
# Fixtures. The token is assembled here from literal OIDC field names, so a
# parser that stopped reading one could not make this file agree with it.
# ---------------------------------------------------------------------------
const
  TestKeyId = "ct-identity-2026-08"
  RotatedKeyId = "ct-identity-2026-11"
  Subject = "acct_01HQ8Z3K"
  Issuer = "https://login.metacraft-labs.com"
  Aud = "codetracer-desktop"
  T0 = 1_787_875_200'i64
  Hour = 3600'i64

proc b64u(s: string): string =
  encode(s).replace("+", "-").replace("/", "_").replace("=", "")

proc fakeSign(message: seq[byte]): seq[byte] =
  ## A stand-in for RS256. It is not cryptography and does not pretend to be —
  ## it is a deterministic function of every message byte, which is the only
  ## property these cases need: change any byte and the signature no longer
  ## matches. The real primitive sits at the same seam
  ## (`IdentityTransport.verifySignature`), so these cases exercise the code
  ## path the product does with a different function behind it, and
  ## `test_identity_rs256_seam.nim` is what puts a real RSA signature through
  ## that seam.
  result = newSeq[byte](32)
  var acc: uint32 = 0x9E37_79B9'u32
  for b in message:
    acc = (acc xor uint32(b)) * 16_777_619'u32
  for i in 0 ..< 32:
    acc = (acc xor uint32(i)) * 16_777_619'u32
    result[i] = byte((acc shr 13) and 0xFF'u32)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc signingInput(issuedAt, expiresAt: int64; keyId, subject: string): string =
  let header = "{\"alg\":\"RS256\",\"kid\":\"" & keyId & "\",\"typ\":\"JWT\"}"
  let payload = "{\"sub\":\"" & subject & "\",\"iss\":\"" & Issuer &
    "\",\"aud\":\"" & Aud & "\",\"iat\":" & $issuedAt &
    ",\"exp\":" & $expiresAt & "}"
  b64u(header) & "." & b64u(payload)

proc token(issuedAt = T0; expiresAt = T0 + Hour; keyId = TestKeyId;
           subject = Subject; corruptSignature = false): string =
  let input = signingInput(issuedAt, expiresAt, keyId, subject)
  var sig = fakeSign(bytesOf(input))
  if corruptSignature:
    sig[0] = byte((uint32(sig[0]) + 1'u32) and 0xFF'u32)
  var sigText = newString(sig.len)
  for i, b in sig:
    sigText[i] = char(b)
  input & "." & b64u(sigText)

proc renewedTokenAt(now: int64): string =
  ## A token the issuer would mint AT `now` — issued then, expiring one hour
  ## later. A renewal is a NEW token, not the old one with a later expiry: the
  ## second kind has an `iat` from the past and a lifetime the derived refresh
  ## point would already consider half spent.
  token(issuedAt = now, expiresAt = now + Hour)

proc keys(kid = TestKeyId): seq[JwkKey] =
  @[JwkKey(kid: kid, alg: "RS256", kty: "RSA", n: "AQAB", e: "AQAB")]

type
  TransportLog = ref object
    ## What the session actually ASKED for. Assertions read this rather than
    ## the outcomes.
    tokenFetches: int
    jwksFetches: int
    signatureChecks: int
    keyIdsSeen: seq[string]

proc fakeTransport(log: TransportLog; knownKey = TestKeyId;
                   issuedToken = "";
                   tokenFetchFails = false;
                   tokenFetchRevoked = false;
                   publishedKeys: seq[JwkKey] = @[]): IdentityTransport =
  IdentityTransport(
    fetchToken: proc(): auto =
      log.tokenFetches = log.tokenFetches + 1
      if tokenFetchRevoked:
        # What an issuer says when a refresh token has been revoked: RFC 6749
        # §5.2's `invalid_grant`. There is no list to poll; this IS the channel.
        resolvedErr[string](pkAccessDenied, "invalid_grant")
      elif tokenFetchFails:
        resolvedErr[string](pkTransport, "no network")
      else:
        resolvedOk(issuedToken),
    fetchJwks: proc(): auto =
      log.jwksFetches = log.jwksFetches + 1
      resolvedOk(publishedKeys),
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

proc newSession(log: TransportLog; published: seq[JwkKey] = keys();
                knownKey = TestKeyId; issuedToken = "";
                tokenFetchFails = false; tokenFetchRevoked = false;
                jwksReturns: seq[JwkKey] = @[]): IdentitySession =
  newIdentitySession(
    fakeTransport(log, knownKey = knownKey, issuedToken = issuedToken,
                  tokenFetchFails = tokenFetchFails,
                  tokenFetchRevoked = tokenFetchRevoked,
                  publishedKeys = jwksReturns),
    published, Issuer, Aud)

suite "identity session (ID1)":

  # -------------------------------------------------------------------------
  test "admission checks the signature exactly once, and only after inspection":
    let log = TransportLog()
    let s = newSession(log)
    let d = awaitOutcome(s.admit(token(), T0))

    counted d.isOk
    counted d.value.kind() == dkAccepted
    counted d.value.band() == ibNormal
    counted d.value.claims().subject() == Subject
    counted s.hasToken()
    counted s.bandOf(T0) == ibNormal

    # ONCE. Not once per entitlement question — `decide` is pure and consults
    # the admitted claims, which is the split that makes a browser's
    # asynchronous verifier usable at all.
    counted log.signatureChecks == 1
    counted s.signatureChecks() == 1
    counted log.keyIdsSeen == @[TestKeyId]

    for _ in 0 ..< 50:
      counted s.decide(T0).kind() == dkAccepted
    counted log.signatureChecks == 1
    counted log.tokenFetches == 0
    counted log.jwksFetches == 0

  # -------------------------------------------------------------------------
  test "a token that fails inspection never becomes a network event":
    ## Everything answerable locally is answered locally, and that is now more
    ## than it was: an unknown `kid`, a foreign issuer and another client's
    ## audience are all settled from the cached JWKS with no call at all.
    for bad in [token(keyId = RotatedKeyId),
                "not.a.token",
                token(subject = ""),
                b64u("{\"alg\":\"none\",\"kid\":\"" & TestKeyId & "\"}") & "." &
                  b64u("{\"sub\":\"x\"}") & "." & b64u("sig")]:
      let log = TransportLog()
      let s = newSession(log)
      let d = awaitOutcome(s.admit(bad, T0))
      counted d.isOk
      counted not d.value.identityIsInForce()
      counted log.signatureChecks == 0
      counted not s.hasToken()

    # An unknown key id is named as such, which is what lets a product say
    # "update to pick up the new key" rather than "your token is forged".
    let log2 = TransportLog()
    let s2 = newSession(log2)
    counted awaitOutcome(s2.admit(token(keyId = RotatedKeyId), T0))
      .value.kind() == dkUnknownKeyId

    # THE POSITIVE TWIN. Without it every count above is satisfied by an
    # `admit` that refuses everything and never calls the transport.
    let log3 = TransportLog()
    let s3 = newSession(log3)
    counted awaitOutcome(s3.admit(token(), T0)).value.kind() == dkAccepted
    counted log3.signatureChecks == 1

  # -------------------------------------------------------------------------
  test "a valid, un-aged token makes no network call at all":
    ## Asserted as ZERO, not as "fewer than the others".
    let log = TransportLog()
    let s = newSession(log)
    discard awaitOutcome(s.admit(token(), T0))
    counted log.signatureChecks == 1

    # Through the whole first half of the token's life.
    for offset in [0'i64, 60, 600, Hour div 2 - 1]:
      let now = T0 + offset
      counted s.plan(now) == raNone
      counted awaitOutcome(s.refresh(now)).value == raNone
    counted log.tokenFetches == 0
    counted s.tokenFetches() == 0

    # And `decide` stays pure across a hundred questions.
    for i in 0 ..< 100:
      counted s.decide(T0 + int64(i)).kind() == dkAccepted
    counted log.tokenFetches == 0
    counted log.signatureChecks == 1

  # -------------------------------------------------------------------------
  test "past half its life the session renews, silently":
    let renewAt = T0 + Hour div 2
    let log = TransportLog()
    let s = newSession(log, issuedToken = renewedTokenAt(renewAt))
    discard awaitOutcome(s.admit(token(), T0))

    counted s.plan(renewAt) == raSilent
    let r = awaitOutcome(s.refresh(renewAt))
    counted r.isOk
    # The action REPORTED is the one that was true when the refresh began, so a
    # successful renewal stays distinguishable from one that was never needed.
    counted r.value == raSilent
    counted log.tokenFetches == 1
    counted log.signatureChecks == 2

    # The new token is in force, and its own refresh point has moved.
    counted s.decide(renewAt).kind() == dkAccepted
    counted s.plan(renewAt) == raNone

    # THERE IS NO SECOND BAND THAT ALSO RENEWS. `raVisible` was the warning
    # band's action — name the date to the user — and it made sense when expiry
    # was weeks away and the remedy was a purchase. A refresh token renews
    # without the user present, so a dialog there would be about something the
    # client is already fixing.
    counted not compiles(raVisible)
    counted not compiles(refreshActionFor(ibWarning))
    counted refreshActionFor(ibNormal) == raNone
    counted refreshActionFor(ibRenewing) == raSilent
    counted refreshActionFor(ibExpired) == raPrompt
    counted refreshActionFor(ibNotYetValid) == raNone

  # -------------------------------------------------------------------------
  test "a refresh that cannot reach the network leaves the session usable":
    let renewAt = T0 + Hour div 2
    let log = TransportLog()
    let s = newSession(log, tokenFetchFails = true)
    discard awaitOutcome(s.admit(token(), T0))

    let r = awaitOutcome(s.refresh(renewAt))
    counted r.isErr
    counted log.tokenFetches == 1

    # The token already held is untouched. A failed renewal must not cost a
    # session that is still valid.
    counted s.hasToken()
    let d = s.decide(renewAt)
    counted d.kind() == dkAccepted
    counted d.band() == ibRenewing
    counted d.claims().subject() == Subject
    counted not s.isRevoked()

  # -------------------------------------------------------------------------
  test "a refusal to renew is how revocation arrives":
    ## THE REPLACEMENT FOR THE REVOCATION LIST. The retired version fetched a
    ## list of revoked subjects over its own transport and thresholded its
    ## staleness on licensing's renew lead. OIDC has no such channel: RFC 6749
    ## §5.2's `invalid_grant` on the refresh IS the notification, and it is
    ## bounded by the ID token's own lifetime rather than by a 30-day period.
    let renewAt = T0 + Hour div 2
    let log = TransportLog()
    let s = newSession(log, tokenFetchRevoked = true)
    discard awaitOutcome(s.admit(token(), T0))
    counted not s.isRevoked()
    counted s.decide(renewAt).kind() == dkAccepted

    let r = awaitOutcome(s.refresh(renewAt))
    counted r.isErr
    counted s.isRevoked()

    # REVOCATION OUTRANKS EXPIRY, because it is the fact a product must report:
    # "sign in again" would invite the user to try something that will be
    # refused.
    let d = s.decide(renewAt)
    counted d.kind() == dkRevoked
    counted "ended elsewhere" in d.detail()
    counted not d.identityIsInForce()
    counted s.decide(T0 + Hour * 2).kind() == dkRevoked

    # A network failure is NOT a revocation, which is the distinction that
    # makes the flag worth having.
    let log2 = TransportLog()
    let s2 = newSession(log2, tokenFetchFails = true)
    discard awaitOutcome(s2.admit(token(), T0))
    discard awaitOutcome(s2.refresh(renewAt))
    counted not s2.isRevoked()
    counted s2.decide(renewAt).kind() == dkAccepted

    # And the list is gone, asserted at compile time because these names were
    # exported from `session.nim` and a rewrite could reintroduce one silently.
    counted not compiles(s.revocations())
    counted not compiles(s.refreshRevocations())
    counted not compiles(s.revocationsAreStale(T0))
    counted not compiles(s.revocationFetches())

  # -------------------------------------------------------------------------
  test "a token that verifies clears a revocation the issuer has overtaken":
    ## If the issuer mints another token for this session, whatever refusal
    ## marked it revoked has been overtaken. Leaving the flag set would make a
    ## re-signed-in user permanently refused with no way back.
    let renewAt = T0 + Hour div 2
    let log = TransportLog()
    let s = newSession(log, tokenFetchRevoked = true)
    discard awaitOutcome(s.admit(token(), T0))
    discard awaitOutcome(s.refresh(renewAt))
    counted s.isRevoked()

    discard awaitOutcome(s.admit(renewedTokenAt(renewAt), renewAt))
    counted not s.isRevoked()
    counted s.decide(renewAt).kind() == dkAccepted

  # -------------------------------------------------------------------------
  test "the key set is refetched on rotation, and never replaced by nothing":
    ## A rotation looks like `dkUnknownKeyId` from here. Refetching is what
    ## turns that from a dead end into a recovery — but a fetch that succeeded
    ## with an EMPTY set would replace a working key set with one that refuses
    ## every token, and the client would have done that to itself.
    let log = TransportLog()
    let s = newSession(log, knownKey = RotatedKeyId,
                       jwksReturns = keys(RotatedKeyId))
    counted awaitOutcome(s.admit(token(keyId = RotatedKeyId), T0))
      .value.kind() == dkUnknownKeyId
    counted log.signatureChecks == 0

    counted awaitOutcome(s.refreshKeys()).isOk
    counted log.jwksFetches == 1
    counted s.publishedKeys().len == 1
    counted s.publishedKeys()[0].kid == RotatedKeyId

    # And now it admits.
    counted awaitOutcome(s.admit(token(keyId = RotatedKeyId), T0))
      .value.kind() == dkAccepted

    # The empty case is REFUSED and the previous keys are kept.
    let log2 = TransportLog()
    let s2 = newSession(log2, jwksReturns = @[])
    let r = awaitOutcome(s2.refreshKeys())
    counted r.isErr
    counted s2.publishedKeys().len == 1
    counted s2.publishedKeys()[0].kid == TestKeyId
    counted awaitOutcome(s2.admit(token(), T0)).value.kind() == dkAccepted

  # -------------------------------------------------------------------------
  test "an invalid signature is refused, and does not admit the token":
    let log = TransportLog()
    let s = newSession(log)
    let d = awaitOutcome(s.admit(token(corruptSignature = true), T0))
    counted d.isOk
    counted d.value.kind() == dkBadSignature
    counted not d.value.identityIsInForce()
    counted not s.hasToken()
    # It DID reach the verifier — the refusal is the verifier's, not a local
    # shortcut, which is what distinguishes this from the inspection cases.
    counted log.signatureChecks == 1
    # And a rejected token leaks no claims.
    counted d.value.claims().subject() == ""

  # -------------------------------------------------------------------------
  test "a session with no token is refused, and says so":
    let log = TransportLog()
    let s = newSession(log)
    counted not s.hasToken()
    counted s.bandOf(T0) == ibExpired
    counted s.plan(T0) == raPrompt
    let d = s.decide(T0)
    counted d.kind() == dkMalformed
    counted "no token" in d.detail()
    counted not d.identityIsInForce()
    counted log.signatureChecks == 0

  # -------------------------------------------------------------------------
  test "a decision cannot be forged through the exported constructor":
    let forged = rejectedDecision(dkAccepted, "trying to manufacture one")
    counted forged.kind() == dkMalformed
    counted not forged.identityIsInForce()
    counted forged.claims().subject() == ""
    counted forged.band() == ibNotYetValid

  # -------------------------------------------------------------------------
  test "assertion count":
    ## The fingerprint. A count that moves without a matching change to the
    ## cases above means a case stopped running — trap 4b's silent skip, which
    ## a pass/fail tally cannot show.
    check countedAssertions == ExpectedAssertions
