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
import ../../frontend/viewmodel/identity/jwt

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
    checkClaims(parseJson("""{"iss":"""" & Issuer & """","aud":["x","""" & Aud &
                          """"],"exp":2000000000}"""), Issuer, Aud, 1_000_000_000)

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
