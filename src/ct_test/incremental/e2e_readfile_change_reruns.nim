## M6a — `e2e_readfile_change_reruns` + the read-file fail-safe.
##
## END-TO-END: a test that READ a file is RE-RUN when that file changes, and is
## NOT re-run when an UNRELATED file changes — driven through the SAME pieces the
## production runner uses:
##
##   1. the MCR/RR read-file extractor (`native_readfiles.readFileDepsNative`)
##      derives the read-file set (path + record-time mtime + content signature)
##      from a recording's accessed-file projection;
##   2. that set populates the `CtfsStore` file index (`StoreTest.readFiles` →
##      `buildStore`, M4a) with the recorded mtime AND a content-hash baseline;
##   3. AND it is folded into the per-test ROOT HASH (`rootHashOfDepsAndReadFiles`,
##      M6a) so the deep path also re-decides on a read-file change;
##   4. the M4b invalidation query (`invalidateShallow` / `invalidateDeep`, which
##      call the shared `foldFileInvalidation`) re-runs EXACTLY the reader tests
##      of a changed file, and skips the rest.
##
## Both arms are asserted (changed read file ⇒ re-run; unrelated change ⇒ skip),
## in BOTH the mtime (default) and content-hash (`FileSignal.byHash`) modes, plus
## the FAIL-SAFE: a read file that becomes UNREADABLE / MISSING ⇒ re-run.
##
## The recording side is the documented MCR/RR accessed-file PROJECTION (a live
## rr replay is Linux/rr-specific, gated the same way the campaign gates
## rr-dependent tests); the store + invalidation + root-hash fold are the REAL
## production code paths, exercised in full. Following the M4b test convention,
## the per-file change signals are NAMED procs over the fixture's literal paths
## (not GC-capturing closures), so they satisfy the `gcsafe, raises: []` seam.

import std/[unittest, tables, sets, options, os]
import results

import engine          # CachedDep, ExecutedFunction, backendStrategies, tbSourceInterpreted
import ctfs_store      # CtfsStore, StoreTest, buildStore, key64
import root_hash       # rootHashOfDeps, rootHashOfDepsAndReadFiles, ReadFileDep
import invalidation    # the M4b query (+ foldFileInvalidation) under test
import native_readfiles # the M6a extractor

# ---------------------------------------------------------------------------
# Fixture constants: two tests, each reading a DIFFERENT data file, plus a
# shared executed function. The paths are module-level so the change-signal
# procs can compare against them WITHOUT capturing GC'd locals.
# ---------------------------------------------------------------------------

const
  CfgPath = "data/config.json"
  CsvPath = "data/table.csv"
  CfgSize = 256'i64
  CfgMtime = 1000'i64
  CsvSize = 1024'i64
  CsvMtime = 2000'i64

