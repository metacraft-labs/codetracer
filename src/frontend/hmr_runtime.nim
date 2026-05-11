## src/frontend/hmr_runtime.nim
##
## CodeTracer's wiring of the IsoNim HMR layer.
##
## Architecture: external LiveReload daemon. `just build` starts a
## `livereload` Node process that watches `src/build-debug/` (the
## directory Tup writes into). The daemon listens on
## `ws://localhost:35729/livereload` — the canonical LiveReload
## endpoint — and broadcasts `reload` messages to every connected
## client when any file under the tree changes.
##
## The renderer is a thin WebSocket client. Each ct window connects
## to the daemon and reacts to incoming messages:
##
## - `.css` paths → the matching `<link rel="stylesheet">` tag's
##   href gets a cache-bust query and the browser refetches.
## - anything else → the JS bundle is re-evaluated by reading
##   `ui.js` via Node `fs.readFileSync` and injecting it as an
##   inline `<script>`. The new bundle's top-level
##   `{.uiComponent.}`-emitted `hmrRegisterFactory` calls write
##   fresh factories into slots whose `symBodyHash` changed; mounts
##   that read those slots re-render in place via their
##   `mountUiHot` reactive boundary.
##
## The daemon model centralises the watching: N concurrent ct
## windows share a single file watcher and a single fan-out, rather
## than each window polling the disk independently. Edits to
## third-party JS/CSS that codetracer happens to load (anything
## under build-debug/) are reloaded just as automatically as Nim or
## Stylus rebuilds — the daemon doesn't know or care what touched
## the file.
##
## Build-time switch: `-d:ctHmr`. The Tup `!nim_js` rule passes the
## flag (alongside `-d:isonimHmr`). Production builds, which don't
## set the flag, see this module's `else` branch and pay no
## runtime cost.
##
## Runtime switch: `CT_HMR=0` (or `false` / `off`) in the
## renderer's environment opts out of installing the transport.
## The default is on — once a developer ran `just build` they
## already opted in at compile time, and asking them to also
## remember an env var per-launch defeats the workflow.
##
## Daemon URL: `CT_LIVERELOAD_URL` env override; defaults to the
## canonical LiveReload port and path.

when not defined(js):
  {.error: "src/frontend/hmr_runtime requires the JS backend".}

when defined(ctHmr):
  import std/jsffi
  import isonim/web/hmr_livereload

  proc nodeProcessEnv(name: cstring): cstring
    {.importjs: "(globalThis.process && globalThis.process.env && globalThis.process.env[#])".}

  proc isHmrRequested*(): bool =
    ## HMR is on by default for `-d:ctHmr` builds. `CT_HMR=0`
    ## (or `false` / `off`) opts out for a launch.
    let v = nodeProcessEnv(cstring"CT_HMR")
    if v.isNil or v.len == 0:
      return true
    return v != cstring"0" and v != cstring"false" and v != cstring"off"

  proc resolveLiveReloadUrl(): cstring =
    let override = nodeProcessEnv(cstring"CT_LIVERELOAD_URL")
    if not override.isNil and override.len > 0:
      override
    else:
      cstring"ws://localhost:35729/livereload"

  proc installCtHmrTransport*(bundleUrl: cstring): LiveReloadTransport =
    ## Connect the renderer to the external LiveReload daemon that
    ## `just build` started. Returns the transport so the caller
    ## can `disconnect()` later, or nil if HMR is opted out at
    ## runtime.
    ##
    ## `bundleUrl` is the URL the document's `<script>` tag used to
    ## load the bundle. The LiveReload transport resolves it
    ## relative to `document.baseURI` to find the on-disk file
    ## (file:// scheme), then prefers reading via Node
    ## `fs.readFileSync` + inline `<script>` injection over the
    ## browser-native cache-busted `<script src>` path, which is
    ## unreliable on file:// in Electron.
    if not isHmrRequested():
      return nil
    let url = resolveLiveReloadUrl()
    installLiveReloadTransport(url = url, bundleUrl = bundleUrl)

else:
  type
    LiveReloadTransport* = ref object
      ## Stub so callers can store a typed reference even on non-HMR builds.

  proc isHmrRequested*(): bool = false

  proc installCtHmrTransport*(bundleUrl: cstring): LiveReloadTransport =
    ## No-op on production builds. Returns nil so call sites can do
    ## `discard installCtHmrTransport(...)` regardless of build mode.
    nil
