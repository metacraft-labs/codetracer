## The web instantiation's browser half — everything `web_platform.nim`
## deliberately does not contain.
##
## `platform/web_platform.nim` builds all seven facades over a `BrowserBridge`
## and a `StoreVolume`, and reaches no browser API. This module supplies both,
## and is one of only two in the web instantiation that a browser is needed to
## run (the other is `opfs_volume.nim`). Its header explains why the split runs
## this way rather than the obvious way: NS1's gate cannot type-check a
## `when defined(js)` branch, and a web instantiation written as one large
## such branch would be the most important module in the product to check and
## the one nothing checks.
##
## ## What "boot" does, in order, and why the order is the specification's
##
## 1. Ask for persistence, and record whether the browser *answered* — §4.2.
## 2. Choose a volume: OPFS if the browser has it, in-memory otherwise. The
##    in-memory case is a product surface (§4.2's third row), not a failure.
## 3. Open the store, which may **refuse** — §4.5. A refusal is returned as a
##    refusal; no platform is installed, because a platform is a thing that can
##    write, and a refused store must not be written to.
## 4. Build the platform and install it.
##
## The user-facing announcement is `session.durability.announcement`, and
## nothing may be edited until `acknowledgeDurability` has been called — that
## gate lives in `project_store.nim` and is enforced by `web_platform.nim`'s
## `writeText`/`writeBytes`, so a view that forgets to render the banner
## produces a refusal rather than silent data loss.

when not defined(js):
  {.error: "web_browser.nim is the browser instantiation of the platform " &
           "facade; native builds use host/desktop_native.nim".}

import std/[jsffi, asyncjs]

import ../platform/outcome
import ../platform/capabilities
import ../platform/clipboard
import ../platform/download
import ../platform/shell
import ../platform/store_volume
import ../platform/memory_volume
import ../platform/project_store
import ../platform/web_platform
import ../platform/web_entry
import ../platform/wasm_worker
import ../platform/noir_wasm_modules
import ../platform/web_deployment
import ./opfs_volume

export web_platform, web_entry

# ---------------------------------------------------------------------------
# Browser bindings
# ---------------------------------------------------------------------------

proc jsNowMs(): float {.importjs: "Date.now()".}

proc jsRandomHex(): cstring {.importjs: """
(function () {
  var bytes = new Uint8Array(16);
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    crypto.getRandomValues(bytes);
  } else {
    for (var i = 0; i < 16; i++) { bytes[i] = Math.floor(Math.random() * 256); }
  }
  var out = '';
  for (var i = 0; i < 16; i++) { out += bytes[i].toString(16).padStart(2, '0'); }
  return out;
})()""".}

proc jsRequestPersistence(): Future[JsObject] {.importjs: """
(async function () {
  try {
    if (!navigator.storage || typeof navigator.storage.persisted !== 'function') {
      return {answered: false, granted: false};
    }
    var already = await navigator.storage.persisted();
    if (already) { return {answered: true, granted: true}; }
    if (typeof navigator.storage.persist !== 'function') {
      return {answered: false, granted: false};
    }
    var granted = await navigator.storage.persist();
    return {answered: true, granted: !!granted};
  } catch (e) {
    return {answered: false, granted: false};
  }
})()""".}

