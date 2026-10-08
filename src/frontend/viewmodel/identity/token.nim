## The CodeTracer identity token: an OpenID Connect ID token, inspected and
## decided upon.
##
## ## What this file used to be, and why that was wrong
##
## It used to define `CTI\x01` — a binary container with a 4-byte magic, an
## LE32 length and a 64-byte Ed25519 signature — and four grace bands with
## licensing's numbers (30 days, 14, 7) taken from
## `CodeTracer-End-User-Licensing.md` §3.3.1a. Both came from reading identity
## and licensing as one question.
##
## **They are not one question.** Licensing asks what this installation may
## run, and must answer on an air-gapped machine; that is why it bakes a key at
## build time, defines its own container, and needs a month of offline grace.
## Identity asks who the user is, and a user signing in is online by
## construction. Inheriting licensing's model made building look cheap and
## adopting look expensive, because the comparison carried a constraint that
## was never identity's.
##
## So the container is gone — a token is a compact JWS from
## `login.metacraft-labs.com`, and `jwt.nim` parses it — and the windows are
## gone with it. **Offline entitlement is still solved, by licensing, which this
## file does not touch.** What identity keeps is one much smaller thing: refresh
## before the issuer's own `exp`, so a user is not bounced out mid-session.
##
## ## The bands that remain, and where their numbers come from
##
## ```text
## iat                      iat + lifetime/2                 exp
##  |------------------------------|------------------------->|------->
##     ibNormal                      ibRenewing                 ibExpired
##     nothing to do                 refresh in background       sign in again
## ```
##
## Three, not four, and the missing one is the point: `ibWarning` existed to
## name a date to the user, which only makes sense when expiry is weeks away
## and the remedy is a purchase. An ID token lives about an hour and renews
## from a refresh token without the user present, so a warning band would be a
## dialog about something the client is already fixing.
##
## The refresh point is HALF THE TOKEN'S OWN LIFETIME, derived from `iat` and
## `exp` rather than configured. That is ordinary OAuth client hygiene and not
## a window inherited from anywhere: it scales with whatever lifetime the
## issuer chose, so a client tuned for a one-hour token still behaves when the
## issuer moves to fifteen minutes.
##
## ## This module cannot reach the network, structurally
##
## Unchanged from the version this replaces, and still the property worth the
## most:
##
##   * it imports nothing from `viewmodel/host/`, nothing from `platform/`, and
##     no `std` module that can open a socket;
##   * it does not read a clock — `nowUnix` is a parameter. That is also why it
##     avoids `std/times`, whose behaviour differs across the two backends;
##   * it does not read a file, an environment variable, or a global;
##   * it carries no conditional compilation at all, which
##     `identity-no-escape-hatch.sh` asserts by counting — and the count is of
##     text, not of code, so this sentence cannot spell the construct it is
##     about. One behaviour on every backend.
##
## `inspectJws` takes the issuer's keys as an argument and the signature check
## happens one layer up, in `session.admit`, because `crypto.subtle.verify`
## returns a promise and a module that can await can be handed something that
## fetches.
##
## ## What a product may do with the result
##
## Claims are **read** by products, never authored by them. Enforced by the type
## system rather than by review: `IdentityClaims`'s fields are not exported,
## the accessors are all `func`, and **there is no exported constructor**. A
## product that wants to invent a subject has to change this file to do it.
##
## Note what is NOT here any more: `entitlements`. An identity token that also
## carried entitlements would re-create the conflation above, one layer down.
## Entitlement is licensing's and billing's; identity says who, and nothing
## else.

import std/[json, strutils]
import ./issuer
import ./jwt

export jwt.JwkKey, jwt.JwtError
export issuer.VerifiableAlgs, issuer.DefaultIssuer

