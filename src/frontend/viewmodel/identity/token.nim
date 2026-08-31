## The CodeTracer identity token, and its verification — ID1.
##
## `CodeTracer-Identity.milestones.org` ID1: "Issue a signed identity token
## every product verifies **locally**, carrying the subject and the entitlement
## claims the billing service resolves." This module is the verification half,
## and it is the thing ID1's last deliverable calls "a verification library
## each product links, so no product implements this twice".
##
## ## Why it lives here, and why it is pure Nim
##
## ID0 was decided on 2026-08-31: identity extends the accounts already on
## `codetracer-ci`, following the CTL pattern licensing proved in production.
## The obvious place to put the verifier is therefore beside licensing's, in
## `codetracer-native-backend`'s Rust — and that is wrong for this layer, for
## one measured reason: **`ct_license_ffi` is a Rust cdylib, and two of the
## products that must link this are Nim compiled to JavaScript.** Noir Studio
## and BlockTracer run in a browser tab. A cdylib is not linkable there, so a
## Rust-only verifier would force a second implementation, which is precisely
## what the deliverable forbids.
##
## Nim under `viewmodel/` compiles to both C and JS, is what BlockTracer
## already consumes, and is reachable from `src/ct` for the CLI. So the
## POLICY — bands, claims, rotation, revocation — lives here once, and the
## PRIMITIVE — the Ed25519 check — is injected per platform (`ct_license_ffi`
## on native, WebCrypto in a tab). That seam is the `SignatureVerifier` below.
##
## ## This module cannot reach the network, structurally
##
## `test_verification_needs_no_network` asks that verification proceed with the
## network disabled. Rather than assert that dynamically, this module is
## written so that it *has no capability to do otherwise*:
##
##   * it imports nothing from `viewmodel/host/`, nothing from `platform/`, and
##     no `std` module that can open a socket;
##   * it does not read a clock — `nowUnix` is a parameter. That is also why it
##     avoids `std/times`, whose behaviour differs across the two backends;
##   * it does not read a file, an environment variable, or a global.
##
## Every input arrives as an argument, so "no network call is on the path" is a
## property of the signature rather than a promise about the body.
##
## ## The bands are INHERITED, not invented
##
## ID1's third deliverable says bounded offline grace "inheriting licensing's
## windows and per-account exceptions rather than inventing new ones".
## `CodeTracer-End-User-Licensing.md` §3.3.1a publishes exactly that model, and
## the finding that shaped this file is that **it publishes it and nothing
## implements it**: `renew_after`, `warn_after` and `key_id` appear in the
## spec's own CTL field table and in neither the Rust verifier nor the C#
## issuer. `LicenseValidity` has three states — `Valid`, `NotYetValid`,
## `Expired` — and `is_valid()` is a strict equality, so there is no grace
## concept in the code at all.
##
## So the four bands below are the spec's, with the spec's numbers:
##
## ```text
## issued_at            renew_after        warn_after         expires_at
##     |--------------------|------------------|------------------|------->
##       ibNormal              ibRenewing         ibWarning         ibExpired
##       no network needed     silent renewal     names the date    free tier
## ```
##
## And the last band is the one people get wrong: **expiry falls back, it does
## not refuse.** §3.3.1a gives the reason, and it is stronger than kindness —
## refusing is not enforceable, because a user whose token expired can delete
## it and get the anonymous tier that ID3 guarantees anyway. `ibExpired` is
## therefore a loss of *entitlement*, never of the core loop.
##
## ## What a product may do with the result
##
## ID1: "Claims are **read** by products, never authored by them — entitlement
## policy stays per product, identity does not." That is enforced by the type
## system here rather than by review: `IdentityClaims`'s fields are not
## exported, the accessors are all `func`, and **there is no exported
## constructor**. The only way to obtain claims is `verifyToken`, which will
## not produce them without a signature that checks out. A product that wants
## to invent a subject has to change this file to do it.

