## THE DRIVER: what turns `viewmodel/identity/`'s pure functions into a sign-in.
##
## Everything under `viewmodel/identity/` is a function of its arguments — it
## parses a discovery document, classifies an RFC 8628 poll response, computes
## the next interval, checks claims against a clock that is passed in. None of
## it can reach a network, and that is enforced rather than intended:
## `session.nim` keeps the only network-capable type (`IdentityTransport`) as a
## record of procs the caller supplies, and `device_grant.nim` states that the
## polling loop belongs to the caller.
##
## This module is that caller. It owns:
##
##   * the discovery fetch and its URL construction,
##   * the device-authorization POST,
##   * the polling loop, with the RFC's interval rules applied by
##     `device_grant.nextInterval` / `shouldKeepPolling` rather than restated,
##   * the token request and the JWKS fetch,
##   * and the assembly of an `IdentityTransport` for `session.nim`.
##
## It owns no *rules*. Every decision below is delegated to the pure module
## that already holds it, and that separation is the point: the rules are
## tested without a network and the plumbing is tested against a real issuer.
##
## ## What "the composition root" means here, and what has no default
##
## `newOidcClient` takes `issuer`, `clientId` and `caFile` and defaults none of
## the first two. The issuer default lives one level down, in
## `issuer.DefaultIssuer`, where it is an ordinary parameter and not a
## compiled-in constant — so pointing a local build at a local issuer needs no
## escape hatch and must not acquire one. `clientId` has no default anywhere,
## for the reason `session.newIdentitySession` gives about `audience`: a
## default would be a guess about which client is running, which is the check
## `aud` exists to make.
##
## ## Errors are sentences, not exceptions
##
## Every proc here returns an error string that is empty on success, matching
## `device_grant.parseDeviceAuthorization` and `parseTokenGrant`. A polling
## loop that has to catch exceptions from four call sites to satisfy RFC 8628's
## "keep polling" is a loop that will eventually stop polling for the wrong
## reason. `parseDiscovery` is the one exception to this, because it raises by
## design, so `discover` catches it and converts.

import std/[asyncdispatch, json, strutils, times, uri]

import nim_everywhere/async_compat
import nim_everywhere/http
import nim_everywhere/platform
import ./http_transport

import ../../frontend/viewmodel/platform/outcome
import ../../frontend/viewmodel/identity/issuer
import ../../frontend/viewmodel/identity/jwt
import ../../frontend/viewmodel/identity/device_grant
import ../../frontend/viewmodel/identity/session
import ../../frontend/viewmodel/identity/rs256_verifier

export issuer, jwt, device_grant, session, rs256_verifier

const
  DiscoveryPath* = "/.well-known/openid-configuration"
    ## RFC 8414 §3: inserted between the issuer's host and its path component.
    ## Every issuer this organisation runs has no path component, so the
    ## construction below is a concatenation; `discoveryUrl` still strips a
    ## trailing slash so that `https://issuer/` and `https://issuer` agree.

  DeviceGrantType* = "urn:ietf:params:oauth:grant-type:device_code"
    ## RFC 8628 §3.4.

  DefaultScopes* = "openid profile email offline_access"
    ## `openid` is what makes the response carry an `id_token` at all —
    ## `device_grant.poNoIdentity` exists for the client registered without it.
    ## `offline_access` is what makes it carry a refresh token, which is what
    ## `session.refresh` renews with; an issuer may still decline, and
    ## `TokenGrant.hasRefresh` is how a caller finds out.

