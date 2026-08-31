## Headless tests for the identity token and its verification — ID1.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob, and the second
## is not incidental. `viewmodel/identity/token.nim` parses attacker-shaped
## JSON, and CONTRIBUTING.md's portability rule is about exactly that: on the C
## backend `parseJson` raises `JsonParsingError`, on the JS backend V8 throws a
## raw `SyntaxError` that no Nim type matches. The malformed-token cases below
## are the ones that would have caught that, and they only catch it if this
## file runs on both backends — which is why `test_rejects_a_payload_that_is_not_json`
## exists as its own case rather than as one line inside another.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_identity_token.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_identity_token.nim
##
## ## The three ID1 verifications this file carries
##
##   test_verification_needs_no_network
##   test_expiry_degrades_to_grace_then_prompt
##   test_revocation_takes_effect_within_the_stated_window
##
## ## The tautology this suite is written against
##
## The easy way to test a verifier is to build a token with the same code that
## reads it and assert they agree. That passes over a verifier that accepts
## everything, and it passes over one that accepts nothing if the builder is
## broken in the mirror way.
##
## So the fixture below is an ISSUER, not a mirror: it emits the container as
## bytes, from the field names the spec publishes, and nothing in it imports
## the parser. And every acceptance case is paired with a REJECTION over a
## one-field mutation of the same bytes — if the verifier stopped reading a
## field, its acceptance case would still pass and its rejection twin would go
## red immediately. That pairing is the control, per
## Testing/Verification-Harness-Traps.md 4a.

import std/[json, strutils, unittest]

import ../../identity/token

# ---------------------------------------------------------------------------
# Counted assertions. `counted` is a TEMPLATE so that `check` is inlined into
# the `test` body where `testStatusIMPL` is in scope — inside a proc every
# check would print and still report [OK]. Same reasoning as
# `test_noir_wasm_delivery.nim`.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 120
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it. A count that moves without explanation is how
  ## trap 4b's silent skip becomes visible.

# ---------------------------------------------------------------------------
# THE ISSUER FIXTURE.
#
# This is deliberately a separate implementation from the parser: it writes the
# published field names as literals and lays out the container by hand. It
# does not import anything from `token.nim` except the format constants, so a
# parser that stopped reading `renew_after` could not make this file agree with
# it.
# ---------------------------------------------------------------------------
const
  TestKeyId = "ct-identity-2026-08"
  RotatedKeyId = "ct-identity-2026-11"
  Subject = "acct_01HQ8Z3K"

  # A fixed instant, so no case reads a clock. 2026-08-31T00:00:00Z.
  T0 = 1_787_875_200'i64

