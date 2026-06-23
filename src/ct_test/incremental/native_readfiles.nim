## MCR/RR accessed-file extractor — the M6a deliverable of the
## Incremental-Test-Runner campaign.
##
## A test's READ-FILE dependency set is "every file the recorded process read at
## runtime". For the native / Multi-Core-Recorder (MCR) and rr replay backends
## this set is ALREADY PRESENT in the standard recording format — the recorder
## captures every mapped/opened file together with its on-disk stat (size +
## mtime) at record time. This module is the EXTRACTOR that derives that set
## from the recording, returning each read file's path plus a content signature
## (the recorded mtime/size, hashed) so a later run can tell whether the file
## changed and re-run the test.
##
## # Where the read-file set lives in an MCR/RR recording (the rr trace format)
##
## rr serializes its trace with Cap'n Proto (`codetracer-rr/src/rr_trace.capnp`).
## The accessed files are recorded in two record kinds:
##
##   * The **`mmaps` stream** — a sequence of `MMap` records, one per memory
##     mapping the recorded process created. Each `MMap` carries (rr_trace.capnp
##     lines 173-209):
##       - `fsname`     — the mapped file's real path on the recording host
##                        (the file the process `mmap`'d, e.g. a data file, a
##                        shared library, the executable itself).
##       - `statSize`   — the file's size at record time (`stat.st_size`).
##       - `statMTime`  — the file's mtime at record time (`stat.st_mtime`).
##       - `statMode`   — the file's mode at record time.
##       - `source.file.backingFileName` — how to fetch the bytes during replay
##                        (an absolute path or one relative to the trace dir).
##     A mapping whose `source` is `zero`/`trace` (anonymous / data-in-trace) has
##     no backing FILE on disk and is NOT a read-file dependency; only the
##     `source.file` (file-backed) mappings name a real external file.
##
##   * The **`OpenedFd` records** — `struct OpenedFd { fd, path, device, inode }`
##     (rr_trace.capnp lines 309-318): the absolute pathname of a "special" file
##     the process opened (e.g. via `openat`). The MCR emulator equivalently
##     records `open`/`openat` syscalls (see the native recorder's
##     `ct_emulator/strace_parser.nim` + `syscall_replay.nim`, which decode the
##     `read`/`open`/`mmap` syscall stream).
##
## So the read-file set is `{ fsname of every file-backed MMap } ∪ { path of
## every OpenedFd that was read }`, each carrying the size+mtime rr captured at
## record time. That stat is exactly the baseline the M4b file-index
## invalidation (`invalidation.foldFileInvalidation`) compares against the
## current on-disk file — a changed mtime (default) or content hash (per config)
## re-runs the reader test.
##
## # The fixture shape (a documented prototype projection)
##
## A LIVE rr/MCR recording + replay is Linux/rr-specific and is NOT runnable in
## this dev shell (macOS arm64 has no rr / Intel PT). So — exactly as
## `native_trace.nim` hand-crafts the native CALLTRACE in a documented JSON shape
## modeled on the recorder's in-memory `CallNode`/`CallRecord` — M6a parses the
## read-file set from a JSON PROJECTION of the rr `MMap`/`OpenedFd` records that a
## native trace dir carries:
##
##   `<traceDir>/native_readfiles.json`
##
## whose shape is a thin, EXPLICITLY-DOCUMENTED projection of the rr trace's
## accessed-file records (there is no canonical on-disk JSON form upstream — rr's
## records are Cap'n Proto and the MCR write-log is binary — so this JSON is a
## clearly-labelled minimal prototype form, NOT an invented competing wire
## format). It maps field-for-field onto `rr_trace.capnp`:
##
## ```json
## {
##   "reads": [
##     { "path": "/abs/path/to/data.json",
##       "source": "file",      // "file" | "trace" | "zero" — only "file" counts
##       "statSize": 128,        // rr MMap.statSize / OpenedFd backing size
##       "statMTime": 1700000000,// rr MMap.statMTime (record-time mtime, seconds)
##       "contentHash": "ab12…"  // OPTIONAL: a content hash captured at record
##                               //   time. When absent it is derived from
##                               //   (statSize, statMTime) — the rr-recorded
##                               //   identity — so the baseline is never empty.
##     }
##   ]
## }
## ```
##
## Mapping to the rr trace records:
##   * `reads[].path`        ⇐ `MMap.fsname` (file-backed mapping) OR
##                             `OpenedFd.path`. The dependency identity.
##   * `reads[].source`      ⇐ `MMap.source` union tag. Only `"file"` (a
##                             file-backed mapping / a real opened file) is a
##                             read-file dependency; `"zero"`/`"trace"` mappings
##                             are anonymous or data-in-trace and are DROPPED.
##   * `reads[].statSize`    ⇐ `MMap.statSize` (record-time `st_size`).
##   * `reads[].statMTime`   ⇐ `MMap.statMTime` (record-time `st_mtime`).
##   * `reads[].contentHash` ⇐ an optional explicit content hash a real extractor
##                             can compute from the trace's backing copy
##                             (`source.file.backingFileName`). When omitted, the
##                             extractor derives the record-time SIGNATURE from
##                             `(statSize, statMTime)` — the identity rr itself
##                             records — so a changed file (new size or mtime)
##                             changes the signature and re-runs the test.
##
## # The `ReadFile` convention (DOCUMENTED)
##
## A read-file dependency is keyed on its PATH and carries:
##   * `path`  — the file's path (`MMap.fsname` / `OpenedFd.path`).
##   * `mtime` — the recorded mtime (`statMTime`). Feeds the store's file index
##               (`FileEntry.mtime`) so the default mtime-mode M4b invalidation
##               has its baseline.
##   * `hash`  — the record-time content SIGNATURE (the explicit `contentHash`
##               when present, else `signatureOf(statSize, statMTime)`). Feeds the
##               root-hash fold + the `FileSignal.byHash` baseline so the
##               hash-mode M4b invalidation has its baseline too.
##
## # Fail-safe invariant (NON-NEGOTIABLE — never a false skip)
##
## Any structural problem — missing/unreadable `native_readfiles.json`, malformed
## JSON, a non-object root, a missing `reads` array, a read entry without a
## non-empty string `path`, a non-integer stat — yields an `Err`. The CALLER
## (the artifact build) turns that into a re-run of the affected test, NEVER a
## silent skip. The reader never raises. An absent `native_readfiles.json` (a
## trace that simply has NO read-file projection, e.g. the M0 interpreted
## fixtures) is reported distinctly via `hasReadFiles`, so the artifact build can
## treat "no read-file record" as an empty dependency set (correct: a recording
## that records no file reads has no read-file dependency) WITHOUT confusing it
## with a CORRUPT record (which must re-run).

