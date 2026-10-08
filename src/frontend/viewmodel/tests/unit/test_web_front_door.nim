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
## * the API origin and the session platform are SEPARATE settings. The API
##   origin (`API_ORIGIN`, default `DefaultApiOrigin`) gets `/api/v1/*`,
##   `/auth/*` and share links; the session platform (`PLATFORM_ORIGIN`) gets
##   the dynamic prefixes and a signed-in `/`, and has NO default. Defaulting
##   the session platform to the API origin forwards `/noir` to a server that
##   answers it 404 — this is the defect the "two origins" suite pins.
##
## And one that is this product's alone: the file's own header has to name
## `$RUNNER_TEMP`, because this workflow's wrangler CWD is not isonim's and the
## wrong placement is silent.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node).

import std/[strutils, unittest]

import ../../platform/web_deployment
import ../../platform/web_entry

const ExpectedAssertions = 95
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

  test "an unconfigured API origin fails CLOSED, never to the shell":
    ck rendered.contains("API_ORIGIN")
    ck rendered.contains("503")
    # The API refusal is decided BEFORE the session branch and before the final
    # static fall-through: an API call must never reach `context.next()`.
    let apiAt = rendered.find("if (isApiPath(url.pathname)) {")
    let refuseAt = rendered.find("return refuse(\n        503,")
    let sessionAt = rendered.find("if (isSessionPath(url.pathname)")
    let nextAt = rendered.rfind("return context.next();")
    ck apiAt >= 0 and refuseAt > apiAt and sessionAt > refuseAt and nextAt > sessionAt
    # Two places hand back to the static artifact: the untagged last line of
    # `onRequest`, and the tagged session fall-through.
    ck rendered.count("return context.next();") == 1
    ck rendered.count("await context.next();") == 1

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

suite "the API origin's surfaces reach the API origin":
  test "/api/v1 and /auth are forwarded, separately from the product routes":
    for prefix in FrontDoorApiPrefixes:
      ck rendered.contains("\"" & prefix & "\",")
      # Not smuggled into the contract's list: these are not product routes,
      # and `frontDoorDynamicPrefixes` must stay exactly `classifyPath`'s.
      ck prefix notin frontDoorDynamicPrefixes(contract)
    ck "/api/v1" in FrontDoorApiPrefixes
    ck "/auth" in FrontDoorApiPrefixes
    ck rendered.contains("underPrefix(pathname, API_PREFIXES)")

  test "a share-link landing path is recognised, and nothing else of that shape":
    const id = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
    ck isShareLinkPath("/acme/" & id & "/download")
    ck isShareLinkPath("/acme/" & id & "/download/")
    ck isShareLinkPath("/acme/" & id.toUpperAscii & "/download")
    ck not isShareLinkPath("/acme/not-a-uuid/download")
    ck not isShareLinkPath("/acme/" & id & "/download/extra")
    ck not isShareLinkPath("/acme/" & id)
    ck not isShareLinkPath("/a/b/" & id & "/download")
    ck not isShareLinkPath("//" & id & "/download")
    ck not isShareLinkPath("/acme/" & id & "x/download")
    ck rendered.contains("SHARE_LINK_PATH.test(pathname)")

suite "two origins: the API origin and the session platform":
  test "the API origin defaults to api.codetracer.com, overridable but never empty":
    ck DefaultApiOrigin == "https://api.codetracer.com"
    ck rendered.contains("const DEFAULT_API_ORIGIN = \"https://api.codetracer.com\";")
    # A non-empty variable wins; an empty one falls through to the default.
    ck rendered.contains("return configured(env, \"API_ORIGIN\") || DEFAULT_API_ORIGIN;")
    ck rendered.contains("env[name].trim()")
    let custom = renderFrontDoorFunction(contract,
      apiOrigin = "https://api.example.test")
    ck custom.contains("const DEFAULT_API_ORIGIN = \"https://api.example.test\";")
    # Rendered with no API origin at all, an API call still refuses rather
    # than being answered by the shell.
    let unconfigured = renderFrontDoorFunction(contract, apiOrigin = "")
    ck unconfigured.contains("const DEFAULT_API_ORIGIN = \"\";")
    ck unconfigured.contains("if (!origin) {")

  test "the session platform has NO default, and is never the API origin":
    # The defect this suite exists for: the session paths sent to the API
    # origin, which answers them 404.
    ck not rendered.contains("DEFAULT_PLATFORM_ORIGIN")
    ck rendered.contains("return configured(env, \"PLATFORM_ORIGIN\");")
    ck not rendered.contains("configured(env, \"PLATFORM_ORIGIN\") ||")
    # The session paths use the session platform; the API paths the API one.
    ck rendered.contains("const platform = sessionPlatform(env);")
    ck rendered.contains("return proxyTo(request, platform, \"origin\");")
    ck rendered.contains("const origin = apiOrigin(env);")
    ck rendered.contains("return proxyTo(request, origin, \"origin\");")
    # The dynamic prefixes are the SESSION list only; the API list is separate.
    ck rendered.contains("return underPrefix(pathname, DYNAMIC_PREFIXES);")

  test "with no session platform, its paths are the static bundle, tagged":
    ck rendered.contains("if (!platform) return serveStaticTagged(context);")
    ck rendered.contains("tagged.headers.set(\"X-CodeTracer-Front-Door\", \"static\");")
    # Copied, not rebuilt through `markPrivate`: tagging a static response
    # must not make it private or change its caching.
    let fnAt = rendered.find("async function serveStaticTagged(context) {")
    ck fnAt >= 0
    let fnEnd = rendered.find("\n}\n", fnAt)
    let body = rendered[fnAt .. fnEnd]
    ck body.contains("new Response(response.body, response)")
    ck not body.contains("markPrivate")
    ck not body.contains("Cache-Control")
    # The fork condition is unchanged: dynamic prefixes, or `/` with a cookie.
    ck rendered.contains("if (isSessionPath(url.pathname) || (url.pathname === \"/\" && session)) {")

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