import std/[json, strutils]

# ---------------------------------------------------------------------------
# The container.
#
# Deliberately the CTL shape, because ID1 says "where the two can be one
# mechanism they should be" and a second envelope format would be a second
# thing to get wrong. The magic differs — a licence and an identity token
# authorise different things and must not be substitutable for one another,
# which a shared magic would permit.
# ---------------------------------------------------------------------------
const
  IdentityMagic* = "CTI\x01"
    ## 4 bytes. `CTL\x01` is the licence container; this is deliberately not it.
  SignatureLen* = 64
    ## Ed25519.
  MinTokenLen* = 4 + 4 + 2 + SignatureLen
    ## magic + length + the smallest possible payload (`{}`) + signature.
  MaxPayloadLen* = 64 * 1024
    ## An identity token is claims, not a document. Licensing allows 1 MiB for
    ## a licence; this is smaller on purpose, because the parser runs on every
    ## verification and an unbounded one is a denial-of-service surface that no
    ## legitimate token needs.

# ---------------------------------------------------------------------------
# The published windows — CodeTracer-End-User-Licensing.md §3.3.1a.
#
# These are the spec's numbers and must not be adjusted here. §3.3.1a states
# them as configuration rather than constants ("the right values differ between
# a cancelled monthly subscriber and an air-gapped enterprise site"), so they
# are the DEFAULTS a token is measured against, and a token may carry wider
# ones — see `WindowPolicy` and the exception rule below.
# ---------------------------------------------------------------------------
const
  SecondsPerDay* = 86_400'i64
  DefaultLicensePeriod* = 30'i64 * SecondsPerDay
    ## `LICENSE_PERIOD`: expires_at - issued_at.
  DefaultRenewLead* = 14'i64 * SecondsPerDay
    ## `LICENSE_RENEW_LEAD`: expires_at - renew_after.
  DefaultWarnLead* = 7'i64 * SecondsPerDay
    ## `LICENSE_WARN_LEAD`: expires_at - warn_after.

  MaxRevocationLatency* = DefaultLicensePeriod
    ## **The window `test_revocation_takes_effect_within_the_stated_window`
    ## must cite.** §3.3.1a: "Revocation reaches a client at its next renewal,
    ## and no sooner. That is the honest statement of what this buys:
    ## cancellation leakage is bounded by the renewal period rather than
    ## eliminated."
    ##
    ## The spec states that qualitatively and never writes a number in the
    ## revocation sentence itself, so this constant DERIVES one, and the
    ## derivation is the claim: a client re-contacts the issuer no later than
    ## `renew_after`, and holds a token no longer than `expires_at`, so the
    ## worst case is a full `LICENSE_PERIOD`. `revocationLatencyBound` below is
    ## the general form, and `identityInvariantsHold` pins the relationship so
    ## that moving any window without moving this is a failing build rather
    ## than a silent widening of the leak.

type
  WindowPolicy* = object
    ## What the *client* considers acceptable. Not what the token asserts —
    ## the token carries its own timestamps and this is what they are checked
    ## against, which is the difference between reading a claim and trusting
    ## one.
    licensePeriod*: int64
    renewLead*: int64
    warnLead*: int64

func defaultWindowPolicy*(): WindowPolicy =
  WindowPolicy(licensePeriod: DefaultLicensePeriod,
               renewLead: DefaultRenewLead,
               warnLead: DefaultWarnLead)

func revocationLatencyBound*(policy: WindowPolicy): int64 =
  ## The worst-case time between an account being revoked and every client
  ## having lost the entitlement. A token is held at most `licensePeriod`, so
  ## that is the bound — renewal makes the TYPICAL case `renewLead`, and the
  ## typical case is not what a security window is stated in.
  policy.licensePeriod

