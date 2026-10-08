## What the OIDC driver does with an issuer's answers — without an issuer.
##
## The rules themselves live in `viewmodel/identity/` and are tested there.
## What is only testable HERE is the plumbing between them: which URL is
## built, which form fields go on the wire, which HTTP status is allowed to
## decide an outcome and which is not, and how the polling loop moves its
## interval. Every one of those is a place where a correct pure module can be
## driven incorrectly.
##
## THE TRANSPORT IS A FAKE AND THAT IS THE POINT OF THIS FILE. It is
## `nim_everywhere`'s `fakeHttpAsyncTransport`, which records every request and
## replays a scripted list of responses — so the assertions below are about
## bytes this code SENT, not about a mock's expectations. The complementary
## test, against a real Zitadel, is `ci/test/identity-live-device-grant.sh`;
## neither replaces the other, and `local-development-parity.md` §4.1 is about
## exactly the failure of having only the first.
##
## Lane: `ct-cli-units` (discovered by `src/ct/**/*_test.nim`).

import std/[asyncdispatch, json, strutils, unittest]
import nim_everywhere/http
import nim_everywhere/platform
import ./oidc

const ExpectedAssertions = 52
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

const
  Issuer = "https://issuer.test"
  ClientId = "codetracer-cli"

proc discoveryDoc(issuer = Issuer): string =
  $(%*{
    "issuer": issuer,
    "jwks_uri": issuer & "/oauth/v2/keys",
    "token_endpoint": issuer & "/oauth/v2/token",
    "authorization_endpoint": issuer & "/oauth/v2/authorize",
    "device_authorization_endpoint": issuer & "/oauth/v2/device_authorization",
    "id_token_signing_alg_values_supported": ["RS256"]})

proc clientWith(fake: FakeHttp): OidcClient =
  newOidcClient(fake.asyncTransport(), Issuer, ClientId)

proc bodyOf(fake: FakeHttp; index: int): string = fake.requests[index].body

suite "the discovery URL is RFC 8414's, and a trailing slash does not matter":
  test "construction":
    ck discoveryUrl("https://issuer.test") ==
      "https://issuer.test/.well-known/openid-configuration"
    ck discoveryUrl("https://issuer.test/") ==
      "https://issuer.test/.well-known/openid-configuration"
    ck discoveryUrl("https://issuer.test///") ==
      "https://issuer.test/.well-known/openid-configuration"

suite "discovery":
  test "a document that names another issuer is refused, not merged":
    # The refusal is `parseDiscovery`'s (RFC 8414 §3.3). What is asserted here
    # is that the driver SURFACES it rather than swallowing the exception and
    # reporting a generic failure — a distinction a user reading the message
    # depends on.
    let fake = newFakeHttp(@[response(200, discoveryDoc("https://elsewhere.test"))])
    let c = clientWith(fake)
    let err = waitFor c.discover()
    ck err.len > 0
    ck err.contains("elsewhere.test")
    ck err.contains(Issuer)
    ck not c.isDiscovered

  test "a good document is bound and its endpoints are kept":
    let fake = newFakeHttp(@[response(200, discoveryDoc())])
    let c = clientWith(fake)
    ck (waitFor c.discover()) == ""
    ck c.isDiscovered
    ck c.config.tokenEndpoint == Issuer & "/oauth/v2/token"
    ck c.config.deviceAuthorizationEndpoint ==
      Issuer & "/oauth/v2/device_authorization"
    ck fake.requests[0].url == discoveryUrl(Issuer)
    ck fake.requests[0].httpMethod == hmGet

  test "an unreachable issuer says so, and does not look like a refusal":
    let fake = newFakeHttp(@[response(599, "connection refused")])
    let c = clientWith(fake)
    let err = waitFor c.discover()
    ck err.contains("connection refused")
    ck not err.contains("HTTP 599")

  test "nothing else can run before discovery has":
    let fake = newFakeHttp(@[])
    let c = clientWith(fake)
    ck (waitFor c.beginDeviceAuthorization(0)).error.contains("discovery has not run")
    ck (waitFor c.fetchJwks()).error.contains("discovery has not run")
    ck (waitFor c.refreshGrant("r")).error.contains("discovery has not run")
    ck fake.requests.len == 0

