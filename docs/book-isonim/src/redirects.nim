## codetracer/docs/book-isonim -- published-URL redirect generation.
##
## Two kinds of URL have to keep resolving after the content behind them moves,
## and both are served the same way (see the mechanism note below):
##
##   1. **Legacy mdBook `*.html` deep links.** The old mdBook served every page
##      at `/section/page.html` (with the root chapter also copied to
##      `/index.html`); the isonim-docs SSG serves clean `/section/page` (output
##      `<route>/index.html`). Without redirects every existing
##      `docs.codetracer.com/*.html` deep link would 404.
##   2. **Clean routes this book has since MOVED** (`movedRoutes` below). The
##      SSG's own URLs are published too -- on the released channel, on
##      `/nightly`, and in whatever links readers have shared -- so
##      reorganizing a section is exactly as breaking as the mdBook migration
##      was, just less obviously. A page that changes section without an entry
##      here is a 404 somebody meets by following a link that used to work.
##
## This module enumerates the legacy `*.html` URL set from the OLD book's
## `SUMMARY.md` (the authoritative list of published pages -- pages absent
## from SUMMARY, like `recording-a-browser-app.md`, were never rendered by
## mdBook and therefore have no legacy URL), maps each to its new clean
## route, and emits:
##
##   1. a meta-refresh HTML stub at each legacy `*.html` path under `public/`
##      -- the LOAD-BEARING mechanism, because docs.codetracer.com publishes
##      to GitHub Pages, which honors NEITHER `_redirects` NOR `.htaccess`;
##      only a real HTML file at the old path reliably redirects there; and
##   2. a `_redirects` manifest (`/old.html /clean 301`) -- harmless on
##      Pages, and belt-and-suspenders should Cloudflare ever front the site.
##
## The new SSG already emits the real home page at `/index.html`, so the
## mdBook root copy (`/index.html` -> `/`) is satisfied by that real page
## and is deliberately NOT overwritten with a stub (the one collision).

import std/[os, strutils]
import core/base_path

type
  LegacyRedirect* = object
    oldUrl*: string      ## legacy URL, e.g. "/getting_started/python.html"
    oldRelPath*: string  ## public-relative stub path, e.g. "getting_started/python.html"
    newRoute*: string    ## new clean route, e.g. "/getting_started/python"
    needsStub*: bool     ## false only for the root /index.html (real home page lives there)

  RedirectCounts* = tuple[legacy, moved: int]
    ## How many stubs each family contributed, reported separately so a build
    ## log (and the tests) can tell "the mdBook migration is intact" from "the
    ## book's own moves are covered". Collapsing them to one number hides a
    ## whole family disappearing behind the other one growing.

const movedRoutes*: array[1, tuple[oldRoute, newRoute: string]] = [
  ## Clean routes this book has moved, oldest first. **Append only**: an entry
  ## removed from here is a published URL that starts 404ing, and the reader who
  ## finds out is the one following a link somebody sent them a year ago.
  ##
  ## DeepReview outgrew being one page inside the usage guide and was given a
  ## section of its own. `/usage_guide/deep_review` is live on the NIGHTLY
  ## channel today (`docs.codetracer.com/nightly/usage_guide/deep_review/`
  ## answers 200; the released channel has not shipped that page yet), and the
  ## page it served is now the section's Introduction at `/deep_review`. The
  ## entry is written for both channels regardless -- the redirect costs one
  ## 400-byte file, and the alternative is remembering to add it at release.
  (oldRoute: "/usage_guide/deep_review", newRoute: "/deep_review"),
]

