## codetracer/docs/book-isonim -- thin SSG entry.
##
## Calls the framework's own `buildSite` with this site's `content/` dir
## and its own `DocsConfig`, passing NO explicit manifest -- letting the
## framework's default (`buildManifestFromContent`) auto-discover the
## route table (and its non-alphabetical nav order, via each page's
## `order:` front matter) from the ported CodeTracer book content.
##
## The Metacraft/CodeTracer docs token layer
## (`theme_tokens.metacraftDocsTokenLayer`) is emitted to CSS and PREPENDED
## onto `assets/style.css` via `buildSite(docsTokensCss = ...)`, and the
## vendored theme binaries (Geist woff2, logo, search glyph, screenshots)
## under `static/` are copied verbatim into `public/assets/` AFTER the
## hash/purge pass so the stylesheet's `url(/assets/...)` refs and the
## content's `/assets/...` image refs resolve to real files.

when defined(js):
  {.error: "build.nim is a C-target (SSG) entry; not for the JS target".}

import std/os
import build_site
import core/docs_tokens
import ./docs_config
import ./theme_tokens
import ./redirects

const legacySummaryPath = "../book/src/SUMMARY.md"
  ## The old mdBook's SUMMARY (relative to this consumer's build CWD): the
  ## authoritative list of legacy published pages the redirects preserve.

when isMainModule:
  let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
  let n = buildSite(contentDir = "content", cfg = bookDocsConfig(),
                    docsTokensCss = tokensCss,
                    # M1: compile this book's own JS mount entry (embeds THIS
                    # site's content) into the hashed `assets/app.js` the pages
                    # reference via `bookDocsConfig().appScriptHref`.
                    clientEntry = "src/main.nim")
  if dirExists("static"):
    copyDir("static", "public" / "assets")
  # Post-build: emit legacy-URL redirect artifacts (meta-refresh *.html
  # stubs + a _redirects manifest) so every old mdBook deep link still
  # resolves. Runs AFTER buildSite (which wipes+rebuilds public/) so the
  # stubs survive, and after the static copy so the collision guard sees
  # every real page already in place.
  let stubs = generateRedirects("public", legacySummaryPath)
  echo "SSG: rendered ", n, " static pages into ./public/"
  echo "SSG: emitted ", stubs, " legacy-URL redirect stubs + _redirects into ./public/"
