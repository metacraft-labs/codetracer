## An OIDC ID token: structure, key selection and claims — everything except
## the signature primitive.
##
## ## Why the primitive is not here
##
## RS256 is verified differently on each target and neither belongs in a
## parsing module. In the browser it is `crypto.subtle` with
## `RSASSA-PKCS1-v1_5`; on the desktop it is `ring`'s
## `RSA_PKCS1_2048_8192_SHA256`, which is already in
## `codetracer-native-backend`'s dependency graph through rustls. This module
## produces the three things such a primitive needs — the signing input, the
## signature bytes, and the selected key — and takes the verdict back.
##
## ## The refusals here are the security content
##
## A JWT parser's defaults are where tokens get forged, so each refusal below
## is deliberate rather than defensive:
##
## **`alg` comes from the ISSUER, never from the token.** A token naming its
## own algorithm is the classic forgery: `none` strips the signature check
## outright, and swapping RS256 for HS256 invites a verifier into treating the
## RSA *public* key as an HMAC secret — which the attacker also has. So
## `allowedAlgs` is passed in, sourced from the issuer's
## `id_token_signing_alg_values_supported`, and a header naming anything else
## is refused before a key is even looked up.
##
## **`kid` is required and must match.** Without it, key selection degenerates
## into "try every key", which turns a rotated-out key into an accepted one for
## as long as it remains published.
##
## **base64url, not base64.** They differ in two characters (`-_` against
## `+/`) and in padding. A decoder that accepts standard base64 for a JWT
## segment accepts tokens the issuer never produced.

import std/[base64, json, strutils]

const
  MaxCompactJwsLen* = 16 * 1024
    ## A bound BEFORE anything decodes. An ID token is a handful of claims; a
    ## conformant one from this issuer is under 2 KiB. Without a limit,
    ## `decodeSegment` and `parseJson` will happily work through a segment of
    ## any size, and this parser runs on every admission over input that
    ## arrives from an attacker's direction — an unbounded parser there is a
    ## denial-of-service surface no legitimate token needs.
    ##
    ## `token.nim` had this reasoning as `MaxPayloadLen` and it did not survive
    ## the move to a compact JWS, which is how a bound gets lost: the code it
    ## guarded was replaced and the guard was not part of the replacement.

type
  JwtError* = object of CatchableError
    ## Every failure here means the token is not usable. Raised rather than
    ## returned so a caller cannot forget to look.

  JwtParts* = object
    ## A compact JWS, split and decoded, with the signing input kept exactly as
    ## it appeared — the signature covers those bytes, so re-encoding the
    ## decoded halves would verify something subtly different.
    signingInput*: string   ## `header.payload`, ASCII, as received
    signature*: seq[byte]
    header*: JsonNode
    claims*: JsonNode
    alg*: string
    kid*: string

  JwkKey* = object
    kid*: string
    alg*: string
    kty*: string
    n*: string              ## base64url modulus, as the JWKS published it
    e*: string              ## base64url exponent
    raw*: JsonNode          ## the whole entry — WebCrypto imports it directly

proc decodeSegment*(seg: string): string =
  ## base64url with padding restored. `decode` accepts the standard alphabet,
  ## so the substitution has to happen here and not be hoped for.
  if seg.len == 0:
    raise newException(JwtError, "an empty token segment")
  for c in seg:
    if c in {'+', '/', '='}:
      raise newException(JwtError,
        "the token segment uses standard base64 ('" & c & "'), not base64url. " &
        "A decoder that accepts both accepts tokens the issuer never produced")
  var s = seg.replace('-', '+').replace('_', '/')
  case s.len mod 4
  of 2: s.add("==")
  of 3: s.add("=")
  of 0: discard
  else:
    raise newException(JwtError, "the token segment is not valid base64url")
  try:
    decode(s)
  except CatchableError as e:
    raise newException(JwtError, "the token segment does not decode: " & e.msg)

proc parseJwt*(compact: string; allowedAlgs: openArray[string]): JwtParts =
  ## Split and decode, and refuse anything whose header does not name an
  ## algorithm the ISSUER advertised. See the module header for why `alg` is
  ## not the token's to choose.
  if compact.len > MaxCompactJwsLen:
    raise newException(JwtError,
      "the token is " & $compact.len & " bytes and this client accepts at most " &
      $MaxCompactJwsLen & ". Refused before decoding: an unbounded parser on " &
      "every admission is a denial-of-service surface")
  let parts = compact.strip().split('.')
  if parts.len != 3:
    raise newException(JwtError,
      "a compact JWS has three dot-separated segments; this has " & $parts.len)

  result.signingInput = parts[0] & "." & parts[1]
  for b in decodeSegment(parts[2]): result.signature.add(byte(b))

  # `decodeSegment` raises `JwtError`, which must propagate with its own
  # sentence rather than be re-wrapped as "not JSON" — so it is done OUTSIDE
  # the guard below. A bare `except:` cannot re-raise selectively, and putting
  # the decode inside would report a base64url problem as a JSON one.
  let headerText = decodeSegment(parts[0])
  let claimsText = decodeSegment(parts[1])
  try:
    result.header = parseJson(headerText)
    result.claims = parseJson(claimsText)
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
    raise newException(JwtError, "a token segment is not JSON")

  result.alg = result.header{"alg"}.getStr()
  result.kid = result.header{"kid"}.getStr()

  if result.alg.len == 0:
    raise newException(JwtError, "the token header names no algorithm")
  if result.alg notin allowedAlgs:
    raise newException(JwtError,
      "the token is signed with '" & result.alg & "' and the issuer advertises " &
      allowedAlgs.join(", ") & ". The algorithm is the issuer's to state, not " &
      "the token's to choose — 'none' removes the check entirely, and HS256 " &
      "invites verifying an RSA public key as an HMAC secret")
  if result.kid.len == 0:
    raise newException(JwtError,
      "the token header names no key id. Without one, selection becomes 'try " &
      "every key', which keeps a rotated-out key working while it is published")

