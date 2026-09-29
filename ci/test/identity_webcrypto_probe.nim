## Node probe for the identity RS256 verifier — the browser end of the
## signature seam, actually executed.
##
## ## Why this is a probe and not a `vm-unit-js` suite
##
## Every async suite under `viewmodel/tests/unit` awaits with
## `onComplete` + `drainPlatformCallbacks` + `doAssert settled`, and that shape
## works because their fakes return `resolvedOk(...)` — already-settled futures
## that `newCompletedFuture` stamps `__syncResolved` so the callback runs
## inline. `outcome.nim`'s own comment says the rest: **`drainPlatformCallbacks`
## drains nim-everywhere's queue, not V8's.**
##
## `crypto.subtle.verify` returns a REAL V8 microtask. Nothing in that harness
## can pump it, so a suite written that way would hit `doAssert settled` — or,
## worse, would have been written to poll and reported a default-constructed
## value as a result. So the WebCrypto path is exercised here instead, under
## Node, the way `ci/test/noir-wasm-worker-e2e.sh` drives `worker.mjs`.
##
## Node's `globalThis.crypto.subtle` implements RSASSA-PKCS1-v1_5 with the same
## API a browser exposes, so this runs the code the tab runs.
##
## ## What it exercises is the whole stack, not one call
##
## The issuer half below generates a real 2048-bit RSA key pair and signs a
## real JWT signing input. Everything after that is the shipped path:
## `jwt.parseJwks` reads the published key, `jwt.parseJwt` splits the token and
## refuses an algorithm the issuer did not advertise, `jwt.selectKey` picks the
## key by `kid`, `webcrypto_verifier` checks the signature, and
## `jwt.checkClaims` binds the result to this issuer and this audience. A probe
## that called only the verifier would leave the four seams between them
## untested, and they are where a token gets accepted for the wrong reason.
##
## Compile and run:
##   nim js -d:nodejs -o:probe.js ci/test/identity_webcrypto_probe.nim
##   node probe.js
##
## Output contract, which `ci/test/identity-webcrypto.sh` asserts:
##   one `[ok] <name>` or `[FAIL] <name>` line per check, then
##   `PROBE-DONE checks=<n> failures=<m>`
## and a non-zero exit when `m > 0`. The summary line is asserted for its
## COUNT, not merely its presence — a probe that silently ran fewer checks is
## trap 4b's silent skip, and the count is the only thing that shows it.

import std/[asyncjs, base64, json, strutils]

import ../../src/frontend/viewmodel/platform/outcome
import ../../src/frontend/viewmodel/identity/issuer
import ../../src/frontend/viewmodel/identity/jwt
import ../../src/frontend/viewmodel/identity/webcrypto_verifier

const ProbeAudience = "codetracer-probe"
const ProbeKid = "probe-1"

var checks = 0
var failures = 0

proc report(name: string; ok: bool) =
  inc checks
  if ok:
    echo "[ok] ", name
  else:
    inc failures
    echo "[FAIL] ", name

proc jsExit(code: int) {.importjs: "process.exit(#)".}
proc jsNowUnix(): int {.importjs: "Math.floor(Date.now() / 1000)".}

# ---------------------------------------------------------------------------
# The ISSUER, in JavaScript, and deliberately not sharing a line of code with
# the verifier under test. It generates a real RSA key pair, exports the public
# half as a real JWK, signs real bytes, and hands both back. A verifier that
# agreed with a signer built from the same helper would be a tautology; this
# agrees with WebCrypto itself.
# ---------------------------------------------------------------------------
proc jsGenerateAndSign(signingInput: cstring): Future[cstring] {.importjs: """
(async function (input) {
  const b64 = function (u8) {
    let s = "";
    for (const b of u8) { s += String.fromCharCode(b); }
    return btoa(s);
  };
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const bytes = new TextEncoder().encode(input);
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" }, pair.privateKey, bytes));
  return JSON.stringify({ jwk: jwk, sig: b64(sig) });
})(#)
""".}

# The hazard `webcrypto_verifier`'s two-string seam exists for, demonstrated
# against WebCrypto itself rather than asserted in a comment: a JWK forwarded
# as published, carrying a `key_ops` that does not include "verify", is
# REFUSED by `importKey`. Returns 1 when the import succeeds, -1 when it does
# not.
proc jsImportRawJwk(jwkText: cstring): Future[int] {.importjs: """
(function (text) {
  try {
    return crypto.subtle
      .importKey("jwk", JSON.parse(text),
                 { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
                 false, ["verify"])
      .then(function () { return 1; })
      .catch(function () { return -1; });
  } catch (e) {
    return Promise.resolve(-1);
  }
})(#)
""".}

# A host whose `crypto.subtle` exists but has no `importKey` — the SYNCHRONOUS
# failure path through the binding's outer `try`, which the asynchronous
# `.catch` cannot reach. Removed and put back, so the checks after it still
# mean something; that restoration is itself asserted.
proc jsRemoveImportKey() {.importjs:
  "(globalThis.__savedImportKey = crypto.subtle.importKey, crypto.subtle.importKey = undefined)".}
