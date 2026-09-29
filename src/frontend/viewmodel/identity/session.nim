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
## the snapshot is taken once and the hot path consults the snapshot. That is a
## shared shape, not a shared mechanism — nothing here reaches into licensing.
##
## ## Where the keys come from
##
## Not from the build. `keysField` holds the issuer's published JWKS, and
## `fetchJwks` refreshes it, because the issuer rotates on its own schedule and
## a build-time pin would make that rotation an outage on the issuer's
## timetable rather than ours. Trust comes from TLS to the issuer's host plus
## `issuer.parseDiscovery` refusing a document that does not name the issuer it
## was fetched for.
##
## ## A VALID TOKEN MAKES NO CALL, and that is asserted
##
## This section used to cite `CodeTracer-End-User-Licensing.md` §3.3.1a and its
## "No network required, no renewal attempted" row, and claim that it made a
## debugger work on a plane for two thirds of a token's life. That was
## licensing's property, borrowed. An ID token lives about an hour, so identity
## cannot promise offline weeks and does not try to — offline entitlement is
## licensing's, through its own file, which this layer does not touch.
##
## What survives is smaller and still worth defending: **a token that is valid
## and not yet half-spent triggers no network call at all.** A refresh client
## that polls anyway satisfies every functional test and quietly turns every
## entitlement question into a request, so `plan` returns `raNone` there,
## `refresh` returns without touching the transport, and `tokenFetches` exists
## so a test can see that it did not happen.

import std/strutils
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
      ## Renewing. Attempt in the background whenever connectivity exists, and
      ## tell the user nothing — a user who is online never learns this band
      ## exists.
      ##
      ## There is no `raVisible` any more. It was the warning band's action:
      ## name the expiry date to the user. That made sense when expiry was
      ## weeks away and the remedy was a purchase; an ID token renews from a
      ## refresh token without the user present, so a dialog there would be
      ## about something the client is already fixing.
    raPrompt
      ## Expired, or the refresh was refused. The product keeps working on the
      ## anonymous tier and asks the user to sign in again.

  IdentityTransport* {.requiresInit.} = ref object
    ## The only thing in this file that can reach a network.
    ##
    ## `{.requiresInit.}` is deliberate and is the same discipline `WasmHost`
    ## carries: adding an operation must break every construction site,
    ## including every test, rather than leaving a `nil` field to be discovered
    ## at runtime by a user.
    fetchToken*: proc(): PlatformFutureT[PlatformOutcome[string]]
      ## Exchange the refresh token for a fresh compact JWS at the issuer's
      ## `token_endpoint`. THIS is the operation that needs the network, and it
      ## is the only reason the network is ever needed — using a token never is.
      ##
      ## A `string`, not `seq[byte]`: a compact JWS is ASCII by construction
      ## (base64url and two dots), and carrying it as bytes invited the caller
      ## to re-encode it. The signature covers exactly the characters the issuer
      ## sent.
    fetchJwks*: proc(): PlatformFutureT[PlatformOutcome[seq[JwkKey]]]
      ## The issuer's published keys. Its own operation rather than a field set
      ## once at construction, because the issuer rotates and a client that
      ## could not refetch would fail every token after a rotation with
      ## `dkUnknownKeyId` and no way out.
    verifySignature*: proc(keyId: string; message: seq[byte];
                           signature: seq[byte]
                          ): PlatformFutureT[PlatformOutcome[bool]]
      ## Asynchronous because WebCrypto is. Implemented by
      ## `rs256_verifier.newWebCryptoVerifier` on both backends — RS256
      ## through `crypto.subtle` in a tab, and through `nim_everywhere/rs256`'s
      ## runtime-loaded libcrypto natively. The seam is the same.

  IdentitySession* = ref object
    transportField: IdentityTransport
    keysField: seq[JwkKey]
    issuerField: string
    audienceField: string
    claimsField: IdentityClaims
    hasTokenField: bool
    admittedAtField: int64
    revokedField: bool
    tokenFetchesField: int
    jwksFetchesField: int
    signatureChecksField: int

func claims*(t: AdmittedToken): IdentityClaims = t.claimsField
func admittedAt*(t: AdmittedToken): int64 = t.admittedAtField
func admittedKeyId*(t: AdmittedToken): string = t.keyIdField