proc parseJwks*(doc: string): seq[JwkKey] =
  ## The issuer's published keys. Entries that are not RSA signing keys are
  ## skipped rather than refused: a JWKS legitimately carries encryption keys
  ## and future algorithms, and a client that broke on them would break on the
  ## issuer adding something unrelated.
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
    raise newException(JwtError, "the JWKS is not JSON")
  for k in j{"keys"}.getElems():
    if k{"kty"}.getStr() != "RSA": continue
    if k.hasKey("use") and k{"use"}.getStr() != "sig": continue
    result.add(JwkKey(
      kid: k{"kid"}.getStr(), alg: k{"alg"}.getStr(),
      kty: k{"kty"}.getStr(), n: k{"n"}.getStr(), e: k{"e"}.getStr(),
      raw: k))

proc selectKey*(keys: openArray[JwkKey]; kid, alg: string): JwkKey =
  ## Exactly the key the token names, or a refusal.
  for k in keys:
    if k.kid == kid:
      if k.alg.len > 0 and k.alg != alg:
        raise newException(JwtError,
          "key '" & kid & "' is published for " & k.alg & " and the token " &
          "claims " & alg)
      if k.n.len == 0 or k.e.len == 0:
        raise newException(JwtError,
          "key '" & kid & "' carries no RSA modulus or exponent")
      return k
  raise newException(JwtError,
    "the issuer publishes no key with id '" & kid & "'. A token naming an " &
    "unknown key is refused rather than tried against the others")

proc checkClaims*(claims: JsonNode; issuer, audience: string; nowUnix: int64;
                  skewSeconds = 60'i64) =
  ## `iss`, `aud`, `exp` and `nbf`. A verified signature only says the issuer
  ## produced this token — not that it was produced for this client, or that
  ## it is still valid.
  let iss = claims{"iss"}.getStr()
  if iss.strip(chars = {'/'}) != issuer.strip(chars = {'/'}):
    raise newException(JwtError,
      "the token was issued by '" & iss & "', not '" & issuer & "'")

  # `aud` is a string or an array of strings — both are legal, and a client
  # that handled only one would reject half of a conformant issuer's tokens.
  var audienceMatches = false
  let aud = claims{"aud"}
  if aud != nil:
    if aud.kind == JString: audienceMatches = aud.getStr() == audience
    elif aud.kind == JArray:
      for a in aud.getElems():
        if a.kind == JString and a.getStr() == audience: audienceMatches = true
  if not audienceMatches:
    raise newException(JwtError,
      "the token's audience is not '" & audience & "'. A token minted for " &
      "another client of the same issuer is a valid token and not ours")

  # OIDC Core §3.1.3.7 rule 4: when `aud` names more than one audience, `azp`
  # MUST be present and MUST be this client.
  #
  # WHY THE RULE EXISTS, because "ours is in the list" looks sufficient and is
  # not. A multi-audience token is one the issuer minted for a client to send
  # ON to another party — that other party is in the list too. Accepting it on
  # the strength of membership alone lets any co-audience replay a token at us
  # as though its holder had signed in here. `azp` is the issuer naming which
  # single client the token was actually FOR.
  if aud != nil and aud.kind == JArray and aud.getElems().len > 1:
    let azp = claims{"azp"}.getStr()
    if azp.len == 0:
      raise newException(JwtError,
        "the token names " & $aud.getElems().len & " audiences and no azp. " &
        "OIDC Core §3.1.3.7 requires one, because a multi-audience token is " &
        "meant to be passed on and every co-audience could otherwise replay " &
        "it here")
    if azp != audience:
      raise newException(JwtError,
        "the token's authorized party is '" & azp & "', not '" & audience &
        "'. It was minted for that client to use, and we are only a " &
        "co-audience")

  let exp = claims{"exp"}.getBiggestInt(0)
  if exp == 0:
    raise newException(JwtError, "the token states no expiry")
  if nowUnix - skewSeconds >= exp:
    raise newException(JwtError, "the token expired at " & $exp)

  let nbf = claims{"nbf"}.getBiggestInt(0)
  if nbf != 0 and nowUnix + skewSeconds < nbf:
    raise newException(JwtError, "the token is not valid until " & $nbf)
