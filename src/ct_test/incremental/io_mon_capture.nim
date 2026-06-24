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
## # Launched binaries are part of the dependency set (spec §16.7.8)
##
## Per `Nim-Parallel-Test-Framework.md` §16.7.8, a test's invalidation set is
##   code deps ∪ read-file deps ∪ LAUNCHED-BINARY deps,
## transitive over the whole process tree. A launched binary (e.g. the compiler a
## test shells out to) loads via mmap/dyld, so it NEVER shows up as an
## `open`/`read` — io-mon records it as a process spawn/exec record
## (`mrProcessSpawn`/`mrProcessExec`, observation `moExecute`, binary path in
## `record.path`). `launchedBinaryPathsFromDepFile` extracts the successful,
## de-duplicated, path-sorted launched-binary set, and `readFilesFromDepFile`
## folds it into the SAME `ReadFile` dependency set as the read files (path +
## content signature). A changed launched binary thus invalidates every test that
## launched it, through the identical M4b store + root-hash fold. A
## SIP-rewritten exec path (a transient `CT_SANDBOX_TOOLS_DIR` copy the §16.7.8
## SIP redirection produced) is mapped BACK to the original system path
## (`unrewriteSipPath`), so the dependency is keyed on the real binary identity.
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

import std/[algorithm, os, osproc, sets, strtabs, tables, times]
import results

import io_mon
import native_readfiles  # ReadFile, signatureOf, NativeReadFilesFile, the shared fold input
import stackable_hooks/propagation as ct_propagation
  # sandboxToolsDir / unrewriteSipPath: map a SIP-rewritten exec path (a transient
  # CT_SANDBOX_TOOLS_DIR copy) BACK to the original system binary identity, so a
  # launched-binary dependency is recorded against the REAL binary, not the copy.

export results
export native_readfiles.ReadFile
# Re-export the shim locator so the CLI can pin REPRO_MONITOR_SHIM_LIB for the
# out-of-process snoop child it spawns in the recorder dev shell (M8).
export io_mon.findShimLibrary

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

  IoMonSnoopEnvVar* = "IO_MON"
    ## Env override for the standalone `io-mon` CLI binary path. Honoured
    ## first by `findSnoopCli`; falls back to the binary name on PATH
    ## (`io-mon`, the M8 nimble `buildSnoop` output). Set by the codetracer
    ## dev shell / `ct_test` build env when the io-mon sibling is present, and by
    ## the M8 tests to pin a freshly-built binary without an install step.

  IoMonSnoopBinaryName* = "io-mon"
    ## The PATH-discoverable name of the standalone snoop CLI (io-mon's
    ## `nimble buildSnoop` output). The runner resolves the live-capture entry
    ## point by this name when `$IO_MON` is unset.

proc findSnoopCli*(): string =
  ## Locate the standalone `io-mon` CLI binary (the M8 out-of-process snoop
  ## entry point), so the runner can drive a LIVE capture in a clean subprocess
  ## rather than in-process. Lookup order:
  ##   1. `$IO_MON` (operator / dev-shell / test pin) — used as-is if it
  ##      names an existing file.
  ##   2. `io-mon` on `$PATH` (the dev shell prepends io-mon's build/bin
  ##      when the sibling is present).
  ## Returns the absolute path of the first existing candidate, or "" when no
  ## snoop CLI is locatable (⇒ the live arm gates / fails safe — never faked).
  let pinned = getEnv(IoMonSnoopEnvVar)
  if pinned.len > 0 and fileExists(pinned):
    return absolutePath(pinned)
  let onPath = findExe(IoMonSnoopBinaryName)
  if onPath.len > 0:
    return onPath
  ""

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

proc isLaunchObservation(kind: MonitorObservationKind): bool =
  ## True for the observation kind that denotes a LAUNCHED binary — a
  ## process spawn/exec. The shim tags both `mrProcessSpawn` (posix_spawn /
  ## fork) and `mrProcessExec` (execve) with `moExecute`, carrying the launched
  ## binary path in `record.path`.
  kind == moExecute