suite "the device authorization request is a PUBLIC client's":
  test "the form carries client_id and scope, and no secret of any kind":
    let fake = newFakeHttp(@[
      response(200, discoveryDoc()),
      response(200, $(%*{
        "device_code": "DEV-SECRET", "user_code": "WDJB-MJHT",
        "verification_uri": "https://issuer.test/device",
        "expires_in": 600, "interval": 5}))])
    let c = clientWith(fake)
    ck (waitFor c.discover()) == ""
    let r = waitFor c.beginDeviceAuthorization(1_000)
    ck r.error == ""
    ck r.auth.userCode == "WDJB-MJHT"
    ck r.auth.expiresAt == 1_600
    ck r.auth.pollInterval == 5

    let body = bodyOf(fake, 1)
    ck body.contains("client_id=" & ClientId)
    ck body.contains("scope=openid")
    # A secret shipped in a binary is not a secret. Asserted rather than
    # assumed, because adding one is a one-line change that nothing else here
    # would notice.
    ck not body.contains("client_secret")
    ck fake.requests[1].httpMethod == hmPost
    ck fake.requests[1].url == Issuer & "/oauth/v2/device_authorization"

  test "the user-facing prompt never carries the device code":
    let fake = newFakeHttp(@[
      response(200, discoveryDoc()),
      response(200, $(%*{
        "device_code": "DEV-SECRET", "user_code": "WDJB-MJHT",
        "verification_uri": "https://issuer.test/device",
        "expires_in": 600}))])
    let c = clientWith(fake)
    discard waitFor c.discover()
    let r = waitFor c.beginDeviceAuthorization(0)
    ck r.auth.displayPrompt.contains("WDJB-MJHT")
    ck not r.auth.displayPrompt.contains("DEV-SECRET")

suite "a 400 is an ANSWER, not a failure — RFC 6749 §5.2":
  # The single most consequential thing in this file. An issuer returns
  # `authorization_pending` and `slow_down` with HTTP 400. A driver that
  # treated the status as the verdict would end every sign-in on the first
  # poll, and would do so while every pure test stayed green.
  proc pollingClient(replies: seq[HttpResponse]): (OidcClient, FakeHttp) =
    let fake = newFakeHttp(@[response(200, discoveryDoc())] & replies)
    let c = clientWith(fake)
    discard waitFor c.discover()
    (c, fake)

  proc anAuth(c: OidcClient; fake: FakeHttp): DeviceAuthorization =
    var a: DeviceAuthorization
    discard parseDeviceAuthorization($(%*{
      "device_code": "DEV-SECRET", "user_code": "U", "verification_uri": "u",
      "expires_in": 600, "interval": 5}), 0, a)
    a

  test "authorization_pending at HTTP 400 keeps the loop alive":
    let (c, fake) = pollingClient(@[
      response(400, $(%*{"error": "authorization_pending"}))])
    let auth = anAuth(c, fake)
    let p = waitFor c.pollOnce(auth)
    ck p.outcome == poPending
    ck p.transportError == ""
    ck shouldKeepPolling(p.outcome, auth, 1)

  test "slow_down at HTTP 400 likewise, and the interval rises":
    let (c, fake) = pollingClient(@[
      response(400, $(%*{"error": "slow_down"}))])
    let auth = anAuth(c, fake)
    let p = waitFor c.pollOnce(auth)
    ck p.outcome == poSlowDown
    ck nextInterval(auth.pollInterval, p.outcome) > auth.pollInterval

  test "access_denied at HTTP 400 stops it":
    let (c, fake) = pollingClient(@[
      response(400, $(%*{"error": "access_denied"}))])
    let auth = anAuth(c, fake)
    let p = waitFor c.pollOnce(auth)
    ck p.outcome == poDenied
    ck not shouldKeepPolling(p.outcome, auth, 1)

  test "the poll form is RFC 8628 §3.4's, device code included":
    let (c, fake) = pollingClient(@[
      response(400, $(%*{"error": "authorization_pending"}))])
    discard waitFor c.pollOnce(anAuth(c, fake))
    let body = bodyOf(fake, 1)
    ck body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    ck body.contains("device_code=DEV-SECRET")
    ck body.contains("client_id=" & ClientId)

  test "an unreachable issuer is NOT a refusal: pending, with the reason kept":
    # A dropped packet must not end a sign-in, and must not be silently
    # indistinguishable from `authorization_pending` either.
    let (c, fake) = pollingClient(@[response(599, "network is unreachable")])
    let p = waitFor c.pollOnce(anAuth(c, fake))
    ck p.outcome == poPending
    ck p.transportError == "network is unreachable"

