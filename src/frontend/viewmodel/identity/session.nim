## The identity session — admission, refresh, and revocation transport (ID1).
##
## `token.nim` decides whether a token is good. This decides *when to go and
## get another one*, and it is the layer where I/O finally becomes legitimate.
##
## ## The rule this module exists to hold
##
## `token.nim` has no capability to reach a network: its clock, its keyring and
## its revocation list are arguments. That property is easy to state and easy
## to lose, and the moment it gets lost is **exactly here** — the natural way
## to write a refresh client is to let the verifier fetch when it notices the
## token is old. So:
##
##   * **The session never fetches. It asks.** Every network operation is a
##     field on an injected `IdentityTransport`, `{.requiresInit.}`, so a new
##     operation fails the build at every construction site rather than
##     defaulting to `nil` and being discovered in a user's tab. Same reasoning
##     as `WasmHost`, and the same shape.
##   * **`decide` and `plan` are pure**, take the clock as an argument, and
##     touch no transport. They are what runs on every entitlement question.
##   * **`refresh` is the only proc here that can make a call**, and in the
##     normal band it makes none — see below, because that is a load-bearing
##     assertion rather than an optimisation.
##
## ## Why admission is asynchronous and decision is not
##
## `crypto.subtle.verify` returns a promise and there is no synchronous
## WebCrypto, so a browser cannot implement `token.SignatureVerifier`'s
## synchronous seam at all. Making verification async everywhere would hand the
## verifier a capability to await — and a proc that can await can be given
## something that fetches. Splitting instead means:
##
##   admit()   ONCE per token. Inspects (pure), then checks the signature
##             through the transport (async). Produces an `AdmittedToken`.
##   decide()  On every entitlement question. Pure, synchronous, no I/O.
##
## `ct_license_ffi` already draws this line between `ct_license_start` and
## `ct_license_heartbeat`, and licensing's own comment gives the same reason:
## the snapshot is taken once and the hot path consults the snapshot.
##
## ## §3.3.1a's normal band means NO NETWORK, and that is asserted
##
## The published table's first row is "Normal operation. No network required,
## **no renewal attempted**." That is not advice — it is the sentence that makes
## a debugger work on a plane for the first two thirds of a token's life. A
## refresh client that polls in the normal band satisfies every functional test
## and destroys the property, so `plan` returns `raNone` there and `refresh`
## returns without touching the transport, and the suite counts transport calls
## to prove it.

import ../platform/outcome
import ./token

export token

type
  AdmittedToken* = object
    ## A token whose signature HAS been checked. Produced only by `admit`.
    ## Fields unexported, for the reason `IdentityClaims`'s are: the claims in
    ## here are trusted, and a type a product can fill in is not a claim, it is
    ## an assertion by the product.
    claimsField: IdentityClaims
    admittedAtField: int64
    keyIdField: string

  RefreshAction* = enum
    ## What the session wants done, derived from the band. The names are the
    ## behaviours §3.3.1a specifies, not the band names, because two different
    ## bands can want the same action and the caller cares about the action.
    raNone
      ## Normal band. **No network required, none attempted.**
    raSilent
      ## Renewing band. Attempt in the background whenever connectivity exists,
      ## and tell the user nothing — a user who is online never learns this
      ## band exists.
    raVisible
      ## Warning band. Still attempt, and now tell the user the date.
    raPrompt
      ## Expired. Entitlements are not in force; the product keeps working on
      ## the anonymous tier and asks the user to sign in again.

  IdentityTransport* {.requiresInit.} = ref object
    ## The only thing in this file that can reach a network.
    ##
    ## `{.requiresInit.}` is deliberate and is the same discipline `WasmHost`
    ## carries: adding an operation must break every construction site,
    ## including every test, rather than leaving a `nil` field to be discovered
    ## at runtime by a user.
    fetchToken*: proc(): PlatformFutureT[PlatformOutcome[seq[byte]]]
      ## Obtain a fresh token. THIS is the operation that needs the network,
      ## and it is the only reason the network is ever needed — using a token
      ## never is.
    fetchRevocations*: proc(): PlatformFutureT[PlatformOutcome[RevocationList]]
    verifySignature*: proc(keyId: string; message: seq[byte];
                           signature: seq[byte]
                          ): PlatformFutureT[PlatformOutcome[bool]]
      ## Asynchronous because WebCrypto is. A native host backed by
      ## `ct_license_ffi` resolves this immediately; the seam is the same.

  IdentitySession* = ref object
    transportField: IdentityTransport
    pinnedKeyIdsField: seq[string]
    policyField: WindowPolicy
    claimsField: IdentityClaims
    hasTokenField: bool
    admittedAtField: int64
    revocationsField: RevocationList
    tokenFetchesField: int
    revocationFetchesField: int
    signatureChecksField: int

func claims*(t: AdmittedToken): IdentityClaims = t.claimsField
func admittedAt*(t: AdmittedToken): int64 = t.admittedAtField
func admittedKeyId*(t: AdmittedToken): string = t.keyIdField

proc newIdentitySession*(transport: IdentityTransport;
                         pinnedKeyIds: seq[string];
                         policy: WindowPolicy): IdentitySession =
  IdentitySession(
    transportField: transport, pinnedKeyIdsField: pinnedKeyIds,
    policyField: policy, claimsField: IdentityClaims(), hasTokenField: false,
    admittedAtField: 0, revocationsField: emptyRevocations(),
    tokenFetchesField: 0, revocationFetchesField: 0, signatureChecksField: 0)