import std/[json, os, algorithm, tables, hashes, strutils]
import results

export results

type
  ReadFile* = object
    ## One read-file dependency extracted from an MCR/RR recording.
    path*: string   ## The read file's path (`MMap.fsname` / `OpenedFd.path`).
    mtime*: int64   ## Record-time mtime (`MMap.statMTime`).
    hash*: string   ## Record-time content signature (see the module doc).

const
  NativeReadFilesFile* = "native_readfiles.json"
    ## The hand-crafted read-file projection a native trace dir carries in this
    ## prototype (see the module doc for the shape + real-rr mapping). A native
    ## trace dir is otherwise marked by `detectBackend`'s structural signals; this
    ## file carries the accessed-file payload.

func signatureOf*(statSize: int64; statMTime: int64): string =
  ## Derive a stable record-time content SIGNATURE from the rr-recorded stat
  ## `(size, mtime)` — the identity rr itself captures for a mapped/opened file.
  ## This is the baseline content hash when the projection carries no explicit
  ## `contentHash`. It is rendered with the SAME `std/hashes.hash` → lowercase-hex
  ## representation the engine's `shallowHash`/`deepHash` use, so a read-file
  ## signature and a function shallow hash are folded with one consistent scheme.
  ##
  ## A file whose size OR mtime changed gets a different signature ⇒ its reader
  ## test re-runs. (Two distinct edits that preserve BOTH size and mtime would
  ## collide — but that is precisely the documented `FileSignal.byHash` case the
  ## explicit `contentHash` covers; the mtime/size signature is the recorded
  ## baseline rr provides, never a false skip relative to rr's own model.)
  var buf = ""
  buf.add $statSize
  buf.add '\x00'
  buf.add $statMTime
  toHex(cast[uint](hash(buf))).toLowerAscii()

proc hasReadFiles*(traceDir: string): bool =
  ## True iff `traceDir` carries a read-file projection. Lets the caller tell a
  ## trace with NO read-file record (an empty dependency set — correct) apart
  ## from a CORRUPT one (which the extractor returns as an `Err` ⇒ re-run).
  fileExists(traceDir / NativeReadFilesFile)

