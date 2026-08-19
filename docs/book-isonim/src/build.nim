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
import docs_scaffold
import core/base_path
import ./docs_config
import ./theme_tokens
import ./redirects

const legacySummaryPath = "../book/src/SUMMARY.md"
  ## The old mdBook's SUMMARY (relative to this consumer's build CWD): the
  ## authoritative list of legacy published pages the redirects preserve.

const basePathEnvVar* = "CT_DOCS_BASE_PATH"
  ## The URL prefix this build is published under, set by `ci/deploy/docs.sh`
  ## per publish channel: unset/empty for the released book at
  ## `docs.codetracer.com/` (built from `stable`), `"/nightly"` for the nightly
  ## book at `docs.codetracer.com/nightly` (built from `dev`). An env var rather
  ## than a CLI flag because the build runs through `just build` -> `nim c -r`,
  ## which would otherwise have to forward arguments through two layers.

when isMainModule:
  # Channel prefix (see `basePathEnvVar`). Normalized here so the value that
  # reaches the config, the redirect stubs and the log line is the same one.
  let channelBase = normalizeBasePath(getEnv(basePathEnvVar))
  # The framework's `buildDocsSite` scaffold does the SSG build, prepends the
  # design-system token CSS onto the composed stylesheet (framework default +
  # this site ships no `style.css` of its own), compiles this book's JS mount
  # entry into the hashed `assets/app.js`, and copies `static/` verbatim.
  let n = buildDocsSite(bookDocsConfig(channelBase),
                        docsTokensCss = metacraftDocsTokensCss(),
                        clientEntry = "src/main.nim")
  # Post-build: emit legacy-URL redirect artifacts (meta-refresh *.html
  # stubs + a _redirects manifest) so every old mdBook deep link still
  # resolves. Runs AFTER buildSite (which wipes+rebuilds public/) so the
  # stubs survive, and after the static copy so the collision guard sees
  # every real page already in place. The stubs are plain HTML the framework
  # never sees, so they carry the channel prefix explicitly.
  let stubs = generateRedirects("public", legacySummaryPath, channelBase)
  echo "SSG: rendered ", n, " static pages into ./public/",
    (if channelBase.len > 0: " (hosted under " & channelBase & ")" else: "")
  echo "SSG: emitted ", stubs, " legacy-URL redirect stubs + _redirects into ./public/"
