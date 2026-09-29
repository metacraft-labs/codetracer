## `jwt.nim` — structure, key selection and claims.
##
## NO NETWORK AND NO CRYPTO. The signature primitive is deliberately not in
## this module, so these tests are about the decisions that surround it — which
## is where JWT verifiers are actually broken. A forged token rarely defeats
## RSA; it persuades the verifier not to use it.
##
## THE ARMS THAT MATTER are the refusals: `alg: none`, an algorithm the issuer
## never advertised, a missing `kid`, an unknown `kid`, standard base64 in
## place of base64url, an audience belonging to another client, and an expired
## token. Each has a control beside it so that a refusal is shown to be
## specific rather than a parser that rejects everything.

import std/[base64, json, strutils, unittest]
import ../../identity/jwt

proc b64u(s: string): string =
  encode(s).replace('+', '-').replace('/', '_').strip(chars = {'='})

proc token(header, payload: string; sig = "signature-bytes"): string =
  b64u(header) & "." & b64u(payload) & "." & b64u(sig)

const
  Issuer = "https://login.metacraft-labs.com"
  Aud = "codetracer-ide"
  GoodHeader = """{"alg":"RS256","kid":"key-1","typ":"JWT"}"""

proc claimsJson(exp = 2_000_000_000, nbf = 0, iss = Issuer, aud = Aud): string =
  result = """{"iss":"""" & iss & """","aud":"""" & aud & """","sub":"u-1","exp":""" & $exp
  if nbf != 0: result.add(""","nbf":""" & $nbf)
  result.add("}")

suite "a token is split and decoded as the issuer produced it":
  test "the signing input is the received bytes, not a re-encoding":
    # The signature covers `header.payload` exactly as transmitted. Rebuilding
    # it from the decoded halves would verify a different string whenever the
    # issuer's JSON spacing or key order differs from ours — which is most of
    # the time.
    let t = token(GoodHeader, claimsJson())
    let p = parseJwt(t, ["RS256"])
    check p.signingInput == t.split('.')[0] & "." & t.split('.')[1]

  test "header, claims, alg and kid come back":
    let p = parseJwt(token(GoodHeader, claimsJson()), ["RS256"])
    check p.alg == "RS256"
    check p.kid == "key-1"
    check p.claims{"sub"}.getStr() == "u-1"
    check p.signature.len > 0

suite "the algorithm is the issuer's to state, not the token's to choose":
  test "'none' is refused":
    # The plainest forgery: strip the signature and say so in the header.
    expect JwtError:
      discard parseJwt(token("""{"alg":"none","kid":"key-1"}""", claimsJson()),
                       ["RS256"])

  test "an algorithm the issuer does not advertise is refused":
    # HS256 against an RSA issuer is the confusion attack: a verifier that
    # honoured it would treat the PUBLIC key as an HMAC secret, which the
    # attacker also has.
    expect JwtError:
      discard parseJwt(token("""{"alg":"HS256","kid":"key-1"}""", claimsJson()),
                       ["RS256"])

  test "an advertised algorithm is accepted":
    # CONTROL: the refusals above must be about the algorithm being unlisted,
    # not about the parser rejecting whatever it is handed.
    check parseJwt(token("""{"alg":"ES256","kid":"key-1"}""", claimsJson()),
                   ["ES256", "RS256"]).alg == "ES256"

  test "a header with no alg at all is refused":
    expect JwtError:
      discard parseJwt(token("""{"kid":"key-1"}""", claimsJson()), ["RS256"])

suite "the key is the one the token names":
  const Jwks = """
  {"keys":[
    {"kty":"RSA","use":"sig","kid":"key-1","alg":"RS256","n":"modulus-1","e":"AQAB"},
    {"kty":"RSA","use":"sig","kid":"key-2","alg":"RS256","n":"modulus-2","e":"AQAB"},
    {"kty":"RSA","use":"enc","kid":"enc-1","n":"modulus-3","e":"AQAB"},
    {"kty":"OKP","crv":"Ed25519","kid":"old-1","x":"xxx"}
  ]}"""

  test "signing keys are taken and others are skipped, not refused":
    # A JWKS legitimately carries encryption keys and algorithms a client does
    # not know. Breaking on them would break on the issuer adding anything.
    let keys = parseJwks(Jwks)
    check keys.len == 2
    check keys[0].kid == "key-1"

  test "the named key is selected":
    check selectKey(parseJwks(Jwks), "key-1", "RS256").n == "modulus-1"

  test "an unknown kid is refused, not tried against the others":
    # "Try every key" keeps a rotated-out key working for as long as it stays
    # published, which is the opposite of what rotation is for.
    expect JwtError:
      discard selectKey(parseJwks(Jwks), "key-99", "RS256")

  test "a missing kid is refused at parse time":
    expect JwtError:
      discard parseJwt(token("""{"alg":"RS256"}""", claimsJson()), ["RS256"])

  test "a key published for another algorithm is refused":
    let mixed = parseJwks("""
      {"keys":[{"kty":"RSA","use":"sig","kid":"key-1","alg":"PS256","n":"m","e":"AQAB"}]}""")
    expect JwtError:
      discard selectKey(mixed, "key-1", "RS256")

