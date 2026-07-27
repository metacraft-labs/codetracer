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

when isMainModule:
  let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
  let n = buildSite(contentDir = "content", cfg = bookDocsConfig(),
                    docsTokensCss = tokensCss)
  if dirExists("static"):
    copyDir("static", "public" / "assets")
  echo "SSG: rendered ", n, " static pages into ./public/"
