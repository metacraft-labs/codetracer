## The signature seam, with a REAL RS256 signature, on whichever backend runs.
##
## ## What this covers that nothing else does
##
## `nim_everywhere`'s own suite proves the libcrypto verifier against a vector
## produced by Node's WebCrypto — two independent implementations agreeing.
## `ci/test/identity-webcrypto.sh` drives the browser half under Node with a
## freshly generated key. Between them sits about ten lines of ADAPTER —
## `bytesToString`, and the mapping from `Rs256Verdict` onto this seam's
## three-state outcome — and neither suite touches it.
##
## Ten lines is exactly the size of thing that gets written once and never
## executed. The mapping is also where the interesting mistake lives: sending
## `rs256Unavailable` to `succeeded(false)` instead of `pkNotSupported` would
## make a host with no libcrypto report every valid token as forged, and every
## refusal test in the tree would still pass.
##
## ## The vector
##
## The same one `nim_everywhere/tests/test_rs256.nim` carries, and for the same
## reason: it was produced by Node 24's `crypto.subtle` (BoringSSL through V8)
## and is verified here by libcrypto. A suite that signed and verified with one
## library would prove that library agrees with itself.

import std/[strutils, unittest]

import ../../platform/outcome
import ../../identity/jwt
import nim_everywhere/rs256 except Rs256Verdict
import ../../identity/rs256_verifier

const
  KatKid = "nv-1"
  KatModulus = "pepoGt0bV51rzT4VQlWbyNltDXScSy-xor3hzuDW9Ld8vDM0SOh48DUzT-ULPaQqsLBh-r8PAiEVAO8PuX2km__NmdNQbtJfSIwZQlinyUY_BU4YpA-PB3e0I7-HREkc6NOTix9zz12ZuNfoYBwhu8pksGJdgUb0ckbsd0Kru7lKxZtPJytNAjTi0gzwDDdHO0yL8tpmlcDFK01DZ6MW0xJHhtNjflY7hQUxHD0c1rQNs9cunPRLGW1JbXgtv0uJuH6Xx0gyufNDOnfrJH7qqWhZpHflv102WC96yf5Z9dzJhtcP7hY3hBrloVQJC5q6pKmKwCdvTUYP1Sei2o2G6w"
  KatSignature = "Z4JC4zgH6CqJVhBn7iAwoxanUSoHdjGpzmzH2ZhXii7SUqBLkKRHM1On3M9-fp_dL9OZ-yIxX-pYdwz83Yg4BneoOHAl2dAGbnsgi-SGi3zWwBMJA79BOocX2ZbWqqczwC7wAAYqRXPah-lEhyJU9I5Q4FMKl7lW8jrMkAioWfmf1i6BBWG_kwgPUm5JF2BPlZnxziDnrQWAA2QQTRYW-FWzRp4LS1x2CtGfu1yb9z7-mkaGU3Nc9n6fRbr_meRyVIGPWfzG8Gr97sY4jgWs8RRw4oybhWJ9qj25IzO7jWflvTSYga3QAbxEg6-qyjTsyowRlr1QkAl04z8EeHJ0Ug"
  KatSigningInput = "eyJhbGciOiJSUzI1NiIsImtpZCI6Im52LTEifQ.eyJpc3MiOiJodHRwczovL2xvZ2luLm1ldGFjcmFmdC1sYWJzLmNvbSIsInN1YiI6Im52LWthdCJ9"

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc keys(): seq[JwkKey] =
  @[JwkKey(kid: KatKid, alg: "RS256", kty: "RSA", n: KatModulus, e: "AQAB")]

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  ## The `onComplete` + `drainPlatformCallbacks` + `doAssert settled` shape
  ## every async ViewModel suite uses. The `doAssert` matters: a future that
  ## never settles must abort loudly rather than leave the case asserting over
  ## a default-constructed value.
  ##
  ## It works here because the NATIVE seam resolves inline — libcrypto is
  ## synchronous — and on JS it does not, which is why the JS cases below
  ## assert availability rather than a verdict. `crypto.subtle.verify` is a
  ## real V8 microtask and `drainPlatformCallbacks` drains nim-everywhere's
  ## queue, not V8's; `ci/test/identity-webcrypto.sh` is what drives that half.
  var captured: PlatformOutcome[T]
  var settled = false
  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true
  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true
  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "the verification future never settled"
  captured

suite "the RS256 seam, on this backend":

  test "the seam reports whether it can verify at all":
    # Said out loud rather than asserted blind, because what is correct here
    # differs by host: a browser has `crypto.subtle` by construction, and a
    # native host may or may not ship a libcrypto this can open.
    echo "    RS256 available on this backend: ", rs256IsAvailableHere()
    when defined(js):
      check rs256IsAvailableHere()

when not defined(js):
  suite "the native seam verifies a real signature":
    ## Only native. The browser half needs a promise pumped, which no unit
    ## harness here can do — see `awaitOutcome`.

    test "a signature from Node's WebCrypto verifies through libcrypto":
      # THE POSITIVE CONTROL, and it is what makes every refusal below mean
      # something: without it they are all satisfied by a seam that answers
      # `unsupported` to everything.
      if not rs256IsAvailableHere():
        # Still an assertion, not a skip: a host that cannot verify must say
        # so through the seam, and must NOT answer `false`.
        let v = awaitOutcome(newWebCryptoVerifier(keys())(
          KatKid, bytesOf(KatSigningInput), bytesOf(decodeB64Url(KatSignature))))
        check v.isErr
        check v.error.kind == pkNotSupported
      else:
        let v = awaitOutcome(newWebCryptoVerifier(keys())(
          KatKid, bytesOf(KatSigningInput), bytesOf(decodeB64Url(KatSignature))))
        check v.isOk
        check v.value

    test "a one-bit-flipped signature is rejected, not errored":
      # The distinction the three-state seam exists for, in the direction that
      # is easy to get backwards: a bad signature is `succeeded(false)`, never
      # an error, or a forged token would read as a broken host.
      if rs256IsAvailableHere():
        var sig = decodeB64Url(KatSignature)
        sig[0] = char(uint8(sig[0]) xor 1'u8)
        let v = awaitOutcome(newWebCryptoVerifier(keys())(
          KatKid, bytesOf(KatSigningInput), bytesOf(sig)))
        check v.isOk
        check not v.value

    test "a one-bit-flipped signing input is rejected":
      if rs256IsAvailableHere():
        var input = KatSigningInput
        input[10] = char(uint8(input[10]) xor 1'u8)
        let v = awaitOutcome(newWebCryptoVerifier(keys())(
          KatKid, bytesOf(input), bytesOf(decodeB64Url(KatSignature))))
        check v.isOk
        check not v.value

    test "a kid the issuer does not publish is refused without reaching libcrypto":
      let v = awaitOutcome(newWebCryptoVerifier(keys())(
        "not-published", bytesOf(KatSigningInput),
        bytesOf(decodeB64Url(KatSignature))))
      check v.isOk
      check not v.value

    test "an empty key set refuses rather than erroring":
      # A client whose JWKS fetch produced nothing must refuse tokens, not
      # report itself broken — the host is fine, the key set is not.
      let v = awaitOutcome(newWebCryptoVerifier(@[])(
        KatKid, bytesOf(KatSigningInput),
        bytesOf(decodeB64Url(KatSignature))))
      check v.isOk
      check not v.value