proc jsRestoreImportKey() {.importjs:
  "(crypto.subtle.importKey = globalThis.__savedImportKey)".}

# And the ASYNCHRONOUS one, which on Node is not reachable through key material
# at all — see the measurement below — so it is reached where it really lives:
# a host whose `verify` rejects. That is the path the binding's `.catch` exists
# for, and without this it would be a guard no arm could kill.
proc jsBreakVerify() {.importjs: """
(globalThis.__savedVerify = crypto.subtle.verify,
 crypto.subtle.verify = function () { return Promise.reject(new Error("probe")); })
""".}
proc jsRestoreVerify() {.importjs:
  "(crypto.subtle.verify = globalThis.__savedVerify)".}

proc b64Url(s: string): string =
  encode(s).replace("+", "-").replace("/", "_").replace("=", "")

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc main() {.async.} =
  let now = jsNowUnix()

  # A real compact JWS: the header names RS256 and a key id, the payload names
  # this issuer and this audience, and the signing input is the two of them
  # joined — exactly the bytes the signature will cover.
  let headerJson = """{"alg":"RS256","kid":"""" & ProbeKid & """","typ":"JWT"}"""
  let payloadJson = $( %*{
    "iss": DefaultIssuer, "aud": ProbeAudience, "sub": "acct_probe",
    "iat": now, "exp": now + 3600})
  let signingInput = b64Url(headerJson) & "." & b64Url(payloadJson)

  let produced = $(await jsGenerateAndSign(signingInput.cstring))
  var issued: JsonNode
  try:
    issued = parseJson(produced)
  except CatchableError:
    issued = newJObject()
  report("the issuer produced a JWK and a signature",
         issued.hasKey("jwk") and issued{"sig"}.getStr().len > 0)
  if not issued.hasKey("jwk") or issued{"sig"}.getStr().len == 0:
    echo "PROBE-DONE checks=", checks, " failures=", failures
    jsExit(1)
    return

  var exported = issued["jwk"]
  let signature = bytesOf(decode(issued{"sig"}.getStr()))

  # WebCrypto's own shapes, asserted rather than assumed.
  report("the exported JWK is an RSA signing key with the RS256 algorithm",
         exported{"kty"}.getStr() == "RSA" and
         exported{"alg"}.getStr() == "RS256" and
         exported{"e"}.getStr() == "AQAB")
  report("the signature is 256 bytes, the modulus size at 2048 bits",
         signature.len == 256)

  # The issuer publishes it the way an issuer does: a JWKS, read by the shipped
  # parser. The exported key carries no `kid` — WebCrypto does not invent one —
  # so the issuer assigns it here, as a real one does.
  exported["kid"] = %ProbeKid
  let jwksDoc = $( %*{"keys": [exported]})
  let keys = parseJwks(jwksDoc)
  report("the issuer's JWKS parses to exactly one usable key",
         keys.len == 1 and keys[0].kid == ProbeKid)

  let verify = newWebCryptoVerifier(keys)
  let message = bytesOf(signingInput)

  # THE POSITIVE CONTROL. Without it, every rejection below is satisfied by a
  # verifier that refuses everything, including a correct signature.
  let good = await verify(ProbeKid, message, signature)
  report("a genuine RS256 signature verifies", good.isOk and good.value)

  # One flipped bit in the signature.
  var tamperedSig = signature
  tamperedSig[0] = byte((uint32(tamperedSig[0]) xor 1'u32) and 0xFF'u32)
  let badSig = await verify(ProbeKid, message, tamperedSig)
  report("a one-bit-flipped signature does not verify",
         badSig.isOk and not badSig.value)

  # One flipped bit in the signing input — the half that catches a verifier
  # checking the signature against the wrong bytes.
  var tamperedMsg = message
  tamperedMsg[10] = byte((uint32(tamperedMsg[10]) xor 1'u32) and 0xFF'u32)
  let badMsg = await verify(ProbeKid, tamperedMsg, signature)
  report("a one-bit-flipped signing input does not verify",
         badMsg.isOk and not badMsg.value)

  # A key id the issuer does not publish: refused, and refused WITHOUT reaching
  # WebCrypto — `materialFor` answers it locally.
  let unknown = await verify("not-published", message, signature)
  report("a key id the issuer does not publish is refused",
         unknown.isOk and not unknown.value)
  report("materialFor answers an unpublished id with no key",
         materialFor(keys, "not-published").kid.len == 0)
  report("materialFor answers a published id with that key",
         materialFor(keys, ProbeKid).n == keys[0].n)

  # UNUSABLE KEY MATERIAL DOES NOT SURFACE AS AN ERROR HERE, AND THAT IS
  # MEASURED RATHER THAN ASSUMED.
  #
  # The natural expectation — the one this probe asserted first, and was wrong
  # about — is that a modulus which cannot be read makes `importKey` reject, so
  # "the issuer published a broken key" arrives as `pkNotSupported` rather than
  # as "your token is invalid". On Node 24 it does not. `importKey("jwk", …)`
  # accepts `n: "!!!not-base64url!!!"`, accepts `n: "AQAB"`, and accepts an
  # EMPTY modulus, all without complaint; the resulting key then fails to
  # verify, so a broken key is indistinguishable from a forged token at this
  # seam.
  #
  # Two things follow, and both are checked rather than written down.
  #
  # It must fail CLOSED. A verifier holding a key it cannot really use must say
  # "not verified", never "verified" — that is the only part of this the seam
  # itself can guarantee.
  #
  # And the guard has to live UPSTREAM, where the key is still a JWKS entry
  # rather than an opaque handle. `jwt.selectKey` refuses a published key whose
  # modulus or exponent is empty, and this is the measurement that makes that
  # refusal load-bearing rather than tidy: without it, nothing downstream would
  # ever report the key as the problem.
  let emptyModulus = $( %*{"kty": "RSA", "n": "", "e": "AQAB", "alg": "RS256"})
  let importedAnyway = await jsImportRawJwk(emptyModulus.cstring)
  report("WebCrypto imports a key with an empty modulus without complaining",
         importedAnyway == 1)

  var unreadable = keys
  unreadable[0].n = "!!!not-base64url!!!"
  let brokenKey = await newWebCryptoVerifier(unreadable)(
    ProbeKid, message, signature)
  report("...so a modulus that cannot be read fails closed rather than erroring",
         brokenKey.isOk and not brokenKey.value)

  var guarded = true
  var noModulus = keys
  noModulus[0].n = ""
  try:
    discard selectKey(noModulus, ProbeKid, "RS256")
    guarded = false
  except JwtError:
    discard
  report("...and selectKey refuses a published key with no modulus, which is where the guard belongs",
         guarded)

  # The one failure that DOES cross as an error, and it is the synchronous
  # path: a `crypto.subtle` with no `importKey` on it throws where the promise
  # is constructed, before there is a promise to reject, and the binding's
  # outer `try` turns that into `pkNotSupported`. This is what keeps the
  # tri-state from being a two-state with a dead third arm.
  jsRemoveImportKey()
  let brokenSync = await verify(ProbeKid, message, signature)
  jsRestoreImportKey()
  report("a WebCrypto without importKey is an error, not a bad-signature verdict",
         brokenSync.isErr)
  report("...and it too is unsupported rather than invalid",
         brokenSync.isErr and brokenSync.error.kind == pkNotSupported)

  jsBreakVerify()
  let verifyRejected = await verify(ProbeKid, message, signature)
  jsRestoreVerify()
  report("a WebCrypto whose verify rejects is an error, not a bad-signature verdict",
         verifyRejected.isErr)
  report("...and that rejection is unsupported rather than invalid",
         verifyRejected.isErr and verifyRejected.error.kind == pkNotSupported)

  # The hazard the two-string seam exists for, shown against WebCrypto rather
  # than claimed. `key_ops` is an ordinary member — Node's own exporter emits
  # one — and forwarding the entry as published makes `importKey` refuse a key
  # the issuer meant us to use.
  var withKeyOps = exported.copy()
  withKeyOps["key_ops"] = %[%"encrypt"]
  let rawImport = await jsImportRawJwk(($withKeyOps).cstring)
  report("WebCrypto itself refuses a JWK whose key_ops omits verify",
         rawImport != 1)
  let rebuiltKeys = parseJwks($( %*{"keys": [withKeyOps]}))
  let rebuilt = await newWebCryptoVerifier(rebuiltKeys)(
    ProbeKid, message, signature)
  report("...and the same key verifies through this module, which carries no key_ops",
         rebuilt.isOk and rebuilt.value)

  # End to end, through the seams a caller actually crosses.
  var endToEnd = false
  var claimsBind = false
  try:
    let compact = signingInput & "." & b64Url(decode(issued{"sig"}.getStr()))
    let parts = parseJwt(compact, VerifiableAlgs)
    let selected = selectKey(keys, parts.kid, parts.alg)
    let verdict = await newWebCryptoVerifier(@[selected])(
      parts.kid, bytesOf(parts.signingInput), parts.signature)
    endToEnd = verdict.isOk and verdict.value
    checkClaims(parts.claims, DefaultIssuer, ProbeAudience, int64(now))
    claimsBind = true
  except CatchableError:
    discard
  report("the compact token parses, selects its key, and verifies end to end",
         endToEnd)
  report("the token's claims bind to this issuer and this audience", claimsBind)

  report("this backend reports WebCrypto as available", webCryptoIsAvailable())

  echo "PROBE-DONE checks=", checks, " failures=", failures
  if failures > 0:
    jsExit(1)

discard main()
