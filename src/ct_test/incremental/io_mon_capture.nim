## io-mon live read-file capture for MATERIALIZED-trace recorders — the M6b
## deliverable of the Incremental-Test-Runner campaign.
##
## # Why a second read-file source
##
## M6a derives a test's READ-FILE dependency set from the RECORDING itself: the
## native / Multi-Core-Recorder (MCR) and rr backends capture every mapped/opened
## file (with its record-time stat) in the standard trace format, and
## `native_readfiles.nim` extracts it from the `native_readfiles.json` projection.
##
## MATERIALIZED-trace recorders (Python, Ruby, JavaScript — the engine's
## `tbSourceInterpreted` backend) carry NO such syscall/accessed-file record in
## the trace. The trace records the executed source, not the files the process
## read off disk. So for those recorders the runner must CAPTURE the read files a
## different way: by running the recorded process under the shared `io-mon`
## filesystem monitor (M5/M6b), whose syscall-interpose shim observes every
## `open`/`read`/`stat` the process performs and writes them to a binary RMDF
## depfile.
##
## # One fold, two sources (the invariant this module preserves)
##
## The captured read-file set must fold into the EXACT SAME machinery M6a wired:
## the M4a `CtfsStore` file index, the M4b `foldFileInvalidation`, and the per-test
## root hash (`root_hash.rootHashOfDepsAndReadFiles`). Rather than add a parallel
## fold, this module CONVERTS the io-mon capture into the SAME
## `native_readfiles.json` projection M6a's extractor (`readFileDepsNativeOrEmpty`)
## already consumes, and writes it into the materialized trace dir. From that point
## the read-file set flows through one code path regardless of which source
## produced it — a changed captured read file re-runs its reader test through the
## identical M4b invalidation + root-hash fold, with the M6a fail-safe intact.
##
## # The read/write classification (DRY with the shim's own model)
##
## io-mon's depfile records each filesystem observation with an
## `observationKind`. The interpose shim tags a file opened/`read` as
## `moFileOpen`/`moFileRead` and a file written/created/truncated/appended as
## `moFileWrite` (see io_mon/shim/{macos_interpose,linux_preload,windows_interpose}).
## A READ-FILE DEPENDENCY is a path the process READ that it did NOT also write —
## an output file the test creates and then reads back is not a dependency on its
## PRIOR content. So the read-file set is
##   { path observed via moFileOpen/moFileRead } \ { path observed via moFileWrite }.
## This mirrors the standard build-system depfile model (inputs = read-not-written).
##
## # Live capture is GATED (the platform shim), never faked
##
## Driving the live interpose end-to-end (the shim actually injecting into a real
## recorded process via DYLD_INSERT_LIBRARIES / LD_PRELOAD) needs the platform
## shim shared library (`librepro_monitor_shim.{dylib,so,dll}`) built and, on
## macOS, the process must not be SIP-protected / hardened in a way that strips
## the injection. When the shim is unavailable, `captureReadFilesLive` returns an
## HONEST `Err` (the caller re-runs the test — fail-safe — and the live e2e is
## gated), NEVER a fabricated capture. The depfile→read-file-set conversion
## (`readFilesFromDepFile`, `writeReadFilesProjection`) is platform-independent and
## is exercised over a controlled depfile even where live injection cannot run.
##
## # Fail-safe invariant (NON-NEGOTIABLE — never a false skip)
##
## Every failure mode — shim missing, snoop run failed, depfile unreadable/corrupt,
## a captured path that cannot be stat'd now — yields an `Err`. The caller
## (`buildArtifactMaterialized`) turns that into a re-run, never a silent skip.

import std/[algorithm, os, sets, tables, times]
import results

import io_mon
import native_readfiles  # ReadFile, signatureOf, NativeReadFilesFile, the shared fold input

export results
export native_readfiles.ReadFile

type
  CapturedReadSet* = object
    ## The read-file dependency set captured for a materialized-recorder run,
    ## ready to fold into the SAME file index + root hash M6a feeds.
    reads*: seq[ReadFile]

const
  IoMonShimEnvVar* = "REPRO_MONITOR_SHIM_LIB"
    ## The env var io-mon's `findShimLibrary` honours first when locating the
    ## interpose shim shared library. Re-exported so the runner / tests can pin a
    ## freshly-built shim without an install step.

proc isReadObservation(kind: MonitorObservationKind): bool =
  ## True for the observation kinds that denote a file the process READ (an
  ## input). `moFileOpen` is a read-flagged open (the shim emits `moFileWrite`
  ## for write/create/truncate/append opens — see `observationForOpen` in the
  ## shim), and `moFileRead` is an explicit read.
  kind == moFileOpen or kind == moFileRead

proc isWriteObservation(kind: MonitorObservationKind): bool =
  ## True for the observation kinds that denote a file the process WROTE (an
  ## output). A path that was written is excluded from the read-dependency set.
  kind == moFileWrite

proc readPathsFromDepFile*(dep: MonitorDepFile): seq[string] =
  ## Derive the READ-FILE path set from a captured io-mon depfile: every path
  ## observed via a read (open/read) that was NOT also written, de-duplicated and
  ## path-sorted. A successful syscall only (`result >= 0`) — a failed open names
  ## no real input file. Empty paths are dropped (a record with no resolved path,
  ## e.g. a read on an anonymous fd, is not a file dependency).
  var written = initHashSet[string]()
  for rec in dep.records:
    if rec.path.len > 0 and isWriteObservation(rec.observationKind):
      written.incl rec.path
  var reads = initOrderedTable[string, bool]()
  for rec in dep.records:
    if rec.path.len == 0:
      continue
    if not isReadObservation(rec.observationKind):
      continue
    if rec.result < 0:
      continue  # a failed open/read names no real input file
    if rec.path in written:
      continue  # the process WROTE this file: it is an output, not a dependency
    reads[rec.path] = true
  result = @[]
  for path in reads.keys:
    result.add path
  result.sort(cmp)

