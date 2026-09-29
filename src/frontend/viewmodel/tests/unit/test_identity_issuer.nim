## `issuer.parseDiscovery` — the shared identity issuer's metadata, and the
## check that binds a fetched document to the issuer it claims to describe.
##
## NO NETWORK. The fixture below is the live issuer's own document, reduced to
## the fields this module reads and measured on 2026-09-30 — so the happy path
## asserts against what `login.metacraft-labs.com` actually returns rather than
## against a shape invented here.
##
## THE ASSERTION THAT MATTERS is the issuer mismatch. A discovery document is
## configuration fetched over the network, and it names the
## `authorization_endpoint` — where the user types their password — and the
## `jwks_uri` — which key validates the result. A client that merged a
## document without checking whose it is would let whoever chose the document
## choose both. RFC 8414 §3.3 requires the check; this file is what makes it
## real rather than commented.

import std/[strutils, unittest]
import ../../identity/issuer

const LiveDocument = """
{
  "issuer": "https://login.metacraft-labs.com",
  "authorization_endpoint": "https://login.metacraft-labs.com/oauth/v2/authorize",
  "token_endpoint": "https://login.metacraft-labs.com/oauth/v2/token",
  "device_authorization_endpoint": "https://login.metacraft-labs.com/oauth/v2/device_authorization",
  "jwks_uri": "https://login.metacraft-labs.com/oauth/v2/keys",
  "id_token_signing_alg_values_supported": ["RS256"],
  "grant_types_supported": [
    "authorization_code", "refresh_token",
    "urn:ietf:params:oauth:grant-type:device_code"
  ]
}
"""

proc withoutField(doc, field: string): string =
  ## Drop one line from the fixture, so each "missing field" case is the live
  ## document minus exactly one thing rather than a separate hand-written stub
  ## that might differ in some other way too.
  result = ""
  for line in doc.splitLines():
    if ("\"" & field & "\"") notin line: result.add(line & "\n")

suite "the live issuer's document parses to the endpoints a client needs":
  test "every endpoint comes from the document, not from a constant here":
    let c = parseDiscovery(LiveDocument)
    check c.issuer == "https://login.metacraft-labs.com"
    check c.jwksUri == "https://login.metacraft-labs.com/oauth/v2/keys"
    check c.tokenEndpoint == "https://login.metacraft-labs.com/oauth/v2/token"
    check c.authorizationEndpoint ==
      "https://login.metacraft-labs.com/oauth/v2/authorize"
    check c.deviceAuthorizationEndpoint ==
      "https://login.metacraft-labs.com/oauth/v2/device_authorization"

  test "the device endpoint is present, which is what lets ID2 repoint":
    # ID2's device grant is RFC 8628 and the issuer implements it natively, so
    # the flow is redirected rather than rewritten. If this ever stopped being
    # advertised, that plan would be wrong and this is where it shows.
    check parseDiscovery(LiveDocument).deviceAuthorizationEndpoint.len > 0

  test "RS256 is what it signs with, and what the client checks for":
    check parseDiscovery(LiveDocument).signingAlgs == @["RS256"]

suite "a document is bound to the issuer it was fetched for":
  test "an issuer that does not match is REFUSED, not merged":
    # The attack this closes: substitute the document, and you have chosen
    # where the user signs in and which key validates the answer.
    let hostile = LiveDocument.replace("https://login.metacraft-labs.com\",",
                                       "https://login.evil.example\",")
    expect DiscoveryError:
      discard parseDiscovery(hostile)

  test "a trailing slash is not a mismatch":
    # `https://issuer` and `https://issuer/` are the same issuer, and refusing
    # on that difference would be a false alarm that teaches people to widen
    # the check.
    check parseDiscovery(LiveDocument,
      "https://login.metacraft-labs.com/").issuer ==
      "https://login.metacraft-labs.com"

  test "a document with no issuer at all is refused":
    expect DiscoveryError:
      discard parseDiscovery(LiveDocument.withoutField("issuer"))

suite "a document that cannot support a client is refused, not half-used":
  test "no jwks_uri means nothing could verify a token":
    expect DiscoveryError:
      discard parseDiscovery(LiveDocument.withoutField("jwks_uri"))

  test "no device_authorization_endpoint means the desktop flow cannot begin":
    expect DiscoveryError:
      discard parseDiscovery(LiveDocument.withoutField("device_authorization_endpoint"))

  test "an issuer signing only with something unverifiable is refused":
    # A token this client cannot check is not better than no token. EdDSA is
    # the pointed example: it is what the SUPERSEDED licensing-derived design
    # used, so an issuer offering only it would look familiar and still be
    # unusable here.
    let eddsaOnly = LiveDocument.replace("\"RS256\"", "\"EdDSA\"")
    expect DiscoveryError:
      discard parseDiscovery(eddsaOnly)

  test "an issuer offering RS256 among others is accepted":
    # CONTROL for the check above: it must refuse on "none we can verify",
    # not on "any we cannot".
    let mixed = LiveDocument.replace("\"RS256\"", "\"ES256\", \"RS256\"")
    check "RS256" in parseDiscovery(mixed).signingAlgs

  test "a document that is not JSON is refused with that reason":
    expect DiscoveryError:
      discard parseDiscovery("<html>a login page, not metadata</html>")

  test "a malformed document does not escape as an exception the caller cannot name":
    ## THE BACKEND IS THE POINT OF THIS CASE. On the C backend `parseJson`
    ## raises `JsonParsingError`, a `CatchableError`, and any guard catches it.
    ## On the JS backend it defers to V8's `JSON.parse`, which throws a raw
    ## `SyntaxError` that matches NO Nim exception type — so a
    ## `try/except CatchableError` catches nothing and the exception escapes
    ## into the renderer.
    ##
    ## This module shipped with the narrow guard and therefore crashed the tab
    ## on attacker-shaped input. Measured on this checkout's Nim: the same
    ## `except CatchableError` answers "caught" under `nim c` and lets the
    ## exception ESCAPE under `nim js -d:nodejs`.
    ##
    ## So the assertion is not "it refuses" — it is "it refuses with OUR
    ## exception type", which is the half that only fails on one backend, and
    ## this suite runs on both.
    for hostile in ["<html>a login page, not metadata</html>", "{not json",
                    "", "{\"issuer\": ", "[[[", "\x00\x01\x02"]:
      expect DiscoveryError:
        discard parseDiscovery(hostile)

    # THE POSITIVE CONTROL. Without it a `parseDiscovery` that raised
    # `DiscoveryError` unconditionally would satisfy every line above.
    check parseDiscovery(LiveDocument).issuer == DefaultIssuer