proc mapNewRoute*(relNoExt: string): string =
  ## Map an old book source path (no `.md`, forward-slash) to its new clean
  ## route, mirroring how the content was ported in M1:
  ##   introduction        -> /getting_started/introduction  (M5: the Introduction
  ##                                                            prose moved out of the
  ##                                                            root landing into its
  ##                                                            own Getting Started page)
  ##   CONTRIBUTING         -> /misc/contributing      (SUMMARY groups it under Misc)
  ##   <section>/overview   -> /<section>              (section overview -> section index)
  ##   <section>/<page>     -> /<section>/<page>
  ##   <page>               -> /<page>
  var route =
    if relNoExt == "introduction":
      "/getting_started/introduction"
    elif relNoExt == "CONTRIBUTING":
      "/reference/contributing"
    elif relNoExt.endsWith("/overview"):
      "/" & relNoExt[0 ..< relNoExt.len - "/overview".len]
    else:
      "/" & relNoExt
  # Reorg to the WebFlow 3-section organization: fold `building_and_packaging`
  # and `misc` into `reference`, and move the root `installation` page under
  # `getting_started`. Keeps legacy mdBook URLs redirecting to where the content
  # actually lives now.
  for (frm, dst) in [("/misc/", "/reference/"),
                     ("/building_and_packaging/", "/reference/")]:
    if route.startsWith(frm):
      route = dst & route[frm.len .. ^1]
  if route == "/installation":
    route = "/getting_started/installation"
  route

proc parseSummaryPaths*(summaryText: string): seq[string] =
  ## Extract every `](./PATH.md)` link target from an mdBook SUMMARY.md,
  ## returning the forward-slash relative paths (with `.md`) in file order.
  for line in summaryText.splitLines():
    var i = 0
    while true:
      let open = line.find("](./", i)
      if open < 0: break
      let start = open + len("](./")
      let close = line.find(')', start)
      if close < 0: break
      let target = line[start ..< close]
      if target.endsWith(".md"):
        result.add target
      i = close + 1

proc legacyRedirects*(summaryPath: string): seq[LegacyRedirect] =
  ## Enumerate the legacy URL set from the old book's SUMMARY.md and map
  ## each entry to its new clean route. Appends the mdBook root copy
  ## (`/index.html` -> `/`, `needsStub = false`) so completeness checks
  ## account for it without ever clobbering the real generated home page.
  let text = readFile(summaryPath)
  for rel in parseSummaryPaths(text):
    let relNoExt = rel[0 ..< rel.len - ".md".len]
    let oldRelPath = relNoExt & ".html"
    result.add LegacyRedirect(
      oldUrl: "/" & oldRelPath,
      oldRelPath: oldRelPath,
      newRoute: mapNewRoute(relNoExt),
      needsStub: true)
  result.add LegacyRedirect(
    oldUrl: "/index.html",
    oldRelPath: "index.html",
    newRoute: "/",
    needsStub: false)

proc movedRouteRedirects*(): seq[LegacyRedirect] =
  ## `movedRoutes` in the same shape as the legacy set, so both families share
  ## one emitter, one manifest and one set of assertions.
  ##
  ## The stub path is the old route's own `index.html` -- the exact file the SSG
  ## used to write there, and the one GitHub Pages serves for a trailing-slash
  ## URL. Nothing else at that path would be found: Pages does not fall back to
  ## a sibling `*.html`.
  for moved in movedRoutes:
    result.add LegacyRedirect(
      oldUrl: moved.oldRoute,
      oldRelPath: moved.oldRoute[1 .. ^1] & "/index.html",
      newRoute: moved.newRoute,
      needsStub: true)

proc metaRefreshStub*(cleanUrl: string): string =
  ## A minimal, self-contained HTML page that redirects to `cleanUrl` three
  ## ways: an immediate `<meta http-equiv="refresh">`, a `<link rel=canonical>`
  ## (so search engines fold the old URL into the new one), and a
  ## `location.replace` fallback (no history entry). `noindex` keeps the stub
  ## itself out of search results. `cleanUrl` is a site-root path with no
  ## quotes, so no escaping is required.
  "<!doctype html>\n" &
  "<html lang=\"en\">\n<head>\n" &
  "<meta charset=\"utf-8\">\n" &
  "<meta http-equiv=\"refresh\" content=\"0; url=" & cleanUrl & "\">\n" &
  "<link rel=\"canonical\" href=\"" & cleanUrl & "\">\n" &
  "<meta name=\"robots\" content=\"noindex\">\n" &
  "<title>Redirecting…</title>\n" &
  "<script>location.replace(\"" & cleanUrl & "\");</script>\n" &
  "</head>\n<body>\n" &
  "<p>This page has moved to <a href=\"" & cleanUrl & "\">" & cleanUrl & "</a>.</p>\n" &
  "</body>\n</html>\n"

