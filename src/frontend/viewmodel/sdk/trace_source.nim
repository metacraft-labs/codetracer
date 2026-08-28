## sdk/trace_source.nim
##
## `TraceSource` — where a `DebuggerSession` gets its trace bytes from.
##
## This is the Embed SDK's answer to "the consumer configures where bytes
## come from" (CodeTracer-Embed-SDK.md §3.2, "Network policy, endpoints,
## auth" is deliberately *not* in the SDK). The SDK never picks a URL, never
## contacts a CodeTracer host, and never learns what the bytes *mean*: a
## trace is a container of steps, and resolving anything else — a chain's
## transaction, say — to a container is one layer up, in the Client SDK
## (BlockTracer/Client-SDK.md §1).
##
## The four kinds named by CodeTracer-Embed-SDK.md §3.1 are:
##
##   `http-range`  a container served over HTTP with byte-range support
##   `opfs`        a container already in the browser's Origin Private FS
##   `bytes`       a container already in memory
##   `custom`      a `BlockSource` escape hatch, so a consumer whose storage
##                 the SDK has never heard of can still be replayed
##
## A fifth kind, `local-folder`, is this repository's native analogue: the
## on-disk trace folder that `replay-server` loads via the DAP `launch`
## argument `traceFolder`. It is not in §3.1 because §3.1 describes the
## browser package, but it is the shape every native headless session uses
## today and leaving it out would have meant the native seam bypassing
## `TraceSource` entirely — which is exactly the drift this type exists to
## prevent.
##
## Works on both the C and JS backends: nothing here touches the filesystem,
## the network or the DOM. Turning a `TraceSource` into actual bytes is the
## transport's job (`BackendService`), not this module's.

import std/json

type
  TraceSourceKind* = enum
    ## How the trace container is reachable. The wire spellings are the
    ## strings the DAP `launch` argument carries, so they are part of the
    ## contract rather than an implementation detail.
    tskLocalFolder = "local-folder"
      ## A trace folder on the machine running the replay engine. Native
      ## only; a browser session can never produce one.
    tskHttpRange = "http-range"
      ## A `.ct` container served over HTTP with `Range` support.
    tskOpfs = "opfs"
      ## A container in the browser's Origin Private File System.
    tskBytes = "bytes"
      ## A container already resident in memory.
    tskCustom = "custom"
      ## A consumer-supplied `BlockSource`.

  BlockSource* = ref object
    ## The `custom` escape hatch of CodeTracer-Embed-SDK.md §3.1.
    ##
    ## "Block" here means a *byte block of the container* — the unit the
    ## CTFS reader fetches (see `src/db-backend/src/ctfs_trace_reader/`).
    ## It has nothing to do with a blockchain block, and the SDK has no
    ## concept of one (§3.2, last row).
    ##
    ## A consumer implements the two procs and the SDK asks for ranges; it
    ## never asks where they came from.
    name*: string
      ## Human-readable identity, used only in error messages so a failure
      ## names the source the consumer configured rather than a bare index.
    lengthProc*: proc(): int64 {.closure.}
      ## Total container length in bytes, or a negative value when the
      ## source cannot report it.
    readRangeProc*: proc(offset: int64; length: int): seq[byte] {.closure.}
      ## Read `length` bytes at `offset`. May return fewer bytes at EOF.

  TraceSource* = object
    ## A fully-specified place to read one trace container from.
    case kind*: TraceSourceKind
    of tskLocalFolder:
      folder*: string
        ## Absolute or relative path to the trace folder.
    of tskHttpRange:
      url*: string
        ## Base URL of the container. The SDK issues range requests against
        ## it and nothing else; it adds no headers of its own and performs
        ## no auth (§3.2).
    of tskOpfs:
      opfsPath*: string
        ## Path within the Origin Private File System.
    of tskBytes:
      bytes*: seq[byte]
        ## The container itself.
    of tskCustom:
      blockSource*: BlockSource
        ## The consumer's reader.

  TraceSourceDefect* = object of ValueError
    ## Raised by `validate` when a `TraceSource` cannot possibly be opened —
    ## an empty URL, a `custom` source with no reader. This is a programming
    ## error in the consumer's construction, not a runtime failure of the
    ## trace, so it is distinct from `DebuggerSessionError`.

# ---------------------------------------------------------------------------
# Constructors
#
# Named constructors rather than raw object construction, so that adding a
# field to a kind does not break every call site and so that the wire spelling
# stays in one place.
# ---------------------------------------------------------------------------

