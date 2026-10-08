## The browser TAB, wired to the real browser — and nothing else.
##
## ## Why this is its own module
##
## `platform/browser_facades.nim` builds the clipboard, download and shell
## facades over a `BrowserTabBridge` and reaches no browser API. `web_browser.nim`
## supplied the bridge, and that was fine while the web deployment was the only
## thing that had a tab.
##
## The container deployment has one too. Its page is a browser tab talking to a
## `ct host` over a socket: the filesystem, the process and the VCS come from
## the container, and the clipboard, the file pickers, the download and the
## window are the tab's — §6.6 of `Architecture/UI-Bundle-And-Endpoints.md`.
## Reaching the bridge through `web_browser.nim` would have linked the project
## store, the OPFS volume and the wasm host into a bundle that has none of the
## three, which is the same argument `web_browser.nim`'s own header makes one
## level up.
##
## So the ten tab operations live here, imported by both. `web_browser.nim`'s
## `newBrowserBridge` still composes one into `BrowserBridge.tab`; the container
## boot hands one to `newContainerPlatform`. One implementation, two callers.
##
## ## `when defined(js)` and no other arm
##
## Everything here is `importjs` or `{.emit.}`. A native build has no tab and
## must not link this; the guard is at the import, in the two modules that use
## it, rather than as a `when` inside every proc — which is the split
## `web_browser.nim` already argues for.

import std/[jsffi, asyncjs]

import ../platform/outcome
import ../platform/clipboard
import ../platform/download
import ../platform/shell
import ../platform/browser_facades

export browser_facades

# ---------------------------------------------------------------------------
# The browser APIs. Each returns `{ok, message}` rather than throwing, so the
# settle helpers below have one shape to read instead of two.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# `{ok, message}` -> `PlatformOutcome`
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

proc newBrowserTabBridge*(): BrowserTabBridge =
  ## The ten operations `platform/browser_facades.nim` builds the clipboard,
  ## download and shell facades over, wired to the real browser.
  ##
  ## Split out of `newBrowserBridge` when those builders moved down into
  ## `browser_facades.nim`: the WEB bridge is this plus a project-store volume,
  ## a `WasmHost` and a share origin, and the CONTAINER deployment is a tab
  ## with none of those three. Keeping the two records apart is what lets the
  ## container reach the same three builders without inventing a store.
  BrowserTabBridge(
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
      # The same allow-list `desktop_electron` applies, from the same place.
      # This arm did NOT have it: the string went straight to `window.open`,
      # and `javascript:` and `data:text/html` are not uniformly refused there
      # across browsers.  The rule was written on the facade field as prose and
      # honoured by one of the two implementations that can open anything.
      if not allowedExternalUrlScheme(url):
        refuseExternalUrl(url)
      else:
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
      """.})
