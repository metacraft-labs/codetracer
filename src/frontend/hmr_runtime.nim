## src/frontend/hmr_runtime.nim
##
## CodeTracer's wiring of the IsoNim HMR layer.
##
## Build-time switch: `-d:ctHmr`. The `build-ui-js-hmr` Justfile recipe
## passes `-d:ctHmr` and (transitively) `-d:isonimHmr` so the IsoNim
## component-slot machinery is active. Without `-d:ctHmr` this module
## is empty — production builds carry no HMR code.
##
## Runtime switch: `CT_HMR=1` in the renderer's environment. Even when
## the binary is built with `-d:ctHmr`, the FS-watch transport is only
## installed when the env var is set. That lets a developer ship a
## single dev binary and decide per-launch whether to enable HMR.
##
## The transport is `isonim/web/hmr_fs_watch.nim` — Node's `fs.watch`
## on the bundle file. CodeTracer's renderer is an Electron renderer
## with Node integration, so `globalThis.require('fs')` is available.
## When Tup rewrites `src/build-debug/frontend/ui.js`, `fs.watch` fires,
## the transport debounces a flurry, and `applyBundleByScriptTag`
## reloads the bundle. The new bundle's top-level
## `{.uiComponent.}`-emitted registrations write fresh factories into
## slots whose `symBodyHash` changed; mounts that read those slots
## re-render in place via their `mountUiHot` reactive boundary.
##
## Bundle path resolution: the env var `CT_HMR_BUNDLE` (absolute path)
## takes priority. Otherwise we infer from the renderer's existing
## `paths.frontendJsPath` so HMR works against whatever the active
## build produced.

when not defined(js):
  {.error: "src/frontend/hmr_runtime requires the JS backend".}

when defined(ctHmr):
  import std/jsffi
  import isonim/web/hmr_fs_watch

  proc nodeProcessEnv(name: cstring): cstring
    {.importjs: "(globalThis.process && globalThis.process.env && globalThis.process.env[#])".}

  proc isHmrRequested*(): bool =
    ## True when the renderer's environment opts into HMR. Reading
    ## `process.env.CT_HMR` works in Electron renderers; in pure
    ## browsers `globalThis.process` is undefined and the importjs
    ## guard returns undefined which converts to false.
    let v = nodeProcessEnv(cstring"CT_HMR")
    not v.isNil and (v == cstring"1" or v == cstring"true")

  proc resolveBundleFile(): cstring =
    ## Bundle file the FS watcher should observe. Honour
    ## `CT_HMR_BUNDLE` first; otherwise return empty so the caller
    ## (which knows the active path) can supply it.
    let override = nodeProcessEnv(cstring"CT_HMR_BUNDLE")
    if not override.isNil and override.len > 0:
      override
    else:
      cstring""

  proc installCtHmrTransport*(defaultBundleFile: cstring;
                              bundleUrl: cstring): FsWatchTransport =
    ## Install the FS-watch HMR transport when `CT_HMR=1`. Pass the
    ## bundle file the watcher should observe (overridden by
    ## `CT_HMR_BUNDLE` if set) and the URL the browser will use to
    ## reload it (typically the same relative URL the initial
    ## `<script>` tag used). Returns the transport so the caller can
    ## `disconnect()` later, or nil if HMR is not requested at runtime.
    if not isHmrRequested():
      return nil

    let chosen =
      block:
        let env = resolveBundleFile()
        if env.len > 0: env else: defaultBundleFile
    if chosen.len == 0:
      # No path to watch — skip silently. A noisier failure mode here
      # would interrupt every renderer launch that happens to have a
      # ctHmr build but no CT_HMR=1 env, which is the wrong default.
      return nil

    installFsWatchTransport(chosen, bundleUrl)

else:
  type
    FsWatchTransport* = ref object
      ## Stub so callers can store a typed reference even on non-HMR builds.

  proc isHmrRequested*(): bool = false

  proc installCtHmrTransport*(defaultBundleFile: cstring;
                              bundleUrl: cstring): FsWatchTransport =
    ## No-op on production builds. Returns nil so call sites can do
    ## `discard installCtHmrTransport(...)` regardless of build mode.
    nil
