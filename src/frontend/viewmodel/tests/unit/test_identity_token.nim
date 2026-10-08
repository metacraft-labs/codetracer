## `token.nim` — inspection, bands and decisions, with no signature anywhere.
##
## ## What changed, and why this suite shrank
##
## This file used to lay out a `CTI\x01` container by hand — magic, LE32 length,
## a 64-byte signature — and assert four grace bands with licensing's numbers
## (30 days, 14, 7) from `CodeTracer-End-User-Licensing.md` §3.3.1a. Both are
## gone: a token is a compact JWS from the shared issuer, and offline
## entitlement is licensing's problem, solved by licensing's own file.
##
## Two cases went with them. `the published windows are inherited, not invented`
## asserted three constants that no longer exist, and
## `test_revocation_takes_effect_within_the_stated_window` asserted a revocation
## list thresholded on licensing's renew lead — a channel the issuer does not
## offer. OIDC delivers revocation by refusing to renew, which is the session
## layer's business and is asserted there.
##
## ## The fixtures are still a SEPARATE IMPLEMENTATION from the parser
##
## That property is the reason the old file wrote the container out by hand, and
## it survives the format change: the JWS below is assembled from literal field
## names and its own base64url, importing nothing from `jwt.nim`. A parser that
## stopped reading `exp` could not make this file agree with it.
##
## ## No signature, and that is the design
##
## `token.nim` has no verification seam any more. There is nothing here for a
## signature to be injected into, because the one place a signature is checked
## is `session.admit`, asynchronously, and `ci/test/identity-webcrypto.sh` plus
## `test_identity_rs256_seam.nim` are what exercise the primitive. This suite is
## about everything decidable WITHOUT it, which is where JWT verifiers actually
## go wrong.

import std/[base64, json, strutils, unittest]

import ../../identity/token

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 80
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it. A count that moves without explanation is how
  ## trap 4b's silent skip becomes visible.

# ---------------------------------------------------------------------------
# The ISSUER, by hand. Field names are OIDC Core §2's, written as literals.
# ---------------------------------------------------------------------------
const
  TestKeyId = "ct-identity-2026-08"
  RotatedKeyId = "ct-identity-2026-11"
  Subject = "acct_01HQ8Z3K"
  Issuer = "https://login.metacraft-labs.com"
  Aud = "codetracer-desktop"

  # A fixed instant, so no case reads a clock. 2026-08-31T00:00:00Z.
  T0 = 1_787_875_200'i64
  # An hour, which is the order of an ID token's life. Not a constant borrowed
  # from anywhere: the point of the derived refresh band is that the client
  # works for whatever lifetime the issuer chose.
  Hour = 3600'i64

proc b64u(s: string): string =
  encode(s).replace("+", "-").replace("/", "_").replace("=", "")

proc jws(payload: JsonNode; kid = TestKeyId; alg = "RS256";
         segments = 3; signature = "sig-bytes"): string =
  ## header.payload.signature, assembled here rather than by `jwt.nim`.
  let header = %*{"alg": alg, "kid": kid, "typ": "JWT"}
  result = b64u($header) & "." & b64u($payload)
  if segments >= 3:
    result.add("." & b64u(signature))

