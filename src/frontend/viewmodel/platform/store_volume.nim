## The substrate the project store is built on — and the reason it is smaller
## than `FileSystemFacade`.
##
## NS2 (Noir-Studio.milestones.org) asks for a "directory-tree project store
## over OPFS". OPFS is not a filesystem: it has no symlinks, no realpath, no
## file watching, no temporary directory the platform reclaims, no permissions
## and no atomic rename in every engine. Building `ProjectStore` directly on
## `FileSystemFacade` would therefore mean an OPFS implementation of half a
## dozen operations that OPFS cannot express, each refusing — and then the
## store above it branching on which refusals it got. So the dependency runs
## the other way round: `StoreVolume` is the eight operations OPFS *does* have,
## `project_store.nim` adds atomicity, versioning, locking and quota over them,
## and `web_platform.nim` presents the result as a `FileSystemFacade`.
##
## ## Why this is a vtable of `proc`s and not a concept
##
## Same reason `FileSystemFacade` is (see `fs.nim`): the implementation is
## chosen at run time. A tab picks OPFS when OPFS is there and the in-memory
## volume when it is not (Noir-Studio.md §4.2, the third row), and both live in
## the same binary. A static typeclass would make the fallback a second build.
##
## ## Every operation is a `PlatformFuture`, and here that is not ceremony
##
## OPFS's directory and file handles are obtained through promises in every
## engine; `createWritable` is a promise; `getFileHandle` is a promise. A
## synchronous signature could not have been honoured, which is the constraint
## NS1 wrote down and NS2 is the first to actually hit.

import ./outcome
import ./paths

export outcome

type
  VolumeEntryKind* = enum
    vekMissing
    vekFile
    vekDirectory

  VolumeEntry* = object
    name*: string
      ## The entry's own name, never a path. Same rule as `FsDirEntry`.
    kind*: VolumeEntryKind
    size*: int64
      ## Zero for directories and for missing entries.

  VolumeUsage* = object
    ## What the origin is using and what it may use.
    ##
    ## `known` is separate from the numbers because
    ## `navigator.storage.estimate()` is an *estimate* the browser is entitled
    ## to round, delay or decline, and a volume that reports `0 / 0` as though
    ## it were a measurement would make "check headroom before a large write"
    ## refuse every write. NS2 asks for storage usage to be surfaced; it does
    ## not ask us to invent it when the platform declines to say.
    known*: bool
    usedBytes*: int64
    quotaBytes*: int64

  StoreVolume* {.requiresInit.} = ref object
    ## `{.requiresInit.}` for the reason `fs.nim` records at length: without it
    ## a new operation added here defaults to `nil` at every construction site
    ## and the OPFS implementation silently does not have it.
    description*: string
      ## Shown to a user, e.g. "the browser's origin-private filesystem".
    durable*: bool
      ## Whether the bytes survive a reload. **Not** whether they survive
      ## eviction — nothing survives eviction, which is the whole point of
      ## Noir-Studio.md §4.1's three tiers.

    readBytes*: proc(path: string): PlatformFuture[PlatformOutcome[seq[byte]]]
    writeBytes*: proc(path: string; content: seq[byte]
                     ): PlatformFuture[PlatformOutcome[Nothing]]
    stat*: proc(path: string): PlatformFuture[PlatformOutcome[VolumeEntry]]
    list*: proc(path: string): PlatformFuture[PlatformOutcome[seq[VolumeEntry]]]
    createDir*: proc(path: string): PlatformFuture[PlatformOutcome[Nothing]]
    remove*: proc(path: string; recursive: bool
                 ): PlatformFuture[PlatformOutcome[Nothing]]
    move*: proc(source, destination: string
               ): PlatformFuture[PlatformOutcome[Nothing]]
      ## Replaces the destination if it exists. This is the operation
      ## `project_store.nim`'s write-temp-then-replace turns on, so an engine
      ## whose `move` is not atomic must say so rather than emulate it with
      ## copy-then-delete — see `host/opfs_volume.nim`, which does exactly that
      ## and is why `atomicMove` exists below.
    atomicMove*: bool
      ## Whether `move` replaces the destination in one step. False means the
      ## store must not claim `test_interrupted_writes_leave_the_previous_state_intact`
      ## for this volume, and `project_store.nim` reports it rather than
      ## pretending.
    usage*: proc(): PlatformFuture[PlatformOutcome[VolumeUsage]]