proc launchedBinaryPathsFromDepFile*(dep: MonitorDepFile): seq[string] =
  ## Derive the LAUNCHED-BINARY path set from a captured io-mon depfile: every
  ## successful spawn/exec (`moExecute`) record's binary path, de-duplicated and
  ## path-sorted. Per spec §16.7.8 a test's invalidation set is
  ##   code deps ∪ read-file deps ∪ LAUNCHED-BINARY deps,
  ## transitive over the whole process tree — a launched binary loads via
  ## mmap/dyld, so it NEVER appears as an `open`/`read` and must be folded from
  ## the spawn/exec records explicitly.
  ##
  ## Filtering:
  ##   * `moExecute` records only (spawn / exec).
  ##   * a non-empty path (a spawn with no resolved binary path is not a usable
  ##     dependency — e.g. a bare `fork` with no exec carries no binary).
  ##   * `result >= 0`: a failed spawn names no launched binary. (The shim only
  ##     records a `posix_spawn` when it succeeded, and a `fork` parent record
  ##     carries the child pid (>0); `execve` records carry the default 0. A
  ##     negative result would denote a failed launch and is excluded.)
  ##
  ## SANDBOX → ORIGINAL mapping (spec §16.7.8 SIP redirection): a SIP-protected
  ## sub-target is redirected at spawn time to its injectable
  ## `CT_SANDBOX_TOOLS_DIR` copy, so the recorded exec path may be the transient
  ## sandbox copy. We map it BACK to the original system path so the dependency
  ## is recorded against the REAL binary identity (a change to the real
  ## `/bin/sh` must invalidate, not a change to a throwaway copy).
  let sandboxDir = ct_propagation.sandboxToolsDir()
  var launched = initOrderedTable[string, bool]()
  for rec in dep.records:
    if rec.path.len == 0:
      continue
    if not isLaunchObservation(rec.observationKind):
      continue
    if rec.result < 0:
      continue  # a failed spawn/exec names no launched binary
    # Map a sandbox-rewritten path back to the original system binary identity.
    let original = ct_propagation.unrewriteSipPath(rec.path, sandboxDir)
    launched[original] = true
  result = @[]
  for path in launched.keys:
    result.add path
  result.sort(cmp)

proc readFilesFromDepFile*(dep: MonitorDepFile): Result[seq[ReadFile], string] =
  ## Convert a captured io-mon depfile into the dependency SET in the SAME
  ## `ReadFile` shape M6a produces (path + mtime + content signature), so both
  ## sources feed one fold. This folds BOTH:
  ##   * read-file deps (read-not-written paths — `readPathsFromDepFile`), and
  ##   * LAUNCHED-BINARY deps (spawn/exec binaries — `launchedBinaryPathsFromDepFile`),
  ## per spec §16.7.8 (a test's invalidation set includes the binaries it
  ## launched, transitive over the process tree). A launched binary loads via
  ## mmap/dyld so it never appears as a read; folding it here means a changed
  ## launched binary (e.g. the compiler) invalidates every test that launched it,
  ## through the IDENTICAL M4b store + root-hash fold.
  ##
  ## io-mon captures at RUN TIME, so the "record-time" stat is the file's CURRENT
  ## on-disk stat at capture — exactly the baseline the M4b invalidation will
  ## later compare a subsequent on-disk stat against. A path (read file OR
  ## launched binary) that cannot be stat'd at capture (it vanished between
  ## observation and capture finalize) is an `Err` (⇒ re-run, fail-safe — never
  ## silently dropped). A launched binary that is ALSO a read path is folded
  ## once (the de-dup below keys on path).
  var acc: seq[ReadFile] = @[]
  var seenPaths = initHashSet[string]()

  proc addPathDep(path: string): Result[void, string] =
    ## Stat `path` at capture time and fold it as a `ReadFile` (path + mtime +
    ## content signature). Shared by the read-file and launched-binary folds so
    ## both carry the IDENTICAL content-signature shape (DRY). A path that cannot
    ## be stat'd ⇒ `Err` (fail-safe re-run). De-duplicated by path.
    if path in seenPaths:
      return ok()
    var size: int64 = 0
    var mtime: int64 = 0
    try:
      if fileExists(path):
        size = int64(getFileSize(path))
        mtime = getLastModificationTime(path).toUnix()
      else:
        # A captured dependency path that no longer exists at capture finalize:
        # we cannot establish a baseline, so be conservative (fail-safe).
        return err("captured dependency no longer present: " & path)
    except CatchableError as e:
      return err("failed to stat captured dependency " & path & ": " & e.msg)
    seenPaths.incl path
    acc.add ReadFile(path: path, mtime: mtime, hash: signatureOf(size, mtime))
    ok()

  for path in readPathsFromDepFile(dep):
    ? addPathDep(path)
  for path in launchedBinaryPathsFromDepFile(dep):
    ? addPathDep(path)
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

