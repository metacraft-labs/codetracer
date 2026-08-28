## The filesystem facade.
##
## Desktop: native paths. Web: the project store (Noir-Studio.md §4).
## Container: the container's filesystem, over endpoints.
##
## ## What the signatures deliberately do NOT contain
##
## No `File`, no file descriptor, no `FileHandle`, no `walkDir` iterator. Every
## one of those is a value that only means something inside the process that
## produced it, and every one of them would make the container instantiation a
## second architecture rather than a third column. A directory listing is a
## `seq` because a remote listing arrives all at once; a read is by path
## because a remote read cannot hand back a descriptor.
##
## Reads and writes are whole-value on purpose. Streaming a 2 GB file is not a
## thing the front end does — it opens traces through the backend, which has
## its own transport — and a streaming signature would be a promise three
## instantiations would each keep differently.

import ./outcome
import ./capabilities

export outcome

type
  FsEntryKind* = enum
    fekMissing
    fekFile
    fekDirectory
    fekSymlink
    fekOther

  FsStat* = object
    kind*: FsEntryKind
    size*: int64
    modifiedMs*: int64
      ## Milliseconds since the Unix epoch. Not a `times.Time`: the web store
      ## records what it was told and a container reports its own clock, and a
      ## strongly-typed instant would imply an agreement about which clock that
      ## none of the three can make.
    readOnly*: bool

  FsDirEntry* = object
    name*: string
      ## The entry's own name, never a full path. The caller joins with
      ## `paths./` — which keeps a container's absolute paths out of the UI.
    kind*: FsEntryKind

  FsWatchEventKind* = enum
    fwkCreated
    fwkModified
    fwkDeleted
    fwkRenamed

  FsWatchEvent* = object
    kind*: FsWatchEventKind
    path*: string
    previousPath*: string
      ## Set for `fwkRenamed` only.

  FsWatchHandle* = distinct string
    ## Opaque and serialisable, so a container instantiation can mint one on
    ## its side and the front end can cancel it by name. An `int` would have
    ## worked in-process and would have had to change the day it did not.

  FileSystemFacade* = ref object
    ## A vtable rather than a typeclass or a method-dispatch hierarchy: the
    ## instantiation is chosen at run time (a test installs a fake; `ct host`
    ## installs a remote one), and every field is independently satisfiable —
    ## which is what makes `test_a_remote_instantiation_needs_no_signature_change`
    ## a cheap check rather than a rewrite.
    profile*: PlatformProfile

    readText*: proc(path: string): PlatformFuture[PlatformOutcome[string]]
    readBytes*: proc(path: string): PlatformFuture[PlatformOutcome[seq[byte]]]
    writeText*: proc(path, content: string): PlatformFuture[PlatformOutcome[Nothing]]
    writeBytes*: proc(path: string; content: seq[byte]): PlatformFuture[PlatformOutcome[Nothing]]
    appendText*: proc(path, content: string): PlatformFuture[PlatformOutcome[Nothing]]

    stat*: proc(path: string): PlatformFuture[PlatformOutcome[FsStat]]
    listDir*: proc(path: string): PlatformFuture[PlatformOutcome[seq[FsDirEntry]]]

    createDir*: proc(path: string): PlatformFuture[PlatformOutcome[Nothing]]
      ## Recursive, and succeeds when the directory already exists. The
      ## non-recursive, fails-if-present variant is the one every caller has to
      ## wrap, so the facade offers the wrapped shape only.
    remove*: proc(path: string; recursive: bool): PlatformFuture[PlatformOutcome[Nothing]]
    copy*: proc(source, destination: string): PlatformFuture[PlatformOutcome[Nothing]]
    move*: proc(source, destination: string): PlatformFuture[PlatformOutcome[Nothing]]

    realPath*: proc(path: string): PlatformFuture[PlatformOutcome[string]]
      ## Symlinks resolved against the real tree. Distinct from
      ## `paths.normalizePath`, which is textual and needs no host.
    makeTempDir*: proc(prefix: string): PlatformFuture[PlatformOutcome[string]]

    watch*: proc(path: string; recursive: bool;
                 onEvent: proc(event: FsWatchEvent)
                ): PlatformFuture[PlatformOutcome[FsWatchHandle]]
    unwatch*: proc(handle: FsWatchHandle): PlatformFuture[PlatformOutcome[Nothing]]

proc `==`*(a, b: FsWatchHandle): bool {.borrow.}
proc `$`*(handle: FsWatchHandle): string {.borrow.}

proc exists*(facade: FileSystemFacade; path: string
            ): PlatformFuture[PlatformOutcome[bool]] =
  ## Convenience over `stat`, because "does it exist" is the question callers
  ## actually ask and re-deriving it from `fekMissing` at every site is how the
  ## missing-file case gets handled three different ways.
  let statFuture = facade.stat(path)
  when defined(js):
    result = newPromise(proc(resolve: proc(v: PlatformOutcome[bool])) =
      discard statFuture.then(proc(s: PlatformOutcome[FsStat]) =
        if s.ok: resolve(succeeded(s.value.kind != fekMissing))
        else: resolve(failed[bool](s.error))))
  else:
    let promise = newFuture[PlatformOutcome[bool]]("fs.exists")
    statFuture.addCallback(proc() =
      if statFuture.failed:
        promise.complete(failed[bool](
          pkFailed, "stat failed", statFuture.readError.msg))
      else:
        let s = statFuture.read()
        if s.ok: promise.complete(succeeded(s.value.kind != fekMissing))
        else: promise.complete(failed[bool](s.error)))
    result = promise

proc unavailableFileSystem*(profile: PlatformProfile): FileSystemFacade =
  ## Every operation refuses, naming the capability. Used as the base for
  ## partial instantiations (so a new facade field is a refusal rather than a
  ## nil-call crash) and as the whole facade in the host-free build.
  FileSystemFacade(
    profile: profile,
    readText: proc(path: string): auto = resolvedUnsupported[string]("reading files"),
    readBytes: proc(path: string): auto = resolvedUnsupported[seq[byte]]("reading files"),
    writeText: proc(path, content: string): auto = resolvedUnsupported[Nothing]("writing files"),
    writeBytes: proc(path: string; content: seq[byte]): auto = resolvedUnsupported[Nothing]("writing files"),
    appendText: proc(path, content: string): auto = resolvedUnsupported[Nothing]("writing files"),
    stat: proc(path: string): auto = resolvedUnsupported[FsStat]("inspecting files"),
    listDir: proc(path: string): auto = resolvedUnsupported[seq[FsDirEntry]]("listing directories"),
    createDir: proc(path: string): auto = resolvedUnsupported[Nothing]("creating directories"),
    remove: proc(path: string; recursive: bool): auto = resolvedUnsupported[Nothing]("removing files"),
    copy: proc(source, destination: string): auto = resolvedUnsupported[Nothing]("copying files"),
    move: proc(source, destination: string): auto = resolvedUnsupported[Nothing]("moving files"),
    realPath: proc(path: string): auto = resolvedUnsupported[string]("resolving paths"),
    makeTempDir: proc(prefix: string): auto = resolvedUnsupported[string]("temporary directories"),
    watch: proc(path: string; recursive: bool;
                onEvent: proc(event: FsWatchEvent)): auto =
      resolvedUnsupported[FsWatchHandle]("watching the filesystem"),
    unwatch: proc(handle: FsWatchHandle): auto = resolvedUnsupported[Nothing]("watching the filesystem"))
