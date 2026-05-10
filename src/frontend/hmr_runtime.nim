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
  import isonim/web/hmr_css_watch

  proc nodeProcessEnv(name: cstring): cstring
    {.importjs: "(globalThis.process && globalThis.process.env && globalThis.process.env[#])".}

  proc isHmrRequested*(): bool =
    ## HMR is on by default for `-d:ctHmr` builds — the developer who
    ## ran `just build` already opted in at compile time, so making
    ## them remember to also `CT_HMR=1` every time they launch ct
    ## defeats the "edit, save, see the change" flow. The env var is
    ## now an *opt-out*: set `CT_HMR=0` (or `false` / `off`) to launch
    ## the dev binary without installing the watchers.
    ##
    ## Production builds — which lack `-d:ctHmr` entirely — never
    ## reach this code; the `else` branch below short-circuits to
    ## the no-op stub and the JS bundle contains no HMR machinery.
    let v = nodeProcessEnv(cstring"CT_HMR")
    if v.isNil or v.len == 0:
      return true
    return v != cstring"0" and v != cstring"false" and v != cstring"off"

  proc resolveBundleFile(): cstring =
    ## Bundle file the FS watcher should observe. Honour
    ## `CT_HMR_BUNDLE` first; otherwise return empty so the caller
    ## (which knows the active path) can supply it.
    let override = nodeProcessEnv(cstring"CT_HMR_BUNDLE")
    if not override.isNil and override.len > 0:
      override
    else:
      cstring""

  # ---------------------------------------------------------------------
  # CSS LiveReload — Tup builds Stylus → CSS, we watch the .css output
  # and swap each codetracer-managed `<link rel=stylesheet>` tag's
  # href when its file mtime changes.
  # ---------------------------------------------------------------------

  proc nodePathDirname(path: cstring): cstring =
    {.emit: [result,
      " = (globalThis.require ? globalThis.require('path').dirname(",
      path, ") : ", path, ");"].}

  proc nodePathJoin(a, b: cstring): cstring =
    {.emit: [result,
      " = (globalThis.require ? globalThis.require('path').join(",
      a, ", ", b, ") : (", a, " + '/' + ", b, "));"].}

  proc decodeUriJs(s: cstring): cstring
    {.importjs: "decodeURIComponent(#)".}

  proc windowLocationPathname(): cstring =
    {.emit: [result, " = window.location.pathname;"].}

  proc indexHtmlDir(): cstring =
    ## Filesystem directory that contains the loaded index.html. We
    ## resolve this from `window.location.pathname` because the
    ## renderer process does not have direct access to
    ## `codetracerExeDir` (that lives in the Electron main process).
    ## On Linux/macOS the pathname is already a real path; on
    ## Windows it has a leading slash before the drive letter
    ## (`/C:/path/...`) — `decodeURIComponent` plus Node's
    ## `path.dirname` smooth that out for both cases.
    let raw = windowLocationPathname()
    nodePathDirname(decodeUriJs(raw))

  iterator stylesheetLinkHrefs(): cstring =
    ## Yields the `href` attribute of every `<link rel="stylesheet">`
    ## tag in the document, in document order.
    var nodes: JsObject
    {.emit: [nodes,
      " = document.querySelectorAll('link[rel=\"stylesheet\"]');"].}
    let n = nodes["length"].to(int)
    for i in 0 ..< n:
      var hrefVal: cstring
      {.emit: [hrefVal, " = ",
        nodes, "[", i, "].getAttribute('href') || '';"].}
      yield hrefVal

  proc startsWithJs(s, prefix: cstring): bool =
    # Importjs `#` placeholders are sequential — referencing the same
    # parameter twice from a single pattern requires separate
    # placeholders, so we emit the JS literally.
    {.emit: [result,
      " = (typeof ", s, " === 'string' && ",
      s, ".indexOf(", prefix, ") === 0);"].}

  proc isCodetracerManaged(href: cstring): bool =
    ## Filter out third-party stylesheets whose .css files are
    ## vendored copies the developer never edits. Codetracer's own
    ## stylesheets all live under `frontend/styles/` (built from
    ## `.styl` sources by Tup's `!stylus` rule). Watching anything
    ## else is wasted file handles.
    startsWithJs(href, cstring"frontend/styles/")

  iterator scriptSrcs(): cstring =
    ## Yields the `src` attribute of every non-empty `<script>` tag.
    var nodes: JsObject
    {.emit: [nodes, " = document.querySelectorAll('script[src]');"].}
    let n = nodes["length"].to(int)
    for i in 0 ..< n:
      var src: cstring
      {.emit: [src, " = ", nodes, "[", i, "].getAttribute('src') || '';"].}
      if src.len > 0:
        yield src

  proc resolveBundlePath(defaultBundleFile: cstring): cstring =
    ## Find the on-disk file the renderer's bundle `<script>` tag
    ## actually loaded. Order:
    ##   1. `CT_HMR_BUNDLE` env override (absolute path).
    ##   2. The first `<script src>` whose URL ends with the bundle's
    ##      basename, resolved against the index.html directory.
    ##   3. The `defaultBundleFile` argument the caller supplied.
    ##
    ## Auto-resolution is the right default because Electron loads
    ## relative `<script src>` URLs against the index.html location,
    ## and the developer's per-machine path is recoverable from
    ## `window.location.pathname`. Sidesteps the symlink + duplicate-
    ## copy ambiguity (Tup `cp`s `ui.js` to `public/ui.js` for the
    ## server-mode loader; Electron only ever loads the
    ## non-`public/` copy).
    let envOverride = resolveBundleFile()
    if envOverride.len > 0:
      return envOverride
    let baseDir = indexHtmlDir()
    for src in scriptSrcs():
      # Skip absolute URLs (third-party CDNs, vendored bundles served
      # from absolute paths). The codetracer ui.js is loaded with a
      # plain relative href.
      if startsWithJs(src, cstring"http://") or
          startsWithJs(src, cstring"https://") or
          startsWithJs(src, cstring"file://") or
          startsWithJs(src, cstring"/"):
        continue
      # Match the basename so a developer who renamed the bundle
      # output still finds it.
      var matchesDefault: bool
      let defaultBasename = defaultBundleFile
      {.emit: [matchesDefault,
        " = (",
        src, ".indexOf(", defaultBasename, ".substring(",
          defaultBasename, ".lastIndexOf('/') + 1)) !== -1);"].}
      if matchesDefault:
        return nodePathJoin(baseDir, src)
    defaultBundleFile

  proc installCtHmrTransport*(defaultBundleFile: cstring;
                              bundleUrl: cstring): FsWatchTransport =
    ## Install the FS-watch HMR transports when `CT_HMR=1`:
    ## - one transport for the JS bundle (`ui.js`).
    ## - one CSS watcher per codetracer-managed stylesheet `<link>`
    ##   tag in the document. Stylus rebuilds rewrite the .css
    ##   output; the CSS watcher swaps the `href` to a cache-busted
    ##   URL so the browser refetches without a full page reload.
    ##
    ## Returns the JS-bundle transport so the caller can `disconnect()`
    ## it later, or nil if HMR is not requested at runtime. The CSS
    ## watchers are tracked in a module-scope list and detached at
    ## process exit; we don't expose them on the return value for
    ## simplicity.
    if not isHmrRequested():
      return nil

    let chosen = resolveBundlePath(defaultBundleFile)
    if chosen.len == 0:
      # No path to watch — skip silently. A noisier failure mode here
      # would interrupt every renderer launch that happens to have a
      # ctHmr build but no CT_HMR=1 env, which is the wrong default.
      return nil

    let jsTransport = installFsWatchTransport(chosen, bundleUrl)

    let baseDir = indexHtmlDir()
    for href in stylesheetLinkHrefs():
      if not isCodetracerManaged(href):
        continue
      let localPath = nodePathJoin(baseDir, href)
      # Selector matches the original href verbatim — the watcher
      # itself updates the DOM tag's href to a cache-busted version
      # on each change, but the *selector* always refers to the
      # original href because the matched node is the same `<link>`
      # element whose href is being mutated. We use an exact match so
      # multiple stylesheets in the same directory don't collide.
      var selector: cstring
      {.emit: [selector,
        " = 'link[rel=\"stylesheet\"][href=\"' + ", href, " + '\"]';"].}
      discard installCssWatcher(localPath, selector)

    jsTransport

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
