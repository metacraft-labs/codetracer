## Unit tests for `viewmodel/identity/oidc_redirect` — the shared
## Authorization-Code + PKCE redirect flow behind both CodeTracer sign-in
## surfaces (SSO-M4).
##
## Runs on BOTH backends, which is the point of keeping the module pure:
##
##   nim c  -r --path:src/frontend/viewmodel src/frontend/viewmodel/tests/unit/test_oidc_redirect.nim
##   nim js -r --path:src/frontend/viewmodel src/frontend/viewmodel/tests/unit/test_oidc_redirect.nim
##
## ...or through the lanes, which discover this file by glob:
##
##   just test-vm-unit      # C
##   just test-vm-unit-js   # JS
##
## THE PKCE VECTORS ARE THE RFC'S OWN. `codeVerifierFromEntropy` is checked
## against the octet list in RFC 7636 Appendix A and `codeChallengeFromDigest`
## against Appendix B, so a passing test means "this agrees with the standard",
## not "this agrees with itself". A base64url encoder that is merely
## self-consistent is exactly the defect that shows up as an
## `invalid_grant` at a token endpoint months later.

import std/[strutils, tables, unittest]

import identity/oidc_redirect

var countedAssertions = 0
template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 117
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# RFC 7636 Appendix A: these octets base64url-encode to the example verifier.
const RfcEntropy: array[32, byte] = [
  116'u8, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
  22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121
]
const RfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
# RFC 7636 Appendix B: SHA-256 of the ASCII verifier above.
const RfcDigest: array[32, byte] = [
  19'u8, 211, 30, 150, 26, 26, 216, 236, 47, 22, 177, 12, 76, 152, 46, 8,
  118, 168, 120, 173, 109, 241, 68, 86, 110, 225, 137, 74, 203, 112, 249, 195
]
const RfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