func identityInvariantsHold*(policy: WindowPolicy): bool =
  ## The band boundaries must be strictly ordered, or the state machine below
  ## has bands that cannot be entered. Checked rather than assumed because
  ## §3.3.1a permits these to be configured per account, and a configuration
  ## that inverts them would silently delete the warning band.
  policy.licensePeriod > policy.renewLead and
    policy.renewLead > policy.warnLead and
    policy.warnLead > 0

type
  IdentityBand* = enum
    ## §3.3.1a's four bands, plus the two states that precede having a usable
    ## token at all. The ORDER is meaningful: everything from `ibNormal` to
    ## `ibWarning` is a working product, `ibExpired` is a working product
    ## without paid entitlement, and the two below `ibNormal` are not a
    ## product state but a verification failure.
    ibNotYetValid
      ## `now < not_before`. A token issued for the future.
    ibNormal
      ## `issued_at` .. `renew_after`. No network required, none attempted.
    ibRenewing
      ## `renew_after` .. `warn_after`. Renewal is attempted in the background
      ## whenever connectivity exists. SILENT: a user who is online never
      ## learns this band exists.
    ibWarning
      ## `warn_after` .. `expires_at`. Still working. The user is told the
      ## date — §3.3.1a: "The message names the date, not a countdown."
    ibExpired
      ## Past `expires_at`. Paid entitlement stops; the product does NOT.

  DecisionKind* = enum
    ## Why a token was or was not accepted. Note `dkRevoked` and `dkExpired`
    ## are DISTINCT, and that distinction does not exist in licensing today:
    ## `LicenseStatus` has no `Expired` variant at all and launders expiry into
    ## the free-tier path, so "no token" and "expired token" are
    ## indistinguishable at its API boundary. A product that cannot tell them
    ## apart cannot write §3.3.1a's warning message, which is why this enum
    ## separates them.
    dkAccepted
      ## The signature checked out and the token is within its life. The band
      ## says which part of it.
    dkExpired
      ## Verified, but past `expires_at`. **Claims are still returned** — the
      ## subject is known, the entitlements are not in force. A product needs
      ## the subject to say whose token expired.
    dkRevoked
      ## Verified and in date, but the subject is on the revocation list.
    dkUnknownKeyId
      ## No pinned key bears this `key_id`. This is what makes rotation
      ## expressible at all: licensing has no `key_id` in its container and
      ## bounds a compromised key only with a 365-day binary-age gate.
    dkBadSignature
      ## A pinned key exists for the `key_id` and rejected the message.
    dkMalformed
      ## Container or claims did not parse, or violated a rule below.

  IdentityClaims* = object
    ## Read-only by construction: no field is exported, and no constructor is.
    ## `verifyToken` is the only producer in the module's public surface.
    subjectField: string
    keyIdField: string
    issuedAtField: int64
    notBeforeField: int64
    renewAfterField: int64
    warnAfterField: int64
    expiresAtField: int64
    entitlementsField: seq[string]
    windowExceptionReasonField: string

  IdentityDecision* = object
    kindField: DecisionKind
    bandField: IdentityBand
    claimsField: IdentityClaims
    detailField: string

  SignatureVerifier* = proc(keyId: string; message: openArray[byte];
                            signature: openArray[byte]): bool {.gcsafe, raises: [].}
    ## The injected primitive. Returns false for an unknown key id as well as a
    ## bad signature; `PinnedKeyring.knows` distinguishes the two, because a
    ## product must be able to say "update to pick up the new key" rather than
    ## "your token is forged".

  PinnedKeyring* = object
    ## The keys this BUILD trusts, pinned at build time — the
    ## `PRODUCTION_VERIFYING_KEY_BYTES` pattern `enforcement.rs` already uses,
    ## generalised from one key to a set so that rotation does not require the
    ## binary-age gate to be the only answer.
    keyIds*: seq[string]
    verify*: SignatureVerifier

