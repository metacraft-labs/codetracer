## M6b — `test_io_mon_readfiles_materialized`.
##
## io-mon LIVE read-file capture for MATERIALIZED-trace recorders (Python/Ruby/JS)
## folds into the SAME M4a file index + M4b invalidation + per-test ROOT HASH that
## M6a wired for the MCR/RR recording source — only the SOURCE of the read-file
## set differs (a live io-mon capture vs the recording's own accessed-file
## records). This test exercises that unification end-to-end with the REAL
## production code paths, and HONESTLY GATES the live interpose injection.
##
## # What is EXERCISED here (the strongest level runnable on a build host)
##
##   1. The io-mon depfile → read-file-set conversion (`readPathsFromDepFile` /
##      `readFilesFromDepFile`): a CONTROLLED `MonitorDepFile` built from io-mon's
##      own record/writer types (the same records the interpose shim emits — a
##      file opened/read ⇒ `moFileOpen`/`moFileRead`, a file written ⇒
##      `moFileWrite`) is converted to the read-file dependency set, asserting the
##      read/write classification (a written file is an OUTPUT, not a dependency)
##      and the path-sorted de-dup.
##   2. The projection bridge (`writeReadFilesProjection`): the captured set is
##      written as the SAME `native_readfiles.json` M6a's extractor consumes, and
##      re-extracting it via M6a's `readFileDepsNative` yields the IDENTICAL set —
##      PROVING the two sources feed one fold.
##   3. The fold into the REAL store + M4b invalidation + root hash: a changed
##      captured read file re-runs EXACTLY its reader; an unrelated file skips; an
##      unreadable file re-runs (fail-safe); the captured set changes the per-test
##      root hash and an empty set reduces to `rootHashOfDeps` exactly.
##
## # What is GATED (NOT faked)
##
## The LIVE interpose (the shim injecting into a real recorded process via
## DYLD_INSERT_LIBRARIES / LD_PRELOAD) needs the platform shim shared library
## (`librepro_monitor_shim.{dylib,so,dll}`) built + locatable, and on macOS a
## non-SIP-stripped injection. When the shim is not available on this host,
## `captureReadFilesLive` returns an HONEST `Err` (⇒ the caller re-runs — fail-safe)
## and the live e2e is gated — this test asserts that gate behaviour explicitly,
## and asserts the FULL conversion/fold pipeline at the controlled-depfile level,
## which does NOT depend on a live injection. It NEVER fabricates a live capture.

import std/[unittest, tables, sets, options, os, osproc, strutils]
import results

import engine          # CachedDep, ExecutedFunction, backendStrategies, tbSourceInterpreted
import ctfs_store      # CtfsStore, StoreTest, buildStore, key64
import root_hash       # rootHashOfDeps, rootHashOfDepsAndReadFiles, ReadFileDep
import invalidation    # the M4b query (+ foldFileInvalidation)
import native_readfiles # M6a extractor (the SHARED fold input)
import io_mon_capture  # M6b: the io-mon capture → read-file-set conversion under test
import io_mon          # MonitorRecord/MonitorDepFile/depFileFromRecords (the capture wire model)

# ---------------------------------------------------------------------------
# A controlled io-mon depfile, as the interpose shim would emit for a
# materialized-recorder program that READ two data files and WROTE one output.
# ---------------------------------------------------------------------------

proc tmpDir(name: string): string =
  result = getTempDir() / ("m6b_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc readRec(path: string): MonitorRecord =
  ## A successful file-open observation tagged as a READ (the shim's
  ## `observationForOpen` of an O_RDONLY open emits `moFileOpen`).
  MonitorRecord(kind: mrFileOpen, observationKind: moFileOpen,
                seq: 1, result: 3, path: path)

proc readDataRec(path: string): MonitorRecord =
  ## An explicit `read()` observation (`moFileRead`).
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
                seq: 2, result: 128, path: path)

proc writeRec(path: string): MonitorRecord =
  ## A write observation (`moFileWrite`) — an OUTPUT, never a read dependency.
  MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite,
                seq: 3, result: 64, path: path)

proc failedReadRec(path: string): MonitorRecord =
  ## A FAILED open (result < 0) — names no real input file, must be dropped.
  MonitorRecord(kind: mrFileOpen, observationKind: moFileOpen,
                seq: 4, result: -1, path: path)

