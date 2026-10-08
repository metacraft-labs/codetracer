## The shared identity issuer: Zitadel at `login.metacraft-labs.com`.
##
## ## Identity is not licensing, and this file exists because they were merged
##
## ID0 chose to build identity on the mechanism licensing already had —
## `PRODUCTION_VERIFYING_KEY_BYTES`, `ct_license_ffi`, Ed25519 over a
## `CTL\x01` container — and `token.nim` followed it, defining a `CTI\x01`
## container by analogy and taking its grace windows from
## `CodeTracer-End-User-Licensing.md` §3.3.1a.
##
## **They answer different questions.** Licensing asks what this installation
## may run, and must answer on an air-gapped machine, which is why it bakes a
## key at build time and verifies with no network. Identity asks who the user
## is, and a user signing in is online by construction. Reading them as one
## question made building look cheap and adopting look expensive, because the
## comparison inherited a constraint that was never identity's.
##
## So: **licensing is untouched by this module and identity stops borrowing
## from it.** Nothing here references CTL, `ct_license_ffi`, or a baked key.
##
## ## What the issuer actually advertises
##
## Measured against the live issuer on 2026-09-30 rather than assumed:
##
##     issuer                        https://login.metacraft-labs.com
##     jwks_uri                      /oauth/v2/keys
##     device_authorization_endpoint /oauth/v2/device_authorization
##     token_endpoint                /oauth/v2/token
##     id_token_signing_alg_values   ["RS256"]
##     grant_types                   … urn:ietf:params:oauth:grant-type:device_code
##
## Two consequences for the migration. The device grant is NATIVE — ID2's work
## repoints rather than being rewritten. And the signing algorithm is **RS256
## only**, while both existing verifiers are Ed25519, so the verification
## primitive is the real work: WebCrypto implements RSASSA-PKCS1-v1_5
## directly, the desktop has no such primitive today.
##
## ## Why the issuer is checked against the document
##
## `parseDiscovery` REFUSES a document whose `issuer` is not the one that was
## asked for. RFC 8414 §3.3 requires exactly this, and the reason is the
## obvious attack on discovery: a caller who can influence which document is
## fetched otherwise chooses the `authorization_endpoint` and the `jwks_uri` —
## that is, where the user types their password and which key validates the
## result. A discovery document is configuration fetched over the network, and
## the issuer field is what binds it to the issuer that was intended.

import std/[json, strutils]

const
  DefaultIssuer* = "https://login.metacraft-labs.com"
    ## The organisation's shared identity system. Every product uses it; a
    ## per-product account system is what this campaign exists to avoid.

  VerifiableAlgs* = ["RS256"]
    ## What a client here can actually check. Kept as a list rather than a
    ## single string so that an issuer adding ES256 later is a configuration
    ## change and not a code change — but an issuer offering ONLY something
    ## absent from this list has to be refused rather than trusted, because a
    ## token nobody can verify is not an improvement on no token.

type
  IssuerConfig* = object
    ## The endpoints a client needs, taken from the issuer rather than
    ## hardcoded, so that a path change at the issuer does not require a
    ## release here.
    issuer*: string
    jwksUri*: string
    deviceAuthorizationEndpoint*: string
    tokenEndpoint*: string
    authorizationEndpoint*: string
    signingAlgs*: seq[string]

  DiscoveryError* = object of CatchableError
    ## Raised rather than returned: every failure below means the client
    ## cannot authenticate at all, and a caller that forgot to check a result
    ## code would proceed against endpoints it never validated.

proc requireStr(d: JsonNode; key, why: string): string =
  if not d.hasKey(key) or d[key].kind != JString or d[key].getStr().len == 0:
    raise newException(DiscoveryError,
      "the discovery document has no usable '" & key & "': " & why)
  d[key].getStr()

proc parseDiscovery*(doc: string; expectedIssuer = DefaultIssuer): IssuerConfig =
  ## Parse an OpenID Provider Metadata document and bind it to the issuer that
  ## was asked for.
  var j: JsonNode
  try:
    j = parseJson(doc)
  except:
    # THE BARE `except:` IS DELIBERATE, AND IT IS NOT STYLE. On the C backend
    # `parseJson` raises `JsonParsingError`, a `CatchableError`. On the JS
    # backend it defers to V8's `JSON.parse` (see `std/json`'s `when
    # defined(js)` branch and its `importjs: "JSON.parse(#)"`), which throws a
    # raw `SyntaxError` that NO Nim exception type matches — so
    # `except CatchableError` catches NOTHING there and the exception escapes
    # into the renderer.
    #
    # Measured on this checkout's Nim rather than argued: a `try/except
    # CatchableError` around `parseJson("{not json")` answers "caught" under
    # `nim c` and lets the exception ESCAPE under `nim js -d:nodejs`. The bare
    # form catches it on both.
    #
    # This module runs on both backends by design and parses input that
    # arrives over the network from an attacker's direction, so the narrow form
    # is a crash on the backend the renderer ships on. `token.nim:405` and
    # `device_grant.nim:176` already carry this comment's ancestor;
    # `identity-token-mutation.sh`'s M17 and G9 arms exist to keep it.
    raise newException(DiscoveryError, "the discovery document is not JSON")
  if j.kind != JObject:
    raise newException(DiscoveryError,
      "the discovery document is not a JSON object")

  let advertised = requireStr(j, "issuer",
    "without it the document cannot be bound to the issuer it claims to describe")

  # RFC 8414 §3.3. See the header: this is what stops a substituted document
  # from choosing where the user signs in and which key validates the result.
  if advertised.strip(chars = {'/'}) != expectedIssuer.strip(chars = {'/'}):
    raise newException(DiscoveryError,
      "the discovery document is for '" & advertised & "' but '" &
      expectedIssuer & "' was asked for. A document that does not name the " &
      "issuer it was fetched for chooses the authorization endpoint and the " &
      "signing keys, so it is refused rather than merged")

  result.issuer = advertised
  result.jwksUri = requireStr(j, "jwks_uri",
    "nothing could verify a token without it")
  result.tokenEndpoint = requireStr(j, "token_endpoint",
    "no flow can exchange anything for a token without it")
  result.authorizationEndpoint = requireStr(j, "authorization_endpoint",
    "the browser flow has nowhere to send the user")
  result.deviceAuthorizationEndpoint = requireStr(j,
    "device_authorization_endpoint",
    "the desktop flow is RFC 8628 and has nowhere to begin")

  for a in j{"id_token_signing_alg_values_supported"}.getElems():
    if a.kind == JString: result.signingAlgs.add(a.getStr())
  if result.signingAlgs.len == 0:
    raise newException(DiscoveryError,
      "the discovery document advertises no id_token signing algorithms")

  var usable = false
  for a in result.signingAlgs:
    if a in VerifiableAlgs: usable = true
  if not usable:
    raise newException(DiscoveryError,
      "the issuer signs with " & result.signingAlgs.join(", ") &
      " and this client can verify only " & VerifiableAlgs.join(", ") &
      ". A token nobody here can check is not better than no token")