type
  IdentityBand* = enum
    ## The ORDER is meaningful: `ibNormal` and `ibRenewing` are a working
    ## signed-in product, `ibExpired` is a working product that must sign in
    ## again, and `ibNotYetValid` is not a product state but a verification
    ## failure.
    ibNotYetValid
      ## `now < nbf`. A token issued for the future.
    ibNormal
      ## Valid, and not yet half-way through its life. Nothing to do.
    ibRenewing
      ## Past half its life. Renew in the background from the refresh token.
      ## SILENT: a user who is online never learns this band exists.
    ibExpired
      ## Past `exp`. The product keeps working on the anonymous tier ID3
      ## guarantees; the user is asked to sign in again.

  DecisionKind* = enum
    ## Why a token was or was not accepted. `dkExpired` and `dkRevoked` stay
    ## distinct because they need different words to a user: one says sign in
    ## again, the other says this session was ended elsewhere.
    dkAccepted
      ## The signature checked out and the token is within its life.
    dkExpired
      ## Verified, but past `exp`. **Claims are still returned** — a product
      ## needs the subject to say whose session ended.
    dkRevoked
      ## The issuer refused to renew (`invalid_grant`). Sourced by the session
      ## layer from a failed refresh, which is how OIDC actually delivers
      ## revocation: there is no list to poll.
    dkUnknownKeyId
      ## The issuer's JWKS publishes no key with this `kid`. A rotated-out key
      ## is refused rather than tried against the others.
    dkBadSignature
      ## A published key exists for the `kid` and rejected the signing input.
    dkWrongIssuer
      ## Signed by somebody, correctly, and not by our issuer.
    dkWrongAudience
      ## Our issuer's token, minted for another of its clients. Genuine,
      ## unexpired, correctly signed, and not ours — which is why it is its own
      ## kind rather than `dkMalformed`.
    dkMalformed
      ## Structure or claims did not parse, or violated a rule below.

  IdentityClaims* = object
    ## Read-only by construction: no field is exported, and no constructor is.
    subjectField: string
    issuerField: string
    audienceField: string
    keyIdField: string
    issuedAtField: int64
    notBeforeField: int64
    expiresAtField: int64

  IdentityDecision* = object
    kindField: DecisionKind
    bandField: IdentityBand
    claimsField: IdentityClaims
    detailField: string

# ---------------------------------------------------------------------------
# Accessors. All `func`, all read-only.
# ---------------------------------------------------------------------------
func subject*(c: IdentityClaims): string = c.subjectField
func issuer*(c: IdentityClaims): string = c.issuerField
func audience*(c: IdentityClaims): string = c.audienceField
func keyId*(c: IdentityClaims): string = c.keyIdField
func issuedAt*(c: IdentityClaims): int64 = c.issuedAtField
func notBefore*(c: IdentityClaims): int64 = c.notBeforeField
func expiresAt*(c: IdentityClaims): int64 = c.expiresAtField

func renewAfter*(c: IdentityClaims): int64 =
  ## DERIVED, not a claim. Half the token's own lifetime, so the client scales
  ## with whatever the issuer chose rather than carrying a number of its own.
  ##
  ## A claim called `renew_after` is what the retired container had, copied
  ## from licensing's CTL field table, and it is the wrong shape for OIDC: no
  ## issuer emits one, so the client would be reading a field only it writes.
  if c.issuedAtField <= 0 or c.expiresAtField <= c.issuedAtField:
    return 0
  c.issuedAtField + (c.expiresAtField - c.issuedAtField) div 2

func rejectedDecision*(kind: DecisionKind; detail: string): IdentityDecision =
  ## The ONLY exported constructor for a decision, and it can only build a
  ## REFUSAL. `dkAccepted` is coerced to `dkMalformed`, so the session layer can
  ## report an inspection failure without acquiring the ability to manufacture
  ## an acceptance — which would be authoring an identity by the back door.
  ## The claims are always empty for the same reason a rejected token yields
  ## none.
  IdentityDecision(
    kindField: (if kind == dkAccepted: dkMalformed else: kind),
    bandField: ibNotYetValid, claimsField: IdentityClaims(),
    detailField: detail)

func kind*(d: IdentityDecision): DecisionKind = d.kindField
func band*(d: IdentityDecision): IdentityBand = d.bandField
func claims*(d: IdentityDecision): IdentityClaims = d.claimsField
func detail*(d: IdentityDecision): string = d.detailField

