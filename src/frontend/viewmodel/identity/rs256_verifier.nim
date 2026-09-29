## The identity signature seam — RS256, on whichever backend this is.
##
## It was called `webcrypto_verifier.nim` and answered `unsupported` on
## anything that was not a browser. It now has both halves, so the name would
## have been a lie in the direction that matters: a reader checking whether the
## desktop verifies signatures would have found a file named after the browser.
##
## `session.IdentityTransport.verifySignature` is asynchronous precisely so
## that this file can exist: `crypto.subtle.verify` returns a promise and there
## is no synchronous WebCrypto, so the browser could never have implemented a
## synchronous verification seam.
##
## ## Where the key comes from, and why that changed
##
## This file used to verify **Ed25519 against a key baked into the build**,
## because identity was built by copying licensing's mechanism. Licensing has
## to verify on an air-gapped machine, so a baked key is the only thing it can
## use. Identity does not: a user signing in is online by construction, and the
## shared issuer publishes its keys and rotates them.
##
## So the key now arrives as a **JWK from the issuer's `jwks_uri`**, and trust
## comes from two things that are checked rather than assumed — TLS to the
## issuer's host, and `issuer.parseDiscovery` refusing a discovery document
## that does not name the issuer it was fetched for (RFC 8414 §3.3), which is
## what stops a substituted document from choosing the `jwks_uri`. A baked key
## would have made rotation a release, which for an issuer that rotates on its
## own schedule means an outage on the issuer's timetable rather than ours.
##
## ## This is exercised, not merely written
##
## The obvious way to ship a browser crypto binding is to write it, assert it
## appears in the bundle, and hope. That is the shape this campaign keeps
## calling a vacuous pass. It is avoidable here because **Node's
## `globalThis.crypto.subtle` implements RSASSA-PKCS1-v1_5 with the same API a
## browser exposes**, so this code can be run for real rather than inspected.
##
## It is *not* a `vm-unit-js` suite that does this: `crypto.subtle.verify`
## resolves on V8's microtask queue, which `drainPlatformCallbacks` does not
## drain. The gate is `ci/test/identity-webcrypto.sh`, which compiles
## `ci/test/identity_webcrypto_probe.nim` against this module and runs it under
## Node. The probe generates a real 2048-bit RSA key pair, exports its public
## half as a real JWK, signs a real JWT signing input, and verifies it through
## this exact code — a good signature verifies, a one-bit-flipped signature and
## a one-bit-flipped message do not, and unusable key material comes back as an
## error rather than a bad-signature verdict.
##
## ## Three states, not two
##
## `crypto.subtle` can *reject* — bad key material, an algorithm the host does
## not implement — and that is a different fact from "this signature is not
## valid". Collapsing them would report a forged token when the real problem is
## a misconfigured build, and would make a host that cannot do RSA look like a
## user presenting bad tokens.
##
## The boundary is crossed as a NUMBER rather than an exception, deliberately.
## Verification-Harness-Traps.md 3 is about a boundary that speaks two shapes;
## a rejected promise marshalled into Nim is exactly that hazard, and on the JS
## backend a DOMException matches no Nim exception type at all — the same class
## CONTRIBUTING.md records for `parseJson`. So the JS side catches its own
## rejection and returns `-1`, and nothing throws across the seam.

import nim_everywhere/rs256
import ../platform/outcome
import ./jwt

export rs256.Rs256Verdict

func bytesToString(b: seq[byte]): string =
  ## The shared verifier takes the signing input and the signature as raw
  ## bytes-in-a-string, which is what libcrypto wants; this seam speaks
  ## `seq[byte]`, which is what WebCrypto wants. One conversion, here, rather
  ## than two representations threaded through the module.
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)

export jwt.JwkKey

const
  VerifyValid* = 1
  VerifyRejected* = 0
  VerifyUnavailable* = -1

  WebCryptoAlgorithm* = "RSASSA-PKCS1-v1_5"
    ## RS256's WebCrypto spelling. RSASSA-PSS is a *different* algorithm with
    ## the same key type, so importing a key under one and verifying under the
    ## other fails rather than silently succeeding — which is why the name is
    ## stated once here and used for both calls.

func materialFor*(keys: openArray[JwkKey]; keyId: string): JwkKey =
  ## The key published under that id, or one whose `kid` is empty when the
  ## issuer publishes none. Separate from verification so that "we do not know
  ## this key" stays distinguishable from "this signature is wrong" — the
  ## distinction `jwt.selectKey` draws by raising, preserved down here for the
  ## seam, which has no way to raise.
  for k in keys:
    if k.kid == keyId and k.kid.len > 0:
      return k
  JwkKey()