proc readFilesFromDepFile*(dep: MonitorDepFile): Result[seq[ReadFile], string] =
  ## Convert a captured io-mon depfile into the read-file dependency SET in the
  ## SAME `ReadFile` shape M6a produces (path + mtime + content signature), so
  ## both sources feed one fold.
  ##
  ## io-mon captures at RUN TIME, so the "record-time" stat is the file's CURRENT
  ## on-disk stat at capture — exactly the baseline the M4b invalidation will
  ## later compare a subsequent on-disk stat against. A path that cannot be
  ## stat'd at capture (it vanished between read and capture finalize) is an `Err`
  ## (⇒ re-run, fail-safe — never silently dropped).
  var acc: seq[ReadFile] = @[]
  for path in readPathsFromDepFile(dep):
    var size: int64 = 0
    var mtime: int64 = 0
    try:
      if fileExists(path):
        size = int64(getFileSize(path))
        mtime = getLastModificationTime(path).toUnix()
      else:
        # A captured read path that no longer exists at capture finalize: we
        # cannot establish a baseline, so be conservative.
        return err("captured read file no longer present: " & path)
    except CatchableError as e:
      return err("failed to stat captured read file " & path & ": " & e.msg)
    acc.add ReadFile(path: path, mtime: mtime, hash: signatureOf(size, mtime))
  acc.sort(proc (a, b: ReadFile): int = cmp(a.path, b.path))
  ok(acc)

proc writeReadFilesProjection*(traceDir: string;
                               reads: seq[ReadFile]): Result[void, string] =
  ## Persist a captured read-file set into the materialized trace dir as the SAME
  ## `native_readfiles.json` projection M6a's `readFileDepsNativeOrEmpty`
  ## consumes, so the io-mon-captured set folds through the IDENTICAL file index +
  ## root-hash path — only the SOURCE differs.
  ##
  ## Each read is emitted as a file-backed entry carrying an explicit
  ## `contentHash` (the capture-time signature) so the projection round-trips back
  ## to the same `ReadFile` set without re-deriving it. The JSON is written with
  ## explicit escaping (no `std/json` dependency cycle needed for this tiny
  ## shape).
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)
  proc esc(s: string): string =
    result = ""
    for c in s:
      case c
      of '"': result.add "\\\""
      of '\\': result.add "\\\\"
      of '\n': result.add "\\n"
      of '\r': result.add "\\r"
      of '\t': result.add "\\t"
      else: result.add c
  var body = "{\n  \"reads\": [\n"
  for i, rf in reads:
    body.add "    { \"path\": \"" & esc(rf.path) & "\", \"source\": \"file\", " &
      "\"statMTime\": " & $rf.mtime & ", \"contentHash\": \"" & esc(rf.hash) & "\" }"
    if i < reads.high:
      body.add ","
    body.add "\n"
  body.add "  ]\n}\n"
  try:
    writeFile(traceDir / NativeReadFilesFile, body)
  except CatchableError as e:
    return err("failed to write read-file projection: " & e.msg)
  ok()

proc ioMonShimAvailable*(): bool =
  ## True iff the io-mon interpose shim shared library is locatable (so the LIVE
  ## capture path can run). Gates the live-injection e2e: when false, the live
  ## capture is not runnable here and the caller falls back to the fail-safe
  ## re-run rather than faking a capture.
  findShimLibrary().len > 0

proc captureReadFilesLive*(command: seq[string];
                           depfilePath: string): Result[seq[ReadFile], string] =
  ## Run `command` (the recorded materialized-recorder process) under io-mon's
  ## LIVE interpose monitor, producing a depfile at `depfilePath`, then derive the
  ## read-file dependency set from it.
  ##
  ## GATED: requires the platform shim shared library (`ioMonShimAvailable`). When
  ## the shim is missing, returns an HONEST `Err` (⇒ the caller re-runs the test —
  ## fail-safe — and the live e2e is gated on this host) rather than a fabricated
  ## capture. A non-zero snoop exit or an unreadable/corrupt depfile is likewise an
  ## `Err`.
  if command.len == 0:
    return err("io-mon live capture: empty command")
  if not ioMonShimAvailable():
    return err("io-mon live capture gated: " & IoMonShimEnvVar &
      " unset and no librepro_monitor_shim found (build it via io-mon's " &
      "scripts/build_shim.sh)")
  var args = @["run", "--depfile", depfilePath, "--"]
  args.add command
  var exitCode: int
  try:
    exitCode = runFsSnoopCli("ct-test-io-mon", args)
  except CatchableError as e:
    return err("io-mon snoop run failed: " & e.msg)
  if exitCode != 0:
    return err("io-mon snoop run exited non-zero (" & $exitCode & ")")
  var dep: MonitorDepFile
  try:
    dep = readMonitorDepFile(depfilePath)
  except CatchableError as e:
    return err("io-mon depfile unreadable: " & e.msg)
  readFilesFromDepFile(dep)
