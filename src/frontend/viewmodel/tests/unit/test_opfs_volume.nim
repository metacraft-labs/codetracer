## `host/opfs_volume.nim` against a fake origin-private filesystem.
##
## **JS only, and registered in `vm-unit-js` alone** — its subject is a hard
## `{.error.}` on the C target, exactly as `host/desktop_native.nim` is on the
## JS one. That is the same split `test_platform_desktop_native.nim` already
## draws, in the opposite direction, and `ci/lib/test-lane-files.sh` records
## both.
##
## ## What is faked, and what is emphatically not
##
## The fake is `navigator.storage` — `getDirectory()` returning a directory
## handle with `getFileHandle`, `getDirectoryHandle`, `removeEntry` and
## `entries()`, and file handles with `getFile`, `createWritable` and
## (optionally) `move`. It implements the File System Access API's shapes and
## its DOMException names, because those are what `opfs_volume.nim` is written
## against.
##
## Nothing in `opfs_volume.nim` is replaced or stubbed. Every `{.importjs.}`
## body below runs unmodified: the path walk segment by segment, the
## `{create: true}` flags, the `createWritable`/`write`/`close` sequence, the
## `abort` on a failed write, the `for await` over `entries()`, the
## `handle.move` feature detection and its read-write-delete fallback, and the
## DOMException-name-to-`PlatformErrorKind` translation. A test that stubbed
## the module would leave its subject absent; this one leaves the *platform*
## absent, which is the only kind of absence a browser API test can avoid.
##
## ## Every assertion here is awaited, and that is the point
##
## An OPFS operation is genuinely pending — `settle` in `opfs_volume.nim` never
## stamps `__syncResolved`, deliberately — so `drainPlatformCallbacks` cannot
## deliver it and the synchronous `awaitOutcome` used elsewhere would report
## "never settled" rather than a result. So this suite is written as one
## `{.async.}` driver, and the harness below makes a failure inside it *fail
## the process*: an async test whose rejection nobody observes is the classic
## silent no-op, and node would otherwise exit 0 having asserted nothing.

when not defined(js):
  {.error: "test_opfs_volume.nim drives the browser OPFS implementation and " &
           "runs on the JS backend only; it is registered in vm-unit-js".}

import std/[asyncjs, jsffi, strutils]

import ../../platform/outcome
import ../../platform/store_volume
import ../../host/opfs_volume

# ---------------------------------------------------------------------------
# The harness: assertions that cannot be swallowed by an unobserved rejection
# ---------------------------------------------------------------------------

var checksRun = 0
var failures: seq[string] = @[]

proc expect(condition: bool; what: string) =
  inc checksRun
  if not condition:
    failures.add what

proc expectEq[T](actual, wanted: T; what: string) =
  inc checksRun
  if actual != wanted:
    failures.add what & " (got '" & $actual & "', wanted '" & $wanted & "')"

proc reportAndExit() =
  ## `quit 1` on any failure, and `quit 1` on *no assertions at all*, which is
  ## how an async suite fails invisibly: the driver rejects before the first
  ## check and the process still exits 0.
  echo ""
  echo "[Suite] host/opfs_volume.nim against a fake origin-private filesystem"
  if checksRun == 0:
    echo "  [FAILED] the driver ran no assertions at all"
    quit 1
  for failure in failures:
    echo "  [FAILED] " & failure
  if failures.len > 0:
    echo ""
    echo "opfs_volume: " & $failures.len & " of " & $checksRun & " check(s) failed"
    quit 1
  echo "  [OK] " & $checksRun & " check(s) against the real module"
  echo ""
  echo "opfs_volume: 0 failed, " & $checksRun & " check(s)"

# ---------------------------------------------------------------------------
# The fake platform
# ---------------------------------------------------------------------------