# ---------------------------------------------------------------------------
# Accessors. All `func`, all read-only. This is deliverable 5.
# ---------------------------------------------------------------------------
func subject*(c: IdentityClaims): string = c.subjectField
func keyId*(c: IdentityClaims): string = c.keyIdField
func issuedAt*(c: IdentityClaims): int64 = c.issuedAtField
func notBefore*(c: IdentityClaims): int64 = c.notBeforeField
func renewAfter*(c: IdentityClaims): int64 = c.renewAfterField
func warnAfter*(c: IdentityClaims): int64 = c.warnAfterField
func expiresAt*(c: IdentityClaims): int64 = c.expiresAtField
func entitlements*(c: IdentityClaims): seq[string] = c.entitlementsField
func windowExceptionReason*(c: IdentityClaims): string =
  c.windowExceptionReasonField

func kind*(d: IdentityDecision): DecisionKind = d.kindField
func band*(d: IdentityDecision): IdentityBand = d.bandField
func claims*(d: IdentityDecision): IdentityClaims = d.claimsField
func detail*(d: IdentityDecision): string = d.detailField

func hasEntitlement*(c: IdentityClaims; name: string): bool =
  ## Reading an entitlement is a lookup, never a policy decision. What a
  ## product DOES about a missing entitlement is the product's business; ID1's
  ## rule is only that the claim itself is not authored here.
  for e in c.entitlementsField:
    if e == name:
      return true
  false

func entitlementsAreInForce*(d: IdentityDecision): bool =
  ## The single question a product should ask before granting a paid surface.
  ## `dkExpired` returns claims and this returns false for it, which is the
  ## whole point of returning claims for an expired token.
  d.kindField == dkAccepted

# ---------------------------------------------------------------------------
# The revocation list.
# ---------------------------------------------------------------------------
type
  RevocationList* = object
    subjects*: seq[string]
    obtainedAt*: int64
      ## When the client last refreshed this list. Carried so that a product
      ## can say how stale its knowledge is; the bound on that staleness is
      ## `revocationLatencyBound`.

func emptyRevocations*(): RevocationList =
  RevocationList(subjects: @[], obtainedAt: 0)

func isRevoked*(list: RevocationList; subject: string): bool =
  for s in list.subjects:
    if s == subject:
      return true
  false

# ---------------------------------------------------------------------------
# The band, as a pure function of the claims and the clock.
# ---------------------------------------------------------------------------
func bandAt*(c: IdentityClaims; nowUnix: int64): IdentityBand =
  ## Boundary conventions are licensing's, deliberately, so that a token and a
  ## licence do not disagree about the same instant: expiry is INCLUSIVE
  ## (`is_expired` uses `>=`), `not_before` is EXCLUSIVE (`<`), and
  ## `not_before` is tested FIRST so a token whose `not_before` is after its
  ## `expires_at` reports not-yet-valid rather than expired.
  if c.notBeforeField > 0 and nowUnix < c.notBeforeField:
    return ibNotYetValid
  if c.expiresAtField > 0 and nowUnix >= c.expiresAtField:
    return ibExpired
  if c.warnAfterField > 0 and nowUnix >= c.warnAfterField:
    return ibWarning
  if c.renewAfterField > 0 and nowUnix >= c.renewAfterField:
    return ibRenewing
  ibNormal

func shouldAttemptRenewal*(band: IdentityBand): bool =
  ## True in both grace bands. §3.3.1a starts renewal at `renew_after` and does
  ## not stop it when warnings begin.
  band in {ibRenewing, ibWarning}

func shouldWarnUser*(band: IdentityBand): bool =
  ## §3.3.1a: the renewing band is SILENT. Warning the user there would make a
  ## band whose whole purpose is invisibility visible.
  band == ibWarning

