## Node probe for ID1's WebCrypto verifier — the browser end of the signature
## seam, actually executed.
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
## Node's `globalThis.crypto.subtle` implements Ed25519 with the same API a
## browser exposes, so this runs the code the tab runs.
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

import std/[asyncjs, base64, strutils]

import ../../src/frontend/viewmodel/platform/outcome
import ../../src/frontend/viewmodel/identity/webcrypto_verifier

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

# ---------------------------------------------------------------------------
# The ISSUER, in JavaScript, and deliberately not sharing a line of code with
# the verifier under test. It generates a real Ed25519 key pair, signs real
# bytes, and hands back base64. A verifier that agreed with a signer built from
# the same helper would be a tautology; this agrees with WebCrypto itself.
# ---------------------------------------------------------------------------
proc jsGenerateAndSign(message: seq[byte]): Future[cstring] {.importjs: """
(async function (msg) {
  const b64 = function (u8) {
    let s = "";
    for (const b of u8) s += String.fromCharCode(b);
    return btoa(s);
  };
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true,
                                               ["sign", "verify"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" },
                                                      pair.privateKey,
                                                      Uint8Array.from(msg)));
  return b64(raw) + ":" + b64(sig);
})(#)
""".}

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc main() {.async.} =
  # A message shaped like a real signed region: magic + length + payload.
  let message = bytesOf("CTI\x01" & "\x20\x00\x00\x00" &
                        "{\"sub\":\"acct_probe\",\"key_id\":\"probe\"}")

  let combined = $(await jsGenerateAndSign(message))
  let parts = combined.split(':')
  report("the issuer produced a public key and a signature", parts.len == 2)
  if parts.len != 2:
    echo "PROBE-DONE checks=", checks, " failures=", failures
    jsExit(1)
    return

  let publicKeyB64 = parts[0]
  let signature = bytesOf(decode(parts[1]))

  # WebCrypto's own shapes, asserted rather than assumed: 32-byte raw Ed25519
  # public key, 64-byte signature. `token.SignatureLen` is 64 for this reason,
  # and if a host ever disagreed the container layout would be wrong.
  report("the exported public key is 32 raw bytes",
         decode(publicKeyB64).len == 32)
  report("the signature is 64 bytes, matching the container's reserved field",
         signature.len == 64)

  let keys = @[PinnedKeyMaterial(keyId: "probe", publicKeyBase64: publicKeyB64)]
  let verify = newWebCryptoVerifier(keys)

  # THE POSITIVE CONTROL. Without it, every rejection below is satisfied by a
  # verifier that refuses everything, including a correct signature.
  let good = await verify("probe", message, signature)
  report("a genuine Ed25519 signature verifies", good.isOk and good.value)

  # One flipped bit in the signature.
  var tamperedSig = signature
  tamperedSig[0] = byte((uint32(tamperedSig[0]) xor 1'u32) and 0xFF'u32)
  let badSig = await verify("probe", message, tamperedSig)
  report("a one-bit-flipped signature does not verify",
         badSig.isOk and not badSig.value)

  # One flipped bit in the message — the half that catches a verifier checking
  # the signature against the wrong bytes.
  var tamperedMsg = message
  tamperedMsg[10] = byte((uint32(tamperedMsg[10]) xor 1'u32) and 0xFF'u32)
  let badMsg = await verify("probe", tamperedMsg, signature)
  report("a one-bit-flipped message does not verify",
         badMsg.isOk and not badMsg.value)

  # A key id this build does not pin: refused, and refused WITHOUT reaching
  # WebCrypto — `materialFor` answers it locally.
  let unknown = await verify("not-pinned", message, signature)
  report("an unpinned key id is refused", unknown.isOk and not unknown.value)
  report("materialFor answers an unpinned id with the empty string",
         materialFor(keys, "not-pinned").len == 0)
  report("materialFor answers a pinned id with its material",
         materialFor(keys, "probe") == publicKeyB64)

  # Unusable key material must be an ERROR, not a rejection. Reporting "your
  # token is invalid" for "this build's key is corrupt" sends the user to the
  # wrong place entirely.
  #
  # THERE ARE TWO WAYS THIS FAILS AND THEY TAKE DIFFERENT CODE PATHS, which is
  # why both are exercised. Un-decodable text throws SYNCHRONOUSLY out of
  # `atob`, caught by the binding's outer `try`. Well-formed base64 that is not
  # a valid Ed25519 point makes `importKey` reject ASYNCHRONOUSLY, caught by
  # its `.catch`. A probe that covered only the first left the second's arm
  # with nothing to kill — which is exactly what happened when this file was
  # first written, and is why the two are now separate checks.
  let notBase64 = @[PinnedKeyMaterial(keyId: "probe",
                                      publicKeyBase64: "!!!not-base64!!!")]
  let brokenSync = await newWebCryptoVerifier(notBase64)("probe", message, signature)
  report("key material that is not base64 is an error, not a bad-signature verdict",
         brokenSync.isErr)
  report("...and it names the reason as unsupported rather than invalid",
         brokenSync.isErr and brokenSync.error.kind == pkNotSupported)

  # Valid base64, but five bytes rather than an Ed25519 point: importKey
  # rejects, asynchronously.
  let wrongLength = @[PinnedKeyMaterial(keyId: "probe",
                                        publicKeyBase64: encode("hello"))]
  let brokenAsync = await newWebCryptoVerifier(wrongLength)("probe", message, signature)
  report("key material of the wrong length is an error, not a bad-signature verdict",
         brokenAsync.isErr)
  report("...and it too is unsupported rather than invalid",
         brokenAsync.isErr and brokenAsync.error.kind == pkNotSupported)

  report("this backend reports WebCrypto as available", webCryptoIsAvailable())

  echo "PROBE-DONE checks=", checks, " failures=", failures
  if failures > 0:
    jsExit(1)

discard main()