proc claimsJson(subject = Subject; issuer = Issuer; audience = Aud;
                issuedAt = T0; expiresAt = T0 + Hour;
                notBefore = 0'i64): JsonNode =
  result = %*{"sub": subject, "iss": issuer, "aud": audience}
  if issuedAt != 0: result["iat"] = %issuedAt
  if expiresAt != 0: result["exp"] = %expiresAt
  if notBefore != 0: result["nbf"] = %notBefore

proc keys(kid = TestKeyId): seq[JwkKey] =
  ## What the issuer publishes. `n` and `e` are not exercised here — nothing in
  ## this suite verifies a signature — but `selectKey` refuses a key with an
  ## empty modulus, so they have to be present for the key to be usable at all.
  @[JwkKey(kid: kid, alg: "RS256", kty: "RSA", n: "AQAB", e: "AQAB")]

proc inspect(payload: JsonNode; kid = TestKeyId; alg = "RS256";
             published = TestKeyId; audience = Aud): TokenInspection =
  inspectJws(jws(payload, kid = kid, alg = alg), keys(published), Issuer,
             audience)

proc decide(payload: JsonNode; nowUnix = T0): IdentityDecision =
  let i = inspect(payload)
  if not i.inspectionOk():
    return rejectedDecision(i.inspectionKind(), i.inspectionDetail())
  decideVerified(i.inspectionClaims(), nowUnix)

suite "identity token (ID1)":

  # -------------------------------------------------------------------------
  test "the refresh point is derived from the token's own lifetime":
    ## NOT CONFIGURED, AND NOT A CLAIM. The retired version read a
    ## `renew_after` claim whose default came from licensing's
    ## `LICENSE_RENEW_LEAD` — a field no OIDC issuer emits, so the client was
    ## reading something only it wrote. Half the token's own lifetime scales
    ## with whatever the issuer chose, which is the property that matters when
    ## the issuer moves from an hour to fifteen minutes.
    let i = inspect(claimsJson())
    counted i.inspectionOk()
    let c = i.inspectionClaims()
    counted c.issuedAt() == T0
    counted c.expiresAt() == T0 + Hour
    counted c.renewAfter() == T0 + Hour div 2

    # A fifteen-minute token refreshes at seven and a half minutes, with no
    # constant changed anywhere.
    let short = inspect(claimsJson(expiresAt = T0 + 900)).inspectionClaims()
    counted short.renewAfter() == T0 + 450

    # And a token whose timestamps cannot describe a lifetime has no refresh
    # point at all, rather than one in the past.
    let noIat = inspect(claimsJson(issuedAt = 0)).inspectionClaims()
    counted noIat.renewAfter() == 0

  # -------------------------------------------------------------------------
  test "the bands, and expiry is inclusive":
    ## The boundary that matters: a token is NOT valid at the second it
    ## expires. An exclusive test accepts it for one more second, which is the
    ## kind of off-by-one that never shows up in a functional test.
    let c = inspect(claimsJson()).inspectionClaims()

    counted bandAt(c, T0) == ibNormal
    counted bandAt(c, T0 + Hour div 2 - 1) == ibNormal
    counted bandAt(c, T0 + Hour div 2) == ibRenewing
    counted bandAt(c, T0 + Hour - 1) == ibRenewing
    counted bandAt(c, T0 + Hour) == ibExpired
    counted bandAt(c, T0 + Hour + 1) == ibExpired

    # `nbf` is EXCLUSIVE, and is tested FIRST: a token whose `nbf` is after its
    # `exp` reads as not-yet-valid rather than expired, because that is the
    # more accurate thing to tell somebody.
    let future = inspect(claimsJson(notBefore = T0 + 10)).inspectionClaims()
    counted bandAt(future, T0) == ibNotYetValid
    counted bandAt(future, T0 + 9) == ibNotYetValid
    counted bandAt(future, T0 + 10) == ibNormal

    let inverted = inspect(claimsJson(notBefore = T0 + Hour + 100)).inspectionClaims()
    counted bandAt(inverted, T0 + Hour + 1) == ibNotYetValid

    # THREE BANDS RENEW OR DO NOT, and only one renews. There is no second
    # band that also renews, because there is no warning band.
    counted shouldAttemptRenewal(ibRenewing)
    counted not shouldAttemptRenewal(ibNormal)
    counted not shouldAttemptRenewal(ibExpired)
    counted not shouldAttemptRenewal(ibNotYetValid)

  # -------------------------------------------------------------------------
  test "inspection takes no clock, so expiry is decided in one place":
    ## `inspectJws` is deliberately clock-free: `exp` and `nbf` are left to
    ## `bandAt`. A version that also checked the window would make a token's
    ## validity a function of two comparisons that can drift apart.
    ##
    ## Asserted behaviourally rather than by reading the signature: an
    ## ALREADY-EXPIRED token inspects OK. It is `decideVerified` that calls it
    ## expired, and it still returns the claims when it does.
    let expired = claimsJson(issuedAt = T0 - 2 * Hour, expiresAt = T0 - Hour)
    let i = inspect(expired)
    counted i.inspectionOk()
    counted i.inspectionKind() == dkAccepted

    let d = decide(expired, nowUnix = T0)
    counted d.kind() == dkExpired
    counted d.band() == ibExpired
    # CLAIMS ARE RETURNED. A product cannot write "your session ended" without
    # knowing whose, and expiry falls back to the anonymous tier rather than
    # refusing — refusing is not even enforceable, since a user can delete the
    # token and get that tier anyway.
    counted d.claims().subject() == Subject
    counted not d.identityIsInForce()

    # ...and a token valid at the same instant is in force, which is the
    # control that stops the above being true of a decision that refuses
    # everything.
    counted decide(claimsJson()).identityIsInForce()

  # -------------------------------------------------------------------------
  test "a key the issuer does not publish is refused, distinctly":
    ## `dkUnknownKeyId` and `dkBadSignature` must stay different, because a
    ## product has to be able to say "update to pick up the new key" rather
    ## than "your token is forged". This is the rotation story, and it is now
    ## the issuer's JWKS rather than a set pinned into the build.
    let rotated = inspect(claimsJson(), kid = RotatedKeyId,
                          published = TestKeyId)
    counted not rotated.inspectionOk()
    counted rotated.inspectionKind() == dkUnknownKeyId
    counted RotatedKeyId in rotated.inspectionDetail()

    # The same token against a JWKS that HAS rotated is fine, with nothing
    # rebuilt — which is the whole reason the keys are fetched.
    let afterRotation = inspect(claimsJson(), kid = RotatedKeyId,
                                published = RotatedKeyId)
    counted afterRotation.inspectionOk()

  # -------------------------------------------------------------------------
  test "another issuer, and another of our issuer's clients, are told apart":
    ## Two different facts that both mean "not ours", and they need different
    ## words. A wrong `iss` is somebody else's account system. A wrong `aud` is
    ## our own issuer minting a token for a different client of ours — genuine,
    ## unexpired, correctly signed, and not for us. Collapsing them would
    ## report a configuration mistake as an attack.
    let foreign = inspectJws(jws(claimsJson(issuer = "https://login.evil.example")),
                             keys(), Issuer, Aud)
    counted not foreign.inspectionOk()
    counted foreign.inspectionKind() == dkWrongIssuer

    let otherClient = inspect(claimsJson(audience = "some-other-client"))
    counted not otherClient.inspectionOk()
    counted otherClient.inspectionKind() == dkWrongAudience

    counted dkWrongIssuer != dkWrongAudience
    counted dkWrongIssuer != dkMalformed
    counted dkWrongAudience != dkMalformed

  # -------------------------------------------------------------------------
  test "a token that is not a token is refused, and says which part":
    # Structure first: the parser's refusals arrive here as `dkMalformed` with
    # the parser's own sentence, so a reader is told what was wrong.
    let twoSegments = inspectJws(jws(claimsJson(), segments = 2), keys(),
                                 Issuer, Aud)
    counted not twoSegments.inspectionOk()
    counted twoSegments.inspectionKind() == dkMalformed
    counted "three" in twoSegments.inspectionDetail()

    # `alg` is the ISSUER's to state. `none` strips the check outright and
    # HS256 invites verifying an RSA public key as an HMAC secret.
    for hostile in ["none", "HS256", "ES256"]:
      let bad = inspect(claimsJson(), alg = hostile)
      counted not bad.inspectionOk()
      counted bad.inspectionKind() == dkMalformed

    # A payload that is not JSON at all.
    let notJson = inspectJws(b64u("""{"alg":"RS256","kid":"k"}""") & "." &
                             b64u("{not json") & "." & b64u("sig"),
                             keys(kid = "k"), Issuer, Aud)
    counted not notJson.inspectionOk()
    counted notJson.inspectionKind() == dkMalformed

  # -------------------------------------------------------------------------
  test "claims that do not hold together are refused, each by name":
    ## TWO RULES, DOWN FROM SEVEN. The five that went were windows. What is
    ## left is what nothing upstream checks: `jwt` covers `alg`, `kid`, `iss`,
    ## `aud`, `exp` and `nbf`, and none of it looks at `sub` or at the two
    ## timestamps agreeing with each other.
    let noSubject = inspect(claimsJson(subject = ""))
    counted not noSubject.inspectionOk()
    counted noSubject.inspectionKind() == dkMalformed
    counted "subject" in noSubject.inspectionDetail()

    let inverted = inspect(claimsJson(issuedAt = T0 + Hour, expiresAt = T0))
    counted not inverted.inspectionOk()
    counted "lifetime" in inverted.inspectionDetail()

    # THE POSITIVE TWIN, and it is what stops `claimRuleViolation` becoming a
    # function that returns a sentence for everything.
    counted claimRuleViolation(inspect(claimsJson()).inspectionClaims()) == ""

  # -------------------------------------------------------------------------
  test "claims cannot be authored by a product":
    ## Enforced by the type system rather than by review. The fields are
    ## unexported, the accessors are all `func`, and there is no exported
    ## constructor — so a product that wants to invent a subject has to change
    ## `token.nim` to do it.
    counted not compiles(IdentityClaims(subjectField: "forged"))
    counted not compiles(IdentityClaims().subjectField)
    counted not compiles(IdentityClaims().expiresAtField)

    var c = inspect(claimsJson()).inspectionClaims()
    counted not compiles(c.subjectField = "forged")
    counted c.subject() == Subject

    # And a decision cannot be forged into an acceptance: the only exported
    # constructor coerces `dkAccepted` away.
    let forged = rejectedDecision(dkAccepted, "trying to manufacture one")
    counted forged.kind() == dkMalformed
    counted not forged.identityIsInForce()
    counted forged.claims().subject() == ""

  # -------------------------------------------------------------------------
  test "nothing here carries an entitlement":
    ## An identity token that also carried entitlements would re-create the
    ## licensing/identity conflation one layer down. Identity says WHO;
    ## entitlement is licensing's and billing's.
    ##
    ## Asserted as an absence, which is only meaningful because it is checked
    ## at compile time: these names existed in this file's previous version.
    counted not compiles(IdentityClaims().entitlementsField)
    counted not compiles(inspect(claimsJson()).inspectionClaims().entitlements())
    counted not compiles(hasEntitlement(
      inspect(claimsJson()).inspectionClaims(), "replay:unlimited"))
    counted not compiles(entitlementsAreInForce(decide(claimsJson())))
    # The replacement says what it means.
    counted decide(claimsJson()).identityIsInForce()

  # -------------------------------------------------------------------------
  test "nothing here inherits a licensing window":
    ## The other half of the same claim, and the reason it is a case rather
    ## than a comment: every one of these names was exported from this module,
    ## and a rewrite that reintroduced one would compile silently.
    counted not compiles(DefaultLicensePeriod)
    counted not compiles(DefaultRenewLead)
    counted not compiles(DefaultWarnLead)
    counted not compiles(MaxRevocationLatency)
    counted not compiles(defaultWindowPolicy())
    counted not compiles(WindowPolicy())
    counted not compiles(ibWarning)
    counted not compiles(shouldWarnUser(ibRenewing))
    counted not compiles(IdentityMagic)
    counted not compiles(SignatureLen)
    counted not compiles(PinnedKeyring())
    counted not compiles(emptyRevocations())

  # -------------------------------------------------------------------------
  test "assertion count":
    ## The fingerprint. A count that moves without a matching change to the
    ## cases above means a case stopped running — trap 4b's silent skip, which
    ## a pass/fail tally cannot show.
    check countedAssertions == ExpectedAssertions