type
  OidcClient* = ref object
    ## Fields unexported: the transport is the only thing here that can reach a
    ## network, and a type that hands it out invites a second caller with its
    ## own loop and its own interpretation of `slow_down`.
    transportField: HttpAsyncTransport
    issuerField: string
    clientIdField: string
    scopesField: string
    configField: IssuerConfig
    discoveredField: bool

  DeviceAuthorizationResult* = object
    error*: string
    auth*: DeviceAuthorization

  PollResult* = object
    outcome*: PollOutcome
    payload*: string
      ## The raw body, kept so the caller can hand it to `parseTokenGrant`
      ## without a second request. `classifyPollResponse` says WHETHER the poll
      ## finished; the payload says what it yielded, and `device_grant.nim`
      ## explains why those are two passes.
    transportError*: string
      ## Non-empty when the issuer was not REACHED, as opposed to answering.
      ## The distinction is load-bearing: RFC 8628's loop continues through a
      ## network fault and stops on `access_denied`, so collapsing the two
      ## would either abandon a sign-in over one dropped packet or poll a dead
      ## device code forever.

  GrantResult* = object
    error*: string
    grant*: TokenGrant

  JwksResult* = object
    error*: string
    keys*: seq[JwkKey]

func issuerOf*(c: OidcClient): string = c.issuerField
func clientId*(c: OidcClient): string = c.clientIdField
func config*(c: OidcClient): IssuerConfig = c.configField
func isDiscovered*(c: OidcClient): bool = c.discoveredField

proc newOidcClient*(transport: HttpAsyncTransport; issuer: string;
                    clientId: string; scopes = DefaultScopes): OidcClient =
  ## `issuer` and `clientId` are required. See the header.
  doAssert transport != nil, "an OidcClient needs a transport"
  doAssert issuer.len > 0, "an OidcClient needs an issuer"
  doAssert clientId.len > 0,
    "an OidcClient needs a client id: it is this client's identity at the " &
    "issuer, and the audience check exists to compare against it"
  OidcClient(transportField: transport, issuerField: issuer,
             clientIdField: clientId, scopesField: scopes,
             discoveredField: false)

func discoveryUrl*(issuer: string): string =
  ## Exported so a test can assert the construction without a network.
  issuer.strip(leading = false, chars = {'/'}) & DiscoveryPath

func formEncode(fields: openArray[(string, string)]): string =
  ## `application/x-www-form-urlencoded`, which is what RFC 6749 §4.1.3 and RFC
  ## 8628 §3.1 and §3.4 all require. Written here rather than reached for from
  ## `std/httpclient` so that this module does not depend on the client the
  ## transport happens to use.
  var parts: seq[string]
  for (k, v) in fields:
    parts.add encodeUrl(k) & "=" & encodeUrl(v)
  parts.join("&")

const FormHeaders = @[
  HttpHeader(name: "Content-Type", value: "application/x-www-form-urlencoded"),
  HttpHeader(name: "Accept", value: "application/json")]

proc discover*(c: OidcClient): Future[string] {.async.} =
  ## Fetch and bind the discovery document. Returns "" or a sentence.
  ##
  ## The binding — that the document's `issuer` equals the one asked for — is
  ## `parseDiscovery`'s, not this module's. RFC 8414 §3.3 is the whole reason
  ## fetching configuration over the network is safe at all, and restating the
  ## check here would let the two drift.
  let reply = await c.transportField(
    newRequest(hmGet, discoveryUrl(c.issuerField), "",
               @[HttpHeader(name: "Accept", value: "application/json")]))
  if reply.status != 200:
    return "the issuer's discovery document could not be fetched from " &
      discoveryUrl(c.issuerField) & ": " &
      (if isTransportFailure(reply): reply.body
       else: "HTTP " & $reply.status)
  try:
    c.configField = parseDiscovery(reply.body, c.issuerField)
    c.discoveredField = true
    return ""
  except DiscoveryError as err:
    return err.msg

