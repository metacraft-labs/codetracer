## The Electron renderer's `fs.watch`, served by the main process.
##
## The desktop's watchers live in the main process (`index/config.nim`'s file
## watches are here too); the renderer registers none of its own. Its
## filesystem facade (`viewmodel/host/desktop_electron.nim`) answers
## `fs.watch` by asking this module over IPC:
##
## * `CODETRACER::fs-watch` {handle, path, recursive} — start watching `path`
##   with node's `fs.watch`, for the window that asked;
## * `CODETRACER::fs-unwatch` {handle} — stop;
## * `CODETRACER::fs-watch-event` {handle, kind, path} — sent to that window
##   for each change: `kind` is `fwkCreated`, `fwkModified` or `fwkDeleted`,
##   `path` the changed entry's full path.
##
## Its first consumer is the status bar's certificate indicator, whose
## triggers — `.git` (staging, a commit, a checkout), the repository root (a
## top-level edit) and the certificate store's directories — refresh it when a
## fact moves rather than only on its 15 s timer (Status-Bar.md).
##
## Each watch belongs to the window that asked (`window_routing`), and its
## events go to that window alone; a watch whose window has closed is closed
## on its next event. Handles are the renderer's, so the table is keyed by
## window and handle. A path that cannot be watched is simply not watched: the
## renderer has already answered the facade call (it checks the path exists),
## and its timer still refreshes.

when not defined(js):
  {.error: "index/renderer_fs_watch runs in the index process (JS).".}

import std/[async, jsffi, tables]

import electron_vars, window_routing
import ../viewmodel/host/main_process_wire

proc nodeWatch(path: cstring; recursive: bool;
               onChange: proc(eventType, filename: JsObject)): JsObject
  {.importjs: "require('fs').watch(#, {recursive: #, persistent: false}, #)".}
proc onError(watcher: JsObject; handler: proc(error: JsObject))
  {.importjs: "#.on('error', #)".}
proc closeWatcher(watcher: JsObject) {.importjs: "#.close()".}
proc existsSync(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc pathJoin(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc isNullish(value: JsObject): bool {.importjs: "((#) == null)".}

var watchers = initTable[string, JsObject]()
  ## `<window key>/<handle>` -> the `FSWatcher`.

proc watchKey(window: int; handle: string): string =
  $window & "/" & handle

proc stop(key: string) =
  if key in watchers:
    let watcher = watchers[key]
    watchers.del key
    try: closeWatcher(watcher)
    except: discard

proc deliver(window: int; key: string; payload: JsObject) =
  ## To the window that asked; outside every window's context (a suite, `ct
  ## host`) through the ordinary send path.
  if window < 0:
    mainWindow.webContents.send(cstring(FsWatchEventChannel), payload)
    return
  let w = windowWithId(window)
  if w.isNil:
    stop(key)
    return
  w.sendTo(cstring(FsWatchEventChannel), payload)

proc onFsWatch*(sender: JsObject; request: JsObject) {.async.} =
  let handle = $request[cstring"handle"].to(cstring)
  let path = request[cstring"path"].to(cstring)
  let recursive = request[cstring"recursive"].to(bool)
  let window = currentWindowKey()
  let key = watchKey(window, handle)
  stop(key)
  var watcher: JsObject = nil
  try:
    watcher = nodeWatch(path, recursive,
      proc(eventType, filename: JsObject) =
        # `filename` is relative to the watched path, and may be missing on
        # some platforms: the event is then about the path itself.
        let full = if isNullish(filename): path
                   else: pathJoin(path, filename.to(cstring))
        let kind =
          if $eventType.to(cstring) == "change": cstring"fwkModified"
          elif existsSync(full): cstring"fwkCreated"
          else: cstring"fwkDeleted"
        deliver(window, key, JsObject{handle: cstring(handle), kind: kind,
                                path: full}))
  except:
    return
  onError(watcher, proc(error: JsObject) = stop(key))
  watchers[key] = watcher

proc onFsUnwatch*(sender: JsObject; request: JsObject) {.async.} =
  stop(watchKey(currentWindowKey(), $request[cstring"handle"].to(cstring)))

proc activeRendererWatches*(): int =
  ## How many watches are open. For the suites.
  watchers.len
