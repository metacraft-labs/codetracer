## codetracer/docs/book-isonim -- thin SSR entry.
##
## Calls the framework's own `renderRoute` with this site's `content/`
## dir and its own `DocsConfig`, passing NO explicit manifest -- letting
## the framework's default (`buildManifestFromContent`) auto-discover the
## route table from the ported CodeTracer book content.

when defined(js):
  {.error: "ssr.nim is a C-target (server-side) entry point".}

import "../../../../isonim-docs/src/ssr" as frameworkSsr
import ./docs_config

proc renderRoute*(path: string; contentDir = "content"): tuple[status: int, html: string] =
  frameworkSsr.renderRoute(path, contentDir, cfg = bookDocsConfig())

when isMainModule:
  let (status, html) = renderRoute("/")
  echo "SSR smoke: GET / -> ", status, " (", html.len, " bytes)"