proc beginDeviceAuthorization*(c: OidcClient; nowUnix: int64
                              ): Future[DeviceAuthorizationResult] {.async.} =
  ## RFC 8628 §3.1. No client secret: the desktop CLI is a PUBLIC client, and
  ## a secret shipped in a binary is not a secret.
  if not c.discoveredField:
    return DeviceAuthorizationResult(
      error: "discovery has not run, so there is no device authorization endpoint")
  let reply = await c.transportField(
    newRequest(hmPost, c.configField.deviceAuthorizationEndpoint,
               formEncode({"client_id": c.clientIdField,
                           "scope": c.scopesField}), FormHeaders))
  if reply.status != 200:
    return DeviceAuthorizationResult(
      error: "the device authorization request was refused: " &
        (if isTransportFailure(reply): reply.body
         else: "HTTP " & $reply.status & " " & reply.body))
  var auth: DeviceAuthorization
  let parseError = parseDeviceAuthorization(reply.body, nowUnix, auth)
  if parseError.len > 0:
    return DeviceAuthorizationResult(error: parseError)
  DeviceAuthorizationResult(auth: auth)

proc pollOnce*(c: OidcClient; auth: DeviceAuthorization): Future[PollResult] {.async.} =
  ## One RFC 8628 §3.4 exchange. Does NOT decide whether to poll again — that
  ## is `shouldKeepPolling`, over an outcome and a clock.
  ##
  ## A non-200 is still CLASSIFIED rather than rejected: RFC 6749 §5.2 returns
  ## `authorization_pending` and `slow_down` with a 400, so treating the status
  ## as the answer would end every sign-in on the first poll.
  let reply = await c.transportField(
    newRequest(hmPost, c.configField.tokenEndpoint,
               formEncode({"client_id": c.clientIdField,
                           "grant_type": DeviceGrantType,
                           "device_code": auth.secretDeviceCode}),
               FormHeaders))
  if isTransportFailure(reply):
    return PollResult(outcome: poPending, payload: "",
                      transportError: reply.body)
  PollResult(outcome: classifyPollResponse(reply.body), payload: reply.body)

proc fetchJwks*(c: OidcClient): Future[JwksResult] {.async.} =
  if not c.discoveredField:
    return JwksResult(error: "discovery has not run, so there is no jwks_uri")
  let reply = await c.transportField(
    newRequest(hmGet, c.configField.jwksUri, "",
               @[HttpHeader(name: "Accept", value: "application/json")]))
  if reply.status != 200:
    return JwksResult(error: "the issuer's keys could not be fetched from " &
      c.configField.jwksUri & ": " &
      (if isTransportFailure(reply): reply.body
       else: "HTTP " & $reply.status))
  let keys = parseJwks(reply.body)
  if keys.len == 0:
    # NOT AN EMPTY SUCCESS. An issuer that has signed nothing since its keys
    # expired publishes `{"keys":[]}`, and a client that accepted that would
    # go on to refuse every token with "unknown key id" instead of saying the
    # issuer published none.
    return JwksResult(error: "the issuer published no usable signing keys at " &
      c.configField.jwksUri)
  JwksResult(keys: keys)

proc refreshGrant*(c: OidcClient; refreshToken: string
                  ): Future[GrantResult] {.async.} =
  ## RFC 6749 §6. This is what `IdentityTransport.fetchToken` is.
  if not c.discoveredField:
    return GrantResult(error: "discovery has not run, so there is no token endpoint")
  let reply = await c.transportField(
    newRequest(hmPost, c.configField.tokenEndpoint,
               formEncode({"client_id": c.clientIdField,
                           "grant_type": "refresh_token",
                           "refresh_token": refreshToken,
                           "scope": c.scopesField}), FormHeaders))
  if reply.status != 200:
    return GrantResult(error: "the refresh was refused: " &
      (if isTransportFailure(reply): reply.body
       else: "HTTP " & $reply.status & " " & reply.body))
  var grant: TokenGrant
  let parseError = parseTokenGrant(reply.body, epochTime().int64, grant)
  if parseError.len > 0:
    return GrantResult(error: parseError)
  GrantResult(grant: grant)

# ---------------------------------------------------------------------------
# The loop. Clock and sleep are INJECTED, so the RFC's timing rules can be
# exercised without waiting for them — the same reason every pure module here
# takes `nowUnix` rather than calling the clock.
# ---------------------------------------------------------------------------
type
  DeviceGrantProgress* = proc(auth: DeviceAuthorization; outcome: PollOutcome)
    ## Called once per poll. The caller is what shows the user a prompt; this
    ## module deliberately does not print, so it can run under a test, a TUI
    ## and a GUI without knowing which.

