## The browser end of ID1's signature seam — Ed25519 via WebCrypto.
##
## `session.IdentityTransport.verifySignature` is asynchronous precisely so
## that this file can exist: `crypto.subtle.verify` returns a promise and there
## is no synchronous WebCrypto, so the browser could never have implemented
## `token.SignatureVerifier`'s synchronous seam.
##
## ## This is exercised, not merely written
##
## The obvious way to ship a browser crypto binding is to write it, assert it
## appears in the bundle, and hope. That is the shape this campaign keeps
## calling a vacuous pass. It is avoidable here because **Node's
## `globalThis.crypto.subtle` implements Ed25519 with the same API a browser
## exposes**, so this code can be run for real rather than inspected.
##
## It is *not* a `vm-unit-js` suite that does this: `crypto.subtle.verify`
## resolves on V8's microtask queue, which `drainPlatformCallbacks` does not
## drain. The gate is `ci/test/identity-webcrypto.sh`, which compiles
## `ci/test/identity_webcrypto_probe.nim` against this module and runs it
## under Node. The probe generates a real Ed25519 key pair, signs a real
## container, and verifies it through this exact code — a good signature
## verifies, a one-bit-flipped signature and a one-bit-flipped message do not,
## and unusable key material comes back as an error rather than a bad-signature
## verdict. It is wired into `just test-identity`. The JS lane runs real
## Ed25519; the C lane runs the refusal below. Both are the shipped path for
## their backend.
##
## ## Three states, not two
##
## `crypto.subtle` can *reject* — bad key material, an algorithm the host does
## not implement — and that is a different fact from "this signature is not
## valid". Collapsing them would report a forged token when the real problem is
## a misconfigured build, and would make a host that cannot do Ed25519 look
## like a user presenting bad tokens.
##
## The boundary is crossed as a NUMBER rather than an exception, deliberately.
## Verification-Harness-Traps.md 3 is about a boundary that speaks two shapes;
## a rejected promise marshalled into Nim is exactly that hazard, and on the JS
## backend a DOMException matches no Nim exception type at all — the same class
## CONTRIBUTING.md records for `parseJson`. So the JS side catches its own
## rejection and returns `-1`, and nothing throws across the seam.

import ../platform/outcome
import ./session

type
  PinnedKeyMaterial* = object
    ## A public key this BUILD trusts, by id. The `keyId` must match the
    ## token's `key_id` claim; `publicKeyBase64` is the raw 32-byte Ed25519
    ## public key, base64-encoded — the same bytes `enforcement.rs` bakes in as
    ## `PRODUCTION_VERIFYING_KEY_BYTES`, carried as text so a build can pin
    ## several.
    keyId*: string
    publicKeyBase64*: string

const
  VerifyValid* = 1
  VerifyRejected* = 0
  VerifyUnavailable* = -1

func materialFor*(keys: seq[PinnedKeyMaterial]; keyId: string): string =
  ## "" when this build pins no key under that id. Separate from verification
  ## so that "we do not know this key" stays distinguishable from "this
  ## signature is wrong" — the distinction `token.nim` draws between
  ## `dkUnknownKeyId` and `dkBadSignature`, preserved down here.
  for k in keys:
    if k.keyId == keyId:
      return k.publicKeyBase64
  ""

when defined(js):
  import std/asyncjs

  proc jsVerifyEd25519(keyB64: cstring; message: seq[byte];
                       signature: seq[byte]): Future[int] {.importjs: """
(function (kb, msg, sig) {
  try {
    var raw = Uint8Array.from(atob(kb), function (c) { return c.charCodeAt(0); });
    var m = Uint8Array.from(msg);
    var s = Uint8Array.from(sig);
    var subtle = (globalThis.crypto && globalThis.crypto.subtle) || null;
    if (!subtle) { return Promise.resolve(-1); }
    return subtle
      .importKey("raw", raw, { name: "Ed25519" }, false, ["verify"])
      .then(function (key) {
        return subtle.verify({ name: "Ed25519" }, key, s, m);
      })
      .then(function (valid) { return valid ? 1 : 0; })
      .catch(function () { return -1; });
  } catch (e) {
    return Promise.resolve(-1);
  }
})(#, #, #)
""".}
    ## Returns 1 / 0 / -1 rather than a boolean or a rejection. See the header:
    ## a rejected promise is a shape this side of the boundary cannot name.

  proc verifyThroughWebCrypto(keyB64: string; message: seq[byte];
                              signature: seq[byte]
                             ): PlatformFutureT[PlatformOutcome[bool]] =
    var promise = newPromise(proc(resolve: proc(value: PlatformOutcome[bool])) =
      discard jsVerifyEd25519(keyB64.cstring, message, signature).then(
        proc(code: int) =
          if code == VerifyValid:
            resolve(succeeded(true))
          elif code == VerifyRejected:
            resolve(succeeded(false))
          else:
            resolve(failed[bool](pkNotSupported,
              "WebCrypto could not perform an Ed25519 verification",
              "importKey or verify rejected, or crypto.subtle is absent"))))
    promise

proc newWebCryptoVerifier*(keys: seq[PinnedKeyMaterial]): proc(
    keyId: string; message: seq[byte]; signature: seq[byte]
  ): PlatformFutureT[PlatformOutcome[bool]] =
  ## The `IdentityTransport.verifySignature` implementation for a browser.
  ##
  ## FAILS CLOSED on every path that is not an affirmative verification, which
  ## is the contract `licensing_ffi.nim` already documents for a cdylib that
  ## will not load: a verifier that cannot run must never mean "accept".
  result = proc(keyId: string; message: seq[byte]; signature: seq[byte]
               ): PlatformFutureT[PlatformOutcome[bool]] =
    let material = materialFor(keys, keyId)
    if material.len == 0:
      return resolvedOk(false)
    when defined(js):
      verifyThroughWebCrypto(material, message, signature)
    else:
      # Not a browser. The native end of this seam is `ct_license_ffi`, and
      # answering `false` here rather than `unsupported` would be worse than
      # useless: it would make a desktop build silently reject every valid
      # token instead of saying that its verifier is missing.
      resolvedUnsupported[bool]("Ed25519 verification through WebCrypto")

proc webCryptoIsAvailable*(): bool =
  ## Whether this backend can verify at all. A product should ask before
  ## admitting a token so that "your token is invalid" is never shown for
  ## "this build has no verifier".
  when defined(js):
    true
  else:
    false
