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
##
## ## WHETHER THE POSITIVE CONTROL RAN IS DECLARED HERE, NOT DISCOVERED
##
## This suite used to ask `rs256IsAvailableHere()` at runtime and quietly shape
## itself around the answer. Two of its cases were `if rs256IsAvailableHere():`
## with no `else`, so on a host where the seam could not open a libcrypto they
## executed ZERO assertions and still printed `[OK]`; the case named "a
## signature from Node's WebCrypto verifies through libcrypto" asserted the
## ABSENCE of that capability and reported the name of the presence. Six green
## cases, nothing verified, exit 0 — proven by planting `check false` inside
## one of those dead branches, which did not redden the run. (It was recorded
## as an issue in `codetracer-specs`, dated 2026-10-27; that issue is now
## resolved and lives only in that repo's git history.)
##
## So availability is now a COMPILE-TIME EXPECTATION (`Rs256ExpectedHere`) that
## the first case asserts against the runtime answer. A backend where the seam
## is supposed to work and does not is RED, with the remedy in the failure
## message. And every case asserts in BOTH arms, with the same number of
## counted assertions either way, so:
##
##   * no branch can go dead and stay green;
##   * `CHECKS: <n>` is backend-independent, which is what PLAT-17's parity
##     gate (`ci/test/vm-unit-wasm-parity.sh`) compares between the C lane and
##     the wasm32 lane;
##   * `CHECKS: 0` is classified as a failure by
##     `ci/lib/test-lane-report.sh`'s `classify_test_run`, so a future
##     regression to zero assertions reddens the LANE and not only this file.
##
## ## Where the native libcrypto comes from, which is a lane fact
##
## Measured at codetracer `0bb1547334` on x86_64-linux: run as a bare binary
## the seam is UNAVAILABLE (there is no global `ld.so` cache on NixOS and a
## bare soname resolves to nothing), and run the way the lane runs it the seam
## is AVAILABLE. `ci/lib/run-nim-test-lane.sh` puts `CT_LD_LIBRARY_PATH` on
## `LD_LIBRARY_PATH` for the RUN of every native lane — the dev shell's
## sqlite/pcre/glib/**openssl**/zstd set, exported by `nix/shells/ci-base.nix`
## — and `ci/test/vm-unit-wasm-parity.sh`'s native arm does the same. So the
## native seam is exercised for real by `just test-vm-unit`, and the honest way
## to run this file by hand is:
##
##     LD_LIBRARY_PATH="$CT_LD_LIBRARY_PATH:$LD_LIBRARY_PATH" ./the-binary
##
## A native host that still cannot open one needs `-d:nimEverywhereCryptoLib=
## <path>`, which `nim_everywhere/rs256` accepts as a compile-time define
## precisely so the choice is not a runtime knob. On macOS `dyld` ignores
## `LD_LIBRARY_PATH` entirely, so that define (or `DYLD_LIBRARY_PATH`) is the
## route there; no darwin host was available to measure it, and the failure
## this file now produces names the remedy rather than passing vacuously.
##
## The one backend where the native seam CANNOT be present is wasm32 under
## emscripten (`vm-unit-wasm`, the only lane CI runs AS a lane — it also runs
## this file's NATIVE arm, with openssl, through
## `ci/test/vm-unit-wasm-parity.sh`'s own `measure_file`): a wasm32
## module links no host shared object, and the lane sets no `LD_LIBRARY_PATH`
## for that reason. There `Rs256ExpectedHere` is `false`, the cases assert the
## three-state refusal instead — which is real coverage of the mis-mapping the
## header above calls the interesting mistake — and the suite says out loud
## that the libcrypto half did not run here.

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

# WHETHER THE SEAM MUST BE ABLE TO VERIFY ON THIS BACKEND, decided at compile
# time so that a host which cannot is a FAILURE rather than a
# differently-shaped pass. See the header.
const Rs256ExpectedHere* =
  when defined(js):
    # `crypto.subtle` is in the platform; there is nothing to load.
    true
  elif defined(emscripten) or defined(wasm32):
    # A wasm32 linear-memory module has no host shared object to `dlopen`, and
    # `ci/lib/run-nim-test-lane.sh`'s wasm branch sets no `LD_LIBRARY_PATH` for
    # exactly that reason. False is the correct answer here, not a concession.
    false
  else:
    # A native host, running under a lane that puts the dev shell's openssl on
    # `LD_LIBRARY_PATH` for the run. Measured available at codetracer
    # `0bb1547334` on x86_64-linux through that path.
    true

# ---------------------------------------------------------------------------
# Counted assertions — the fingerprint `test_identity_session.nim`,
# `test_identity_token.nim` and `test_device_grant.nim` already carry, and
# whose absence here is what let two cases stop asserting unnoticed.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

