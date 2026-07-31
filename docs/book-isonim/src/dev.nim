## Live-reloading dev server for the CodeTracer book (book-isonim consumer).
##
## Serves this book's own `content/` plus its themed assets (`assets/style.css`
## with the Metacraft token CSS prepended, and the `static/` fonts & icons -- the
## same dirs `build.nim` maps into `public/assets/`) over HTTP, and watches
## `content/` so any edit hot-reloads every open tab via the framework's
## `dev_server` WebSocket live-reload channel.
##
## The book is root-hosted (docs.codetracer.com, no basePath), so dev URLs match
## production directly. Driven by `just dev-docs` (server) + `just open-docs` (browser);
## optional first arg is the port (default 8000).

import std/[os, strutils, asyncdispatch]
import dev_server
import core/docs_tokens
import ./docs_config
import ./theme_tokens

export dev_server

proc newDocsDevServer*(contentDir = "content";
                       assetsDirs = @["assets", "static"]): DevServer =
  ## This book's themed live-reload dev server. Exposed so a test drives the
  ## exact `just dev-docs` wiring without binding a socket.
  newDevServer(contentDir = contentDir, cfg = bookDocsConfig(),
               assetsDirs = assetsDirs,
               docsTokensCss = docsTokensCssLive(),
               tokensCssProvider = (proc(): string = docsTokensCssLive()),
               watchPaths = @[docsDesignSystemPath],
               # M1: serve this book's compiled JS mount entry at /assets/app.js
               # (compiled lazily on first request), so dev matches the built site.
               clientEntry = "src/main.nim")

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8000
  # host: 2nd arg or AH_DEV_HOST env; default loopback (pass 0.0.0.0 for LAN).
  let host =
    if paramCount() >= 2: paramStr(2)
    elif existsEnv("AH_DEV_HOST"): getEnv("AH_DEV_HOST")
    else: "127.0.0.1"
  let server = newDocsDevServer()
  stdout.writeLine "CodeTracer book dev server -> http://" & host & ":" & $port &
    "  (watching content/ + shared design system, live reload on; Ctrl-C to stop)"
  stdout.flushFile()
  waitFor serve(server, port, host = host)
