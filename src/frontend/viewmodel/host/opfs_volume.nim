## The OPFS implementation of `StoreVolume` — Noir-Studio.md §4's substrate.
##
## This module and `web_browser.nim` are the *only* two in the web
## instantiation that touch a browser API. Everything else —
## `platform/project_store.nim`, `platform/web_platform.nim`,
## `platform/archive.nim`, `platform/web_entry.nim` — is host-free and is
## compiled by `ci/test/hostfree-build.sh` and run by `vm-unit-js`. That split
## is deliberate and is described at length in `web_platform.nim`'s header: NS1
## records that the host-free gate cannot see inside `when defined(js)`, so the
## web instantiation is written to put almost nothing there.
##
## ## Why this is testable under node, which has no OPFS
##
## Every browser call below goes through `opfsRoot()`, which reads
## `navigator.storage.getDirectory` from the global object. A test installs its
## own `navigator.storage.getDirectory` returning a hand-written directory
## handle, and this module then exercises its real code paths — `getFileHandle`
## with `{create: true}`, `createWritable`, `write`, `close`, `getFile`,
## `arrayBuffer`, `removeEntry`, the async iterator over `entries()` — against
## it. That is not a mock of this module; it is a fake of the *platform*, which
## is the only kind of double that leaves the subject present.
##
## ## The three OPFS facts that shape the code
##
## 1. **`createWritable()` truncates first.** The default is
##    `keepExistingData: false`, so the target file is emptied when the
##    writable opens. `project_store.nim` never writes over a live file for
##    this reason; here it just means a failed write leaves an empty file,
##    which is why the store's temp is outside the working tree.
## 2. **There is no `rename`.** `FileSystemHandle.move()` exists in Chromium
##    and is not universal; Safari shipped `move()` for files in 17. So `move`
##    below tries the native call and falls back to read-write-delete, and
##    `atomicMove` reports which it got. The store consults that rather than
##    assuming.
## 3. **A directory handle is not a path.** Every operation walks the path
##    segment by segment from the root, because there is no `resolve(path)`
##    primitive. That walk is the reason each operation is several promises
##    deep and the reason `StoreVolume` could never have been synchronous.

when not defined(js):
  {.error: "opfs_volume.nim is the browser implementation of StoreVolume; " &
           "native builds use platform/memory_volume.nim or the desktop " &
           "filesystem facade".}

import std/[jsffi, asyncjs]

import ../platform/outcome
import ../platform/store_volume

export store_volume

type
  OpfsSupport* = enum
    osUnavailable
      ## No `navigator.storage.getDirectory`. §4.2's third row.
    osAvailable

proc jsHasOpfs(): bool =
  var available = false
  {.emit: """
  try {
    `available` = (typeof navigator !== 'undefined') &&
                  !!navigator.storage &&
                  (typeof navigator.storage.getDirectory === 'function');
  } catch (e) {
    `available` = false;
  }
  """.}
  available

proc jsHasNativeMove(): bool =
  ## Whether `FileSystemFileHandle.prototype.move` exists. Feature-detected
  ## rather than version-sniffed: the same engine has shipped it for files and
  ## not for directories, and a user-agent test would get that wrong in both
  ## directions.
  var available = false
  {.emit: """
  try {
    `available` = (typeof FileSystemFileHandle !== 'undefined') &&
                  (typeof FileSystemFileHandle.prototype.move === 'function');
  } catch (e) {
    `available` = false;
  }
  """.}
  available

proc opfsSupport*(): OpfsSupport =
  if jsHasOpfs(): osAvailable else: osUnavailable

# ---------------------------------------------------------------------------
# The raw async bridge
# ---------------------------------------------------------------------------
#
# One `{.emit.}` per operation, each returning a JS promise that settles with
# `{ok: true, value}` or `{ok: false, kind, message, detail}`. The shape is
# uniform so `settle` below is written once: a per-operation error translation
# is how a `NotFoundError` ends up reported as a generic failure at one call
# site and correctly at another.