# ---------------------------------------------------------------------------
# Path normalisation, shared by every implementation
# ---------------------------------------------------------------------------

proc rfind(s: string; c: char): int =
  result = -1
  for i in countdown(s.len - 1, 0):
    if s[i] == c: return i

proc volumePath*(path: string): string =
  ## The canonical form of a path inside a volume: `/`-separated, no leading
  ## slash, no `.` or `..` segments left, no trailing slash.
  ##
  ## Escaping the volume is not an error to be reported, it is a shape that
  ## cannot be expressed: `normalizePath` collapses `..` textually and anything
  ## still leading with `..` is clamped to the root. A store whose paths could
  ## climb out of it would defeat `capFilesystemArbitraryPaths` being absent
  ## from the web profile.
  var normalized = normalizePath(path)
  while normalized.len > 0 and normalized[0] == '/':
    normalized = normalized[1 .. ^1]
  while normalized.len > 1 and normalized[^1] == '/':
    normalized = normalized[0 .. ^2]
  if normalized == "." or normalized == "..":
    return ""
  var built = ""
  var segment = ""
  var i = 0
  while i <= normalized.len:
    if i == normalized.len or normalized[i] == '/':
      if segment == ".." :
        # Climb, but never above the root.
        let cut = rfind(built, '/')
        if cut >= 0: built = built[0 ..< cut]
        else: built = ""
      elif segment == "." or segment.len == 0:
        discard
      else:
        if built.len > 0: built.add '/'
        built.add segment
      segment = ""
    else:
      segment.add normalized[i]
    inc i
  built

proc volumeParent*(path: string): string =
  let normalized = volumePath(path)
  let cut = rfind(normalized, '/')
  if cut < 0: "" else: normalized[0 ..< cut]

proc volumeName*(path: string): string =
  let normalized = volumePath(path)
  let cut = rfind(normalized, '/')
  if cut < 0: normalized else: normalized[cut + 1 .. ^1]

proc isUnder*(ancestor, path: string): bool =
  ## Whether `path` is `ancestor` or lies inside it. Both are normalised first,
  ## so `isUnder("a", "ab")` is false where a naive prefix test would say true.
  let a = volumePath(ancestor)
  let p = volumePath(path)
  if a.len == 0: return true
  if p == a: return true
  p.len > a.len and p[0 ..< a.len] == a and p[a.len] == '/'

proc unavailableVolume*(why: string): StoreVolume =
  ## A volume where nothing works, naming the reason. The honest answer for a
  ## build that has no storage at all — as opposed to the in-memory volume,
  ## which works and loses your data, and must never be confused with this.
  StoreVolume(
    description: why,
    durable: false,
    atomicMove: false,
    readBytes: proc(path: string): auto =
      resolvedUnsupported[seq[byte]]("reading from " & why),
    writeBytes: proc(path: string; content: seq[byte]): auto =
      resolvedUnsupported[Nothing]("writing to " & why),
    stat: proc(path: string): auto =
      resolvedUnsupported[VolumeEntry]("inspecting " & why),
    list: proc(path: string): auto =
      resolvedUnsupported[seq[VolumeEntry]]("listing " & why),
    createDir: proc(path: string): auto =
      resolvedUnsupported[Nothing]("creating directories in " & why),
    remove: proc(path: string; recursive: bool): auto =
      resolvedUnsupported[Nothing]("removing from " & why),
    move: proc(source, destination: string): auto =
      resolvedUnsupported[Nothing]("moving within " & why),
    usage: proc(): auto =
      resolvedUnsupported[VolumeUsage]("measuring " & why))