proc depFileToProjection*(depfilePath, traceDir: string):
    Result[seq[ReadFile], string] =
  ## Read an io-mon depfile that was already produced OUT OF PROCESS (e.g. by the
  ## standalone `io-mon` CLI run inside a recorder's dev shell), convert it
  ## into the read-file dependency SET, and write it into `traceDir` as the SAME
  ## `native_readfiles.json` projection M6a folds. This is the seam the CLI's
  ## `captureMaterializedReadFiles` uses: the snoop runs in the recorder shell and
  ## writes the depfile; the runner converts + persists it here, in-process.
  ##
  ## Fail-safe: an unreadable/corrupt depfile, a vanished captured read file, or a
  ## projection write failure is an `Err` (⇒ the caller re-runs, never a false
  ## skip). An EMPTY captured set (the macOS chained-fixups interpose gap) is a
  ## valid `ok(@[])` — it writes an empty projection and contributes no read-file
  ## dependency; the CLI's `deterministic=false` capture-gate still re-runs such a
  ## test, so an empty capture is never mistaken for "no dependencies".
  var dep: MonitorDepFile
  try:
    dep = readMonitorDepFile(depfilePath)
  except CatchableError as e:
    return err("io-mon depfile unreadable: " & e.msg)
  let reads = ? readFilesFromDepFile(dep)
  ? writeReadFilesProjection(traceDir, reads)
  ok(reads)

proc ioMonShimAvailable*(): bool =
  ## True iff the io-mon interpose shim shared library is locatable (so the LIVE
  ## capture path can run). Gates the live-injection e2e: when false, the live
  ## capture is not runnable here and the caller falls back to the fail-safe
  ## re-run rather than faking a capture.
  findShimLibrary().len > 0

proc ioMonLiveCaptureAvailable*(): bool =
  ## True iff BOTH halves of the M8 live-capture wiring are present: the
  ## interpose shim shared library (`ioMonShimAvailable`) AND the standalone
  ## `io-mon` CLI binary on PATH / `$IO_MON` (`findSnoopCli`). The
  ## out-of-process snoop binary is what lets the runner drive a live capture in
  ## a clean subprocess (the shim injected around the recorder's program, not
  ## around the runner). When either is absent the live arm gates and the caller
  ## fails safe to a re-run — NEVER a fabricated capture.
  ##
  ## NOTE (honest platform reality): availability here means the wiring is
  ## complete, NOT that the platform will actually capture. On macOS 26 / arm64e
  ## the `__DATA,__interpose` mechanism does not intercept libc calls from
  ## modern chained-fixups binaries, so a wired capture can still yield an EMPTY
  ## read set even for a freshly-built user binary. An empty captured set is
  ## still folded honestly (it just contributes no read-file dependency); the
  ## artifact's `deterministic=false` capture-gate fail-safe (in the CLI) ensures
  ## a materialized test whose reads could not be captured still re-runs.
  ioMonShimAvailable() and findSnoopCli().len > 0