func identityIsInForce*(d: IdentityDecision): bool =
  ## The single question a product should ask before treating a user as signed
  ## in. `dkExpired` returns claims and this returns false for it, which is the
  ## whole point of returning claims for an expired token.
  ##
  ## It was called `entitlementsAreInForce`. Identity grants no entitlements —
  ## that is licensing's and billing's — so the old name asserted the
  ## conflation this file exists to have removed.
  d.kindField == dkAccepted

# ---------------------------------------------------------------------------
# The band, as a pure function of the claims and the clock.
# ---------------------------------------------------------------------------
func bandAt*(c: IdentityClaims; nowUnix: int64): IdentityBand =
  ## Expiry is INCLUSIVE (`>=`) and `nbf` is EXCLUSIVE (`<`), and `nbf` is
  ## tested FIRST so a token whose `nbf` is after its `exp` reports
  ## not-yet-valid rather than expired. The inclusive boundary matters: a token
  ## is not valid *at* the second it expires, and an exclusive test would
  ## accept it for one more.
  if c.notBeforeField > 0 and nowUnix < c.notBeforeField:
    return ibNotYetValid
  if c.expiresAtField > 0 and nowUnix >= c.expiresAtField:
    return ibExpired
  let renew = c.renewAfter()
  if renew > 0 and nowUnix >= renew:
    return ibRenewing
  ibNormal

func shouldAttemptRenewal*(band: IdentityBand): bool =
  ## One band, and it is silent. There is no second band that also renews,
  ## because there is no warning band: the client fixes this without the user.
  band == ibRenewing

# ---------------------------------------------------------------------------
# Claim rules that do not depend on the signature.
# ---------------------------------------------------------------------------
func claimRuleViolation*(c: IdentityClaims): string =
  ## Empty when the claims are self-consistent. The returned sentence is what
  ## `dkMalformed`'s detail carries, so a rejection always names its reason.
  ##
  ## TWO RULES, DOWN FROM SEVEN, and the five that went were windows. What is
  ## left is what nothing upstream checks: `jwt.checkIssuerAndAudience` covers
  ## `iss`/`aud`/`azp`, `jwt.parseJwt` covers `alg`/`kid`, and
  ## `jwt.checkValidityWindow` covers `exp`/`nbf` — none of them looks at `sub`
  ## or at the two timestamps agreeing with each other.
  if c.subjectField.len == 0:
    return "the token names no subject, so it identifies nobody"
  if c.issuedAtField > 0 and c.issuedAtField >= c.expiresAtField:
    return "iat is not before exp, so the token has no lifetime"
  ""

# ---------------------------------------------------------------------------
# Inspection: everything decidable WITHOUT the signature, and without a clock.
# ---------------------------------------------------------------------------
type
  TokenInspection* = object
    ## THIS TYPE EXISTS BECAUSE WEBCRYPTO IS ASYNCHRONOUS. `crypto.subtle.verify`
    ## returns a promise and there is no synchronous WebCrypto, so the options
    ## were to make verification async everywhere — which would hand the
    ## verifier a capability to await, and a proc that can await can be given
    ## something that fetches — or to split the work at the one place that
    ## genuinely needs I/O.
    ##
    ## So: inspection is PURE and takes no clock; the signature is checked
    ## ONCE, at admission, where a future is appropriate. `ct_license_ffi`
    ## already draws the same line between `ct_license_start` and
    ## `ct_license_heartbeat`, for the same reason.
    okField: bool
    kindField: DecisionKind
    detailField: string
    claimsField: IdentityClaims
    messageField: seq[byte]
    signatureField: seq[byte]

func inspectionOk*(i: TokenInspection): bool = i.okField
func inspectionKind*(i: TokenInspection): DecisionKind = i.kindField
func inspectionDetail*(i: TokenInspection): string = i.detailField
func inspectionClaims*(i: TokenInspection): IdentityClaims = i.claimsField
func signedMessage*(i: TokenInspection): seq[byte] = i.messageField
func tokenSignature*(i: TokenInspection): seq[byte] = i.signatureField