when defined(js):
  import std/asyncjs

  proc jsVerifyRs256(modulusB64Url: cstring; exponentB64Url: cstring;
                     message: seq[byte];
                     signature: seq[byte]): Future[int] {.importjs: """
(function (n, e, msg, sig) {
  try {
    var subtle = (globalThis.crypto && globalThis.crypto.subtle) || null;
    if (!subtle) { return Promise.resolve(-1); }
    var jwk = { kty: "RSA", n: n, e: e, alg: "RS256" };
    var alg = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
    return subtle
      .importKey("jwk", jwk, alg, false, ["verify"])
      .then(function (key) {
        return subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, key,
                             Uint8Array.from(sig), Uint8Array.from(msg));
      })
      .then(function (valid) { return valid ? 1 : 0; })
      .catch(function () { return -1; });
  } catch (err) {
    return Promise.resolve(-1);
  }
})(#, #, #, #)
""".}
    ## THE KEY IS REBUILT FROM TWO STRINGS, NOT FORWARDED.
    ##
    ## The obvious binding hands `importKey` the JWKS entry as the issuer
    ## published it. That fails on members which disagree with the import — a
    ## `key_ops` omitting `"verify"`, an `ext: false` against an extractable
    ## import, an `alg` naming something else — and WebCrypto's refusal is a
    ## rejected promise, so a published key the issuer meant us to use would
    ## surface as "this host cannot verify". These are ordinary JWK members,
    ## not hypothetical: Node's own `exportKey("jwk", …)` emits `key_ops` and
    ## `ext`, and the probe asserts that a raw entry carrying them really is
    ## refused.
    ##
    ## Filtering them out would work and would have to be kept correct as JWK
    ## grows members. Passing only the modulus and the exponent means there is
    ## nothing to filter: no member the issuer publishes can reach `importKey`,
    ## because the object is built here out of two strings.
    ##
    ## `alg` is fixed for the same reason `jwt.parseJwt` takes its algorithm
    ## from the issuer rather than the token: this verifier does RS256, so the
    ## algorithm is not the key's to choose either.
    ##
    ## Returns 1 / 0 / -1 rather than a boolean or a rejection. See the header:
    ## a rejected promise is a shape this side of the boundary cannot name. The
    ## `.catch` covers the asynchronous refusal (a modulus that will not decode,
    ## a key too small); the surrounding `try` covers the synchronous one — a
    ## host that has `crypto.subtle` but no `importKey` on it throws where the
    ## promise is constructed, before there is a promise to reject. The probe
    ## exercises both, because they are different code paths and an arm that
    ## can only kill one of them leaves the other unguarded.
    ##
    ## The key is imported on every call rather than cached. An RSA import is
    ## microseconds and admission happens once per token (`session.admit`), so
    ## a cache here would trade nothing measurable for the one bug a key cache
    ## reliably produces — a rotated-out `kid` that keeps verifying because the
    ## imported handle outlived the JWKS entry it came from.

  proc verifyThroughWebCrypto(key: JwkKey; message: seq[byte];
                              signature: seq[byte]
                             ): PlatformFutureT[PlatformOutcome[bool]] =
    var promise = newPromise(proc(resolve: proc(value: PlatformOutcome[bool])) =
      discard jsVerifyRs256(key.n.cstring, key.e.cstring, message, signature).then(
        proc(code: int) =
          if code == VerifyValid:
            resolve(succeeded(true))
          elif code == VerifyRejected:
            resolve(succeeded(false))
          else:
            resolve(failed[bool](pkNotSupported,
              "WebCrypto could not perform an RS256 verification",
              "importKey or verify rejected, or crypto.subtle is absent"))))
    promise

proc newWebCryptoVerifier*(keys: seq[JwkKey]): proc(
    keyId: string; message: seq[byte]; signature: seq[byte]
  ): PlatformFutureT[PlatformOutcome[bool]] =
  ## The `IdentityTransport.verifySignature` implementation for a browser,
  ## over the keys the issuer currently publishes.
  ##
  ## FAILS CLOSED on every path that is not an affirmative verification, which
  ## is the contract `licensing_ffi.nim` already documents for a cdylib that
  ## will not load: a verifier that cannot run must never mean "accept".
  result = proc(keyId: string; message: seq[byte]; signature: seq[byte]
               ): PlatformFutureT[PlatformOutcome[bool]] =
    let key = materialFor(keys, keyId)
    if key.kid.len == 0:
      return resolvedOk(false)
    when defined(js):
      verifyThroughWebCrypto(key, message, signature)
    else:
      # NOT A BROWSER, AND NO LONGER UNSUPPORTED. `nim_everywhere/rs256`
      # verifies the same RSASSA-PKCS1-v1_5 through libcrypto, opened at
      # runtime, and its verdict maps onto this seam one-for-one.
      #
      # It could not have been `ct_license_ffi`, which is where an earlier
      # version of this comment pointed. That crate cannot be built on Windows
      # at all — it depends transitively on `lldb-sys` through
      # `ct-native-replay`, which is why `licensing_ffi.nim` carries a
      # `CT_LICENSE_DEV_NO_FFI` escape hatch in the first place — so an
      # identity verifier behind it would have been absent on a whole platform.
      #
      # THE THREE-STATE ANSWER IS PRESERVED EXACTLY, and it is the reason the
      # shared module returns a verdict rather than a bool. `rs256Unavailable`
      # becomes `pkNotSupported`, never `false`: a host with no libcrypto must
      # say its verifier is missing, not that every valid token is forged.
      case verifyRs256(bytesToString(message), bytesToString(signature),
                       key.n, key.e)
      of rs256Valid: resolvedOk(true)
      of rs256Rejected: resolvedOk(false)
      of rs256Unavailable:
        resolvedUnsupported[bool]("RS256 verification through libcrypto")

proc rs256IsAvailableHere*(): bool =
  ## Whether this backend can verify at all. A product should ask before
  ## admitting a token so that "your token is invalid" is never shown for
  ## "this build has no verifier".
  ##
  ## On a browser this is true by construction — `crypto.subtle` is in the
  ## platform. Natively it is a MEASUREMENT: `rs256IsAvailable` tries to open
  ## libcrypto and answers what actually happened, which is the honest answer
  ## on a host that does not ship one.
  when defined(js):
    true
  else:
    rs256IsAvailable()
