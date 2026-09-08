## OIDC Authorization-Code + PKCE: the one redirect flow both CodeTracer
## surfaces use, and the single place that decides how they differ.
##
## SSO-M4 of the customer-identity initiative. The web IDE and the desktop app
## sign in against the same identity provider with the same grant; what differs
## between them is exactly two things:
##
## * **where the authorization response is delivered.** A browser tab gets it on
##   an https origin it already occupies. A desktop app has no origin, so RFC
##   8252 gives it two choices: a loopback listener on 127.0.0.1 (section 7.3) or
##   a private-use URI scheme the OS hands back (section 7.1).
## * **who opens the authorization URL.** A browser navigates. A native app MUST
##   hand the URL to the system browser and MUST NOT use an embedded web view
##   (RFC 8252 section 8.12), because an embedded view can read what the user
##   types into the identity provider.
##
## Everything else — the parameters, PKCE, the state check, the shape of a
## response — is identical, so it lives here once and is exercised by one test
## suite on both backends.
##
## **This module is pure, and deliberately so.** It imports `std/[strutils,
## tables, uri]` and nothing else. It performs no I/O, opens no socket, reads no
## environment variable and computes no hash: the caller supplies entropy and a
## SHA-256 digest, because those come from `crypto.subtle` in a browser and from
## a native library in the desktop build, and a module that reached for either
## could not be tested on both backends. What is left is the part that is easy to
## get subtly wrong and impossible to notice: parameter assembly, base64url
## without padding, the RFC 7636 verifier charset, and response parsing that has
## to reject an attacker-supplied state without ever leaking which character
## differed.

import std/[algorithm, strutils, tables, uri]

type
  AuthSurface* = enum ## Which of the two delivery shapes a client uses.
    ## The web build: the response returns to an https origin the browser is
    ## already on.
    asWebRedirect
    ## The desktop build, RFC 8252 section 7.3: a listener bound to
    ## 127.0.0.1 on an ephemeral port chosen at run time.
    asNativeLoopback
    ## The desktop build, RFC 8252 section 7.1: a private-use URI scheme
    ## registered with the OS, e.g. `codetracer://auth/callback`.
    asNativeScheme

  AuthorizationRequest* = object ## Everything needed to build one authorization URL.
    authorizationEndpoint*: string
    clientId*: string
    redirectUri*: string
    scopes*: seq[string]
    state*: string
    nonce*: string
    codeChallenge*: string
    ## Optional. Empty means "do not send it". `prompt=none` is what a silent
    ## cross-product single-sign-on check sends; `prompt=login` forces a fresh
    ## authentication.
    prompt*: string
    ## Provider-reserved extras, e.g. the identity-provider selection scope this
    ## deployment uses to pre-pick an upstream provider. Kept as a table rather
    ## than as named fields so a provider-specific parameter never becomes part
    ## of this type's shape.
    extra*: Table[string, string]

  AuthorizationOutcomeKind* = enum
    aoCode        ## The provider returned an authorization code.
    aoError       ## The provider returned an OAuth error response.
    aoMalformed   ## Not a usable authorization response at all.

  AuthorizationOutcome* = object
    case kind*: AuthorizationOutcomeKind
    of aoCode:
      code*: string
      returnedState*: string
    of aoError:
      error*: string
      errorDescription*: string
      errorState*: string
    of aoMalformed:
      reason*: string

const
  ## RFC 7636 section 4.1. A verifier shorter than 43 characters does not carry
  ## enough entropy for the exchange binding to be worth anything.
  MinCodeVerifierLen* = 43
  MaxCodeVerifierLen* = 128
  ## RFC 7636 section 4.2. `plain` is deliberately absent: it makes the challenge
  ## equal to the verifier, so an attacker who can see the authorization request
  ## can complete the exchange, which is the entire attack PKCE exists to stop.
  CodeChallengeMethodS256* = "S256"
  ## RFC 7636 section 4.1 unreserved set: ALPHA / DIGIT / "-" / "." / "_" / "~".
  CodeVerifierAlphabet* = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '.', '_', '~'}

  Base64UrlAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