proc localFolderTrace*(folder: string): TraceSource =
  ## A trace folder on the replay engine's own filesystem.
  TraceSource(kind: tskLocalFolder, folder: folder)

proc httpRangeTrace*(url: string): TraceSource =
  ## A container served over HTTP with byte-range support.
  TraceSource(kind: tskHttpRange, url: url)

proc opfsTrace*(opfsPath: string): TraceSource =
  ## A container in the browser's Origin Private File System.
  TraceSource(kind: tskOpfs, opfsPath: opfsPath)

proc bytesTrace*(bytes: seq[byte]): TraceSource =
  ## A container already in memory. Works with no network at all
  ## (CodeTracer-Embed-SDK.md §8, "Offline").
  TraceSource(kind: tskBytes, bytes: bytes)

proc customTrace*(source: BlockSource): TraceSource =
  ## A consumer-supplied reader.
  TraceSource(kind: tskCustom, blockSource: source)

proc newBlockSource*(name: string;
                     length: proc(): int64 {.closure.};
                     readRange: proc(offset: int64;
                                     length: int): seq[byte] {.closure.}): BlockSource =
  ## Build a `custom` reader. Both procs are required; `validate` rejects a
  ## source missing either, because the alternative is a nil-call inside the
  ## replay engine with no way back to the consumer's code.
  BlockSource(name: name, lengthProc: length, readRangeProc: readRange)

# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------

proc describe*(source: TraceSource): string =
  ## A short, log-safe description. Deliberately does not print `bytes`
  ## contents or a full URL query string.
  case source.kind
  of tskLocalFolder: "local-folder:" & source.folder
  of tskHttpRange: "http-range:" & source.url
  of tskOpfs: "opfs:" & source.opfsPath
  of tskBytes: "bytes:" & $source.bytes.len & "B"
  of tskCustom:
    if source.blockSource.isNil: "custom:<nil>"
    else: "custom:" & source.blockSource.name

proc isValid*(source: TraceSource): bool =
  ## Whether the source is complete enough to attempt an open.
  case source.kind
  of tskLocalFolder: source.folder.len > 0
  of tskHttpRange: source.url.len > 0
  of tskOpfs: source.opfsPath.len > 0
  of tskBytes: source.bytes.len > 0
  of tskCustom:
    (not source.blockSource.isNil) and
      (not source.blockSource.lengthProc.isNil) and
      (not source.blockSource.readRangeProc.isNil)

proc validate*(source: TraceSource) =
  ## Raise `TraceSourceDefect` when the source cannot be opened.
  ##
  ## Called by `DebuggerSession.launch` before anything is sent to the
  ## backend, so a mis-constructed source fails at the consumer's call site
  ## with a message naming the kind — not later, inside a worker, as a
  ## `SecurityError` from a stack the consumer did not write
  ## (CodeTracer-Embed-SDK.md §5.1, "Failure must be legible").
  if not source.isValid:
    raise newException(TraceSourceDefect,
      "TraceSource of kind '" & $source.kind &
      "' is incomplete: " & source.describe())

# ---------------------------------------------------------------------------
# Wire form
# ---------------------------------------------------------------------------

proc toLaunchArgs*(source: TraceSource): JsonNode =
  ## The DAP `launch` arguments for this source.
  ##
  ## `local-folder` maps to `traceFolder`, which is what `replay-server`
  ## deserialises today (`src/db-backend/src/dap_server.rs`), so the native
  ## path keeps working byte-for-byte.
  ##
  ## The browser kinds map to a `traceSource` object. `bytes` and `custom`
  ## carry no payload in the JSON: the container bytes and the consumer's
  ## reader are handed to the transport out of band (a `postMessage`
  ## transfer, not a base64 blob in a DAP request). The JSON names the kind
  ## so the engine knows which binding to expect, and the transport is
  ## responsible for having made it.
  case source.kind
  of tskLocalFolder:
    %*{"traceFolder": source.folder}
  of tskHttpRange:
    %*{"traceSource": {"kind": $source.kind, "url": source.url}}
  of tskOpfs:
    %*{"traceSource": {"kind": $source.kind, "path": source.opfsPath}}
  of tskBytes:
    %*{"traceSource": {"kind": $source.kind, "byteLength": source.bytes.len}}
  of tskCustom:
    %*{"traceSource": {"kind": $source.kind,
                       "name": (if source.blockSource.isNil: ""
                                else: source.blockSource.name)}}