proc readFileDepsNative*(traceDir: string): Result[seq[ReadFile], string] =
  ## Extract the read-file dependency SET from a native (MCR/RR) recording's
  ## accessed-file projection (`<traceDir>/native_readfiles.json`).
  ##
  ## Returns the de-duplicated, path-sorted set of `ReadFile`s — only file-backed
  ## reads (`source == "file"`); anonymous / data-in-trace mappings are dropped.
  ## Each carries the record-time mtime + content signature.
  ##
  ## Any structural problem yields an `Err` (⇒ re-run upstream, never a skip). An
  ## ABSENT projection file is itself an `Err` here — callers that want to treat
  ## "no read-file record" as an empty set should gate on `hasReadFiles` first
  ## (the M0 interpreted fixtures carry no projection and SHOULD decode to `@[]`).
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  let p = traceDir / NativeReadFilesFile
  if not fileExists(p):
    return err("native read-files file not found: " & p)
  var raw: string
  try:
    raw = readFile(p)
  except CatchableError as e:
    return err("failed to read " & p & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & p & ": " & e.msg)
  if root.kind != JObject:
    return err(NativeReadFilesFile & " root must be a JSON object")
  if not root.hasKey("reads") or root["reads"].kind != JArray:
    return err(NativeReadFilesFile & " must have an array 'reads' field")

  # Collect the read-file SET (de-duplicated by path). A real recording can map
  # the same file several times (multiple mmaps / re-opens); the dependency set
  # is the SET of paths, so we de-dup by path and keep the FIRST record-time stat
  # for each (the stat is the file's identity at record time — all records of the
  # same file in one recording carry the same on-disk stat).
  var seen = initTable[string, bool]()
  var resultSeq: seq[ReadFile] = @[]
  for i, entry in root["reads"].elems:
    if entry.kind != JObject:
      return err(NativeReadFilesFile & " reads[" & $i & "] is not an object")
    if not entry.hasKey("path") or entry["path"].kind != JString:
      return err(NativeReadFilesFile & " reads[" & $i & "] missing string 'path'")
    let path = entry["path"].getStr()
    if path.len == 0:
      return err(NativeReadFilesFile & " reads[" & $i & "] has an empty 'path'")

    # The `source` union tag: only a file-backed mapping / real opened file is a
    # read-file dependency. An anonymous (`zero`) or data-in-trace (`trace`)
    # mapping names no external file and is dropped. A missing `source` defaults
    # to "file" (an `OpenedFd` is always a real file; the field is optional).
    let source =
      if entry.hasKey("source"):
        if entry["source"].kind != JString:
          return err(NativeReadFilesFile & " reads[" & $i &
            "] 'source' must be a string")
        entry["source"].getStr()
      else: "file"
    if source notin ["file", "zero", "trace"]:
      return err(NativeReadFilesFile & " reads[" & $i & "] has unknown source '" &
        source & "' (expected file|zero|trace)")
    if source != "file":
      continue  # anonymous / data-in-trace: not an external read-file dependency

    # Record-time stat. `statSize`/`statMTime` must be integers when present (rr
    # always records them; a malformed type is a corrupt record ⇒ Err ⇒ re-run).
    var statSize: int64 = 0
    if entry.hasKey("statSize"):
      if entry["statSize"].kind != JInt:
        return err(NativeReadFilesFile & " reads[" & $i & "] 'statSize' must be an integer")
      statSize = entry["statSize"].getBiggestInt()
    var statMTime: int64 = 0
    if entry.hasKey("statMTime"):
      if entry["statMTime"].kind != JInt:
        return err(NativeReadFilesFile & " reads[" & $i & "] 'statMTime' must be an integer")
      statMTime = entry["statMTime"].getBiggestInt()

    # Content signature: the explicit `contentHash` when present (a real extractor
    # can hash the trace's backing copy), else derived from the rr-recorded
    # (size, mtime) identity so the baseline is NEVER empty.
    let contentHash =
      if entry.hasKey("contentHash"):
        if entry["contentHash"].kind != JString:
          return err(NativeReadFilesFile & " reads[" & $i &
            "] 'contentHash' must be a string")
        let h = entry["contentHash"].getStr()
        if h.len == 0:
          return err(NativeReadFilesFile & " reads[" & $i &
            "] has an empty 'contentHash'")
        h
      else:
        signatureOf(statSize, statMTime)

    if not seen.hasKeyOrPut(path, true):
      resultSeq.add ReadFile(path: path, mtime: statMTime, hash: contentHash)

  # An empty set is VALID (a file-backed-free recording reads no external file).
  resultSeq.sort(proc (a, b: ReadFile): int = cmp(a.path, b.path))
  ok(resultSeq)

proc readFileDepsNativeOrEmpty*(traceDir: string): Result[seq[ReadFile], string] =
  ## Convenience for the artifact build: extract the read-file set, treating an
  ## ABSENT projection as an EMPTY set (a trace with no read-file record has no
  ## read-file dependency — correct, not a failure) while still surfacing a
  ## CORRUPT projection as an `Err` (⇒ re-run, fail-safe). Use this when read-file
  ## tracking is BEST-EFFORT additive over an existing decision path; use
  ## `readFileDepsNative` when the projection's presence is required.
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  if not hasReadFiles(traceDir):
    return ok(newSeq[ReadFile]())
  readFileDepsNative(traceDir)