func base64UrlNoPad*(data: openArray[byte]): string =
  ## base64url (RFC 4648 section 5) with padding omitted, which is what RFC 7636
  ## section 4.2 requires of a code challenge.
  ##
  ## Hand-rolled rather than taken from `std/base64` because that encoder emits
  ## the standard `+/` alphabet and `=` padding; converting afterwards means
  ## producing a wrong string and repairing it, and every place that has to be
  ## repaired is a place a caller can forget to. Encoding into the right alphabet
  ## directly leaves nothing to remember.
  result = newStringOfCap((data.len + 2) div 3 * 4)
  var i = 0
  while i + 2 < data.len:
    let n = (int(data[i]) shl 16) or (int(data[i + 1]) shl 8) or int(data[i + 2])
    result.add Base64UrlAlphabet[(n shr 18) and 63]
    result.add Base64UrlAlphabet[(n shr 12) and 63]
    result.add Base64UrlAlphabet[(n shr 6) and 63]
    result.add Base64UrlAlphabet[n and 63]
    i += 3
  let rest = data.len - i
  if rest == 1:
    let n = int(data[i]) shl 16
    result.add Base64UrlAlphabet[(n shr 18) and 63]
    result.add Base64UrlAlphabet[(n shr 12) and 63]
  elif rest == 2:
    let n = (int(data[i]) shl 16) or (int(data[i + 1]) shl 8)
    result.add Base64UrlAlphabet[(n shr 18) and 63]
    result.add Base64UrlAlphabet[(n shr 12) and 63]
    result.add Base64UrlAlphabet[(n shr 6) and 63]

func codeVerifierFromEntropy*(entropy: openArray[byte]): string =
  ## Build an RFC 7636 code verifier from caller-supplied random bytes.
  ##
  ## The entropy is an ARGUMENT, not something this module obtains. A browser
  ## gets it from `crypto.getRandomValues` and a native build from the OS; a
  ## module that chose for itself would need a compile-time backend switch and
  ## would stop being testable with known inputs — and a PKCE verifier whose
  ## generation cannot be tested with known inputs is one nobody has checked.
  ##
  ## 32 bytes encode to 43 characters, exactly the RFC's minimum.
  base64UrlNoPad(entropy)

func codeChallengeFromDigest*(digest: openArray[byte]): string =
  ## The S256 challenge: base64url of the SHA-256 of the verifier's ASCII bytes.
  ## The DIGEST is supplied for the same reason the entropy is.
  base64UrlNoPad(digest)

func isValidCodeVerifier*(verifier: string): bool =
  ## RFC 7636 section 4.1: 43..128 characters from the unreserved set.
  ##
  ## Worth checking rather than assuming, because the failure is silent in the
  ## worst way: an over-long or out-of-charset verifier is accepted by the client
  ## and rejected at the token endpoint, where the error says the code is
  ## invalid — which sends you looking at the code.
  if verifier.len < MinCodeVerifierLen or verifier.len > MaxCodeVerifierLen:
    return false
  for ch in verifier:
    if ch notin CodeVerifierAlphabet:
      return false
  true

func requiresSystemBrowser*(surface: AuthSurface): bool =
  ## RFC 8252 section 8.12: a native app must open the authorization URL in the
  ## system browser and must not use an embedded web view. Expressed as a
  ## property of the surface so no call site decides it by hand.
  surface != asWebRedirect

func isLoopbackRedirect*(uri: string): bool =
  ## RFC 8252 section 7.3 permits `http` for loopback and ONLY for loopback.
  ## Both spellings of the loopback host are accepted; a name that merely
  ## resolves to a loopback address today (`localhost`) is not, because what it
  ## resolves to is not under the app's control.
  uri.startsWith("http://127.0.0.1:") or uri.startsWith("http://[::1]:")

func isPrivateUseSchemeRedirect*(uri: string): bool =
  ## RFC 8252 section 7.1. A private-use scheme has no `//` authority and must
  ## not be one of the schemes a browser would claim.
  let colon = uri.find(':')
  if colon <= 0 or colon + 1 >= uri.len:
    return false
  let scheme = uri[0 ..< colon].toLowerAscii
  if scheme in ["http", "https", "file", "data", "javascript"]:
    return false
  for ch in scheme:
    if ch notin {'a' .. 'z', '0' .. '9', '+', '-', '.'}:
      return false
  true

func isAcceptableRedirect*(surface: AuthSurface, uri: string): bool =
  ## Whether a redirect URI is one this surface is allowed to use.
  ##
  ## This is the check that keeps the two implementations honest about their
  ## difference. The web surface must use https — an `http` origin would send the
  ## authorization response over cleartext — and the loopback exemption exists
  ## only for native apps, which have nowhere else to receive it.
  case surface
  of asWebRedirect:
    uri.startsWith("https://")
  of asNativeLoopback:
    isLoopbackRedirect(uri)
  of asNativeScheme:
    isPrivateUseSchemeRedirect(uri)