suite "base64url is not base64":
  test "standard base64 in a segment is refused with that reason":
    # They differ in two characters and in padding. Accepting both accepts
    # tokens the issuer never produced.
    expect JwtError:
      discard decodeSegment("ab+cd")
    expect JwtError:
      discard decodeSegment("ab/cd")

  test "unpadded base64url round-trips":
    # CONTROL for the above: the decoder must accept what an issuer really
    # sends, which is unpadded.
    check decodeSegment(b64u("""{"a":1}""")) == """{"a":1}"""

suite "a verified signature is not the whole check":
  test "an audience belonging to another client is refused":
    # The sharpest of these: such a token is genuine, unexpired and correctly
    # signed by the right issuer. It is simply not ours.
    expect JwtError:
      checkClaims(parseJson(claimsJson(aud = "some-other-client")),
                  Issuer, Aud, 1_000_000_000)

  test "an audience array containing ours is accepted":
    # `aud` may be a string or an array; a client handling only one would
    # reject half of a conformant issuer's tokens.
    checkClaims(parseJson("""{"iss":"""" & Issuer & """","aud":["""" & Aud &
                          """"],"exp":2000000000}"""), Issuer, Aud, 1_000_000_000)

    # THIS CASE USED TO ASSERT `["x", ours]` WITHOUT AN `azp`, AND THAT WAS THE
    # PERMISSIVENESS OIDC FORBIDS. Membership in a multi-audience list is not
    # enough — see the `azp` suite below — so the plural form needs the issuer
    # to name which client the token was for. It is still accepted; it just has
    # to say so.
    checkClaims(parseJson("""{"iss":"""" & Issuer & """","aud":["x","""" & Aud &
                          """"],"azp":"""" & Aud &
                          """","exp":2000000000}"""), Issuer, Aud, 1_000_000_000)

  test "another issuer's token is refused":
    expect JwtError:
      checkClaims(parseJson(claimsJson(iss = "https://login.evil.example")),
                  Issuer, Aud, 1_000_000_000)

  test "an expired token is refused, and skew does not rescue it":
    expect JwtError:
      checkClaims(parseJson(claimsJson(exp = 1_000_000_000)),
                  Issuer, Aud, 1_000_000_200)

  test "a token just inside the skew window is accepted":
    # CONTROL: expiry must be refused on being expired, not on being close.
    checkClaims(parseJson(claimsJson(exp = 1_000_000_000)),
                Issuer, Aud, 1_000_000_030)

  test "a token not yet valid is refused":
    expect JwtError:
      checkClaims(parseJson(claimsJson(nbf = 1_000_000_500)),
                  Issuer, Aud, 1_000_000_000)

  test "a token with no expiry at all is refused":
    expect JwtError:
      checkClaims(parseJson("""{"iss":"""" & Issuer & """","aud":"""" & Aud &
                            """"}"""), Issuer, Aud, 1_000_000_000)

