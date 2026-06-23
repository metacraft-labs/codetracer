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

import std/[unittest, tables, sets, options, os, strutils]
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