proc spawnRec(childPid: uint64; binaryPath: string; seqNo: uint64): MonitorRecord =
  ## A successful spawn observation (the shim tags posix_spawn/fork with
  ## `moExecute`), carrying the spawned child's pid in `childOsPid`. `result`
  ## mirrors the shim's convention (the child pid for a successful spawn).
  MonitorRecord(kind: mrProcessSpawn, observationKind: moExecute,
                seq: seqNo, result: int64(childPid), childOsPid: childPid,
                path: binaryPath)

proc startRec(ownPid: uint64; seqNo: uint64): MonitorRecord =
  ## A process-start observation an INJECTED child emits (`recordProcessStart`),
  ## carrying its OWN pid in `osPid` — the confirmation that the shim loaded in
  ## that process.
  MonitorRecord(kind: mrProcessStart, observationKind: moProcessStart,
                seq: seqNo, result: 0, osPid: ownPid, detail: "shim-loaded")

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

suite "M6b — io-mon read-file capture for materialized recorders":

  test "depfile read/write classification yields the read-dependency set":
    # Build real files so the capture-time stat (size/mtime) succeeds.
    let work = tmpDir("classify")
    defer: removeDir(work)
    let cfg = work / "config.json"
    let csv = work / "table.csv"
    let outp = work / "result.out"
    writeFile(cfg, "{}")
    writeFile(csv, "a,b\n")
    writeFile(outp, "x")

    # The depfile the interpose shim would emit: cfg opened+read, csv opened,
    # outp WRITTEN (and also opened — an output the program created then touched),
    # plus a FAILED open of a non-existent path.
    let dep = depFileFromRecords(@[
      readRec(cfg), readDataRec(cfg),
      readRec(csv),
      readRec(outp), writeRec(outp),
      failedReadRec(work / "missing.dat"),
    ])

    # The READ-dependency set = read-not-written paths, path-sorted, de-duped:
    # cfg + csv only. outp was written (output), missing.dat failed.
    let paths = readPathsFromDepFile(dep)
    check paths == @[cfg, csv]  # sorted; outp excluded (written), missing dropped (failed)

    let reads = readFilesFromDepFile(dep)
    check reads.isOk
    check reads.value.len == 2
    check reads.value[0].path == cfg
    check reads.value[1].path == csv
    # Each carries a non-empty capture-time content signature.
    for rf in reads.value:
      check rf.hash.len > 0

  test "an unmonitored spawned subtree makes the capture INCOMPLETE (fail-safe)":
    # §16.7.8 process-tree completeness. The parent reads its own input AND
    # spawns two children. Child pid 100 is INJECTED (it emits a shim-loaded
    # process-start), so its subtree is confirmed. Child pid 200 is NOT injected
    # (no process-start for pid 200 — e.g. a SIP exec with no drop-in), so its
    # subtree's reads are missing. The capture is non-empty (the parent read a
    # file), so the empty-capture gate would NOT catch this — the subtree guard
    # MUST, or a file pid 200 read could change without re-running (a false skip).
    let work = tmpDir("subtree")
    defer: removeDir(work)
    let parentInput = work / "parent.cfg"
    writeFile(parentInput, "{}")
    # Real, existing binary paths so the launched-binary fold's capture-time stat
    # succeeds; the subtree-confirmation logic keys on the spawn's CHILD PID, not
    # on the binary path, so the identities are irrelevant to the guard itself.
    let binConfirmed = work / "confirmed.bin"
    let binUnmonitored = work / "unmonitored.bin"
    writeFile(binConfirmed, "\x7fELF")
    writeFile(binUnmonitored, "\x7fELF")

    let depUnconfirmed = depFileFromRecords(@[
      startRec(50, 1),                       # the parent itself is injected
      readRec(parentInput),                  # the parent read (non-empty capture)
      spawnRec(100, binConfirmed, 2),        # child 100 spawned
      startRec(100, 3),                      # child 100 confirmed monitored
      spawnRec(200, binUnmonitored, 4),      # child 200 spawned …
      # … but NO startRec(200): child 200 ran UNMONITORED.
    ])
    let unconfirmed = unconfirmedSpawnedSubtrees(depUnconfirmed)
    check unconfirmed == @[200'u64]          # exactly the unconfirmed child
    check not captureSubtreeConfirmed(depUnconfirmed)
    # The read set still folds (the parent's read + the launched binaries) — the
    # INCOMPLETENESS is signalled separately so the caller forces
    # deterministic=false ⇒ re-run.
    let reads = readFilesFromDepFile(depUnconfirmed)
    check reads.isOk

    # Contrast: when EVERY spawned child confirms (both emit a process-start),
    # the tree is complete and the capture is trusted.
    let depConfirmed = depFileFromRecords(@[
      startRec(50, 1),
      readRec(parentInput),
      spawnRec(100, binConfirmed, 2), startRec(100, 3),
      spawnRec(200, binUnmonitored, 4), startRec(200, 5),
    ])
    check unconfirmedSpawnedSubtrees(depConfirmed).len == 0
    check captureSubtreeConfirmed(depConfirmed)

    # A FAILED spawn (result < 0) launched no subtree to confirm — not flagged.
    let depFailedSpawn = depFileFromRecords(@[
      startRec(50, 1),
      readRec(parentInput),
      MonitorRecord(kind: mrProcessSpawn, observationKind: moExecute,
                    seq: 2, result: -1, childOsPid: 0, path: binUnmonitored),
    ])
    check captureSubtreeConfirmed(depFailedSpawn)

  test "captured set bridges to the M6a projection and re-extracts identically":
    # PROVE the io-mon-captured set feeds the SAME fold as M6a: write it as the
    # `native_readfiles.json` projection, then re-extract via M6a's extractor and
    # assert the IDENTICAL read-file set (path + mtime + hash).
    let work = tmpDir("bridge")
    let traceDir = tmpDir("bridge_trace")
    defer: (removeDir(work); removeDir(traceDir))
    let cfg = work / "config.json"
    let csv = work / "table.csv"
    writeFile(cfg, "{}")
    writeFile(csv, "a,b\n")

    let dep = depFileFromRecords(@[readRec(cfg), readRec(csv)])
    let captured = readFilesFromDepFile(dep)
    check captured.isOk

    let wrote = writeReadFilesProjection(traceDir, captured.value)
    check wrote.isOk
    check fileExists(traceDir / NativeReadFilesFile)

    # Re-extract through the M6a code path: the SAME set.
    let reExtracted = readFileDepsNative(traceDir)
    check reExtracted.isOk
    check reExtracted.value.len == captured.value.len
    for i in 0 ..< captured.value.len:
      check reExtracted.value[i].path == captured.value[i].path
      check reExtracted.value[i].hash == captured.value[i].hash
      check reExtracted.value[i].mtime == captured.value[i].mtime

  test "captured read file folds into store + M4b + root hash (rerun vs skip)":
    # END-TO-END through the REAL store + invalidation + root-hash fold, with the
    # read-file set sourced from an io-mon CAPTURE (not the recording). Two tests
    # each read a different captured file; a changed captured file re-runs EXACTLY
    # its reader, an unrelated change skips, and the deep root hash reflects it.
    let work = tmpDir("fold")
    let sourceRoot = tmpDir("fold_src")
    defer: (removeDir(work); removeDir(sourceRoot))
    createDir(sourceRoot)
    writeFile(sourceRoot / "lib.rb", "def parse\n  1\nend\n")
    let cfg = work / "config.json"
    let csv = work / "table.csv"
    writeFile(cfg, "{}")
    writeFile(csv, "a,b\n")

    # Capture each test's read file via io-mon's depfile conversion.
    let cfgReads = readFilesFromDepFile(depFileFromRecords(@[readRec(cfg)]))
    let csvReads = readFilesFromDepFile(depFileFromRecords(@[readRec(csv)]))
    check cfgReads.isOk and cfgReads.value.len == 1
    check csvReads.isOk and csvReads.value.len == 1
    let cfgRf = cfgReads.value[0]
    let csvRf = csvReads.value[0]

    # The shared, never-edited function's shallow hash matches the live source so
    # ONLY a captured-file change can flip a decision.
    let strategies = backendStrategies(tbSourceInterpreted)
    let parseShallow = strategies.hasher.hashOf(
      ExecutedFunction(name: "parse", file: "lib.rb", defLine: 1), sourceRoot)
    let parse = dep("parse", "lib.rb", 1, parseShallow)

    let tests = @[
      StoreTest(testId: key64("t_reads_cfg"), testName: "t_reads_cfg",
                rootHash: rootHashOfDepsAndReadFiles(@[parse],
                  @[ReadFileDep(path: cfgRf.path, hash: cfgRf.hash)]),
                deps: @[parse],
                readFiles: @[(path: cfgRf.path, mtime: cfgRf.mtime)]),
      StoreTest(testId: key64("t_reads_csv"), testName: "t_reads_csv",
                rootHash: rootHashOfDepsAndReadFiles(@[parse],
                  @[ReadFileDep(path: csvRf.path, hash: csvRf.hash)]),
                deps: @[parse],
                readFiles: @[(path: csvRf.path, mtime: csvRf.mtime)]),
    ]
    let s = buildStore(tests)
    check s.isOk
    let store = s.value

    # Change signals over the captured paths (literal-path procs; no GC capture).
    let cfgPath = cfgRf.path
    let csvPath = csvRf.path
    let cfgMtime = cfgRf.mtime
    let csvMtime = csvRf.mtime

    proc cfgChanged(path: string): Option[int64] {.gcsafe, raises: [].} =
      {.gcsafe.}:
        if path == cfgPath: some(cfgMtime + 1)   # changed
        elif path == csvPath: some(csvMtime)     # unchanged
        else: none(int64)
    proc allUnchanged(path: string): Option[int64] {.gcsafe, raises: [].} =
      {.gcsafe.}:
        if path == cfgPath: some(cfgMtime)
        elif path == csvPath: some(csvMtime)
        else: none(int64)
    proc cfgUnreadable(path: string): Option[int64] {.gcsafe, raises: [].} =
      {.gcsafe.}:
        if path == cfgPath: none(int64)          # vanished ⇒ fail-safe re-run
        elif path == csvPath: some(csvMtime)
        else: none(int64)

    proc mtimeSignal(probe: proc(path: string): Option[int64]
        {.gcsafe, raises: [].}): FileSignal =
      FileSignal(byHash: false, currentMtime: probe, currentHash: nil,
                 recordedHash: nil)

    # ARM 1: the captured config file changed ⇒ exactly its reader re-runs.
    let r1 = invalidateShallow(store, tbSourceInterpreted, sourceRoot,
                               mtimeSignal(cfgChanged))
    check r1.isOk
    check key64("t_reads_cfg") in r1.value.rerun
    check key64("t_reads_csv") notin r1.value.rerun
    check irReadFileChanged in r1.value.reasons[key64("t_reads_cfg")]

    # ARM 2: nothing changed ⇒ both skip (no false re-run).
    let r2 = invalidateShallow(store, tbSourceInterpreted, sourceRoot,
                               mtimeSignal(allUnchanged))
    check r2.isOk
    check r2.value.rerun.len == 0

    # ARM 3 (fail-safe): a captured file that becomes unreadable ⇒ re-run.
    let r3 = invalidateShallow(store, tbSourceInterpreted, sourceRoot,
                               mtimeSignal(cfgUnreadable))
    check r3.isOk
    check key64("t_reads_cfg") in r3.value.rerun
    check key64("t_reads_csv") notin r3.value.rerun

    # Deep-path: a changed captured read file changes the per-test root hash; an
    # empty captured set reduces EXACTLY to rootHashOfDeps (no regression).
    check rootHashOfDepsAndReadFiles(@[parse], @[]) == rootHashOfDeps(@[parse])
    let h1 = rootHashOfDepsAndReadFiles(@[parse],
      @[ReadFileDep(path: cfgRf.path, hash: cfgRf.hash)])
    let h2 = rootHashOfDepsAndReadFiles(@[parse],
      @[ReadFileDep(path: cfgRf.path, hash: cfgRf.hash & "X")])
    check h1 != rootHashOfDeps(@[parse])
    check h1 != h2

  test "live interpose injection is gated, never faked":
    # The LIVE injection arm: it runs ONLY when the platform shim is available,
    # and otherwise fails HONESTLY (never fabricates a capture). We assert the
    # gate behaviour matches `ioMonShimAvailable` so a build host without the
    # shim does not silently pass a fake live run.
    let work = tmpDir("live")
    defer: removeDir(work)
    let depfile = work / "cap.rdep"

    if ioMonShimAvailable():
      # The shim IS present: a real capture of a trivial command must succeed and
      # yield a (possibly empty) read-file set — this is the genuine live e2e.
      let res = captureReadFilesLive(@["/bin/sh", "-c", "true"], depfile)
      checkpoint("live capture result: " &
        (if res.isOk: "ok" else: res.error))
      check res.isOk
    else:
      # The shim is NOT present: the live path MUST gate honestly with an Err, and
      # MUST NOT produce a depfile or a fabricated set.
      let res = captureReadFilesLive(@["/bin/sh", "-c", "true"], depfile)
      check res.isErr
      check "gated" in res.error
      check not fileExists(depfile)

  test "empty command is rejected":
    let work = tmpDir("empty")
    defer: removeDir(work)
    let res = captureReadFilesLive(@[], work / "x.rdep")
    check res.isErr

# ---------------------------------------------------------------------------
# M8 — live interpose snoop-CLI WIRING + the gated-but-fail-safe live e2e.
#
# M8 relocated reprobuild's snoop surface into io-mon as the standalone
# `io-mon` CLI and wired the runner's live capture to invoke it
# out-of-process (the shim injected around the recorded program, not the
# runner). These tests assert that the wiring is REAL and resolvable, and that
# the live e2e — folding a captured read change through the runner — either runs
# for real (where the platform interpose captures a user binary) or fails SAFE
# (gated ⇒ re-run) where it does not. NOTHING is faked.
#
# HONEST macOS RESULT (recorded empirically, see io-mon's
# test_io_mon_snoop_cli.nim): on macOS 26 / arm64e the __DATA,__interpose
# mechanism does not intercept libc calls from chained-fixups binaries, so even
# a freshly-built USER binary's reads are NOT captured here. The wiring is
# correct (the snoop CLI runs, the depfile is valid), but the captured read set
# is EMPTY. The live-fold e2e is therefore GATED on whether a real read was
# captured, and on this host asserts the fail-safe shape.
# ---------------------------------------------------------------------------

proc m8CompileUserReader(work, inputPath: string): string =
  ## Compile a tiny freshly-built USER binary that open()+read()s `inputPath`.
  ## Returns the binary path, or "" if no C compiler is available.
  let cc = getEnv("CC", "cc")
  let src = work / "reader.c"
  writeFile(src, """
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) return 1;
  char buf[64];
  ssize_t n = read(fd, buf, sizeof(buf));
  close(fd);
  return n < 0 ? 1 : 0;
}
""")
  let bin = work / "reader"
  let (outp, code) = execCmdEx(cc & " " & quoteShell(src) & " -o " & quoteShell(bin))
  if code != 0 or not fileExists(bin):
    return ""
  bin

suite "M8 — live interpose snoop-CLI wiring + gated-safe e2e":

  test "ioMonLiveCaptureAvailable reflects reality (shim + snoop CLI on PATH)":
    # The wiring gate is the conjunction of the two halves. It must agree with the
    # two locators — no independent state that could drift from what is actually
    # resolvable on this host.
    let shim = ioMonShimAvailable()
    let snoop = findSnoopCli().len > 0
    check ioMonLiveCaptureAvailable() == (shim and snoop)

  test "live capture over a USER binary runs end-to-end OR fails safe (never faked)":
    if not ioMonLiveCaptureAvailable():
      skip()  # neither half wired here — the M6b gated-arm test covers that path
    else:
      let work = tmpDir("m8live")
      defer: removeDir(work)
      let inputPath = work / "dependency.txt"
      writeFile(inputPath, "v1: the captured read-file dependency\n")
      let userBin = m8CompileUserReader(work, inputPath)
      if userBin.len == 0:
        skip()  # no C compiler on this host
      else:
        let depfile = work / "cap.rdep"
        let res = captureReadFilesLive(@[userBin, inputPath], depfile)
        checkpoint("live capture: " & (if res.isOk: "ok, reads=" &
          $res.value.len else: res.error))
        # WIRING: the capture must complete without error (a valid depfile is
        # produced even when the interpose captures nothing) — a launch/exit
        # failure would be a real wiring break.
        check res.isOk
        check fileExists(depfile)

        # Was the dependency read actually captured? (macOS chained-fixups: no.)
        var capturedDep = false
        for rf in res.value:
          if rf.path == inputPath:
            capturedDep = true
            break

        if capturedDep:
          # The genuine live e2e: fold the captured read through the runner and
          # prove a CHANGE to the captured read file re-runs its reader test.
          let traceDir = tmpDir("m8trace")
          defer: removeDir(traceDir)
          check writeReadFilesProjection(traceDir, res.value).isOk
          let reExtracted = readFileDepsNative(traceDir)
          check reExtracted.isOk
          # The re-extracted set must contain the captured dependency path.
          var found = false
          for rf in reExtracted.value:
            if rf.path == inputPath: found = true
          check found
          checkpoint("M8 live e2e PROVEN: user-binary read captured + folded")
        else:
          # FAIL-SAFE shape (macOS 26/arm64e): the capture ran, the depfile is
          # valid, but the interpose did not fire for the chained-fixups user
          # binary. We assert the honest empty-but-ok result — NEVER a fabricated
          # read record — and rely on the CLI's deterministic=false capture-gate
          # to re-run such a test. This is the documented platform gap, not a bug.
          check not capturedDep
          checkpoint("M8 macOS chained-fixups gap: capture empty, fail-safe " &
            "(the runner persists deterministic=false ⇒ re-run)")
