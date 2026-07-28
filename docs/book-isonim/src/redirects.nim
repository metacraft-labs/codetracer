## codetracer/docs/book-isonim -- legacy mdBook URL redirect generation.
##
## The old mdBook served every page at `/section/page.html` (with the root
## chapter also copied to `/index.html`); the isonim-docs SSG serves clean
## `/section/page` (output `<route>/index.html`). Without redirects every
## existing `docs.codetracer.com/*.html` deep link would 404.
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

type
  LegacyRedirect* = object
    oldUrl*: string      ## legacy URL, e.g. "/getting_started/python.html"
    oldRelPath*: string  ## public-relative stub path, e.g. "getting_started/python.html"
    newRoute*: string    ## new clean route, e.g. "/getting_started/python"
    needsStub*: bool     ## false only for the root /index.html (real home page lives there)

proc mapNewRoute*(relNoExt: string): string =
  ## Map an old book source path (no `.md`, forward-slash) to its new clean
  ## route, mirroring how the content was ported in M1:
  ##   introduction        -> /                       (root Introduction -> home)
  ##   CONTRIBUTING         -> /misc/contributing      (SUMMARY groups it under Misc)
  ##   <section>/overview   -> /<section>              (section overview -> section index)
  ##   <section>/<page>     -> /<section>/<page>
  ##   <page>               -> /<page>
  if relNoExt == "introduction":
    "/"
  elif relNoExt == "CONTRIBUTING":
    "/misc/contributing"
  elif relNoExt.endsWith("/overview"):
    "/" & relNoExt[0 ..< relNoExt.len - "/overview".len]
  else:
    "/" & relNoExt

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

proc generateRedirects*(publicDir, summaryPath: string): int =
  ## Write a meta-refresh stub at every legacy `*.html` path under
  ## `publicDir` and a `_redirects` manifest at `publicDir/_redirects`.
  ## Returns the number of stub files written. A stub is skipped when its
  ## target path already exists as a real generated page (the root
  ## `/index.html`), so the real home page is never overwritten.
  let redirects = legacyRedirects(summaryPath)
  var lines: seq[string] = @[]
  var written = 0
  for r in redirects:
    if r.needsStub:
      lines.add r.oldUrl & " " & r.newRoute & " 301"
      let outPath = publicDir / r.oldRelPath
      # Never overwrite a real generated page. Clean pages are always
      # emitted as `<route>/index.html`, so a stub whose basename is
      # `index.html` would land on a real page (the home page, or any
      # section index) -- skip those. Every other `*.html` stub path is
      # distinct from every real page path, so re-running is idempotent
      # (it simply rewrites the stub).
      if outPath.extractFilename == "index.html":
        continue
      createDir(outPath.parentDir())
      writeFile(outPath, metaRefreshStub(r.newRoute))
      inc written
  writeFile(publicDir / "_redirects", lines.join("\n") & "\n")
  written
