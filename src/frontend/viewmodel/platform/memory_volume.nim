## The in-memory volume: Noir-Studio.md §4.2's third row, and the substrate
## every store test runs against.
##
## ## It is a product surface first and a test double second
##
## §4.2: "OPFS unavailable — private browsing, an unsupported engine: the
## session runs against an in-memory store and **says so before the first
## keystroke**, because work will be lost on close. Never a blank failure."
## That is this module. It is shipped code, not a fixture, and
## `durable = false` is the honest declaration that drives the announcement in
## `store_durability.nim`.
##
## Its second job follows for free. Because the in-memory case is a real
## platform condition, the store's whole contract — atomic replace, quota,
## schema refusal, one writer — has to hold over it, so testing the store
## against this volume is not testing a stand-in. The OPFS volume adds
## persistence and nothing else.
##
## ## Every operation resolves synchronously, and that is deliberate
##
## `resolved` uses `newCompletedFuture`, which stamps `__syncResolved` so
## `async_compat.onComplete` delivers inline (see `outcome.nim`, and NS1's note
## that a bare `newPromise` here would make every JS assertion a silent
## no-op). So a suite can drive the whole store synchronously on both backends
## through `test_platform_facade.nim`'s `awaitOutcome` shape — which is what
## lets `vm-unit-js` cover the store at all, since node has no OPFS.
##
## ## The fault knobs are the point of several NS2 verifications
##
## `test_interrupted_writes_leave_the_previous_state_intact` and
## `e2e_project_survives_reload_and_crash` both need a write that fails *in the
## middle*, and a quota that is actually reachable. Neither is observable
## against a volume that always succeeds, so the volume grows two knobs rather
## than the tests growing a mock. They live on `MemoryVolume`, not on
## `StoreVolume`, so no production caller can reach them.

import std/[tables, algorithm]

import ./outcome
import ./store_volume

export store_volume

type
  MemoryVolume* = ref object
    ## The backing state, separate from the `StoreVolume` vtable built over it,
    ## so a test can hold both: the vtable to drive the store, the object to
    ## inject a fault or read what actually landed.
    files: Table[string, seq[byte]]
    directories: Table[string, bool]
    quotaBytes*: int64
      ## Zero means unlimited. A positive value makes `QuotaExceededError`
      ## reachable — §4.4's "a write that fails on QuotaExceededError discards
      ## the temporary file and leaves the original intact".
    failWritesUnder*: string
      ## A path prefix whose writes fail with `pkFailed`. This models the tab
      ## being closed mid-write: the bytes never land. Empty disables it.
    failMoves*: bool
      ## Makes `move` fail. This models the *other* half of an interrupted
      ## atomic replace — the temp file is written and the rename never
      ## happens — which is the case that must leave the original untouched.
    writeCount*: int
    moveCount*: int

proc find(s: string; c: char): int =
  ## Local rather than `std/strutils`, for the same reason `paths.nim` carries
  ## its own `startsWith`: this module is in the host-free surface and every
  ## import is one more edge the gate has to reason about.
  result = -1
  for i in 0 ..< s.len:
    if s[i] == c: return i

proc newMemoryVolume*(quotaBytes: int64 = 0): MemoryVolume =
  result = MemoryVolume(
    files: initTable[string, seq[byte]](),
    directories: initTable[string, bool](),
    quotaBytes: quotaBytes)
  result.directories[""] = true

proc usedBytes*(volume: MemoryVolume): int64 =
  for _, content in volume.files:
    result += content.len.int64

proc ensureParents(volume: MemoryVolume; path: string) =
  var current = volumeParent(path)
  while current.len > 0:
    volume.directories[current] = true
    current = volumeParent(current)
  volume.directories[""] = true

proc entryKind(volume: MemoryVolume; path: string): VolumeEntryKind =
  let normalized = volumePath(path)
  if normalized.len == 0: return vekDirectory
  if volume.files.hasKey(normalized): return vekFile
  if volume.directories.hasKey(normalized): return vekDirectory
  vekMissing