proc metaRefreshTarget*(stubHtml: string): string =
  ## Parse the redirect target back out of a stub's meta-refresh directive
  ## (`content="0; url=<target>"`). Returns "" if none is present. Used by
  ## the verification test to confirm each stub points at the right route.
  const marker = "url="
  let mIdx = stubHtml.find("http-equiv=\"refresh\"")
  if mIdx < 0: return ""
  let uIdx = stubHtml.find(marker, mIdx)
  if uIdx < 0: return ""
  let start = uIdx + marker.len
  let close = stubHtml.find('"', start)
  if close < 0: return ""
  stubHtml[start ..< close].strip()

proc isRedirectStub*(html: string): bool =
  ## Whether a file already at a stub's path is one of OUR stubs rather than a
  ## real rendered page. Used by the overwrite guard below, and by the tests
  ## that count real pages in `public/`.
  html.contains("http-equiv=\"refresh\"")

proc generateRedirects*(publicDir, summaryPath: string;
                        basePath = ""): RedirectCounts =
  ## Write a meta-refresh stub at every legacy `*.html` path and every moved
  ## clean route under `publicDir`, plus a `_redirects` manifest at
  ## `publicDir/_redirects` covering both. Returns the per-family stub counts.
  ##
  ## `basePath` is the channel prefix this build is hosted under (`""` for the
  ## released book at `docs.codetracer.com/`, `"/nightly"` for the nightly
  ## channel, `"/pr/<N>"` for a pull-request preview). These stubs are
  ## hand-emitted HTML the framework's base-path pass never sees, so BOTH the
  ## URL a stub redirects to and the manifest's old/new URL pair are prefixed
  ## here -- an unprefixed `/getting_started/python` in a `/nightly` stub would
  ## bounce the reader out of the nightly site.
  ##
  ## **Never overwrites a real generated page.** The moved-route family made
  ## that guard load-bearing rather than defensive: its stubs live at
  ## `<route>/index.html`, which is exactly where the SSG writes real pages, so
  ## a moved-route entry whose old page is still generated would otherwise
  ## replace that page with a redirect to itself. The guard is on the file's
  ## CONTENT, not on its name -- re-running is idempotent (a previous stub is
  ## rewritten in place), while a real page is left alone and reported.
  let base = normalizeBasePath(basePath)
  var lines: seq[string] = @[]
  var counts: RedirectCounts = (legacy: 0, moved: 0)
  var clobbered: seq[string] = @[]

  proc emit(r: LegacyRedirect): bool =
    ## True when a stub was written. Appends the manifest line either way: the
    ## manifest describes the intended redirect, and (for the root `/index.html`
    ## collision) the real page at the destination already satisfies it.
    lines.add base & r.oldUrl & " " & base & r.newRoute & " 301"
    if not r.needsStub:
      return false
    let outPath = publicDir / r.oldRelPath
    if fileExists(outPath) and not isRedirectStub(readFile(outPath)):
      clobbered.add r.oldUrl
      return false
    createDir(outPath.parentDir())
    writeFile(outPath, metaRefreshStub(base & r.newRoute))
    true

  for r in legacyRedirects(summaryPath):
    if emit(r): inc counts.legacy
  for r in movedRouteRedirects():
    if emit(r): inc counts.moved

  writeFile(publicDir / "_redirects", lines.join("\n") & "\n")

  # A moved route whose old page is still being generated means the content did
  # not actually move -- the redirect would be dead on arrival, and silently.
  # The legacy root `/index.html` is the one designed collision and is marked
  # `needsStub: false`, so it never reaches the guard.
  if clobbered.len > 0:
    raise newException(ValueError,
      "redirect target is still a real generated page, so the content did " &
      "not move: " & clobbered.join(", "))
  counts