proc newIdentitySession*(transport: IdentityTransport; keys: seq[JwkKey];
                         issuer = DefaultIssuer;
                         audience: string): IdentitySession =
  ## `audience` has no default ON PURPOSE. It is this client's id at the
  ## issuer, and a default would be a guess about which client is running —
  ## which is exactly the check `aud` exists to make. A build that forgets it
  ## fails to compile.
  IdentitySession(
    transportField: transport, keysField: keys, issuerField: issuer,
    audienceField: audience, claimsField: IdentityClaims(),
    hasTokenField: false, admittedAtField: 0, revokedField: false,
    tokenFetchesField: 0, jwksFetchesField: 0, signatureChecksField: 0)

# ---------------------------------------------------------------------------
# Counters. Not diagnostics — the suite asserts on them, because "made no
# network call" is otherwise unobservable from outside. A property nothing can
# see is a property nothing defends.
# ---------------------------------------------------------------------------
func tokenFetches*(s: IdentitySession): int = s.tokenFetchesField
func jwksFetches*(s: IdentitySession): int = s.jwksFetchesField
func signatureChecks*(s: IdentitySession): int = s.signatureChecksField
func hasToken*(s: IdentitySession): bool = s.hasTokenField
func isRevoked*(s: IdentitySession): bool = s.revokedField
func publishedKeys*(s: IdentitySession): seq[JwkKey] = s.keysField

# ---------------------------------------------------------------------------
# THE PURE HALF. No transport is reachable from here.
# ---------------------------------------------------------------------------
func bandOf*(s: IdentitySession; nowUnix: int64): IdentityBand =
  if not s.hasTokenField: ibExpired else: bandAt(s.claimsField, nowUnix)

proc decide*(s: IdentitySession; nowUnix: int64): IdentityDecision =
  ## Pure, synchronous, and what runs on every entitlement question.
  if not s.hasTokenField:
    return rejectedDecision(dkMalformed, "no token has been admitted")
  # REVOCATION OUTRANKS EXPIRY, because it is the fact a product must report: a
  # revoked session whose token also expired was ended by somebody, and "sign
  # in again" would invite the user to try something that will be refused.
  #
  # There is no revocation LIST here any more. The retired version fetched one
  # over its own transport and thresholded its staleness on licensing's renew
  # lead — a bespoke channel the issuer does not offer. OIDC delivers
  # revocation by refusing to renew, so that is where this flag comes from.
  if s.revokedField:
    return rejectedDecision(dkRevoked,
      "the issuer refused to renew this session; it was ended elsewhere")
  decideVerified(s.claimsField, nowUnix)

func refreshActionFor*(band: IdentityBand): RefreshAction =
  case band
  of ibNormal: raNone
  of ibRenewing: raSilent
  of ibExpired: raPrompt
  of ibNotYetValid: raNone

func plan*(s: IdentitySession; nowUnix: int64): RefreshAction =
  ## What `refresh` would do, without doing it. Pure, so a caller can schedule
  ## on it — and so the suite can assert the plan and the effect separately,
  ## which is what catches a refresh that acts on a band it did not plan for.
  if not s.hasTokenField:
    return raPrompt
  refreshActionFor(s.bandOf(nowUnix))