proc fakeSign(message: openArray[byte]): seq[byte] =
  ## A stand-in for Ed25519. It is not cryptography and does not pretend to be
  ## — it is a deterministic function of every message byte, which is the only
  ## property the tests need: change any byte of the message and the signature
  ## no longer matches. The real primitive is injected at the same seam
  ## (`PinnedKeyring.verify`), so these tests exercise the same code path the
  ## product does, with a different function behind the seam.
  result = newSeq[byte](SignatureLen)
  var acc: uint32 = 0x9E37_79B9'u32
  for b in message:
    acc = (acc xor uint32(b)) * 16_777_619'u32
  for i in 0 ..< SignatureLen:
    acc = (acc xor uint32(i)) * 16_777_619'u32
    result[i] = byte((acc shr 13) and 0xFF'u32)

proc verifierFor(knownKey: string): SignatureVerifier =
  ## Verifies only for `knownKey`. A different key id yields false, which is
  ## what lets the rotation case distinguish "unknown key" from "bad signature".
  result = proc(keyId: string; message: openArray[byte];
                signature: openArray[byte]): bool {.gcsafe, raises: [].} =
    if keyId != knownKey:
      return false
    let expected = fakeSign(message)
    if expected.len != signature.len:
      return false
    for i in 0 ..< expected.len:
      if expected[i] != signature[i]:
        return false
    true

type IssuedToken = object
  bytes: seq[byte]

proc issue(payload: JsonNode; magic = IdentityMagic;
           corruptSignature = false;
           lengthDelta = 0): IssuedToken =
  ## Lay out magic + u32le length + payload + signature, by hand.
  let text = $payload
  var raw: seq[byte] = @[]
  for c in magic:
    raw.add byte(c)
  let declared = uint32(text.len + lengthDelta)
  raw.add byte(declared and 0xFF'u32)
  raw.add byte((declared shr 8) and 0xFF'u32)
  raw.add byte((declared shr 16) and 0xFF'u32)
  raw.add byte((declared shr 24) and 0xFF'u32)
  for c in text:
    raw.add byte(c)
  var sig = fakeSign(raw)
  if corruptSignature:
    sig[0] = byte((uint32(sig[0]) + 1'u32) and 0xFF'u32)
  raw.add sig
  IssuedToken(bytes: raw)

proc claimsJson(expiresAt = T0 + DefaultLicensePeriod;
                issuedAt = T0;
                keyId = TestKeyId;
                subject = Subject;
                renewAfter = T0 + DefaultLicensePeriod - DefaultRenewLead;
                warnAfter = T0 + DefaultLicensePeriod - DefaultWarnLead;
                notBefore = 0'i64;
                entitlements: seq[string] = @["replay:unlimited", "visual_replay"];
                exceptionReason = ""): JsonNode =
  ## Field names are the ones §3.3.1 publishes, written out here rather than
  ## referenced from the parser.
  result = %*{
    "sub": subject,
    "key_id": keyId,
    "issued_at": issuedAt,
    "renew_after": renewAfter,
    "warn_after": warnAfter,
    "expires_at": expiresAt,
    "entitlements": entitlements
  }
  if notBefore != 0:
    result["not_before"] = %notBefore
  if exceptionReason.len > 0:
    result["window_exception_reason"] = %exceptionReason

proc keyring(known = TestKeyId; pinned: seq[string] = @[TestKeyId]): PinnedKeyring =
  PinnedKeyring(keyIds: pinned, verify: verifierFor(known))

proc decide(t: IssuedToken; nowUnix = T0;
            revocations = emptyRevocations();
            ring = keyring()): IdentityDecision =
  verifyToken(t.bytes, ring, nowUnix, revocations, defaultWindowPolicy())

suite "identity token (ID1)":

  # -------------------------------------------------------------------------
  test "the published windows are inherited, not invented":
    ## ID1's third deliverable: bounded offline grace "inheriting licensing's
    ## windows and per-account exceptions rather than inventing new ones".
    ## CodeTracer-End-User-Licensing.md §3.3.1a publishes 30 / 14 / 7 days.
    counted DefaultLicensePeriod == 30 * 86_400
    counted DefaultRenewLead == 14 * 86_400
    counted DefaultWarnLead == 7 * 86_400
    let p = defaultWindowPolicy()
    counted p.licensePeriod == DefaultLicensePeriod
    counted p.renewLead == DefaultRenewLead
    counted p.warnLead == DefaultWarnLead
    # The ordering the four bands need in order to all be reachable.
    counted identityInvariantsHold(p)
    counted not identityInvariantsHold(
      WindowPolicy(licensePeriod: 10, renewLead: 20, warnLead: 5))
    counted not identityInvariantsHold(
      WindowPolicy(licensePeriod: DefaultLicensePeriod,
                   renewLead: DefaultWarnLead, warnLead: DefaultRenewLead))
    counted not identityInvariantsHold(
      WindowPolicy(licensePeriod: DefaultLicensePeriod,
                   renewLead: DefaultRenewLead, warnLead: 0))

  # -------------------------------------------------------------------------
  test "test_verification_needs_no_network":
    ## "A product verifies a token, checks its claims and proceeds with the
    ## network disabled; obtaining a token needs the network, using one never
    ## does."
    ##
    ## There is no network to disable here, and that is the point rather than a
    ## weakness of the test: `verifyToken` takes the token, the keyring, the
    ## clock and the revocation list as ARGUMENTS. The only injected callable
    ## is the signature primitive, and this case counts its invocations so that
    ## "nothing else was consulted" is measured rather than assumed.
    var verifierCalls = 0
    var callsForExpectedKeyId = 0
    let counting = PinnedKeyring(
      keyIds: @[TestKeyId],
      verify: proc(keyId: string; message: openArray[byte];
                   signature: openArray[byte]): bool {.gcsafe, raises: [].} =
        inc verifierCalls
        if keyId == TestKeyId:
          inc callsForExpectedKeyId
        let expected = fakeSign(message)
        if expected.len != signature.len: return false
        for i in 0 ..< expected.len:
          if expected[i] != signature[i]: return false
        true)

    let d = decide(issue(claimsJson()), ring = counting)
    counted d.kind == dkAccepted
    counted d.band == ibNormal
    counted d.claims.subject == Subject
    counted d.claims.keyId == TestKeyId
    counted d.entitlementsAreInForce()
    counted d.claims.hasEntitlement("visual_replay")
    counted not d.claims.hasEntitlement("enterprise:sso")
    # Exactly one primitive call, and it is the signature check.
    counted verifierCalls == 1
    counted callsForExpectedKeyId == 1

    # The paired REJECTION over the same bytes: flip one signature byte and the
    # same path must refuse. Without this twin, the acceptance above would also
    # pass against a verifier that ignored the signature entirely.
    let tampered = decide(issue(claimsJson(), corruptSignature = true),
                          ring = counting)
    counted tampered.kind == dkBadSignature
    counted not tampered.entitlementsAreInForce()
    counted tampered.claims.subject.len == 0
      # A rejected token yields NO claims. A verifier that returned the
      # parsed subject before checking the signature would let a forged token
      # name any account.
    counted verifierCalls == 2

  # -------------------------------------------------------------------------
  test "test_expiry_degrades_to_grace_then_prompt":
    ## "An expired token produces a grace window and then a prompt, never a
    ## debugger that stops working mid-session."
    ##
    ## §3.3.1a's four bands, walked across one token's life. Each band asserts
    ## BOTH its own name and the two behaviours that distinguish it — whether
    ## renewal is attempted, and whether the user is told — because the
    ## renewing band and the warning band differ in exactly the second one and
    ## a test that only checked the enum would not notice them merging.
    let expiresAt = T0 + DefaultLicensePeriod
    let renewAfter = expiresAt - DefaultRenewLead
    let warnAfter = expiresAt - DefaultWarnLead
    let t = issue(claimsJson(expiresAt = expiresAt))

    # Band 1: normal. No network required, none attempted.
    let normal = decide(t, nowUnix = T0)
    counted normal.kind == dkAccepted
    counted normal.band == ibNormal
    counted not normal.band.shouldAttemptRenewal()
    counted not normal.band.shouldWarnUser()
    counted normal.entitlementsAreInForce()

    # Band 2: renewing, and SILENT.
    let renewing = decide(t, nowUnix = renewAfter + 1)
    counted renewing.kind == dkAccepted
    counted renewing.band == ibRenewing
    counted renewing.band.shouldAttemptRenewal()
    counted not renewing.band.shouldWarnUser()
    counted renewing.entitlementsAreInForce()

    # Band 3: warning. Still working, and now visible.
    let warning = decide(t, nowUnix = warnAfter + 1)
    counted warning.kind == dkAccepted
    counted warning.band == ibWarning
    counted warning.band.shouldAttemptRenewal()
    counted warning.band.shouldWarnUser()
    counted warning.entitlementsAreInForce()
      # The whole point of the warning band: entitlements are STILL in force.

    # Band 4: expired. Entitlements stop; the product does not.
    let expired = decide(t, nowUnix = expiresAt)
    counted expired.kind == dkExpired
    counted expired.band == ibExpired
    counted not expired.entitlementsAreInForce()
    counted expired.claims.subject == Subject
      # Claims ARE returned for an expired token. §3.3.1a's message "names the
      # date, not a countdown", and a product cannot name it without them.
      # Licensing cannot do this: `LicenseStatus` has no expired variant.
    counted expired.claims.expiresAt == expiresAt
    counted expired.detail.len > 0

    # Expiry is INCLUSIVE, matching licensing's `>=`. The boundary second is
    # expired, not valid; the second before it is the warning band.
    counted decide(t, nowUnix = expiresAt - 1).band == ibWarning
    counted decide(t, nowUnix = expiresAt).band == ibExpired

    # The bands are strictly ordered across the whole life, with no gap and no
    # overlap. Counted as one assertion per sample so a merged pair is visible.
    var samples = 0
    for (at, want) in [(T0, ibNormal), (renewAfter - 1, ibNormal),
                       (renewAfter, ibRenewing), (warnAfter - 1, ibRenewing),
                       (warnAfter, ibWarning), (expiresAt - 1, ibWarning),
                       (expiresAt, ibExpired), (expiresAt + 999_999, ibExpired)]:
      inc samples
      counted decide(t, nowUnix = at).band == want
    counted samples == 8

    # A not-yet-valid token is a distinct state, and it is tested FIRST, so a
    # token whose not_before is after its expiry reports not-yet-valid.
    let future = issue(claimsJson(notBefore = T0 + 10))
    counted decide(future, nowUnix = T0).band == ibNotYetValid
    counted decide(future, nowUnix = T0 + 11).band == ibNormal

  # -------------------------------------------------------------------------
  test "test_revocation_takes_effect_within_the_stated_window":
    ## "A revoked account loses entitlement within the documented window on
    ## every product, and the window is the one the licensing spec already
    ## publishes."
    let t = issue(claimsJson())
    let revoked = RevocationList(subjects: @[Subject], obtainedAt: T0)

    let before = decide(t, nowUnix = T0)
    counted before.kind == dkAccepted
    counted before.entitlementsAreInForce()

    let after = decide(t, nowUnix = T0, revocations = revoked)
    counted after.kind == dkRevoked
    counted not after.entitlementsAreInForce()
    counted after.claims.subject == Subject
    counted after.detail.contains("revoked")

    # Another subject on the list must not revoke this one.
    let other = RevocationList(subjects: @["acct_SOMEONE_ELSE"], obtainedAt: T0)
    counted decide(t, nowUnix = T0, revocations = other).kind == dkAccepted
    counted isRevoked(revoked, Subject)
    counted not isRevoked(revoked, "acct_SOMEONE_ELSE")
    counted not isRevoked(emptyRevocations(), Subject)

    # THE WINDOW. §3.3.1a: "Revocation reaches a client at its next renewal,
    # and no sooner ... cancellation leakage is bounded by the renewal period."
    # The spec never writes a number in that sentence, so the bound is DERIVED,
    # and the derivation is pinned here: a client holds a token for at most
    # LICENSE_PERIOD, so that is the worst case.
    counted revocationLatencyBound(defaultWindowPolicy()) == DefaultLicensePeriod
    counted MaxRevocationLatency == DefaultLicensePeriod
    counted MaxRevocationLatency == 30 * 86_400
    counted revocationLatencyBound(defaultWindowPolicy()) > DefaultRenewLead
      # The worst case is the period, NOT the renew lead. Stating the typical
      # case as the bound is how a leak window gets understated.

    # And the bound is only true because a token cannot outlive it. A token
    # that never expires would make revocation unbounded, so it is refused.
    let immortal = issue(%*{
      "sub": Subject, "key_id": TestKeyId, "issued_at": T0,
      "renew_after": T0 + 1, "warn_after": T0 + 2, "expires_at": 0,
      "entitlements": []})
    let immortalDecision = decide(immortal)
    counted immortalDecision.kind == dkMalformed
    counted immortalDecision.detail.contains("never expires")
    counted immortalDecision.claims.subject.len == 0

    # A token whose period exceeds the published default is a per-account
    # exception and needs a recorded reason — §3.3.1a allows the exception
    # "with a recorded reason, not a global loosening".
    let overlong = issue(claimsJson(
      expiresAt = T0 + DefaultLicensePeriod * 4,
      renewAfter = T0 + DefaultLicensePeriod * 4 - DefaultRenewLead,
      warnAfter = T0 + DefaultLicensePeriod * 4 - DefaultWarnLead))
    let overlongDecision = decide(overlong)
    counted overlongDecision.kind == dkMalformed
    counted overlongDecision.detail.contains("recorded")

    let excepted = issue(claimsJson(
      expiresAt = T0 + DefaultLicensePeriod * 4,
      renewAfter = T0 + DefaultLicensePeriod * 4 - DefaultRenewLead,
      warnAfter = T0 + DefaultLicensePeriod * 4 - DefaultWarnLead,
      exceptionReason = "air-gapped site, ticket OPS-4471"))
    let exceptedDecision = decide(excepted)
    counted exceptedDecision.kind == dkAccepted
    counted exceptedDecision.claims.windowExceptionReason.contains("OPS-4471")
    counted windowsExceedPolicy(exceptedDecision.claims, defaultWindowPolicy())

    # Revocation outranks expiry: a revoked subject whose token also expired
    # reports revoked, because that is the fact a product must report.
    let expiredAndRevoked = decide(t, nowUnix = T0 + DefaultLicensePeriod,
                                   revocations = revoked)
    counted expiredAndRevoked.kind == dkRevoked

  # -------------------------------------------------------------------------
  test "key rotation is expressible, which licensing cannot do":
    ## Licensing's container carries no key id: `enforcement.rs` trusts exactly
    ## one baked-in key, so a rotation cannot be signalled to a deployed binary
    ## and the only bound on a compromised key is the 365-day binary-age gate.
    ## A token names its key, so an old build can say "update me" instead.
    let rotated = issue(claimsJson(keyId = RotatedKeyId))

    # A build that pins only the old key does not recognise the new one, and
    # says so SPECIFICALLY — not "forged".
    let oldBuild = decide(rotated)
    counted oldBuild.kind == dkUnknownKeyId
    counted oldBuild.kind != dkBadSignature
    counted oldBuild.detail.contains(RotatedKeyId)
    counted oldBuild.claims.subject.len == 0

    # A build that pins both verifies the new token — this is rotation working.
    let bothPinned = keyring(known = RotatedKeyId,
                             pinned = @[TestKeyId, RotatedKeyId])
    let newBuild = decide(rotated, ring = bothPinned)
    counted newBuild.kind == dkAccepted
    counted newBuild.claims.keyId == RotatedKeyId

    # And an old token still verifies on the new build, which is the whole
    # reason old artifacts stay verifiable across a rotation.
    let oldToken = decide(issue(claimsJson()),
                          ring = keyring(known = TestKeyId,
                                         pinned = @[TestKeyId, RotatedKeyId]))
    counted oldToken.kind == dkAccepted
    counted oldToken.claims.keyId == TestKeyId

    # A key that is PINNED but whose signature does not check out is a bad
    # signature, not an unknown key. The two must not collapse.
    let wrongSigner = decide(issue(claimsJson()),
                             ring = keyring(known = "some-other-key",
                                            pinned = @[TestKeyId]))
    counted wrongSigner.kind == dkBadSignature

  # -------------------------------------------------------------------------
  test "test_rejects_a_payload_that_is_not_json":
    ## THE BACKEND-PORTABILITY CASE. On C this exercises `JsonParsingError`; on
    ## JS it exercises V8's raw `SyntaxError`, which no Nim exception type
    ## matches. `token.nim` catches with a bare `except:` for that reason, and
    ## if it is ever narrowed to `except CatchableError` this case passes under
    ## `nim c` and CRASHES under `nim js` — which is the shape CONTRIBUTING.md
    ## records as a whole class rather than an incident.
    var raw: seq[byte] = @[]
    for c in IdentityMagic: raw.add byte(c)
    let junk = "this is not JSON at all {{{"
    raw.add byte(junk.len and 0xFF)
    raw.add 0'u8
    raw.add 0'u8
    raw.add 0'u8
    for c in junk: raw.add byte(c)
    let sig = fakeSign(raw)
    for b in sig: raw.add b

    let d = verifyToken(raw, keyring(), T0, emptyRevocations(),
                        defaultWindowPolicy())
    counted d.kind == dkMalformed
    counted d.detail.contains("not valid JSON")
    counted d.claims.subject.len == 0

    # A well-formed JSON value that is not an object is a different rejection.
    let arrayToken = issue(%*["not", "an", "object"])
    counted decide(arrayToken).kind == dkMalformed
    counted decide(arrayToken).detail.contains("not a JSON object")

  # -------------------------------------------------------------------------
  test "the container is refused when it is not ours":
    ## A licence must not be usable as an identity token. They authorise
    ## different things, and a shared magic would make substitution a parse
    ## away.
    let asLicence = issue(claimsJson(), magic = "CTL\x01")
    counted asLicence.bytes.len > 0
    let d = decide(asLicence)
    counted d.kind == dkMalformed
    counted d.detail.contains("magic")

    # Length-field mismatches are refused rather than trusted. A declared
    # length that does not account for the whole container is the classic
    # way to smuggle bytes past a signature check.
    counted decide(issue(claimsJson(), lengthDelta = 1)).kind == dkMalformed
    counted decide(issue(claimsJson(), lengthDelta = -1)).kind == dkMalformed
    counted decide(issue(claimsJson(), lengthDelta = 1)).detail.contains(
      "does not account for the whole container")

    # Too short to be a container at all.
    counted verifyToken(@[byte(1), 2, 3], keyring(), T0, emptyRevocations(),
                        defaultWindowPolicy()).kind == dkMalformed

    # An absent verifier fails CLOSED. `licensing_ffi.nim` documents the same
    # contract for a cdylib that will not load, and it is the only safe
    # default: a verifier that cannot run must not mean "accept".
    let noVerifier = PinnedKeyring(keyIds: @[TestKeyId], verify: nil)
    let d2 = verifyToken(issue(claimsJson()).bytes, noVerifier, T0,
                         emptyRevocations(), defaultWindowPolicy())
    counted d2.kind == dkMalformed
    counted d2.kind != dkAccepted
    counted d2.detail.contains("verifier")

  # -------------------------------------------------------------------------
  test "claims that do not hold together are refused, each by name":
    ## Every rejection names its reason, so a refused token is diagnosable
    ## rather than merely refused.
    proc violation(j: JsonNode): string =
      decide(issue(j)).detail

    counted violation(claimsJson(subject = "")).contains("no subject")
    counted violation(claimsJson(keyId = "")).contains("no key_id")
    counted violation(claimsJson(issuedAt = T0 + DefaultLicensePeriod + 1))
      .contains("issued_at is not before expires_at")

    # renew_after < warn_after < expires_at must hold, or a band is unreachable.
    let inverted = claimsJson()
    inverted["renew_after"] = %(T0 + DefaultLicensePeriod - 1)
    inverted["warn_after"] = %(T0 + 1)
    counted violation(inverted).contains("unreachable")

    let missingBands = %*{
      "sub": Subject, "key_id": TestKeyId, "issued_at": T0,
      "expires_at": T0 + DefaultLicensePeriod, "entitlements": []}
    counted violation(missingBands).contains("grace bands")

    # And the positive twin for every one of those: the unmutated claims are
    # accepted. Without it, a `claimRuleViolation` that returned a message for
    # EVERYTHING would satisfy all five rejections above.
    counted claimRuleViolation(
      decide(issue(claimsJson())).claims, defaultWindowPolicy()).len == 0
    counted decide(issue(claimsJson())).kind == dkAccepted

  # -------------------------------------------------------------------------
  test "claims cannot be authored by a product":
    ## ID1: "Claims are **read** by products, never authored by them."
    ##
    ## This is enforced by the type system rather than by review, and the proof
    ## is a compile-time one: `IdentityClaims`'s fields are unexported and the
    ## module exports no constructor, so the expression that would author a
    ## subject does not compile. `compiles()` is the assertion — it is checked
    ## at compile time and reported here.
    counted not compiles(IdentityClaims(subjectField: "acct_FORGED"))
    counted not compiles(block:
      var c = decide(issue(claimsJson())).claims
      c.subjectField = "acct_FORGED")
    counted not compiles(block:
      var c = decide(issue(claimsJson())).claims
      c.entitlementsField.add "enterprise:sso")
    # A default-constructed claims value is legal Nim and is INERT — it names
    # nobody, so it cannot be smuggled in as an identity.
    counted IdentityClaims().subject.len == 0
    counted IdentityClaims().entitlements.len == 0
    counted not IdentityClaims().hasEntitlement("visual_replay")
    # Reading is unrestricted, which is the other half of the rule.
    let c = decide(issue(claimsJson())).claims
    counted c.subject == Subject
    counted c.entitlements.len == 2
    counted c.issuedAt == T0

  # -------------------------------------------------------------------------
  test "assertion count":
    ## The fingerprint. A count that moves without a matching change to the
    ## cases above means a case stopped running — trap 4b's silent skip, which
    ## a pass/fail tally cannot show.
    check countedAssertions == ExpectedAssertions