proc captureViaSnoopBinary(snoopCli: string; command: seq[string];
                           depfilePath: string): Result[void, string] =
  ## Drive a live capture by invoking the standalone `io-mon` CLI OUT OF
  ## PROCESS (`snoopCli run --depfile <depfilePath> -- <command...>`). The snoop
  ## binary injects the shim around `command` in a clean subprocess and writes
  ## the RMDF depfile. The shim shared library is located by the snoop binary via
  ## `$REPRO_MONITOR_SHIM_LIB` / the canonical layout; we forward an explicit pin
  ## when one is locatable so a non-installed dev-shell shim still resolves.
  ##
  ## A launch failure or a non-zero snoop exit is an `Err` (⇒ fail-safe re-run).
  var argv = @[snoopCli, "run", "--depfile", depfilePath, "--"]
  argv.add command
  # Pin the shim for the child so it resolves without inheriting an install.
  let shimLib = findShimLibrary()
  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    childEnv[k] = v
  if shimLib.len > 0:
    childEnv[IoMonShimEnvVar] = shimLib
  var exitCode: int
  try:
    let p = startProcess(argv[0], args = argv[1 .. ^1], env = childEnv,
      options = {poParentStreams})
    exitCode = waitForExit(p)
    close(p)
  except CatchableError as e:
    return err("io-mon snoop binary launch failed: " & e.msg)
  if exitCode != 0:
    return err("io-mon snoop binary exited non-zero (" & $exitCode & ")")
  ok()

proc captureReadFilesLive*(command: seq[string];
                           depfilePath: string): Result[seq[ReadFile], string] =
  ## Run `command` (the recorded materialized-recorder process) under io-mon's
  ## LIVE interpose monitor, producing a depfile at `depfilePath`, then derive the
  ## read-file dependency set from it.
  ##
  ## M8 wiring: when the standalone `io-mon` CLI is locatable
  ## (`findSnoopCli`), the capture runs OUT OF PROCESS through that binary (the
  ## shim injected around `command` in a clean subprocess — the correct topology,
  ## since the shim must wrap the recorder's program, not the runner). When the
  ## snoop binary is absent but the shim shared library IS present, we fall back
  ## to the IN-PROCESS `runFsSnoopCli` driver (the relocated fs_snoop entry point)
  ## so the controlled-depfile / single-host path still works.
  ##
  ## GATED + FAIL-SAFE: requires at minimum the platform shim shared library
  ## (`ioMonShimAvailable`). When the shim is missing, returns an HONEST `Err`
  ## (⇒ the caller re-runs the test — fail-safe — and the live e2e is gated on
  ## this host) rather than a fabricated capture. A launch failure, a non-zero
  ## snoop exit, or an unreadable/corrupt depfile is likewise an `Err`. The
  ## platform may legitimately capture an EMPTY read set (macOS chained-fixups
  ## interpose gap) — that is returned as an empty-but-`ok` set, and the CLI's
  ## `deterministic=false` capture-gate keeps such a test re-running.
  if command.len == 0:
    return err("io-mon live capture: empty command")
  if not ioMonShimAvailable():
    return err("io-mon live capture gated: " & IoMonShimEnvVar &
      " unset and no librepro_monitor_shim found (build it via io-mon's " &
      "scripts/build_shim.sh)")
  let snoopCli = findSnoopCli()
  if snoopCli.len > 0:
    let ran = captureViaSnoopBinary(snoopCli, command, depfilePath)
    if ran.isErr:
      return err(ran.error)
  else:
    # No standalone snoop binary on PATH — fall back to the in-process driver.
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