suite "a malformed token is refused, not thrown":
  ## THE BACKEND IS THE POINT OF THIS SUITE. On the C backend `parseJson`
  ## raises `JsonParsingError`, a `CatchableError`, and any guard catches it.
  ## On the JS backend it defers to V8's `JSON.parse`, which throws a raw
  ## `SyntaxError` that matches NO Nim exception type — so a
  ## `try/except CatchableError` catches nothing and the exception escapes into
  ## the renderer.
  ##
  ## `jwt.nim` shipped with the narrow guard and therefore crashed the tab on
  ## attacker-shaped input, which is the whole class of input this module
  ## exists to handle. Measured on this checkout's Nim: the same
  ## `except CatchableError` answers "caught" under `nim c` and lets the
  ## exception ESCAPE under `nim js -d:nodejs`.
  ##
  ## So the assertion is not "it refuses" — it is "it refuses with OUR
  ## exception type", which is the half that only fails on one backend, and
  ## this suite runs on both.

  proc seg(s: string): string =
    encode(s).replace("+", "-").replace("/", "_").replace("=", "")

  test "a token segment that is not JSON raises JwtError, on every backend":
    let goodHeader = seg("""{"alg":"RS256","kid":"k1"}""")
    for hostile in ["{not json", "[[[", "\"unterminated", "{\"a\":}"]:
      expect JwtError:
        discard parseJwt(goodHeader & "." & seg(hostile) & ".c2ln",
                         ["RS256"])
      expect JwtError:
        discard parseJwt(seg(hostile) & "." & seg("{}") & ".c2ln", ["RS256"])

  test "a JWKS that is not JSON raises JwtError, on every backend":
    for hostile in ["<html>not a key set</html>", "{not json", "[[["]:
      expect JwtError:
        discard parseJwks(hostile)

  test "a base64url problem keeps its own sentence, not the JSON one":
    # The decode happens OUTSIDE the JSON guard so that a segment using
    # standard base64 is reported as that, rather than as "not JSON". A bare
    # `except:` cannot re-raise selectively, so the ordering is the mechanism.
    var named = false
    try:
      discard parseJwt("ab+d.ab+d.ab+d", ["RS256"])
    except JwtError as e:
      named = "base64url" in e.msg
    check named

  test "the refusals above are not a parser that refuses everything":
    # THE POSITIVE CONTROL. Without it every `expect JwtError` is satisfied by
    # a `parseJwt` that raises unconditionally.
    let parts = parseJwt(
      seg("""{"alg":"RS256","kid":"k1"}""") & "." &
      seg("""{"sub":"acct"}""") & "." & seg("sig"), ["RS256"])
    check parts.kid == "k1"
    check parts.alg == "RS256"
    check parts.claims{"sub"}.getStr() == "acct"
    check parseJwks("""{"keys":[{"kty":"RSA","kid":"k1","n":"AQAB","e":"AQAB"}]}""").len == 1

suite "a multi-audience token needs the issuer to name which client it is for":
  ## OIDC Core §3.1.3.7 rule 4. "Ours is in the `aud` list" looks sufficient
  ## and is not: a multi-audience token is one the issuer minted for a client
  ## to pass ON to another party, and that other party is in the list too. On
  ## membership alone, any co-audience could replay a token at us as though its
  ## holder had signed in here. `azp` is the issuer naming the single client the
  ## token was actually for.

  proc claimsWith(audJson, extra: string): JsonNode =
    parseJson("""{"iss":"https://i.test","aud":""" & audJson &
              ""","exp":2000000000""" & extra & "}")

  test "a single audience needs no azp — the rule is about the plural case":
    # THE POSITIVE CONTROL, and it is load-bearing here: demanding `azp`
    # unconditionally would refuse the ordinary token every issuer mints.
    checkClaims(claimsWith("\"us\"", ""), "https://i.test", "us", 1000)
    checkClaims(claimsWith("[\"us\"]", ""), "https://i.test", "us", 1000)

  test "two audiences and no azp is refused":
    expect JwtError:
      checkClaims(claimsWith("[\"us\",\"them\"]", ""),
                  "https://i.test", "us", 1000)

  test "two audiences with azp naming another client is refused":
    # The replay this rule prevents, stated as a case: the token is genuine,
    # unexpired, correctly signed, and lists us — and it was minted for `them`.
    expect JwtError:
      checkClaims(claimsWith("[\"us\",\"them\"]", ""","azp":"them""""),
                  "https://i.test", "us", 1000)

  test "two audiences with azp naming us is accepted":
    checkClaims(claimsWith("[\"us\",\"them\"]", ""","azp":"us""""),
                "https://i.test", "us", 1000)

  test "a token larger than the bound is refused before it is decoded":
    # The bound exists because this parser runs on every admission over input
    # from an attacker's direction. `token.nim` had the same reasoning as
    # `MaxPayloadLen` and it did not survive the move to a compact JWS — which
    # is how a bound gets lost: the code it guarded was replaced and the guard
    # was not part of the replacement.
    let huge = "a".repeat(MaxCompactJwsLen + 1)
    var named = false
    try:
      discard parseJwt(huge, ["RS256"])
    except JwtError as e:
      named = "at most" in e.msg
    check named

    # And the bound does not refuse a real token. Without this the case above
    # is satisfied by a `parseJwt` that refuses everything.
    let ok = parseJwt(
      encode("""{"alg":"RS256","kid":"k1"}""").replace("+", "-")
        .replace("/", "_").replace("=", "") & "." &
      encode("""{"sub":"a"}""").replace("+", "-").replace("/", "_")
        .replace("=", "") & ".c2ln", ["RS256"])
    check ok.kid == "k1"