# Asserted by the last case, and printed as `CHECKS: <n>` so the lane reads the
# RUNTIME count rather than this literal. Deliberately the SAME on the C and
# wasm32 backends — every case below asserts the same number of times in both
# arms — because PLAT-17's parity gate compares the two.
const ExpectedAssertions = when defined(js): 1 else: 11

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
    # THE POSITIVE CONTROL'S GATE. Said out loud *and* asserted against the
    # compile-time expectation: what is correct here differs by backend, but it
    # is decided by this file rather than by whatever the dynamic loader
    # happened to find.
    echo "    RS256 available on this backend: ", rs256IsAvailableHere()
    echo "    RS256 expected on this backend:  ", Rs256ExpectedHere
    when not Rs256ExpectedHere:
      echo "    NOTE: the libcrypto half did NOT run on this backend; the " &
           "cases below assert the three-state REFUSAL, not a verification."
    checkpoint("if this failed with `expected true`: the run has no libcrypto " &
               "it can open. Run it the way the lane does — " &
               "LD_LIBRARY_PATH=\"$CT_LD_LIBRARY_PATH:$LD_LIBRARY_PATH\" — or " &
               "compile with -d:nimEverywhereCryptoLib=<path to libcrypto>. " &
               "See this file's header.")
    counted rs256IsAvailableHere() == Rs256ExpectedHere

when not defined(js):
  suite "the native seam verifies a real signature":
    ## Only native. The browser half needs a promise pumped, which no unit
    ## harness here can do — see `awaitOutcome`.
    ##
    ## EVERY CASE ASSERTS IN BOTH ARMS, with the same count either way. The
    ## unavailable arm is not a skip: it asserts that the seam reports
    ## `pkNotSupported` rather than `succeeded(false)`, which is the
    ## mis-mapping this suite's header names as the interesting mistake.

    test "a signature from Node's WebCrypto verifies through libcrypto":
      # THE POSITIVE CONTROL, and it is what makes every refusal below mean
      # something: without it they are all satisfied by a seam that answers
      # `unsupported` to everything. The case above is what refuses to let
      # this one silently take the other arm.
      let v = awaitOutcome(newWebCryptoVerifier(keys())(
        KatKid, bytesOf(KatSigningInput), bytesOf(decodeB64Url(KatSignature))))
      if rs256IsAvailableHere():
        counted v.isOk
        counted v.value
      else:
        # A host that cannot verify must say so through the seam, and must NOT
        # answer `false`.
        counted v.isErr
        counted v.error.kind == pkNotSupported

    test "a one-bit-flipped signature is rejected, not errored":
      # The distinction the three-state seam exists for, in the direction that
      # is easy to get backwards: a bad signature is `succeeded(false)`, never
      # an error, or a forged token would read as a broken host.
      var sig = decodeB64Url(KatSignature)
      sig[0] = char(uint8(sig[0]) xor 1'u8)
      let v = awaitOutcome(newWebCryptoVerifier(keys())(
        KatKid, bytesOf(KatSigningInput), bytesOf(sig)))
      if rs256IsAvailableHere():
        counted v.isOk
        counted not v.value
      else:
        counted v.isErr
        counted v.error.kind == pkNotSupported

    test "a one-bit-flipped signing input is rejected":
      var input = KatSigningInput
      input[10] = char(uint8(input[10]) xor 1'u8)
      let v = awaitOutcome(newWebCryptoVerifier(keys())(
        KatKid, bytesOf(input), bytesOf(decodeB64Url(KatSignature))))
      if rs256IsAvailableHere():
        counted v.isOk
        counted not v.value
      else:
        counted v.isErr
        counted v.error.kind == pkNotSupported

    test "a kid the issuer does not publish is refused without reaching libcrypto":
      let v = awaitOutcome(newWebCryptoVerifier(keys())(
        "not-published", bytesOf(KatSigningInput),
        bytesOf(decodeB64Url(KatSignature))))
      counted v.isOk
      counted not v.value

    test "an empty key set refuses rather than erroring":
      # A client whose JWKS fetch produced nothing must refuse tokens, not
      # report itself broken — the host is fine, the key set is not.
      let v = awaitOutcome(newWebCryptoVerifier(@[])(
        KatKid, bytesOf(KatSigningInput),
        bytesOf(decodeB64Url(KatSignature))))
      counted v.isOk
      counted not v.value

suite "the RS256 seam's assertion fingerprint":

  test "assertion count":
    ## The fingerprint, and the reason this file cannot go vacuous again. A
    ## count that moves without a matching change to the cases above means a
    ## case stopped asserting — the silent skip a pass/fail tally cannot show.
    ##
    ## `CHECKS: <n>` is printed unconditionally and FIRST, so the lane reads
    ## the real runtime number even on a run where the comparison below fails.
    ## `ci/lib/run-nim-test-lane.sh` and `ci/test/vm-unit-wasm-parity.sh` both
    ## prefer it over the static `ExpectedAssertions` literal, and
    ## `classify_test_run` treats `CHECKS: 0` as a failure.
    echo "CHECKS: ", countedAssertions
    checkpoint("counted " & $countedAssertions & ", declared " &
               $ExpectedAssertions)
    check countedAssertions == ExpectedAssertions