# ---------------------------------------------------------------------------
# Claim rules that do not depend on the signature.
# ---------------------------------------------------------------------------
func windowsExceedPolicy*(c: IdentityClaims; policy: WindowPolicy): bool =
  ## A token may carry wider windows than the defaults — §3.3.1a permits it —
  ## but only as "an explicit per-account exception with a recorded reason,
  ## not a global loosening".
  # A token that never expires is the widest window there is. Licensing uses
  # `expires_at == 0` as a lifetime sentinel; an identity token must not,
  # because a subject that can never be revoked defeats the window this module
  # exists to bound.
  if c.expiresAtField <= 0:
    return true
  let period = c.expiresAtField - c.issuedAtField
  let renewLead = c.expiresAtField - c.renewAfterField
  period > policy.licensePeriod or renewLead > policy.renewLead

func claimRuleViolation*(c: IdentityClaims; policy: WindowPolicy): string =
  ## Empty when the claims are self-consistent. The returned sentence is what
  ## `dkMalformed`'s detail carries, so a rejection always names its reason.
  if c.subjectField.len == 0:
    return "the token names no subject"
  if c.keyIdField.len == 0:
    return "the token names no key_id, so it cannot be verified after a rotation"
  if c.expiresAtField <= 0:
    return "the token never expires; an identity token must be bounded so that " &
      "revocation has a window"
  if c.issuedAtField >= c.expiresAtField:
    return "issued_at is not before expires_at"
  if c.renewAfterField <= 0 or c.warnAfterField <= 0:
    return "the token omits renew_after or warn_after, so it has no grace bands"
  if not (c.renewAfterField < c.warnAfterField and
      c.warnAfterField < c.expiresAtField):
    return "renew_after < warn_after < expires_at does not hold, so a band is " &
      "unreachable"
  if windowsExceedPolicy(c, policy) and c.windowExceptionReasonField.len == 0:
    return "the token's windows exceed the published defaults and record no " &
      "reason; §3.3.1a allows a per-account exception only with a recorded reason"
  ""

# ---------------------------------------------------------------------------
# Parsing.
# ---------------------------------------------------------------------------
func readU32LE(raw: openArray[byte]; at: int): uint32 =
  uint32(raw[at]) or (uint32(raw[at + 1]) shl 8) or
    (uint32(raw[at + 2]) shl 16) or (uint32(raw[at + 3]) shl 24)

proc parseClaims(payload: string; claims: var IdentityClaims): string =
  ## Returns an error sentence, or "" and fills `claims`.
  ##
  ## THE BARE `except:` IS DELIBERATE AND CONTRIBUTING.md SAYS WHY. On the C
  ## backend `parseJson` raises `JsonParsingError`, a `CatchableError`. On the
  ## JS backend it defers to V8's `JSON.parse`, which throws a raw `SyntaxError`
  ## that NO Nim exception type matches — so `except CatchableError` catches
  ## nothing there and the exception escapes into the renderer. This module
  ## runs on both backends by design, and a malformed token is attacker-shaped
  ## input, so the narrow form would be a crash on the backend two of the
  ## products ship on.
  var node: JsonNode
  try:
    node = parseJson(payload)
  except:
    return "the claims payload is not valid JSON"
  if node.kind != JObject:
    return "the claims payload is not a JSON object"

  func str(n: JsonNode; key: string): string =
    let f = n{key}
    if f.isNil or f.kind != JString: "" else: f.getStr

  func num(n: JsonNode; key: string): int64 =
    let f = n{key}
    if f.isNil or f.kind != JInt: 0'i64 else: f.getBiggestInt

  claims.subjectField = str(node, "sub")
  claims.keyIdField = str(node, "key_id")
  claims.issuedAtField = num(node, "issued_at")
  claims.notBeforeField = num(node, "not_before")
  claims.renewAfterField = num(node, "renew_after")
  claims.warnAfterField = num(node, "warn_after")
  claims.expiresAtField = num(node, "expires_at")
  claims.windowExceptionReasonField = str(node, "window_exception_reason")

  claims.entitlementsField = @[]
  let ents = node{"entitlements"}
  if not ents.isNil and ents.kind == JArray:
    for item in ents.items:
      if item.kind == JString:
        claims.entitlementsField.add item.getStr
  ""