func claimsFrom(parts: JwtParts): IdentityClaims =
  ## Pure, and it cannot fail. `parts.claims` is an already-parsed JObject —
  ## `parseJwt` did the parsing and the refusing — so there is nothing here to
  ## catch. The bare `except:` that used to guard this proc's `parseJson` moved
  ## with the call it guarded, into `jwt.nim`.
  func str(n: JsonNode; key: string): string =
    let f = n{key}
    if f.isNil or f.kind != JString: "" else: f.getStr

  func num(n: JsonNode; key: string): int64 =
    let f = n{key}
    if f.isNil or f.kind != JInt: 0'i64 else: f.getBiggestInt

  result.subjectField = str(parts.claims, "sub")
  result.issuerField = str(parts.claims, "iss")
  result.issuedAtField = num(parts.claims, "iat")
  result.notBeforeField = num(parts.claims, "nbf")
  result.expiresAtField = num(parts.claims, "exp")
  # THE HEADER, not a claim. `kid` identifies the signing key and lives beside
  # `alg`; a payload that carried one would be the token naming its own key,
  # which is the same mistake as a token naming its own algorithm.
  result.keyIdField = parts.kid

func refuse(kind: DecisionKind; detail: string): TokenInspection =
  TokenInspection(okField: false, kindField: kind, detailField: detail,
                  claimsField: IdentityClaims())

proc inspectJws*(compact: string; keys: openArray[JwkKey];
                 issuer, audience: string): TokenInspection =
  ## Parse, select the key, bind to this issuer and audience, and check the
  ## claim rules — all of it without a clock and without a signature.
  ##
  ## NO CLOCK IS TAKEN, deliberately. `exp` and `nbf` are left to `bandAt`, so
  ## expiry is decided in exactly one place. A version of this that also
  ## checked the window would make a token's validity a function of two
  ## comparisons that can drift apart.
  var parts: JwtParts
  try:
    parts = parseJwt(compact, VerifiableAlgs)
  except JwtError as e:
    return refuse(dkMalformed, e.msg)

  try:
    discard selectKey(keys, parts.kid, parts.alg)
  except JwtError as e:
    return refuse(dkUnknownKeyId, e.msg)

  try:
    checkIssuerAndAudience(parts.claims, issuer, audience)
  except JwtError as e:
    # `iss` and `aud` failures are told apart because they mean different
    # things operationally: the first is somebody else's issuer, the second is
    # our issuer's token for another of its clients — a configuration mistake
    # rather than an attack, and it needs different words.
    let wrongAudience = "audience" in e.msg or "authorized party" in e.msg
    return refuse(if wrongAudience: dkWrongAudience else: dkWrongIssuer, e.msg)

  let claims = claimsFrom(parts)
  let violation = claimRuleViolation(claims)
  if violation.len > 0:
    return refuse(dkMalformed, violation)

  var message = newSeq[byte](parts.signingInput.len)
  for i, ch in parts.signingInput:
    message[i] = byte(ch)

  TokenInspection(okField: true, kindField: dkAccepted, detailField: "",
                  claimsField: claims, messageField: message,
                  signatureField: parts.signature)

proc decideVerified*(claims: IdentityClaims; nowUnix: int64): IdentityDecision =
  ## The band half, for claims whose signature HAS been checked. Pure.
  let band = bandAt(claims, nowUnix)

  if band == ibNotYetValid:
    return IdentityDecision(kindField: dkMalformed, bandField: band,
                            claimsField: claims,
                            detailField: "the token is not valid yet")

  if band == ibExpired:
    # Claims ARE returned. A product cannot write "your session ended" without
    # knowing whose, and expiry falls back to the anonymous tier rather than
    # refusing to run — refusing is not even enforceable, since a user whose
    # token expired can delete it and get that tier anyway.
    return IdentityDecision(kindField: dkExpired, bandField: band,
                            claimsField: claims,
                            detailField: "the token expired; sign in again")

  IdentityDecision(kindField: dkAccepted, bandField: band, claimsField: claims,
                   detailField: "")
