## Protects the `just dev` live-reload wiring for the CodeTracer book: themed
## stylesheet (token CSS prepended) + branded, reload-injected pages over its
## content/assets/static, and a content edit firing a reload broadcast.

import std/[unittest, os, strutils]
import ../src/dev   # newDocsDevServer + (re-exported) dev_server API

suite "CodeTracer book dev server (themed live-reload wiring)":
  test "serves the themed stylesheet + branded, reload-injected home page":
    let ds = newDocsDevServer()
    let (hs, hct, home) = handleRoute(ds, "/")
    check hs == 200
    check hct == "text/html; charset=utf-8"
    check home.contains("CodeTracer")
    check home.contains(defaultLiveReloadPath)
    let (cs, cct, css) = handleRoute(ds, "/assets/style.css")
    check cs == 200
    check cct == "text/css; charset=utf-8"
    check css.contains("--docs-")
    check handleRoute(ds, "/assets/fonts/Geist-Variable.woff2").status == 200

  test "a content edit fires a live-reload broadcast":
    let tmp = getTempDir() / "codetracer_book_devreload"
    removeDir(tmp); createDir(tmp)
    writeFile(tmp / "index.md", "---\ntitle: Home\n---\n# Home\n")
    let ds = newDocsDevServer(contentDir = tmp)
    let q = ds.hub.subscribe()
    check q[].len == 0
    writeFile(tmp / "index.md", "---\ntitle: Home\n---\n# Home edited\n")
    check ds.pollForChanges().len == 1
    check q[] == @[reloadMessage]