# ---------------------------------------------------------------------------
# THE ASYNCHRONOUS HALF. Everything below may touch the transport, and nothing
# above may.
# ---------------------------------------------------------------------------
proc admit*(s: IdentitySession; compact: string; nowUnix: int64
           ): PlatformFutureT[PlatformOutcome[IdentityDecision]] =
  ## Inspect purely, then check the signature ONCE. A token that fails
  ## inspection never reaches the transport — there is no point spending a
  ## signature check on a token that is already refused, and more importantly a
  ## malformed token must not become a network event.
  ##
  ## EVERYTHING ANSWERABLE LOCALLY IS ANSWERED LOCALLY, and that is more than it
  ## used to be. `inspectJws` now also rejects an unknown `kid`, an issuer that
  ## is not ours and an audience that is not ours, so all three are settled from
  ## the cached JWKS with no call. The retired version had a `pinnedKeyIds` loop
  ## here for the first of those; it is gone because `jwt.selectKey` does it
  ## against the keys the issuer actually publishes.
  let inspection = inspectJws(compact, s.keysField, s.issuerField,
                              s.audienceField)
  if not inspection.inspectionOk():
    return resolvedOk(rejectedDecision(inspection.inspectionKind(),
                                       inspection.inspectionDetail()))

  let claims = inspection.inspectionClaims()

  s.signatureChecksField = s.signatureChecksField + 1
  let message = inspection.signedMessage()
  let signature = inspection.tokenSignature()

  s.transportField.verifySignature(claims.keyId, message, signature)
    .mapOutcome(proc(valid: bool): IdentityDecision =
      if not valid:
        return rejectedDecision(dkBadSignature,
                                "the issuer's key rejected this token")
      s.claimsField = claims
      s.hasTokenField = true
      s.admittedAtField = nowUnix
      # A token that verifies is a live session: whatever refusal marked this
      # session revoked has been overtaken by the issuer minting another one.
      s.revokedField = false
      decideVerified(claims, nowUnix))

proc refreshKeys*(s: IdentitySession
                 ): PlatformFutureT[PlatformOutcome[Nothing]] =
  ## Refetch the issuer's published keys. Called when a token names a `kid` the
  ## cached set does not have — which is what a rotation looks like from here —
  ## and NOT on a schedule: a timer would fetch when nothing had changed and
  ## still be too late for the one token that arrives a second after a
  ## rotation.
  ##
  ## An empty set is REFUSED rather than stored. A JWKS fetch that succeeded
  ## with no keys would replace a working key set with one that rejects every
  ## token as `dkUnknownKeyId`, and the client would have done that to itself.
  s.jwksFetchesField = s.jwksFetchesField + 1
  s.transportField.fetchJwks()
    .thenOutcome(proc(keys: seq[JwkKey]): PlatformFutureT[PlatformOutcome[Nothing]] =
      if keys.len == 0:
        return resolvedErr[Nothing](pkConflict,
          "the issuer published an empty key set; keeping the previous one",
          "replacing a working JWKS with an empty one would refuse every token")
      s.keysField = keys
      resolvedOk())

proc refresh*(s: IdentitySession; nowUnix: int64
             ): PlatformFutureT[PlatformOutcome[RefreshAction]] =
  ## THE ONE PROC HERE THAT MAY CALL OUT, AND IN THE NORMAL BAND IT DOES NOT.
  ##
  ## A token that is valid and not yet half-spent triggers no call. A refresh
  ## client that polls anyway passes every functional test and turns every
  ## entitlement question into a request, so the early return below is the
  ## feature and `tokenFetches` exists so a test can see it did not happen.
  let action = s.plan(nowUnix)
  if action == raNone:
    return resolvedOk(action)

  s.tokenFetchesField = s.tokenFetchesField + 1
  s.transportField.fetchToken()
    .recoverOutcome(proc(error: PlatformError): PlatformFutureT[PlatformOutcome[string]] =
      # THIS IS HOW REVOCATION ARRIVES. RFC 6749 §5.2: an authorization server
      # answers a refresh with a revoked or invalidated grant as
      # `invalid_grant`. There is no list to poll and no endpoint to ask — the
      # refusal IS the notification, and it is bounded by the ID token's own
      # lifetime rather than by a 30-day period.
      #
      # A TRANSPORT FAILURE IS NOT A REVOCATION, and telling them apart is the
      # whole value of the flag. "no network" must leave a valid session valid;
      # marking it revoked would log a user out of a working session for being
      # on a train.
      if error.kind == pkAccessDenied or "invalid_grant" in error.message:
        s.revokedField = true
      resolved(failed[string](error)))
    .thenOutcome(proc(compact: string): PlatformFutureT[PlatformOutcome[RefreshAction]] =
      s.admit(compact, nowUnix).mapOutcome(proc(d: IdentityDecision): RefreshAction =
        # The action REPORTED is the one that was true when the refresh began.
        # Reporting the post-refresh band instead would make a successful
        # renewal indistinguishable from one that never needed to happen.
        action))