proc fileNames*(volume: MemoryVolume): seq[string] =
  ## Every file path in the volume, sorted. For assertions about what a failed
  ## write left behind — a temp file that survived a crash is a defect, and a
  ## test that cannot see it cannot say so.
  for path, _ in volume.files:
    result.add path
  result.sort()

proc rawRead*(volume: MemoryVolume; path: string): seq[byte] =
  volume.files.getOrDefault(volumePath(path), @[])

proc rawWrite*(volume: MemoryVolume; path: string; content: seq[byte]) =
  ## Writes bypassing the quota and the fault knobs. For a test that needs to
  ## *arrange* a state the store would refuse to create — a store written by a
  ## newer schema version, a truncated working-tree file — without the
  ## arrangement itself going through the code under test.
  let normalized = volumePath(path)
  volume.ensureParents(normalized)
  volume.files[normalized] = content

proc rawRemove*(volume: MemoryVolume; path: string) =
  volume.files.del(volumePath(path))

proc asVolume*(volume: MemoryVolume): StoreVolume =
  ## The `StoreVolume` view. Everything above is invisible through it.

  proc readBytes(path: string): PlatformFuture[PlatformOutcome[seq[byte]]] =
    let normalized = volumePath(path)
    if volume.files.hasKey(normalized):
      resolvedOk(volume.files[normalized])
    elif volume.directories.hasKey(normalized):
      resolvedErr[seq[byte]](pkInvalidArgument,
        "'" & normalized & "' is a directory, not a file")
    else:
      resolvedErr[seq[byte]](pkNotFound, "'" & normalized & "' does not exist")

  proc writeBytes(path: string;
                  content: seq[byte]): PlatformFuture[PlatformOutcome[Nothing]] =
    let normalized = volumePath(path)
    if normalized.len == 0:
      return resolvedErr[Nothing](pkInvalidArgument,
        "the volume root is not a file")
    if volume.directories.hasKey(normalized):
      return resolvedErr[Nothing](pkInvalidArgument,
        "'" & normalized & "' is a directory, not a file")
    if volume.failWritesUnder.len > 0 and
       isUnder(volume.failWritesUnder, normalized):
      return resolvedErr[Nothing](pkFailed,
        "the write to '" & normalized & "' was interrupted",
        "injected fault")
    if volume.quotaBytes > 0:
      let existing = volume.files.getOrDefault(normalized, @[]).len.int64
      let after = volume.usedBytes - existing + content.len.int64
      if after > volume.quotaBytes:
        return resolvedErr[Nothing](pkQuotaExceeded,
          "there is not enough room in the store for '" & normalized & "'",
          "QuotaExceededError")
    inc volume.writeCount
    volume.ensureParents(normalized)
    volume.files[normalized] = content
    resolvedOk()

  proc stat(path: string): PlatformFuture[PlatformOutcome[VolumeEntry]] =
    let normalized = volumePath(path)
    let kind = volume.entryKind(normalized)
    var size: int64 = 0
    if kind == vekFile:
      size = volume.files[normalized].len.int64
    resolvedOk(VolumeEntry(name: volumeName(normalized), kind: kind, size: size))

  proc list(path: string): PlatformFuture[PlatformOutcome[seq[VolumeEntry]]] =
    let normalized = volumePath(path)
    if volume.entryKind(normalized) != vekDirectory:
      return resolvedErr[seq[VolumeEntry]](pkNotFound,
        "'" & normalized & "' is not a directory in the store")
    var seen = initTable[string, VolumeEntry]()
    let prefixLen = if normalized.len == 0: 0 else: normalized.len + 1
    for filePath, content in volume.files:
      if not isUnder(normalized, filePath) or filePath == normalized: continue
      let rest = filePath[prefixLen .. ^1]
      let cut = rest.find('/')
      if cut < 0:
        seen[rest] = VolumeEntry(
          name: rest, kind: vekFile, size: content.len.int64)
      else:
        let head = rest[0 ..< cut]
        if not seen.hasKey(head):
          seen[head] = VolumeEntry(name: head, kind: vekDirectory, size: 0)
    for dirPath, _ in volume.directories:
      if not isUnder(normalized, dirPath) or dirPath == normalized: continue
      let rest = dirPath[prefixLen .. ^1]
      let cut = rest.find('/')
      let head = if cut < 0: rest else: rest[0 ..< cut]
      if not seen.hasKey(head):
        seen[head] = VolumeEntry(name: head, kind: vekDirectory, size: 0)
    var names: seq[string] = @[]
    for name, _ in seen:
      names.add name
    names.sort()
    var entries: seq[VolumeEntry] = @[]
    for name in names:
      entries.add seen[name]
    resolvedOk(entries)

  proc createDir(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let normalized = volumePath(path)
    if volume.files.hasKey(normalized):
      return resolvedErr[Nothing](pkAlreadyExists,
        "'" & normalized & "' is already a file")
    volume.ensureParents(normalized)
    if normalized.len > 0:
      volume.directories[normalized] = true
    resolvedOk()

  proc remove(path: string;
              recursive: bool): PlatformFuture[PlatformOutcome[Nothing]] =
    let normalized = volumePath(path)
    if normalized.len == 0:
      return resolvedErr[Nothing](pkInvalidArgument,
        "the volume root cannot be removed")
    case volume.entryKind(normalized)
    of vekMissing:
      resolvedErr[Nothing](pkNotFound, "'" & normalized & "' does not exist")
    of vekFile:
      volume.files.del(normalized)
      resolvedOk()
    else:
      var children: seq[string] = @[]
      for filePath, _ in volume.files:
        if isUnder(normalized, filePath): children.add filePath
      var subdirs: seq[string] = @[]
      for dirPath, _ in volume.directories:
        if dirPath != normalized and isUnder(normalized, dirPath):
          subdirs.add dirPath
      if not recursive and (children.len > 0 or subdirs.len > 0):
        return resolvedErr[Nothing](pkConflict,
          "'" & normalized & "' is not empty")
      for child in children: volume.files.del(child)
      for subdir in subdirs: volume.directories.del(subdir)
      volume.directories.del(normalized)
      resolvedOk()

  proc move(source, destination: string
           ): PlatformFuture[PlatformOutcome[Nothing]] =
    let from0 = volumePath(source)
    let to0 = volumePath(destination)
    if volume.failMoves:
      return resolvedErr[Nothing](pkFailed,
        "the replace of '" & to0 & "' was interrupted", "injected fault")
    if not volume.files.hasKey(from0):
      return resolvedErr[Nothing](pkNotFound,
        "'" & from0 & "' does not exist")
    if volume.directories.hasKey(to0):
      return resolvedErr[Nothing](pkInvalidArgument,
        "'" & to0 & "' is a directory")
    inc volume.moveCount
    volume.ensureParents(to0)
    volume.files[to0] = volume.files[from0]
    volume.files.del(from0)
    resolvedOk()

  proc usage(): PlatformFuture[PlatformOutcome[VolumeUsage]] =
    resolvedOk(VolumeUsage(
      known: true,
      usedBytes: volume.usedBytes,
      quotaBytes: volume.quotaBytes))

  # `atomicMove: true` even though nothing here is crash-safe, and the
  # distinction is worth stating: `atomicMove` claims the *replace* is one step,
  # which it is — the table entry moves or it does not. Durability is the
  # separate `durable: false`, and conflating the two would let the store report
  # a working-tree tier this volume cannot provide.
  StoreVolume(
    description: "an in-memory store held by this tab",
    durable: false,
    atomicMove: true,
    readBytes: readBytes,
    writeBytes: writeBytes,
    stat: stat,
    list: list,
    createDir: createDir,
    remove: remove,
    move: move,
    usage: usage)