proc installFakeOpfs(withNativeMove: bool) =
  ## Defines `navigator.storage.getDirectory` and a `FileSystemFileHandle`
  ## constructor whose prototype does or does not carry `move`, so
  ## `opfs_volume`'s feature detection is exercised in both directions.
  var native = withNativeMove
  {.emit: """
  var makeDir = function () {
    var entries = new Map();
    var self = {
      kind: 'directory',
      getDirectoryHandle: async function (name, options) {
        var existing = entries.get(name);
        if (existing) {
          if (existing.kind !== 'directory') {
            var mismatch = new Error('not a directory');
            mismatch.name = 'TypeMismatchError';
            throw mismatch;
          }
          return existing;
        }
        if (!options || !options.create) {
          var missing = new Error(name + ' not found');
          missing.name = 'NotFoundError';
          throw missing;
        }
        var created = makeDir();
        entries.set(name, created);
        return created;
      },
      getFileHandle: async function (name, options) {
        var existing = entries.get(name);
        if (existing) {
          if (existing.kind !== 'file') {
            var mismatch = new Error('not a file');
            mismatch.name = 'TypeMismatchError';
            throw mismatch;
          }
          return existing;
        }
        if (!options || !options.create) {
          var missing = new Error(name + ' not found');
          missing.name = 'NotFoundError';
          throw missing;
        }
        var created = new globalThis.FileSystemFileHandle(name, self);
        entries.set(name, created);
        return created;
      },
      removeEntry: async function (name, options) {
        var existing = entries.get(name);
        if (!existing) {
          var missing = new Error(name + ' not found');
          missing.name = 'NotFoundError';
          throw missing;
        }
        entries.delete(name);
      },
      entries: function () {
        var pairs = Array.from(entries.entries());
        var i = 0;
        return { [Symbol.asyncIterator]: function () {
          return { next: function () {
            if (i >= pairs.length) { return Promise.resolve({done: true}); }
            var pair = pairs[i++];
            return Promise.resolve({done: false, value: [pair[0], pair[1]]});
          }};
        }};
      },
      __entries: entries
    };
    return self;
  };

  globalThis.FileSystemFileHandle = function (name, parent) {
    this.kind = 'file';
    this.name = name;
    this.__parent = parent;
    this.__bytes = new Uint8Array(0);
  };
  globalThis.FileSystemFileHandle.prototype.getFile = async function () {
    var bytes = this.__bytes;
    return {
      size: bytes.length,
      arrayBuffer: async function () { return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length); }
    };
  };
  globalThis.FileSystemFileHandle.prototype.createWritable = async function () {
    var handle = this;
    // The real API truncates when the writable OPENS. Reproduced, because it
    // is the fact that makes write-temp-then-replace necessary.
    handle.__bytes = new Uint8Array(0);
    var pending = null;
    return {
      write: async function (data) {
        if (globalThis.__ctOpfsQuota &&
            data.length > globalThis.__ctOpfsQuota) {
          var full = new Error('quota');
          full.name = 'QuotaExceededError';
          throw full;
        }
        pending = new Uint8Array(data);
      },
      close: async function () { if (pending) { handle.__bytes = pending; } },
      abort: async function () { pending = null; }
    };
  };
  if (`native`) {
    globalThis.FileSystemFileHandle.prototype.move = async function (dir, name) {
      this.__parent.__entries.delete(this.name);
      this.name = name;
      this.__parent = dir;
      dir.__entries.set(name, this);
    };
  }

  var root = makeDir();
  globalThis.navigator = globalThis.navigator || {};
  globalThis.navigator.storage = {
    getDirectory: async function () { return root; },
    estimate: async function () { return {usage: 1234, quota: 100000}; }
  };
  globalThis.__ctOpfsRoot = root;
  """.}

proc uninstallOpfs() =
  {.emit: """
  if (globalThis.navigator) { delete globalThis.navigator.storage; }
  delete globalThis.FileSystemFileHandle;
  """.}

proc setFakeQuota(maxWriteBytes: int) =
  {.emit: "globalThis.__ctOpfsQuota = `maxWriteBytes`;".}

proc clearFakeQuota() =
  {.emit: "globalThis.__ctOpfsQuota = 0;".}

proc rawBytesAt(path: string): string =
  ## Read the fake's state directly, so an assertion about what landed does not
  ## go back through the module under test.
  var captured: cstring = ""
  let p = path.cstring
  {.emit: """
  try {
    var dir = globalThis.__ctOpfsRoot;
    var parts = `p`.split('/').filter(function (s) { return s.length > 0; });
    for (var i = 0; i < parts.length - 1; i++) { dir = dir.__entries.get(parts[i]); }
    var handle = dir.__entries.get(parts[parts.length - 1]);
    `captured` = String.fromCharCode.apply(null, Array.from(handle.__bytes));
  } catch (e) { `captured` = '<no such entry>'; }
  """.}
  $captured

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = text[i].byte

