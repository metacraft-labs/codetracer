## A REAL DEVICE-GRANT ROUND TRIP AGAINST A REAL ISSUER, and the verification
## of what came back.
##
## This is WD3's verification and it is the only thing that can close the seam
## `metacraft-specs/infrastructure/local-development-parity.md` §4.1 names:
## CodeTracer's identity layer was written, built and unit-tested while **no
## running issuer had ever accepted a token it verified**. A compiling verifier
## closes nothing. What closes it is one process, talking to one running
## Zitadel, over the wire, and then checking the answer with the same code the
## product ships.
##
## ## What is real here
##
## All of it. There is no fake transport, no scripted response and no recorded
## fixture. `ct/identity/http_transport.nim` opens a TLS connection to the
## issuer named on the command line; `ct/identity/oidc.nim` performs RFC 8628
## §3.1's device-authorization request and §3.4's polling exchange; and the ID
## token that comes back is then put through **the product's own** checks in
## order — `jwt.parseJwt`, `jwt.parseJwks` over keys fetched from the issuer's
## `jwks_uri`, `jwt.selectKey`, `rs256_verifier.newWebCryptoVerifier` (which on
## this, the native, backend is `nim_everywhere/rs256` over libcrypto), and
## `jwt.checkClaims` against the issuer and audience passed in.
##
## The one thing this process does not do is approve the sign-in: that is a
## person at a browser, or the harness driving one. It prints the verification
## URI and the user code as a single JSON line on stdout so a harness can read
## them, and then blocks in the poll loop exactly as a user's terminal would.
##
## ## Exit status
##
## 0 only when a token was issued AND every check above passed. Any other
## outcome prints a sentence naming which step failed and exits 1. There is no
## partial success: "the issuer answered" is not the claim.

import std/[json, os, parseopt, strutils, times]
import std/asyncdispatch

import ../../src/ct/identity/http_transport
import ../../src/ct/identity/oidc
import ../../src/frontend/viewmodel/platform/outcome

type Options = object
  issuer: string
  clientId: string
  audience: string
  caFile: string
  scopes: string

proc usage() =
  echo """
identity_live_device_grant_probe --issuer=URL --client-id=ID [--audience=ID]
                                 [--ca-file=PATH] [--scopes="openid ..."]

  --audience defaults to --client-id, which is what an OIDC issuer puts in
             `aud` for the client that asked. It is a separate flag because
             `session.nim` refuses to default it, and a probe that hid the
             distinction would not be exercising the same check the product
             makes.
  --ca-file  a PEM bundle to trust INSTEAD of the system store. A local issuer
             is served by a development CA; there is deliberately no flag that
             turns verification off.
"""

proc parseOptions(): Options =
  result.scopes = DefaultScopes
  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "issuer": result.issuer = value
      of "client-id": result.clientId = value
      of "audience": result.audience = value
      of "ca-file": result.caFile = value
      of "scopes": result.scopes = value
      of "help": usage(); quit(0)
      else:
        echo "unknown option --", key; usage(); quit(2)
    of cmdArgument:
      echo "unexpected argument: ", key; usage(); quit(2)
    else: discard
  if result.issuer.len == 0 or result.clientId.len == 0:
    echo "--issuer and --client-id are both required"; usage(); quit(2)
  if result.audience.len == 0:
    result.audience = result.clientId

proc die(step, detail: string) {.noreturn.} =
  echo "FAILED at ", step, ": ", detail
  quit(1)

proc run(o: Options) {.async.} =
  let client = newOidcClient(
    newIssuerHttpTransport(o.caFile), o.issuer, o.clientId, o.scopes)

  let discoveryError = await client.discover()
  if discoveryError.len > 0:
    die("discovery", discoveryError)
  echo "OK discovery bound to ", client.config.issuer

  let started = await client.beginDeviceAuthorization(realNowUnix())
  if started.error.len > 0:
    die("device authorization", started.error)

  # ONE LINE, PARSEABLE, AND WITHOUT THE DEVICE CODE. The harness needs the
  # URI and the user code; the device code is the bearer secret and printing
  # it would hand the session to anything that reads this process's output.
  echo "DEVICE ", $(%*{
    "verification_uri": started.auth.verificationUri,
    "verification_uri_complete": started.auth.verificationUriComplete,
    "user_code": started.auth.userCode,
    "interval": started.auth.pollInterval,
    "expires_at": started.auth.expiresAt})
  echo "PROMPT ", started.auth.displayPrompt
  flushFile(stdout)

  let granted = await client.awaitDeviceGrant(
    started.auth, realNowUnix, realSleepSeconds,
    proc(auth: DeviceAuthorization; outcome: PollOutcome) =
      echo "POLL ", outcome
      flushFile(stdout))
  if granted.error.len > 0:
    die("the device grant", granted.error)
  echo "OK an id_token was issued"

  # ---- and now the product's own checks, in the product's own order ----
  let jwks = await client.fetchJwks()
  if jwks.error.len > 0:
    die("the JWKS fetch", jwks.error)
  echo "OK the issuer published ", jwks.keys.len, " key(s)"

  var parts: JwtParts
  try:
    parts = parseJwt(granted.grant.idToken, VerifiableAlgs)
  except CatchableError as err:
    die("parsing the id_token", err.msg)
  echo "OK the id_token parses, alg=", parts.alg, " kid=", parts.kid

  let key = selectKey(jwks.keys, parts.kid, parts.alg)
  if key.kid.len == 0:
    die("key selection",
      "the issuer signed with kid '" & parts.kid &
      "' and published no key with that id")
  echo "OK the signing key is one the issuer publishes"

  let verify = newWebCryptoVerifier(jwks.keys)
  var signingBytes = newSeq[byte](parts.signingInput.len)
  for i, ch in parts.signingInput:
    signingBytes[i] = byte(ch)
  let verdict = await verify(parts.kid, signingBytes, parts.signature)
  if not verdict.ok:
    die("the signature check", verdict.error.message & " — " & verdict.error.detail)
  if not verdict.value:
    die("the signature check", "the issuer's key does not verify this token")
  echo "OK the RS256 signature verifies against the issuer's published key"

  try:
    checkClaims(parts.claims, client.config.issuer, o.audience, realNowUnix())
  except CatchableError as err:
    die("the claim check", err.msg)
  echo "OK the claims check out against issuer=", client.config.issuer,
    " audience=", o.audience
  echo "SUBJECT ", parts.claims{"sub"}.getStr()
  echo "PASSED a running issuer accepted a token this code verified"

when isMainModule:
  waitFor run(parseOptions())