proc awaitDeviceGrant*(c: OidcClient; auth: DeviceAuthorization;
                       nowUnix: proc(): int64;
                       sleepSeconds: proc(seconds: int): Future[void];
                       onPoll: DeviceGrantProgress = nil
                      ): Future[GrantResult] {.async.} =
  ## Poll until the grant completes, is refused, or the window closes.
  ##
  ## The interval starts at the issuer's and moves only through
  ## `nextInterval`, so RFC 8628 §3.5's "the increase persists" is honoured by
  ## construction rather than by remembering to honour it.
  var interval = auth.pollInterval
  while true:
    if windowClosed(auth, nowUnix()):
      return GrantResult(error: terminalDetail(poExpired))
    await sleepSeconds(interval)
    let poll = await c.pollOnce(auth)
    if onPoll != nil:
      onPoll(auth, poll.outcome)
    interval = nextInterval(interval, poll.outcome)
    if poll.outcome == poComplete:
      var grant: TokenGrant
      let parseError = parseTokenGrant(poll.payload, nowUnix(), grant)
      if parseError.len > 0:
        return GrantResult(error: parseError)
      return GrantResult(grant: grant)
    if not shouldKeepPolling(poll.outcome, auth, nowUnix()):
      # A transport failure classified itself `poPending` above, so the only
      # way out of the loop other than completion is an answer the RFC defines
      # as terminal, or our own deadline.
      let detail = terminalDetail(poll.outcome)
      return GrantResult(
        error: if detail.len > 0: detail
               else: terminalDetail(poExpired))

proc realSleepSeconds*(seconds: int): Future[void] =
  ## The production sleep. Separate and exported so that a call site reads as
  ## having chosen it, and a test that forgets to inject one fails to compile
  ## rather than sleeping for a minute.
  sleepAsync(seconds * 1000)

proc realNowUnix*(): int64 = epochTime().int64

# ---------------------------------------------------------------------------
# The bridge to `session.nim`.
# ---------------------------------------------------------------------------
proc newHttpIdentityTransport*(c: OidcClient; refreshToken: string;
                               keys: seq[JwkKey]): IdentityTransport =
  ## The `IdentityTransport` `newIdentitySession` needs, over this client.
  ##
  ## `keys` is passed in rather than fetched here because `fetchJwks` is
  ## already one of the transport's operations: a constructor that fetched
  ## would make construction a network call, and `session.nim`'s whole point is
  ## that a valid, unspent token needs no network at all.
  IdentityTransport(
    fetchToken: proc(): PlatformFutureT[PlatformOutcome[string]] =
      let future = newFuture[PlatformOutcome[string]]("oidc.fetchToken")
      let call = c.refreshGrant(refreshToken)
      call.addCallback proc() =
        if call.failed:
          future.complete(failed[string](platformError(
            pkTransport, "the token endpoint could not be reached",
            call.error.msg)))
        else:
          let r = call.read()
          if r.error.len > 0:
            future.complete(failed[string](platformError(
              pkFailed, "the refresh was refused", r.error)))
          else:
            future.complete(succeeded(r.grant.idToken))
      future,

    fetchJwks: proc(): PlatformFutureT[PlatformOutcome[seq[JwkKey]]] =
      let future = newFuture[PlatformOutcome[seq[JwkKey]]]("oidc.fetchJwks")
      let call = c.fetchJwks()
      call.addCallback proc() =
        if call.failed:
          future.complete(failed[seq[JwkKey]](platformError(
            pkTransport, "the issuer's keys could not be reached",
            call.error.msg)))
        else:
          let r = call.read()
          if r.error.len > 0:
            future.complete(failed[seq[JwkKey]](platformError(
              pkFailed, "the issuer published no usable keys", r.error)))
          else:
            future.complete(succeeded(r.keys))
      future,

    verifySignature: newWebCryptoVerifier(keys))