# ---------------------------------------------------------------------------
# Counters. Not diagnostics — the suite asserts on them, because "made no
# network call" is otherwise unobservable from outside. A property nothing can
# see is a property nothing defends.
# ---------------------------------------------------------------------------
func tokenFetches*(s: IdentitySession): int = s.tokenFetchesField
func revocationFetches*(s: IdentitySession): int = s.revocationFetchesField
func signatureChecks*(s: IdentitySession): int = s.signatureChecksField
func hasToken*(s: IdentitySession): bool = s.hasTokenField
func revocations*(s: IdentitySession): RevocationList = s.revocationsField

# ---------------------------------------------------------------------------
# THE PURE HALF. No transport is reachable from here.
# ---------------------------------------------------------------------------
func bandOf*(s: IdentitySession; nowUnix: int64): IdentityBand =
  if not s.hasTokenField: ibExpired else: bandAt(s.claimsField, nowUnix)

proc decide*(s: IdentitySession; nowUnix: int64): IdentityDecision =
  ## Pure, synchronous, and what runs on every entitlement question.
  if not s.hasTokenField:
    return rejectedDecision(dkMalformed, "no token has been admitted")
  decideVerified(s.claimsField, nowUnix, s.revocationsField)

func refreshActionFor*(band: IdentityBand): RefreshAction =
  case band
  of ibNormal: raNone
  of ibRenewing: raSilent
  of ibWarning: raVisible
  of ibExpired: raPrompt
  of ibNotYetValid: raNone

func plan*(s: IdentitySession; nowUnix: int64): RefreshAction =
  ## What `refresh` would do, without doing it. Pure, so a caller can schedule
  ## on it — and so the suite can assert the plan and the effect separately,
  ## which is what catches a refresh that acts on a band it did not plan for.
  if not s.hasTokenField:
    return raPrompt
  refreshActionFor(s.bandOf(nowUnix))

func revocationsAreStale*(s: IdentitySession; nowUnix: int64): bool =
  ## §3.3.1a ties revocation to renewal: "revocation reaches a client at its
  ## next renewal, and no sooner." So the list is stale exactly when the client
  ## would have contacted the issuer anyway — one renew lead. Choosing a
  ## shorter interval here would promise a latency the model does not deliver;
  ## choosing a longer one would exceed the published bound.
  if s.revocationsField.obtainedAt <= 0:
    return true
  nowUnix - s.revocationsField.obtainedAt > s.policyField.renewLead

# ---------------------------------------------------------------------------
# THE ASYNCHRONOUS HALF. Everything below may touch the transport, and nothing
# above may.
# ---------------------------------------------------------------------------
proc admit*(s: IdentitySession; raw: seq[byte]; nowUnix: int64
           ): PlatformFutureT[PlatformOutcome[IdentityDecision]] =
  ## Inspect purely, then check the signature ONCE. A token that fails
  ## inspection never reaches the transport — there is no point spending a
  ## signature check on a container that is already refused, and more
  ## importantly a malformed token must not become a network event.
  let inspection = inspectToken(raw, s.policyField)
  if not inspection.inspectionOk():
    return resolvedOk(rejectedDecision(inspection.inspectionKind(),
                                       inspection.inspectionDetail()))

  let claims = inspection.inspectionClaims()

  # Rotation before authenticity, and before the transport: an unknown key id
  # is answerable without asking anybody.
  var known = false
  for k in s.pinnedKeyIdsField:
    if k == claims.keyId:
      known = true
  if not known:
    return resolvedOk(rejectedDecision(dkUnknownKeyId,
      "no pinned key bears key_id '" & claims.keyId & "'"))

  s.signatureChecksField = s.signatureChecksField + 1
  let message = inspection.signedMessage()
  let signature = inspection.tokenSignature()

  s.transportField.verifySignature(claims.keyId, message, signature)
    .mapOutcome(proc(valid: bool): IdentityDecision =
      if not valid:
        return rejectedDecision(dkBadSignature,
                                "the pinned key rejected this token")
      s.claimsField = claims
      s.hasTokenField = true
      s.admittedAtField = nowUnix
      decideVerified(claims, nowUnix, s.revocationsField))

proc refreshRevocations*(s: IdentitySession
                        ): PlatformFutureT[PlatformOutcome[Nothing]] =
  s.revocationFetchesField = s.revocationFetchesField + 1
  s.transportField.fetchRevocations()
    .mapOutcome(proc(list: RevocationList): Nothing =
      s.revocationsField = list
      nothing)

proc refresh*(s: IdentitySession; nowUnix: int64
             ): PlatformFutureT[PlatformOutcome[RefreshAction]] =
  ## THE ONE PROC HERE THAT MAY CALL OUT, AND IN THE NORMAL BAND IT DOES NOT.
  ##
  ## §3.3.1a's first row is "No network required, no renewal attempted." A
  ## refresh client that polls anyway passes every functional test and quietly
  ## deletes the offline property, so the early return below is the feature and
  ## `tokenFetches` exists so a test can see it did not happen.
  let action = s.plan(nowUnix)
  if action == raNone:
    return resolvedOk(action)

  s.tokenFetchesField = s.tokenFetchesField + 1
  s.transportField.fetchToken()
    .thenOutcome(proc(raw: seq[byte]): PlatformFutureT[PlatformOutcome[RefreshAction]] =
      s.admit(raw, nowUnix).mapOutcome(proc(d: IdentityDecision): RefreshAction =
        # The action REPORTED is the one that was true when the refresh began.
        # Reporting the post-refresh band instead would make a successful
        # renewal indistinguishable from one that never needed to happen, and a
        # caller that warns on `raVisible` would stop warning the moment it
        # succeeded — which is correct — but would also never learn it had been
        # in the warning band at all.
        action))