func knows*(keyring: PinnedKeyring; keyId: string): bool =
  for k in keyring.keyIds:
    if k == keyId:
      return true
  false

# ---------------------------------------------------------------------------
# THE ENTRY POINT.
#
# Every input is an argument. There is no clock read, no file read, no
# environment read and no network call, and that is checked by the signature
# rather than asserted about the body.
# ---------------------------------------------------------------------------
proc verifyToken*(raw: openArray[byte]; keyring: PinnedKeyring;
                  nowUnix: int64; revocations: RevocationList;
                  policy: WindowPolicy): IdentityDecision =
  template reject(k: DecisionKind; why: string): IdentityDecision =
    IdentityDecision(kindField: k, bandField: ibNotYetValid,
                     claimsField: IdentityClaims(), detailField: why)

  if raw.len < MinTokenLen:
    return reject(dkMalformed, "token is shorter than the smallest valid container")
  for i in 0 ..< IdentityMagic.len:
    if raw[i] != byte(IdentityMagic[i]):
      return reject(dkMalformed,
        "container magic is not " & IdentityMagic.escape() &
        "; a licence is not an identity token")

  let declared = readU32LE(raw, 4)
  if declared > MaxPayloadLen.uint32:
    return reject(dkMalformed, "declared payload length exceeds the maximum")
  let payloadStart = 8
  let payloadEnd = payloadStart + declared.int
  if payloadEnd + SignatureLen != raw.len:
    return reject(dkMalformed,
      "declared payload length does not account for the whole container")

  var payload = newString(declared.int)
  for i in 0 ..< declared.int:
    payload[i] = char(raw[payloadStart + i])

  var claims = IdentityClaims()
  let parseError = parseClaims(payload, claims)
  if parseError.len > 0:
    return reject(dkMalformed, parseError)

  let ruleError = claimRuleViolation(claims, policy)
  if ruleError.len > 0:
    return reject(dkMalformed, ruleError)

  # Rotation before authenticity, so that an old build meeting a new key says
  # "update me" rather than "you are forged". The two are different user
  # actions and licensing cannot express the difference at all.
  if not keyring.knows(claims.keyIdField):
    return reject(dkUnknownKeyId,
      "no pinned key bears key_id '" & claims.keyIdField & "'")

  # The signature covers magic + length + payload, exactly as CTL's does.
  let signedLen = payloadEnd
  var message = newSeq[byte](signedLen)
  for i in 0 ..< signedLen:
    message[i] = raw[i]
  var signature = newSeq[byte](SignatureLen)
  for i in 0 ..< SignatureLen:
    signature[i] = raw[payloadEnd + i]

  if keyring.verify.isNil:
    return reject(dkMalformed, "no signature verifier was supplied")
  if not keyring.verify(claims.keyIdField, message, signature):
    return reject(dkBadSignature, "the pinned key rejected this token")

  # Only now are the claims trustworthy enough to return.
  let band = bandAt(claims, nowUnix)

  if band == ibNotYetValid:
    return IdentityDecision(kindField: dkMalformed, bandField: band,
                            claimsField: claims,
                            detailField: "the token is not valid yet")

  # Revocation outranks expiry: a revoked subject whose token also expired is
  # revoked, because that is the fact a product must report.
  if revocations.isRevoked(claims.subjectField):
    return IdentityDecision(kindField: dkRevoked, bandField: band,
                            claimsField: claims,
                            detailField: "the subject is revoked")

  if band == ibExpired:
    # Claims ARE returned. §3.3.1a: expiry falls back to the free tier and does
    # not refuse to run, and a product cannot write "your token expired on <date>"
    # without the subject and the date.
    return IdentityDecision(kindField: dkExpired, bandField: band,
                            claimsField: claims,
                            detailField: "the token expired; entitlements are not in force")

  IdentityDecision(kindField: dkAccepted, bandField: band, claimsField: claims,
                   detailField: "")