proc textOf(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i in 0 ..< bytes.len: result[i] = bytes[i].char

# ---------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------

proc drive() {.async.} =
  # --- support detection -------------------------------------------------
  uninstallOpfs()
  expect(opfsSupport() == osUnavailable,
    "with no navigator.storage, OPFS reports unavailable")
  let refusing = newOpfsVolume()
  expect(not refusing.durable,
    "the unavailable volume does not claim to be durable")
  let refused = await refusing.readBytes("a")
  expect(not refused.ok and refused.error.kind == pkNotSupported,
    "the unavailable volume refuses by name rather than crashing")

  installFakeOpfs(withNativeMove = true)
  expect(opfsSupport() == osAvailable,
    "with navigator.storage present, OPFS reports available")

  let volume = newOpfsVolume()
  expect(volume.durable, "the OPFS volume declares itself durable")
  expect(volume.atomicMove,
    "with FileSystemFileHandle.move present, atomicMove is claimed")

  # --- write, read, and the nested path walk -----------------------------
  let written = await volume.writeBytes(
    "projects/p1/tree/src/main.nr", bytesOf("fn main() {}"))
  expect(written.ok, "a write through four nested directories succeeds")
  expectEq(rawBytesAt("projects/p1/tree/src/main.nr"), "fn main() {}",
    "the bytes reached the fake filesystem at the right path")

  let readBack = await volume.readBytes("projects/p1/tree/src/main.nr")
  expect(readBack.ok, "the file reads back")
  expectEq(textOf(readBack.value), "fn main() {}",
    "the bytes round-trip through getFile/arrayBuffer")

  # --- DOMException translation, which is the module's other real job ----
  let missing = await volume.readBytes("projects/p1/tree/absent.nr")
  expect(not missing.ok, "a missing file fails")
  expectEq($missing.error.kind, $pkNotFound,
    "a NotFoundError becomes pkNotFound, not a generic failure")

  let missingDir = await volume.list("projects/nope")
  expect(not missingDir.ok and missingDir.error.kind == pkNotFound,
    "listing a missing directory is pkNotFound")

  setFakeQuota(4)
  let overQuota = await volume.writeBytes(
    "projects/p1/tree/big.nr", bytesOf("far too many bytes"))
  clearFakeQuota()
  expect(not overQuota.ok, "a write past the quota fails")
  expectEq($overQuota.error.kind, $pkQuotaExceeded,
    "a QuotaExceededError becomes pkQuotaExceeded")
  expectEq(rawBytesAt("projects/p1/tree/big.nr"), "",
    "the aborted write left the file empty rather than partially written")

  # --- stat ---------------------------------------------------------------
  let statFile = await volume.stat("projects/p1/tree/src/main.nr")
  expect(statFile.ok and statFile.value.kind == vekFile,
    "stat reports a file as a file")
  expectEq(statFile.value.size, 12'i64, "stat reports the file's size")
  let statDir = await volume.stat("projects/p1/tree")
  expect(statDir.ok and statDir.value.kind == vekDirectory,
    "stat reports a directory as a directory")
  let statMissing = await volume.stat("projects/p1/tree/absent.nr")
  expect(statMissing.ok and statMissing.value.kind == vekMissing,
    "stat reports a missing entry as missing rather than failing")

  # --- list, over the async iterator -------------------------------------
  discard await volume.writeBytes(
    "projects/p1/tree/Nargo.toml", bytesOf("[package]"))
  let listed = await volume.list("projects/p1/tree")
  expect(listed.ok, "a directory lists")
  var names: seq[string] = @[]
  var kinds: seq[string] = @[]
  for entry in listed.value:
    names.add entry.name
    kinds.add (if entry.kind == vekFile: "file" else: "dir")
  expect("src" in names and "Nargo.toml" in names and "big.nr" in names,
    "the listing names every entry, walked through `for await ... entries()`")
  expectEq(names.len, 3, "the listing names exactly the entries present")
  expect("dir" in kinds and "file" in kinds,
    "the listing distinguishes files from directories")

  # --- move, through the native path -------------------------------------
  discard await volume.writeBytes("projects/p1/tmp/w1", bytesOf("staged"))
  let moved = await volume.move(
    "projects/p1/tmp/w1", "projects/p1/tree/src/main.nr")
  expect(moved.ok, "a native move replaces the destination")
  expectEq(rawBytesAt("projects/p1/tree/src/main.nr"), "staged",
    "the destination now holds the staged bytes")
  expectEq(rawBytesAt("projects/p1/tmp/w1"), "<no such entry>",
    "the source is gone after the move")

  # --- remove --------------------------------------------------------------
  let removed = await volume.remove("projects/p1/tree/Nargo.toml", false)
  expect(removed.ok, "a file is removed")
  expectEq(rawBytesAt("projects/p1/tree/Nargo.toml"), "<no such entry>",
    "the removed file is gone from the fake filesystem")
  let removeMissing = await volume.remove("projects/p1/tree/absent.nr", false)
  expect(not removeMissing.ok and removeMissing.error.kind == pkNotFound,
    "removing a missing file is pkNotFound")

  # --- usage ---------------------------------------------------------------
  let usage = await volume.usage()
  expect(usage.ok and usage.value.known, "storage.estimate is reported")
  expectEq(usage.value.usedBytes, 1234'i64, "usage carries the reported use")
  expectEq(usage.value.quotaBytes, 100000'i64, "usage carries the quota")

  # --- the fallback move, on an engine without handle.move ----------------
  #
  # The second half of the feature detection, and the reason it is not a
  # version check: the same engine has shipped `move` for files and not for
  # directories, and `atomicMove` is what `project_store` consults.
  uninstallOpfs()
  installFakeOpfs(withNativeMove = false)
  let noMove = newOpfsVolume()
  expect(not noMove.atomicMove,
    "without FileSystemFileHandle.move, atomicMove is NOT claimed")
  discard await noMove.writeBytes("t/a", bytesOf("original"))
  discard await noMove.writeBytes("t/b", bytesOf("replacement"))
  let fallback = await noMove.move("t/b", "t/a")
  expect(fallback.ok, "the read-write-delete fallback moves the file")
  expectEq(rawBytesAt("t/a"), "replacement",
    "the fallback replaced the destination's contents")
  expectEq(rawBytesAt("t/b"), "<no such entry>",
    "the fallback removed the source")

proc main() {.async.} =
  try:
    await drive()
  except CatchableError as error:
    failures.add "the driver raised: " & error.msg
  except Exception as error:
    failures.add "the driver raised: " & error.msg
  reportAndExit()

discard main()