func buildAuthorizationUrl*(req: AuthorizationRequest): string =
  ## Assemble the authorization request URL.
  ##
  ## Every value is percent-encoded through `std/uri`. That matters more than it
  ## looks: the provider-reserved scopes this deployment uses contain colons, a
  ## redirect URI contains `://`, and `state` is opaque caller data that may
  ## contain anything at all.
  var query: seq[(string, string)] = @[
    ("client_id", req.clientId),
    ("redirect_uri", req.redirectUri),
    ("response_type", "code"),
    ("scope", req.scopes.join(" ")),
    ("code_challenge", req.codeChallenge),
    ("code_challenge_method", CodeChallengeMethodS256),
    ("state", req.state),
  ]
  if req.nonce.len > 0:
    query.add ("nonce", req.nonce)
  if req.prompt.len > 0:
    query.add ("prompt", req.prompt)
  # Sorted so the URL is deterministic and a test can assert on it. Nim's table
  # iteration order is not specified, and a test that happened to pass on one
  # backend's ordering and fail on the other's would be read as a real defect.
  var extraKeys: seq[string] = @[]
  for key in req.extra.keys:
    extraKeys.add key
  extraKeys.sort()
  for key in extraKeys:
    query.add (key, req.extra[key])

  let separator = if '?' in req.authorizationEndpoint: "&" else: "?"
  result = req.authorizationEndpoint & separator & encodeQuery(query)

func constantTimeEq*(a, b: string): bool =
  ## Compare without an early exit.
  ##
  ## Used for the `state` check. A plain `==` returns as soon as two characters
  ## differ, so the time it takes reveals how long a guessed prefix was, and
  ## `state` is exactly the value an attacker wants to guess in order to graft
  ## their authorization response onto someone else's session.
  if a.len != b.len:
    return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (int(a[i]) xor int(b[i]))
  diff == 0

func parseAuthorizationResponse*(redirectUrl: string): AuthorizationOutcome =
  ## Parse an authorization response, from either delivery shape.
  ##
  ## The same parser serves the browser's `https://.../auth/callback?...`, the
  ## native loopback's `http://127.0.0.1:<port>/callback?...` and the private-use
  ## `codetracer://auth/callback?...`, because in all three the response is the
  ## query string and nothing else. Keeping one parser is what makes "the desktop
  ## app and the web IDE agree about what a response is" true by construction.
  ##
  ## An `error` response is NOT a malformed one: it is the provider correctly
  ## telling the client something, and a silent single-sign-on probe
  ## (`prompt=none`) returning `login_required` is the ordinary, expected answer
  ## meaning "nobody is signed in". Conflating the two would make a normal
  ## not-signed-in state look like a bug.
  var query = ""
  let hash = redirectUrl.find('#')
  let trimmed = if hash >= 0: redirectUrl[0 ..< hash] else: redirectUrl
  let mark = trimmed.find('?')
  if mark >= 0 and mark + 1 < trimmed.len:
    query = trimmed[mark + 1 .. ^1]
  if query.len == 0:
    return AuthorizationOutcome(kind: aoMalformed, reason: "no query string in the authorization response")

  var params = initTable[string, string]()
  for (key, value) in decodeQuery(query):
    # FIRST occurrence wins. A response carrying `code` twice is an attempt to
    # have the client and the provider read different values out of one URL;
    # Go's `FormValue` (which this deployment's provider is written in) also
    # takes the first, so agreeing with it is what keeps them reading the same.
    if not params.hasKey(key):
      params[key] = value

  if params.hasKey("error"):
    return AuthorizationOutcome(
      kind: aoError,
      error: params["error"],
      errorDescription: params.getOrDefault("error_description", ""),
      errorState: params.getOrDefault("state", ""),
    )
  if not params.hasKey("code") or params["code"].len == 0:
    return AuthorizationOutcome(kind: aoMalformed, reason: "no code and no error in the authorization response")
  AuthorizationOutcome(
    kind: aoCode,
    code: params["code"],
    returnedState: params.getOrDefault("state", ""),
  )

func isUsableCode*(outcome: AuthorizationOutcome, expectedState: string): bool =
  ## Whether an outcome may be exchanged: a code, and a state that matches.
  ##
  ## The state check is NOT optional and is not the caller's to skip — that is
  ## why it is folded into the same predicate as "is this a code". An empty
  ## expected state is refused rather than treated as "no check wanted", because
  ## "we forgot to generate one" and "we do not want one" look identical at the
  ## call site and only one of them is acceptable.
  if outcome.kind != aoCode:
    return false
  if expectedState.len == 0:
    return false
  constantTimeEq(outcome.returnedState, expectedState)