suite "oidc_redirect — base64url":
  test "encodes the RFC 4648 section 5 alphabet without padding":
    counted base64UrlNoPad(bytesOf("f")) == "Zg"
    counted base64UrlNoPad(bytesOf("fo")) == "Zm8"
    counted base64UrlNoPad(bytesOf("foo")) == "Zm9v"
    counted base64UrlNoPad(bytesOf("foob")) == "Zm9vYg"
    counted base64UrlNoPad(bytesOf("fooba")) == "Zm9vYmE"
    counted base64UrlNoPad(bytesOf("foobar")) == "Zm9vYmFy"
    counted base64UrlNoPad(@[]) == ""

  test "uses -_ rather than +/ and never emits padding":
    # 0xff 0xef 0xfe is the byte triple whose STANDARD base64 is "/+/+"; if the
    # encoder were the standard alphabet with a substitution forgotten, this is
    # the case that catches it.
    counted base64UrlNoPad(@[0xff'u8, 0xef'u8, 0xfe'u8]) == "_-_-"
    counted '+' notin base64UrlNoPad(@[0xff'u8, 0xef'u8, 0xfe'u8])
    counted '/' notin base64UrlNoPad(@[0xff'u8, 0xef'u8, 0xfe'u8])
    counted '=' notin base64UrlNoPad(bytesOf("f"))
    counted '=' notin base64UrlNoPad(bytesOf("fo"))

suite "oidc_redirect — PKCE (RFC 7636)":
  test "the published verifier vector round-trips":
    counted codeVerifierFromEntropy(RfcEntropy) == RfcVerifier
    counted codeVerifierFromEntropy(RfcEntropy).len == 43
    counted isValidCodeVerifier(codeVerifierFromEntropy(RfcEntropy))

  test "the published S256 challenge vector round-trips":
    counted codeChallengeFromDigest(RfcDigest) == RfcChallenge
    # ...and the challenge is NOT the verifier, which is the whole difference
    # between S256 and the `plain` method this module refuses to offer.
    counted codeChallengeFromDigest(RfcDigest) != RfcVerifier

  test "only S256 is named":
    counted CodeChallengeMethodS256 == "S256"

  test "verifier length bounds are the RFC's":
    counted MinCodeVerifierLen == 43
    counted MaxCodeVerifierLen == 128
    counted not isValidCodeVerifier(repeat('a', 42))
    counted isValidCodeVerifier(repeat('a', 43))
    counted isValidCodeVerifier(repeat('a', 128))
    counted not isValidCodeVerifier(repeat('a', 129))
    counted not isValidCodeVerifier("")

  test "verifier charset is the RFC's unreserved set":
    counted isValidCodeVerifier(repeat('-', 43))
    counted isValidCodeVerifier(repeat('.', 43))
    counted isValidCodeVerifier(repeat('_', 43))
    counted isValidCodeVerifier(repeat('~', 43))
    # The four characters most likely to sneak in from a careless encoder: the
    # standard base64 alphabet's `+` and `/`, its padding `=`, and a space.
    counted not isValidCodeVerifier(repeat('a', 42) & "+")
    counted not isValidCodeVerifier(repeat('a', 42) & "/")
    counted not isValidCodeVerifier(repeat('a', 42) & "=")
    counted not isValidCodeVerifier(repeat('a', 42) & " ")

suite "oidc_redirect — surfaces and redirect URIs (RFC 8252)":
  test "a native surface must use the system browser; the web surface must not":
    counted requiresSystemBrowser(asNativeLoopback)
    counted requiresSystemBrowser(asNativeScheme)
    counted not requiresSystemBrowser(asWebRedirect)

  test "loopback is recognised by address, not by name":
    counted isLoopbackRedirect("http://127.0.0.1:51234/callback")
    counted isLoopbackRedirect("http://[::1]:51234/callback")
    # `localhost` resolves through the OS and is not under the app's control;
    # RFC 8252 section 8.3 says to use the literal address for exactly that reason.
    counted not isLoopbackRedirect("http://localhost:51234/callback")
    counted not isLoopbackRedirect("https://example.test/callback")
    # A host that merely BEGINS with the loopback literal is a different host.
    counted not isLoopbackRedirect("http://127.0.0.1.example.test/callback")

  test "a private-use scheme is not one a browser would claim":
    counted isPrivateUseSchemeRedirect("codetracer://auth/callback")
    counted isPrivateUseSchemeRedirect("com.metacraft.codetracer://auth/callback")
    counted not isPrivateUseSchemeRedirect("https://example.test/callback")
    counted not isPrivateUseSchemeRedirect("http://127.0.0.1:1/callback")
    counted not isPrivateUseSchemeRedirect("javascript:alert(1)")
    counted not isPrivateUseSchemeRedirect("data:text/html,x")
    counted not isPrivateUseSchemeRedirect("file:///tmp/local-file")
    counted not isPrivateUseSchemeRedirect("noscheme")
    counted not isPrivateUseSchemeRedirect(":///auth")

  test "each surface accepts only its own redirect shape":
    # The web surface must not accept http — that is the loopback exemption, and
    # it exists only because a native app has nowhere else to receive a response.
    counted isAcceptableRedirect(asWebRedirect, "https://ide.codetracer.com/auth/callback")
    counted not isAcceptableRedirect(asWebRedirect, "http://ide.codetracer.com/auth/callback")
    counted not isAcceptableRedirect(asWebRedirect, "http://127.0.0.1:5173/auth/callback")
    counted not isAcceptableRedirect(asWebRedirect, "codetracer://auth/callback")

    counted isAcceptableRedirect(asNativeLoopback, "http://127.0.0.1:51234/callback")
    counted not isAcceptableRedirect(asNativeLoopback, "https://ide.codetracer.com/auth/callback")
    counted not isAcceptableRedirect(asNativeLoopback, "codetracer://auth/callback")

    counted isAcceptableRedirect(asNativeScheme, "codetracer://auth/callback")
    counted not isAcceptableRedirect(asNativeScheme, "http://127.0.0.1:51234/callback")
    counted not isAcceptableRedirect(asNativeScheme, "https://ide.codetracer.com/auth/callback")

suite "oidc_redirect — the authorization request":
  setup:
    var request = AuthorizationRequest(
      authorizationEndpoint: "https://login.metacraft-labs.com/oauth/v2/authorize",
      clientId: "123456789",
      redirectUri: "https://ide.codetracer.com/auth/callback",
      scopes: @["openid", "profile", "email"],
      state: "st-abc",
      nonce: "nn-def",
      codeChallenge: RfcChallenge,
      prompt: "",
      extra: initTable[string, string](),
    )

  test "carries every parameter the grant requires":
    let url = buildAuthorizationUrl(request)
    counted url.contains("response_type=code")
    counted url.contains("client_id=123456789")
    counted url.contains("code_challenge_method=S256")
    counted url.contains("code_challenge=" & RfcChallenge)
    counted url.contains("state=st-abc")
    counted url.contains("nonce=nn-def")
    counted url.startsWith("https://login.metacraft-labs.com/oauth/v2/authorize?")

  test "percent-encodes the redirect URI and the space-separated scopes":
    let url = buildAuthorizationUrl(request)
    # An unencoded `://` in a query value would be read as the end of the value
    # by some servers and truncate the redirect — which then mismatches the
    # registration and fails with an error about the redirect, not the encoding.
    counted url.contains("redirect_uri=https%3A%2F%2Fide.codetracer.com%2Fauth%2Fcallback")
    counted not url.contains("redirect_uri=https://")
    counted (url.contains("scope=openid+profile+email") or
             url.contains("scope=openid%20profile%20email"))

  test "omits optional parameters rather than sending them empty":
    request.nonce = ""
    request.prompt = ""
    let url = buildAuthorizationUrl(request)
    # `prompt=` empty is NOT the same as no prompt: it is a request for an
    # unspecified prompt behaviour, and providers differ on what they do with it.
    counted not url.contains("prompt=")
    counted not url.contains("nonce=")

  test "prompt=none is what a silent cross-product check sends":
    request.prompt = "none"
    counted buildAuthorizationUrl(request).contains("prompt=none")

  test "provider-reserved extras are encoded, and ordered deterministically":
    request.extra["idp_selection"] = "urn:zitadel:iam:org:idp:id:9876"
    request.extra["aaa"] = "first"
    let url = buildAuthorizationUrl(request)
    counted url.contains("idp_selection=urn%3Azitadel%3Aiam%3Aorg%3Aidp%3Aid%3A9876")
    # Deterministic ordering: `aaa` sorts before `idp_selection`, on both
    # backends. Nim's table iteration order is unspecified, so without the sort
    # this suite could pass under `nim c` and fail under `nim js` for a reason
    # that has nothing to do with the code being tested.
    counted url.find("aaa=first") < url.find("idp_selection=")
    counted buildAuthorizationUrl(request) == url

  test "appends with & when the endpoint already carries a query":
    request.authorizationEndpoint = "https://login.metacraft-labs.com/authorize?tenant=mcl"
    let url = buildAuthorizationUrl(request)
    counted url.contains("?tenant=mcl&")
    counted not url.contains("?tenant=mcl?")

suite "oidc_redirect — parsing the authorization response":
  test "reads a code from every delivery shape":
    for redirect in [
      "https://ide.codetracer.com/auth/callback?code=AC1&state=st-abc",
      "http://127.0.0.1:51234/callback?code=AC1&state=st-abc",
      "codetracer://auth/callback?code=AC1&state=st-abc",
    ]:
      let outcome = parseAuthorizationResponse(redirect)
      counted outcome.kind == aoCode
      counted outcome.code == "AC1"
      counted outcome.returnedState == "st-abc"

  test "percent-decodes values":
    let outcome = parseAuthorizationResponse(
      "codetracer://auth/callback?code=a%2Fb%2Bc&state=x%20y")
    counted outcome.kind == aoCode
    counted outcome.code == "a/b+c"
    counted outcome.returnedState == "x y"

  test "an error response is reported as an error, not as malformed":
    # A silent single-sign-on probe that finds nobody signed in answers exactly
    # this. Treating it as malformed would turn the ordinary not-signed-in state
    # into a reported defect.
    let outcome = parseAuthorizationResponse(
      "https://ide.codetracer.com/auth/callback?error=login_required&error_description=nobody&state=st-abc")
    counted outcome.kind == aoError
    counted outcome.error == "login_required"
    counted outcome.errorDescription == "nobody"
    counted outcome.errorState == "st-abc"

  test "an error wins over a code in the same response":
    # A response carrying both is not something to salvage a code from.
    let outcome = parseAuthorizationResponse(
      "codetracer://auth/callback?code=AC1&error=access_denied&state=st-abc")
    counted outcome.kind == aoError
    counted outcome.error == "access_denied"

  test "a repeated parameter resolves to its FIRST occurrence":
    # An injected duplicate is an attempt to have the client and the provider
    # read different values out of one URL. Go's net/http FormValue — which the
    # deployed provider is written against — takes the first, so taking the
    # first is what keeps the two agreeing.
    let outcome = parseAuthorizationResponse(
      "codetracer://auth/callback?code=GOOD&code=EVIL&state=st-abc")
    counted outcome.kind == aoCode
    counted outcome.code == "GOOD"

  test "a response with neither a code nor an error is malformed":
    counted parseAuthorizationResponse("codetracer://auth/callback").kind == aoMalformed
    counted parseAuthorizationResponse("codetracer://auth/callback?").kind == aoMalformed
    counted parseAuthorizationResponse("codetracer://auth/callback?state=st-abc").kind == aoMalformed
    counted parseAuthorizationResponse("codetracer://auth/callback?code=&state=st-abc").kind == aoMalformed
    counted parseAuthorizationResponse("").kind == aoMalformed

  test "a fragment is not part of the response":
    let outcome = parseAuthorizationResponse(
      "https://ide.codetracer.com/auth/callback?code=AC1&state=st-abc#code=EVIL")
    counted outcome.kind == aoCode
    counted outcome.code == "AC1"

suite "oidc_redirect — the state check":
  test "matches only an identical state":
    counted constantTimeEq("st-abc", "st-abc")
    counted not constantTimeEq("st-abc", "st-abd")
    counted not constantTimeEq("st-abc", "st-ab")
    counted not constantTimeEq("", "x")
    counted constantTimeEq("", "")

  test "a usable code requires a matching state":
    let good = parseAuthorizationResponse("codetracer://auth/callback?code=AC1&state=st-abc")
    counted isUsableCode(good, "st-abc")
    counted not isUsableCode(good, "st-abd")
    counted not isUsableCode(good, "")

  test "an error or a malformed response is never usable":
    let err = parseAuthorizationResponse("codetracer://auth/callback?error=access_denied&state=st-abc")
    counted not isUsableCode(err, "st-abc")
    let bad = parseAuthorizationResponse("codetracer://auth/callback?state=st-abc")
    counted not isUsableCode(bad, "st-abc")

  test "a response carrying NO state is refused even against a known state":
    # The provider echoes `state` back; a response without one cannot be tied to
    # the request that started the flow, so there is nothing to compare.
    let noState = parseAuthorizationResponse("codetracer://auth/callback?code=AC1")
    counted noState.kind == aoCode
    counted not isUsableCode(noState, "st-abc")

  test "every assertion in this file ran":
    check countedAssertions == ExpectedAssertions