proc jsRead(path: cstring): Future[JsObject] {.importjs: """
(async function (p) {
  try {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < parts.length - 1; i++) {
      dir = await dir.getDirectoryHandle(parts[i]);
    }
    var handle = await dir.getFileHandle(parts[parts.length - 1]);
    var file = await handle.getFile();
    var buffer = await file.arrayBuffer();
    return {ok: true, value: new Uint8Array(buffer)};
  } catch (e) {
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsWrite(path: cstring; data: JsObject): Future[JsObject] {.importjs: """
(async function (p, bytes) {
  try {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < parts.length - 1; i++) {
      dir = await dir.getDirectoryHandle(parts[i], {create: true});
    }
    var handle = await dir.getFileHandle(parts[parts.length - 1], {create: true});
    var writable = await handle.createWritable();
    try {
      await writable.write(bytes);
      await writable.close();
    } catch (inner) {
      try { await writable.abort(); } catch (ignored) {}
      throw inner;
    }
    return {ok: true};
  } catch (e) {
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#, #)""".}

proc jsStat(path: cstring): Future[JsObject] {.importjs: """
(async function (p) {
  try {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    if (parts.length === 0) { return {ok: true, kind: 'dir', size: 0}; }
    for (var i = 0; i < parts.length - 1; i++) {
      dir = await dir.getDirectoryHandle(parts[i]);
    }
    var name = parts[parts.length - 1];
    try {
      var handle = await dir.getFileHandle(name);
      var file = await handle.getFile();
      return {ok: true, kind: 'file', size: file.size};
    } catch (notFile) {
      await dir.getDirectoryHandle(name);
      return {ok: true, kind: 'dir', size: 0};
    }
  } catch (e) {
    if (e && e.name === 'NotFoundError') { return {ok: true, kind: 'missing', size: 0}; }
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsList(path: cstring): Future[JsObject] {.importjs: """
(async function (p) {
  try {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < parts.length; i++) {
      dir = await dir.getDirectoryHandle(parts[i]);
    }
    var names = [];
    var kinds = [];
    for await (var entry of dir.entries()) {
      names.push(entry[0]);
      kinds.push(entry[1].kind);
    }
    return {ok: true, names: names, kinds: kinds};
  } catch (e) {
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsMkdir(path: cstring): Future[JsObject] {.importjs: """
(async function (p) {
  try {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < parts.length; i++) {
      dir = await dir.getDirectoryHandle(parts[i], {create: true});
    }
    return {ok: true};
  } catch (e) {
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#)""".}

proc jsRemove(path: cstring; recursive: bool): Future[JsObject] {.importjs: """
(async function (p, recursive) {
  try {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    if (parts.length === 0) { throw new Error('the volume root cannot be removed'); }
    for (var i = 0; i < parts.length - 1; i++) {
      dir = await dir.getDirectoryHandle(parts[i]);
    }
    await dir.removeEntry(parts[parts.length - 1], {recursive: recursive});
    return {ok: true};
  } catch (e) {
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#, #)""".}

proc jsMove(source, destination: cstring): Future[JsObject] {.importjs: """
(async function (from, to) {
  var readAt = async function (p) {
    var dir = await navigator.storage.getDirectory();
    var parts = p.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < parts.length - 1; i++) {
      dir = await dir.getDirectoryHandle(parts[i]);
    }
    return {dir: dir, name: parts[parts.length - 1]};
  };
  try {
    var src = await readAt(from);
    var handle = await src.dir.getFileHandle(src.name);
    if (typeof handle.move === 'function') {
      var dst = await readAt(to);
      var dstDir = await navigator.storage.getDirectory();
      var dstParts = to.split('/').filter(function (s) { return s.length > 0; });
      for (var i = 0; i < dstParts.length - 1; i++) {
        dstDir = await dstDir.getDirectoryHandle(dstParts[i], {create: true});
      }
      await handle.move(dstDir, dstParts[dstParts.length - 1]);
      return {ok: true};
    }
    var file = await handle.getFile();
    var buffer = await file.arrayBuffer();
    var dstDir2 = await navigator.storage.getDirectory();
    var dstParts2 = to.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < dstParts2.length - 1; i++) {
      dstDir2 = await dstDir2.getDirectoryHandle(dstParts2[i], {create: true});
    }
    var target = await dstDir2.getFileHandle(dstParts2[dstParts2.length - 1], {create: true});
    var writable = await target.createWritable();
    await writable.write(new Uint8Array(buffer));
    await writable.close();
    await src.dir.removeEntry(src.name);
    return {ok: true};
  } catch (e) {
    return {ok: false, kind: (e && e.name) || 'Error',
            message: (e && e.message) || String(e)};
  }
})(#, #)""".}

proc jsUsage(): Future[JsObject] {.importjs: """
(async function () {
  try {
    if (!navigator.storage || typeof navigator.storage.estimate !== 'function') {
      return {ok: true, known: false, used: 0, quota: 0};
    }
    var estimate = await navigator.storage.estimate();
    if (typeof estimate.usage !== 'number' || typeof estimate.quota !== 'number') {
      return {ok: true, known: false, used: 0, quota: 0};
    }
    return {ok: true, known: true, used: estimate.usage, quota: estimate.quota};
  } catch (e) {
    return {ok: true, known: false, used: 0, quota: 0};
  }
})()""".}

# ---------------------------------------------------------------------------
# Error translation, once
# ---------------------------------------------------------------------------

proc errorKindFor(domName: cstring): PlatformErrorKind =
  ## §`outcome.PlatformErrorKind`: "A desktop `ENOENT`, an OPFS
  ## `NotFoundError` and a container `404` are all `pkNotFound`."
  case $domName
  of "NotFoundError": pkNotFound
  of "QuotaExceededError": pkQuotaExceeded
  of "NotAllowedError", "SecurityError": pkAccessDenied
  of "TypeMismatchError", "TypeError": pkInvalidArgument
  of "InvalidModificationError": pkConflict
  of "NoModificationAllowedError": pkConflict
  of "AbortError": pkCancelled
  else: pkFailed

proc settle[T](future: Future[JsObject]; what: string;
               decode: proc(answer: JsObject): T
              ): PlatformFuture[PlatformOutcome[T]] =
  ## Wrap one bridge call. Deliberately NOT `newCompletedFuture`: an OPFS
  ## operation is genuinely pending, and stamping it `__syncResolved` would
  ## make `onComplete` deliver a value that is not there yet. That is why the
  ## store's suite runs against `memory_volume` and why every browser assertion
  ## about this module is written as an awaited promise.
  var capturedDecode = decode
  newPromise(proc(resolve: proc(value: PlatformOutcome[T])) =
    discard future.then(proc(answer: JsObject) =
      var ok = false
      {.emit: "`ok` = !!`answer`.ok;".}
      if ok:
        resolve(succeeded(capturedDecode(answer)))
      else:
        var domName: cstring = ""
        var message: cstring = ""
        {.emit: "`domName` = String(`answer`.kind || 'Error'); `message` = String(`answer`.message || '');".}
        resolve(failed[T](
          errorKindFor(domName), what & " failed", $message))))

proc decodeBytes(answer: JsObject): seq[byte] =
  var length = 0
  {.emit: "`length` = `answer`.value.length;".}
  result = newSeq[byte](length)
  for i in 0 ..< length:
    var b = 0
    {.emit: "`b` = `answer`.value[`i`];".}
    result[i] = b.byte

proc decodeNothing(answer: JsObject): Nothing = nothing

proc decodeStat(answer: JsObject): VolumeEntry =
  var kindText: cstring = ""
  var size = 0
  {.emit: "`kindText` = String(`answer`.kind); `size` = `answer`.size || 0;".}
  let kind =
    case $kindText
    of "file": vekFile
    of "dir": vekDirectory
    else: vekMissing
  VolumeEntry(name: "", kind: kind, size: size.int64)

proc decodeEntries(answer: JsObject): seq[VolumeEntry] =
  var count = 0
  {.emit: "`count` = `answer`.names.length;".}
  for i in 0 ..< count:
    var name: cstring = ""
    var kindText: cstring = ""
    {.emit: "`name` = String(`answer`.names[`i`]); `kindText` = String(`answer`.kinds[`i`]);".}
    result.add VolumeEntry(
      name: $name,
      kind: (if $kindText == "file": vekFile else: vekDirectory),
      size: 0)

proc decodeUsage(answer: JsObject): VolumeUsage =
  var known = false
  var used = 0
  var quota = 0
  {.emit: "`known` = !!`answer`.known; `used` = `answer`.used || 0; `quota` = `answer`.quota || 0;".}
  VolumeUsage(known: known, usedBytes: used.int64, quotaBytes: quota.int64)

proc toJsBytes(content: seq[byte]): JsObject =
  var array: JsObject
  let length = content.len
  {.emit: "`array` = new Uint8Array(`length`);".}
  for i in 0 ..< length:
    let b = content[i].int
    {.emit: "`array`[`i`] = `b`;".}
  array

proc newOpfsVolume*(): StoreVolume =
  ## The volume, or `unavailableVolume` when the browser has no OPFS.
  ##
  ## Returning a refusing volume rather than `nil` is what lets
  ## `web_browser.nim` fall back to `memory_volume` on a *policy* decision it
  ## can state in the UI, rather than on a nil check three frames away.
  if opfsSupport() == osUnavailable:
    return unavailableVolume(
      "this browser provides no origin-private filesystem")

  StoreVolume(
    description: "the browser's origin-private filesystem",
    durable: true,
    atomicMove: jsHasNativeMove(),
    readBytes: proc(path: string): PlatformFuture[PlatformOutcome[seq[byte]]] =
      settle(jsRead(path.cstring), "reading '" & path & "'", decodeBytes),
    writeBytes: proc(path: string; content: seq[byte]
                    ): PlatformFuture[PlatformOutcome[Nothing]] =
      settle(jsWrite(path.cstring, toJsBytes(content)),
             "writing '" & path & "'", decodeNothing),
    stat: proc(path: string): PlatformFuture[PlatformOutcome[VolumeEntry]] =
      settle(jsStat(path.cstring), "inspecting '" & path & "'", decodeStat),
    list: proc(path: string): PlatformFuture[PlatformOutcome[seq[VolumeEntry]]] =
      settle(jsList(path.cstring), "listing '" & path & "'", decodeEntries),
    createDir: proc(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
      settle(jsMkdir(path.cstring), "creating '" & path & "'", decodeNothing),
    remove: proc(path: string; recursive: bool
                ): PlatformFuture[PlatformOutcome[Nothing]] =
      settle(jsRemove(path.cstring, recursive), "removing '" & path & "'",
             decodeNothing),
    move: proc(source, destination: string
              ): PlatformFuture[PlatformOutcome[Nothing]] =
      settle(jsMove(source.cstring, destination.cstring),
             "replacing '" & destination & "'", decodeNothing),
    usage: proc(): PlatformFuture[PlatformOutcome[VolumeUsage]] =
      settle(jsUsage(), "measuring storage", decodeUsage))