suite "the polling loop":
  proc fakeSleep(record: ref seq[int]): proc(seconds: int): Future[void] =
    proc(seconds: int): Future[void] =
      record[].add seconds
      result = newFuture[void]("fakeSleep")
      result.complete()

  test "slow_down raises the interval and the increase PERSISTS":
    # RFC 8628 §3.5. The common wrong implementation returns to the original
    # interval on the next `authorization_pending`; this asserts it does not.
    let fake = newFakeHttp(@[
      response(200, discoveryDoc()),
      response(400, $(%*{"error": "slow_down"})),
      response(400, $(%*{"error": "authorization_pending"})),
      response(200, $(%*{"id_token": "a.b.c", "expires_in": 3600}))])
    let c = clientWith(fake)
    discard waitFor c.discover()
    var auth: DeviceAuthorization
    discard parseDeviceAuthorization($(%*{
      "device_code": "D", "user_code": "U", "verification_uri": "u",
      "expires_in": 600, "interval": 5}), 0, auth)

    let slept = new(seq[int])
    let r = waitFor c.awaitDeviceGrant(auth, proc(): int64 = 1,
                                       fakeSleep(slept))
    ck r.error == ""
    ck r.grant.idToken == "a.b.c"
    ck slept[] == @[5, 10, 10]

  test "a closed window ends the loop without polling":
    let fake = newFakeHttp(@[response(200, discoveryDoc())])
    let c = clientWith(fake)
    discard waitFor c.discover()
    var auth: DeviceAuthorization
    discard parseDeviceAuthorization($(%*{
      "device_code": "D", "user_code": "U", "verification_uri": "u",
      "expires_in": 600}), 0, auth)
    let slept = new(seq[int])
    let r = waitFor c.awaitDeviceGrant(auth, proc(): int64 = 10_000,
                                       fakeSleep(slept))
    ck r.error == terminalDetail(poExpired)
    ck slept[].len == 0
    ck fake.requests.len == 1  # discovery only

  test "a refusal is reported in the issuer's own terms":
    let fake = newFakeHttp(@[
      response(200, discoveryDoc()),
      response(400, $(%*{"error": "access_denied"}))])
    let c = clientWith(fake)
    discard waitFor c.discover()
    var auth: DeviceAuthorization
    discard parseDeviceAuthorization($(%*{
      "device_code": "D", "user_code": "U", "verification_uri": "u",
      "expires_in": 600}), 0, auth)
    let slept = new(seq[int])
    let r = waitFor c.awaitDeviceGrant(auth, proc(): int64 = 1,
                                       fakeSleep(slept))
    ck r.error == terminalDetail(poDenied)

suite "keys":
  test "an empty JWKS is an error, never an empty success":
    # A running issuer that has signed nothing since its keys expired really
    # does publish `{"keys":[]}`; accepting it would turn one clear message
    # into "unknown key id" on every token afterwards.
    let fake = newFakeHttp(@[
      response(200, discoveryDoc()),
      response(200, """{"keys":[]}""")])
    let c = clientWith(fake)
    discard waitFor c.discover()
    let r = waitFor c.fetchJwks()
    ck r.error.contains("no usable signing keys")
    ck r.keys.len == 0

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
