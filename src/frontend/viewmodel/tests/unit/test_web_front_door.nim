## THE FRONT DOOR IS GENERATED FROM THE CONTRACT — WD4.
##
## ## The claim, and the defect it is about
##
## `ide.codetracer.com` decides per request whether to serve the static WASM
## bundle or a substrate-allocated session. The decision needs a list of which
## paths belong to the platform, and WD4 requires that list to be **generated**
## from `web_entry.classifyPath` rather than re-spelled in the edge function.
##
## `web_entry.nim` already warns why: two implementations of "which prefixes
## exist" is how a form reaches the SPA in code and 404s at the CDN. At the
## front door it is worse — a prefix missing from a hand-written list is
## answered by the STATIC page, 200, with no error anywhere, and the session the
## visitor is entitled to simply does not happen.
##
## So the assertions below are about **agreement with the contract**, not about
## a list of names. A case that checked for `"/noir"` by hand would be the
## second implementation it exists to prevent.
##
## ## What else is asserted, and why each one is a bug that was paid for
##
## Every item here was found and fixed in `isonim-web-site/functions/
## _middleware.js`, and the mirror is only worth making if it carries them:
##
## * the cookie is read BY NAME (`other_session_id=x` otherwise flips the
##   branch for a visitor who never signed in);
## * seven cache headers are DELETED, not overridden — `Cache-Control` is not
##   the only header that can admit a response to a cache;
## * `Set-Cookie` is rebuilt from `getSetCookie()`, because `new Headers(other)`
##   folds repeated names and a folded `Set-Cookie` is one a browser cannot
##   split, so a sign-in through the front door would end with no session;
## * `Vary: Cookie`;
## * an unconfigured origin FAILS CLOSED rather than calling `context.next()`,
##   which would serve the static page to a signed-in visitor and would be a
##   cacheable response produced after reading a session cookie.
##
## And one that is this product's alone: the file's own header has to name
## `$RUNNER_TEMP`, because this workflow's wrangler CWD is not isonim's and the
## wrong placement is silent.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node).

import std/[strutils, unittest]

import ../../platform/web_deployment
import ../../platform/web_entry

const ExpectedAssertions = 55
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

let contract = deploymentContract("https://ide.codetracer.com", DeploymentDescriptor())
let rendered = renderFrontDoorFunction(contract)

suite "the allow-list is the contract's, not a second list":
  test "every rewrite prefix that serves the entry document is a dynamic prefix":
    let dynamic = frontDoorDynamicPrefixes(contract)
    ck dynamic.len > 0
    for rule in contract.rewrites:
      if rule.servesEntryDocument:
        ck rule.prefix in dynamic

  test "and every one of them appears in the rendered function":
    for prefix in frontDoorDynamicPrefixes(contract):
      # Quoted, so a prefix that is a substring of another cannot satisfy this
      # by accident: `"/p"` must be there as its own entry and not only inside
      # `"/projects"`.
      ck rendered.contains("\"" & prefix & "\",")

  test "the list tracks `rewritePrefixes`, which reads `classifyPath`":
    # The chain is `classifyPath` -> `rewritePrefixes` -> `deploymentContract`
    # -> here. Asserting the ENDS agree is what makes a prefix added to the
    # classifier reach the edge without a second edit.
    let dynamic = frontDoorDynamicPrefixes(contract)
    for prefix in rewritePrefixes():
      ck prefix in dynamic
    ck dynamic.len == rewritePrefixes().len

  test "`/` is NOT in the list — it is the path that forks":
    # §3.1a: the edge forks on signed-in-ness and nothing else. `/` in the
    # dynamic list would send every anonymous visitor to the platform, which is
    # the anonymous static path this milestone must not touch.
    for prefix in frontDoorDynamicPrefixes(contract):
      ck prefix != "/"
    ck rendered.contains("url.pathname === \"/\" && session")

suite "the parts that were paid for in the other repo":
  test "the cookie is parsed by name, not by `includes`":
    ck rendered.contains("function readCookie")
    ck rendered.contains("trimmed.slice(0, eq) === name")
    # The CODE, not the cautionary comment — which names the broken form on
    # purpose and would otherwise fail this check by explaining it.
    ck not rendered.contains("header.includes(")

  test "seven cache headers are DELETED, not overridden":
    for header in ["Cache-Control", "Expires", "Pragma", "ETag",
                   "Last-Modified", "Age", "CDN-Cache-Control",
                   "Cloudflare-CDN-Cache-Control"]:
      ck rendered.contains("headers.delete(\"" & header & "\")")
    ck rendered.contains("headers.set(\"Cache-Control\", \"private, no-store\")")
    ck rendered.contains("headers.set(\"Vary\", \"Cookie\")")

  test "`Set-Cookie` is rebuilt from `getSetCookie`, not copied":
    ck rendered.contains("getSetCookie")
    ck rendered.contains("headers.append(\"Set-Cookie\"")

  test "an unconfigured origin fails CLOSED":
    ck rendered.contains("PLATFORM_ORIGIN")
    ck rendered.contains("503")
    # The refusal is produced BEFORE any `context.next()`, and the only
    # `context.next()` in the file is the last line of `onRequest`.
    let refuseAt = rendered.find("PLATFORM_ORIGIN")
    let nextAt = rendered.rfind("return context.next();")
    ck refuseAt < nextAt
    # The STATEMENT, not the comment that names it as the wrong answer: there
    # is exactly one place this file hands back to the static artifact, and it
    # is the last line of `onRequest`.
    ck rendered.count("return context.next();") == 1

suite "the refusals are surfaced rather than re-derived":
  test "all six of the substrate's refusal reasons are passed through":
    for reason in ["concurrency", "budget", "flavour_not_allowed",
                   "snapshot_expired", "not_entitled", "unknown_image"]:
      ck rendered.contains("\"" & reason & "\"")

suite "the placement this workflow needs, named in the file":
  test "the header says `$RUNNER_TEMP` and warns about the shimmed case":
    # isonim's file says "the repo root, beside dist/", and copying that
    # sentence into this product would be the silent failure: this workflow
    # `cd`s to `$RUNNER_TEMP` before invoking wrangler.
    ck rendered.contains("$RUNNER_TEMP")
    ck rendered.contains("Shimming")
    # And it says where THIS one goes, not only where isonim's does — the
    # sentence about `dist/` is there to contrast, so its presence is not the
    # thing to assert on.
    ck rendered.contains("$RUNNER_TEMP/functions/")

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