proc jsWriteClipboard(text: cstring): Future[JsObject] {.importjs: """
(async function (t) {
  try {
    await navigator.clipboard.writeText(t);
    return {ok: true};
  } catch (e) {
    return {ok: false, message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsWriteClipboardHtml(html, text: cstring): Future[JsObject] {.importjs: """
(async function (h, t) {
  try {
    if (typeof ClipboardItem === 'undefined') {
      await navigator.clipboard.writeText(t);
      return {ok: true};
    }
    await navigator.clipboard.write([new ClipboardItem({
      'text/html': new Blob([h], {type: 'text/html'}),
      'text/plain': new Blob([t], {type: 'text/plain'})
    })]);
    return {ok: true};
  } catch (e) {
    return {ok: false, message: (e && e.message) || String(e)};
  }
})(#, #)""".}

proc jsOfferDownload(name: cstring; data: JsObject;
                     mimeType: cstring): JsObject {.importjs: """
(function (n, bytes, mime) {
  try {
    var blob = new Blob([bytes], {type: mime});
    var url = URL.createObjectURL(blob);
    var anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = n;
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
    setTimeout(function () { URL.revokeObjectURL(url); }, 0);
    return {ok: true};
  } catch (e) {
    return {ok: false, message: (e && e.message) || String(e)};
  }
})(#, #, #)""".}

proc jsOpenExternal(url: cstring): JsObject {.importjs: """
(function (u) {
  try {
    var opened = window.open(u, '_blank', 'noopener,noreferrer');
    if (!opened) { return {ok: false, message: 'the browser blocked the pop-up'}; }
    return {ok: true};
  } catch (e) {
    return {ok: false, message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsSetFullscreen(fullscreen: bool): Future[JsObject] {.importjs: """
(async function (want) {
  try {
    if (want) { await document.documentElement.requestFullscreen(); }
    else if (document.fullscreenElement) { await document.exitFullscreen(); }
    return {ok: true};
  } catch (e) {
    return {ok: false, message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsIsFullscreen(): bool {.importjs: "(!!document.fullscreenElement)".}
proc jsHasFocus(): bool {.importjs: "(document.hasFocus())".}
proc jsLocationPath(): cstring {.importjs: "(window.location.pathname)".}
proc jsLocationHash(): cstring {.importjs: "(window.location.hash)".}
proc jsLocationSearch(): cstring {.importjs: "(window.location.search)".}
proc jsLocationOrigin(): cstring {.importjs: "(window.location.origin)".}

proc jsShareOrigin(): cstring {.importjs: """
(function () {
  try {
    if (typeof window !== 'undefined' && window.CODETRACER_SHARE_ORIGIN) {
      return String(window.CODETRACER_SHARE_ORIGIN);
    }
  } catch (e) {}
  return '';
})()""".}
  ## The sharing origin is read from the page, never compiled in.
  ##
  ## `ide.codetracer.com` is the hosted product's host, and since the
  ## 2026-08-29 rename `src/ct/online_sharing/remote_config.nim` names it too.
  ## That is a deployment fact, and deployment facts move: the host has gone
  ## `cloud` → `web` → `ide`, and each move found a constant somebody had to
  ## hunt for. A build that hard-coded even the current one would need a
  ## rebuild to follow the next — so this build has none, and a deployment that
  ## sets nothing gets `capShareLink` absent with the sentence
  ## `web_platform.webInstantiationProfile` supplies.

# ---------------------------------------------------------------------------
# Small adapters
# ---------------------------------------------------------------------------

proc settleVoid(future: Future[JsObject]; what: string
               ): PlatformFuture[PlatformOutcome[Nothing]] =
  newPromise(proc(resolve: proc(value: PlatformOutcome[Nothing])) =
    discard future.then(proc(answer: JsObject) =
      var ok = false
      var message: cstring = ""
      {.emit: "`ok` = !!`answer`.ok; `message` = String(`answer`.message || '');".}
      if ok: resolve(succeeded())
      else: resolve(failed[Nothing](pkFailed, what & " failed", $message))))

proc settleSync(answer: JsObject; what: string
               ): PlatformFuture[PlatformOutcome[Nothing]] =
  var ok = false
  var message: cstring = ""
  {.emit: "`ok` = !!`answer`.ok; `message` = String(`answer`.message || '');".}
  if ok: resolvedOk()
  else: resolvedErr[Nothing](pkFailed, what & " failed", $message)

proc toJsBytes(content: seq[byte]): JsObject =
  var array: JsObject
  let length = content.len
  {.emit: "`array` = new Uint8Array(`length`);".}
  for i in 0 ..< length:
    let b = content[i].int
    {.emit: "`array`[`i`] = `b`;".}
  array

# ---------------------------------------------------------------------------
# The bridge
# ---------------------------------------------------------------------------

proc browserWasmHost(delivered: seq[DeliveredWasmModule]): WasmHost
  ## Forward-declared because the bridge is built above the Worker transport
  ## it may need. Defined with `newBrowserWasmHost`, whose reasons it shares.

proc newBrowserBridge*(volume: StoreVolume; persistenceGranted,
                       persistenceAnswered: bool;
                       deliveredWasmModules: seq[DeliveredWasmModule] = @[]
                      ): BrowserBridge =
  BrowserBridge(
    volume: volume,
    persistenceGranted: persistenceGranted,
    persistenceAnswered: persistenceAnswered,
    ownerId: $jsRandomHex(),
      # Per page load, and random. A stable id — derived from the origin, say —
      # would make a reloaded tab indistinguishable from a second one, and
      # §4.3's whole protocol turns on telling those apart.
    nowMs: proc(): int64 = jsNowMs().int64,
    writeClipboardText: proc(text: string
                            ): PlatformFuture[PlatformOutcome[Nothing]] =
      settleVoid(jsWriteClipboard(text.cstring), "copying to the clipboard"),
    writeClipboardHtml: proc(html, plainText: string
                            ): PlatformFuture[PlatformOutcome[Nothing]] =
      settleVoid(jsWriteClipboardHtml(html.cstring, plainText.cstring),
                 "copying to the clipboard"),
    offerDownload: proc(suggestedName: string; content: seq[byte];
                        mimeType: string
                       ): PlatformFuture[PlatformOutcome[Nothing]] =
      settleSync(jsOfferDownload(suggestedName.cstring, toJsBytes(content),
                                 mimeType.cstring), "the download"),
    pickFiles: proc(options: OpenDialogOptions
                   ): PlatformFuture[PlatformOutcome[seq[string]]] =
      # Deliberately not implemented in NS2 and deliberately not faked. Import
      # is a store operation — the picked file is COPIED into the project — and
      # the copy path belongs with the templates and the inline-share decoder
      # that NS6 brings. Refusing by name is better than a picker that hands
      # back host paths the store cannot address.
      resolvedUnsupported[seq[string]]("importing files from your computer"),
    pickDirectory: proc(options: OpenDialogOptions
                       ): PlatformFuture[PlatformOutcome[string]] =
      resolvedUnsupported[string]("importing a folder from your computer"),
    suggestSaveName: proc(options: SaveDialogOptions
                         ): PlatformFuture[PlatformOutcome[string]] =
      # A browser download names itself; there is no dialog to consult first.
      # Answering with the suggestion is correct rather than a refusal: the
      # question "what will this be called" has a true answer here.
      resolvedOk(options.suggestedName),
    openExternalUrl: proc(url: string
                         ): PlatformFuture[PlatformOutcome[Nothing]] =
      settleSync(jsOpenExternal(url.cstring), "opening the link"),
    setFullscreen: proc(fullscreen: bool
                       ): PlatformFuture[PlatformOutcome[Nothing]] =
      settleVoid(jsSetFullscreen(fullscreen), "changing full screen"),
    windowState: proc(): PlatformFuture[PlatformOutcome[WindowState]] =
      resolvedOk(WindowState(
        maximized: false, minimized: false,
        fullscreen: jsIsFullscreen(), focused: jsHasFocus())),
    onWindowStateChanged: proc(handler: proc(state: WindowState)) =
      var capturedHandler = handler
      proc deliver() =
        capturedHandler(WindowState(
          maximized: false, minimized: false,
          fullscreen: jsIsFullscreen(), focused: jsHasFocus()))
      {.emit: """
      if (typeof document !== 'undefined') {
        document.addEventListener('fullscreenchange', function () { `deliver`(); });
        window.addEventListener('focus', function () { `deliver`(); });
        window.addEventListener('blur', function () { `deliver`(); });
      }
      """.},
    shareLinkOrigin: $jsShareOrigin(),
    # NS3's seam, now DERIVED FROM THE DELIVERY rather than asserted empty.
    #
    # The old constant here said the registry was empty because "the worker
    # script ... is not in the bundle". That reason expired at `dev` 07926277,
    # which places the worker script as a required asset and the two Noir
    # modules as optional fetched ones. The RULE underneath it did not expire:
    # declaring `nargo` over modules that were never placed would put
    # `capProcessSpawn` back on a profile whose every run fails, which is the
    # exact thing `platform/wasm_registry.nim` exists to prevent.
    #
    # So the answer is computed from what a caller says was delivered.
    # `deliveredWasmModules` defaults to `@[]`, and an empty delivery yields an
    # empty registry — the same answer as before, reached by ASKING rather than
    # by asserting, and one that changes on its own when a deployment starts
    # placing the modules. A partial delivery is honoured too: the compiler
    # alone declares `compile` and refuses `trace` by name, because
    # `wasm_worker_browser.js` routes by subcommand and both modules are
    # `required: false` in the manifest with their own absence sentences.
    #
    # WHAT IS STILL MISSING, precisely: nothing yet PROBES the deployment. The
    # caller that can answer "were `assets/noir_wasm.wasm` and
    # `assets/noir_tracer_wasm.wasm` actually served, and what were they built
    # from?" does not exist, so every current call passes the default and this
    # tab still ships no toolchain. That is a true statement about this
    # deployment rather than a placeholder.
    wasm: browserWasmHost(deliveredWasmModules))

# ---------------------------------------------------------------------------
# The wasm worker's transport
# ---------------------------------------------------------------------------
#
# THE THIN HALF, deliberately. `platform/wasm_worker.nim` owns the protocol —
# sequence allocation, correlation, output routing, teardown — and is tested on
# both backends against a fake transport. What is left here is the part that
# genuinely needs a browser: constructing a `Worker`, posting text to it, and
# handing text back. That split is `backend/worker_backend.nim`'s, for its
# reasons.
#
# TEXT IN BOTH DIRECTIONS, and the `String(...)` below is why this is written
# out rather than assumed. `worker_backend.nim`'s header records an engine that
# sent objects one way and JSON strings the other, with bare strings for
# bootstrap, and a reader that classified by message type reporting a timeout
# over an engine that had answered. The coercion makes the asymmetry
# impossible to reintroduce from the worker's side: whatever the worker posts
# arrives here as text, and `deliver` rejects anything that is not JSON by
# name. That rejection is itself tested, and on the JS backend it was a real
# defect — V8's `JSON.parse` throws a `SyntaxError` that `except
# CatchableError` does not catch, so the narrow form crashed the tab.

proc jsNewWorker(url: cstring): JsObject
  {.importjs: "new Worker(#, { type: 'module' })".}
proc jsWorkerPost(worker: JsObject; message: cstring)
  {.importjs: "#.postMessage(#)".}
proc jsWorkerTerminate(worker: JsObject)
  {.importjs: "#.terminate()".}

proc newWorkerTransport(scriptUrl: string;
                        onText: proc(message: string)): WasmWorkerTransport =
  ## A transport over a real `Worker`.
  let worker = jsNewWorker(scriptUrl.cstring)
  var deliverText = onText
  proc receive(raw: cstring) =
    deliverText($raw)
  {.emit: """
  `worker`.onmessage = function (event) {
    `receive`(String(event.data));
  };
  `worker`.onerror = function (event) {
    // An error event is not a message, and must not be silently dropped: the
    // protocol's own failure path is the thing that stops a caller waiting
    // forever, so a worker-level error is reported THROUGH it.
    `receive`(JSON.stringify({
      seq: 0, kind: "failed",
      message: "the wasm worker failed: " + String(event.message || event)
    }));
  };
  """.}
  proc send(message: string) =
    jsWorkerPost(worker, message.cstring)
  proc terminateWorker() =
    jsWorkerTerminate(worker)
  WasmWorkerTransport(send: send, terminateWorker: terminateWorker)

proc newBrowserWasmHost*(registry: WasmRegistry; scriptUrl: string): WasmHost =
  ## A `WasmHost` backed by a real `Worker` running `scriptUrl`.
  ##
  ## Called by `browserWasmHost` below whenever a delivery produced a non-empty
  ## registry. The worker script IS in the bundle as of `dev` 07926277 —
  ## `webRuntimeAssets()` declares it a REQUIRED asset at
  ## `wasmWorkerScriptPath` — so the reason this used to go uncalled is gone.
  var worker: WasmWorker
  proc onText(message: string) =
    if not worker.isNil: worker.deliver(message)
  let transport = newWorkerTransport(scriptUrl, onText)
  worker = newWasmWorker(registry, transport)
  worker.asWasmHost()

proc browserWasmHost(delivered: seq[DeliveredWasmModule]): WasmHost =
  ## The registry a delivery implies, behind a real Worker when there is
  ## anything to run.
  ##
  ## An empty delivery keeps `noWasmModules()` rather than starting a Worker
  ## over an empty registry: the two answer identically — `resolve` returns
  ## `wrNoModulesLoaded` for every command either way — and spawning a worker
  ## thread to host nothing is cost with no capability behind it. The choice is
  ## therefore an optimisation over an equivalence, not a second behaviour.
  let registry = noirWasmRegistry(delivered)
  if registry.modules.len == 0:
    return noWasmModules()
  newBrowserWasmHost(registry, "/" & wasmWorkerScriptPath)

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

type
  WebBoot* = object
    ## What boot produced. A refusal is a value here rather than an exception,
    ## because §4.5's refusal has a UI: an explanation and the export path.
    ok*: bool
    web*: WebPlatform
    refusal*: string
    condition*: StorageCondition
    announcement*: string

proc currentEntryRequest*(): EntryRequest =
  ## The URL, as `web_entry` wants it: path and fragment, origin removed, query
  ## carried only so a test can show it being ignored.
  var hash = $jsLocationHash()
  if hash.len > 0 and hash[0] == '#': hash = hash[1 .. ^1]
  var search = $jsLocationSearch()
  if search.len > 0 and search[0] == '?': search = search[1 .. ^1]
  EntryRequest(path: $jsLocationPath(), fragment: hash, query: search)

proc pageOrigin*(): string =
  ## For building share URLs. Read from the page rather than compiled in, for
  ## the same reason `jsShareOrigin` is.
  $jsLocationOrigin()

proc boot*(): Future[WebBoot] {.async.} =
  ## The four steps in the module header.
  let persistence = await jsRequestPersistence()
  var answered = false
  var granted = false
  {.emit: "`answered` = !!`persistence`.answered; `granted` = !!`persistence`.granted;".}

  var volume = newOpfsVolume()
  if opfsSupport() == osUnavailable:
    # §4.2's third row. An in-memory store, and a session that says so.
    volume = newMemoryVolume().asVolume

  let bridge = newBrowserBridge(volume, granted, answered)
  let opened = await openWebStore(bridge)
  if not opened.ok:
    return WebBoot(
      ok: false,
      refusal: opened.error.message,
      condition: conditionFor(volume, granted, answered),
      announcement: "")

  let web = newWebPlatform(bridge, opened.value)
  web.install()
  return WebBoot(
    ok: true,
    web: web,
    condition: opened.value.durability.condition,
    announcement: opened.value.announcement)