proc tmpDir(name: string): string =
  result = getTempDir() / ("m6a_e2e_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

proc writeProjection(traceDir: string; path: string; size, mtime: int64) =
  ## Write an rr-shaped accessed-file projection (one file-backed read).
  writeFile(traceDir / NativeReadFilesFile,
    "{ \"reads\": [ { \"path\": \"" & path & "\", \"source\": \"file\", " &
    "\"statSize\": " & $size & ", \"statMTime\": " & $mtime & " } ] }")

proc writeSource(root: string) =
  ## A tiny real source tree so `invalidateShallow` runs the GENUINE engine
  ## hasher over the shared `parse` function (never edited here → only the FILE
  ## fold can flip a decision).
  createDir(root)
  writeFile(root / "lib.rb", "def parse\n  1\nend\n")

proc currentParseShallow(sourceRoot: string): string =
  ## The shallow hash the engine computes for `parse` over the live source — fed
  ## as the recorded shallow so the function side is UNCHANGED in the query.
  let strategies = backendStrategies(tbSourceInterpreted)
  strategies.hasher.hashOf(
    ExecutedFunction(name: "parse", file: "lib.rb", defLine: 1), sourceRoot)

# Build the two-test store from EXTRACTED read-file sets (real M6a → M4a wiring),
# with the shared function's shallow hash matching `sourceRoot` so only files can
# flip a decision. Returns the store + the record-time content hashes by path.
proc buildReaderStore(cfgTrace, csvTrace, sourceRoot: string):
    tuple[store: CtfsStore; cfgHash, csvHash: string] =
  let cfgReads = readFileDepsNative(cfgTrace)
  let csvReads = readFileDepsNative(csvTrace)
  doAssert cfgReads.isOk and cfgReads.value.len == 1
  doAssert csvReads.isOk and csvReads.value.len == 1
  let cfgRf = cfgReads.value[0]
  let csvRf = csvReads.value[0]
  doAssert cfgRf.path == CfgPath and csvRf.path == CsvPath
  let parse = dep("parse", "lib.rb", 1, currentParseShallow(sourceRoot))
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
  doAssert s.isOk
  (store: s.value, cfgHash: cfgRf.hash, csvHash: csvRf.hash)

# --- Named mtime-change signals (literal paths; no GC capture). ---

proc mtimeCfgChanged(path: string): Option[int64] {.gcsafe, raises: [].} =
  if path == CfgPath: some(CfgMtime + 1)   # changed
  elif path == CsvPath: some(CsvMtime)     # unchanged
  else: none(int64)

proc mtimeAllUnchanged(path: string): Option[int64] {.gcsafe, raises: [].} =
  if path == CfgPath: some(CfgMtime)
  elif path == CsvPath: some(CsvMtime)
  else: none(int64)

proc mtimeCfgUnreadable(path: string): Option[int64] {.gcsafe, raises: [].} =
  if path == CfgPath: none(int64)          # vanished/unreadable ⇒ re-run
  elif path == CsvPath: some(CsvMtime)     # readable + unchanged ⇒ skip
  else: none(int64)

proc mtimeSignal(probe: proc(path: string): Option[int64] {.gcsafe, raises: [].}):
    FileSignal =
  FileSignal(byHash: false, currentMtime: probe, currentHash: nil, recordedHash: nil)

suite "M6a — e2e read-file change re-runs (store + M4b + root hash)":

  test "changed_read_file_reruns_its_reader_unrelated_change_skips_mtime":
    let cfgTrace = tmpDir("cfgtrace")
    let csvTrace = tmpDir("csvtrace")
    let sourceRoot = tmpDir("src")
    defer: (removeDir(cfgTrace); removeDir(csvTrace); removeDir(sourceRoot))
    writeProjection(cfgTrace, CfgPath, CfgSize, CfgMtime)
    writeProjection(csvTrace, CsvPath, CsvSize, CsvMtime)
    writeSource(sourceRoot)
    let s = buildReaderStore(cfgTrace, csvTrace, sourceRoot).store

    # ARM 1: config.json's mtime CHANGED, table.csv UNCHANGED.
    let res1 = invalidateShallow(s, tbSourceInterpreted, sourceRoot,
                                 mtimeSignal(mtimeCfgChanged))
    check res1.isOk
    check key64("t_reads_cfg") in res1.value.rerun     # reader of changed file
    check key64("t_reads_csv") notin res1.value.rerun  # reader of unrelated file
    check irReadFileChanged in res1.value.reasons[key64("t_reads_cfg")]

    # ARM 2: NOTHING changed ⇒ both SKIP (no false re-run).
    let res2 = invalidateShallow(s, tbSourceInterpreted, sourceRoot,
                                 mtimeSignal(mtimeAllUnchanged))
    check res2.isOk
    check res2.value.rerun.len == 0

  test "changed_read_file_reruns_by_content_hash_mode":
    # The hash-mode (FileSignal.byHash) path: a changed CONTENT hash re-runs the
    # reader; an unchanged one skips. The recorded hashes are the record-time
    # content signatures the extractor produced (M6a baseline).
    let cfgTrace = tmpDir("h_cfg")
    let csvTrace = tmpDir("h_csv")
    let sourceRoot = tmpDir("h_src")
    defer: (removeDir(cfgTrace); removeDir(csvTrace); removeDir(sourceRoot))
    writeProjection(cfgTrace, CfgPath, CfgSize, CfgMtime)
    writeProjection(csvTrace, CsvPath, CsvSize, CsvMtime)
    writeSource(sourceRoot)
    let built = buildReaderStore(cfgTrace, csvTrace, sourceRoot)
    let s = built.store

    # The record-time signatures, recovered by recomputing them from the same
    # (size, mtime) the projection recorded — these are the baselines.
    let cfgBaseline = signatureOf(CfgSize, CfgMtime)
    let csvBaseline = signatureOf(CsvSize, CsvMtime)
    doAssert built.cfgHash == cfgBaseline and built.csvHash == csvBaseline

    # config.json's CONTENT changed (new signature); table.csv unchanged.
    proc curHash(path: string): Option[string] {.gcsafe, raises: [].} =
      if path == CfgPath: some("CHANGED_CONTENT")
      elif path == CsvPath: some(signatureOf(CsvSize, CsvMtime))
      else: none(string)
    proc recHash(path: string): Option[string] {.gcsafe, raises: [].} =
      if path == CfgPath: some(signatureOf(CfgSize, CfgMtime))
      elif path == CsvPath: some(signatureOf(CsvSize, CsvMtime))
      else: none(string)
    let signal = FileSignal(byHash: true, currentMtime: nil,
                            currentHash: curHash, recordedHash: recHash)
    let res = invalidateShallow(s, tbSourceInterpreted, sourceRoot, signal)
    check res.isOk
    check key64("t_reads_cfg") in res.value.rerun
    check key64("t_reads_csv") notin res.value.rerun

  test "failsafe_unreadable_read_file_reruns":
    # FAIL-SAFE: a read file that becomes UNREADABLE / MISSING now (the probe
    # returns `none`) ⇒ re-run its reader, NEVER a skip.
    let cfgTrace = tmpDir("fs_cfg")
    let csvTrace = tmpDir("fs_csv")
    let sourceRoot = tmpDir("fs_src")
    defer: (removeDir(cfgTrace); removeDir(csvTrace); removeDir(sourceRoot))
    writeProjection(cfgTrace, CfgPath, CfgSize, CfgMtime)
    writeProjection(csvTrace, CsvPath, CsvSize, CsvMtime)
    writeSource(sourceRoot)
    let s = buildReaderStore(cfgTrace, csvTrace, sourceRoot).store

    let res = invalidateShallow(s, tbSourceInterpreted, sourceRoot,
                                mtimeSignal(mtimeCfgUnreadable))
    check res.isOk
    check key64("t_reads_cfg") in res.value.rerun     # fail-safe re-run
    check key64("t_reads_csv") notin res.value.rerun  # unchanged ⇒ skip

  test "read_file_folded_into_root_hash_changes_the_deep_hash":
    # The deep-path consistency guarantee: a changed read file changes the per-test
    # ROOT HASH (so the deep `invalidateDeep` path also re-decides). An EMPTY
    # read-file set reproduces `rootHashOfDeps` EXACTLY (forward compatibility).
    let parse = dep("parse", "lib.rb", 1, "sh")
    let baseNoFiles = rootHashOfDeps(@[parse])
    let baseEmpty = rootHashOfDepsAndReadFiles(@[parse], @[])
    check baseEmpty == baseNoFiles                     # empty ⇒ identical (no regression)

    let withV1 = rootHashOfDepsAndReadFiles(@[parse],
      @[ReadFileDep(path: CfgPath, hash: signatureOf(CfgSize, CfgMtime))])
    let withV2 = rootHashOfDepsAndReadFiles(@[parse],
      @[ReadFileDep(path: CfgPath, hash: signatureOf(CfgSize, CfgMtime + 1))])
    check withV1 != baseNoFiles                        # a read file changes the hash
    check withV1 != withV2                             # a CHANGED read file re-decides
    # Order independence over the read-file set.
    let twoA = rootHashOfDepsAndReadFiles(@[parse], @[
      ReadFileDep(path: "a", hash: "h1"), ReadFileDep(path: "b", hash: "h2")])
    let twoB = rootHashOfDepsAndReadFiles(@[parse], @[
      ReadFileDep(path: "b", hash: "h2"), ReadFileDep(path: "a", hash: "h1")])
    check twoA == twoB
