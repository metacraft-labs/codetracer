## M6b / §16.7.8 — io-mon LAUNCHED-BINARY fold for materialized recorders.
##
## Spec `Nim-Parallel-Test-Framework.md` §16.7.8: a test's invalidation set is
##   code deps ∪ read-file deps ∪ LAUNCHED-BINARY deps,
## transitive over the whole process tree. A launched binary loads via mmap/dyld,
## so it NEVER appears as an `open`/`read` — it is captured as a process
## spawn/exec record (`mrProcessSpawn`/`mrProcessExec`, observation `moExecute`,
## binary path in `record.path`). This test exercises the fold that folds those
## launched binaries into the SAME M4a file index + M4b invalidation + per-test
## ROOT HASH the read-file set uses (so a changed launched binary — e.g. the
## compiler — re-runs every test that launched it), through the REAL production
## code paths.
##
## What is EXERCISED here (build-host-runnable, no live injection needed):
##   1. `launchedBinaryPathsFromDepFile`: a depfile with spawn/exec records yields
##      the launched-binary path set (successful only, de-duped, path-sorted),
##      and a FAILED spawn / a path-less fork are excluded.
##   2. `readFilesFromDepFile` FOLDS launched binaries into the read-dependency
##      `ReadFile` set (path + content signature), de-duplicated against read
##      paths, with the read-vs-write exclusion intact.
##   3. The SANDBOX → ORIGINAL mapping: a SIP-rewritten exec path (under
##      `CT_SANDBOX_TOOLS_DIR`, produced by `prepareSandboxCopy`) is folded
##      against the ORIGINAL system path, NOT the transient sandbox copy.
##   4. The end-to-end fold into the REAL store + M4b + root hash: a change to a
##      launched binary's content re-runs EXACTLY its launcher; an unrelated
##      change skips; an un-stat'able launched binary ⇒ re-run (fail-safe).

import std/[unittest, options, os, strutils, sets, tables]
import results

import engine          # ExecutedFunction, backendStrategies, tbSourceInterpreted
import ctfs_store      # StoreTest, buildStore, key64
import root_hash       # rootHashOfDeps, rootHashOfDepsAndReadFiles, ReadFileDep
import invalidation    # the M4b query (FileSignal, invalidateShallow, irReadFileChanged)
import io_mon_capture  # the fold under test (launchedBinaryPathsFromDepFile, readFilesFromDepFile)
import io_mon          # MonitorRecord/MonitorDepFile/depFileFromRecords
import stackable_hooks/propagation as ct_propagation  # prepareSandboxCopy

proc tmpDir(name: string): string =
  result = getTempDir() / ("m6b_lb_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc spawnRec(path: string; childPid: int64): MonitorRecord =
  ## A successful posix_spawn record (the shim emits `result == 0`, child pid in
  ## `childOsPid`, binary path in `path`, observation `moExecute`).
  MonitorRecord(kind: mrProcessSpawn, observationKind: moExecute,
                seq: 1, result: 0, childOsPid: uint64(childPid), path: path,
                detail: "posix_spawn")

proc execRec(path: string): MonitorRecord =
  ## A successful execve record (`mrProcessExec`, `moExecute`, path set; the shim
  ## emits the record BEFORE the exec, with the default `result` of 0).
  MonitorRecord(kind: mrProcessExec, observationKind: moExecute,
                seq: 2, result: 0, path: path, detail: "execve")

proc failedSpawnRec(path: string): MonitorRecord =
  ## A FAILED spawn (result < 0) — names no launched binary, must be dropped.
  MonitorRecord(kind: mrProcessSpawn, observationKind: moExecute,
                seq: 3, result: -1, path: path)

proc forkNoPathRec(childPid: int64): MonitorRecord =
  ## A bare fork (no exec) — carries no binary path, contributes no dependency.
  MonitorRecord(kind: mrProcessSpawn, observationKind: moExecute,
                seq: 4, result: childPid, childOsPid: uint64(childPid),
                detail: "fork")

proc readRec(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileOpen, observationKind: moFileOpen,
                seq: 5, result: 3, path: path)

suite "M6b — io-mon launched-binary fold (§16.7.8)":

  test "launched-binary path set: successful only, de-duped, path-sorted":
    let toolA = "/usr/bin/zzz-tool"
    let toolB = "/usr/bin/aaa-tool"
    let dep = depFileFromRecords(@[
      spawnRec(toolA, 100),
      execRec(toolB),
      spawnRec(toolA, 101),        # duplicate launch of toolA
      failedSpawnRec("/usr/bin/never"),  # failed ⇒ excluded
      forkNoPathRec(102),          # path-less fork ⇒ excluded
    ])
    let launched = launchedBinaryPathsFromDepFile(dep)
    # Sorted, de-duped, failed + path-less excluded: aaa-tool then zzz-tool.
    check launched == @[toolB, toolA]

  test "readFilesFromDepFile folds a launched binary into the dependency set":
    # A spawn/exec record for a REAL binary X folds X into the SAME ReadFile set
    # (with a capture-time content signature), alongside the read files.
    let work = tmpDir("fold")
    defer: removeDir(work)
    let binX = work / "compiler"
    let cfg = work / "config.json"
    writeFile(binX, "BINARY-X-V1")
    writeFile(cfg, "{}")

    let dep = depFileFromRecords(@[readRec(cfg), spawnRec(binX, 200)])
    let reads = readFilesFromDepFile(dep)
    check reads.isOk
    # Both the read file AND the launched binary are folded (path-sorted).
    var paths: seq[string] = @[]
    for rf in reads.value: paths.add rf.path
    check binX in paths
    check cfg in paths
    check reads.value.len == 2
    # Each carries a non-empty capture-time content signature.
    for rf in reads.value:
      check rf.hash.len > 0

  test "a launched binary that is also read is folded ONCE (de-dup by path)":
    let work = tmpDir("dedup")
    defer: removeDir(work)
    let binX = work / "tool"
    writeFile(binX, "X")
    # The binary appears both as a read (open) and as a launch (exec).
    let dep = depFileFromRecords(@[readRec(binX), execRec(binX)])
    let reads = readFilesFromDepFile(dep)
    check reads.isOk
    check reads.value.len == 1
    check reads.value[0].path == binX

  test "an un-stat'able launched binary ⇒ Err (fail-safe re-run)":
    let work = tmpDir("missing")
    defer: removeDir(work)
    # A launched binary that does not exist at capture finalize: no baseline.
    let ghost = work / "vanished-tool"
    let dep = depFileFromRecords(@[spawnRec(ghost, 300)])
    let reads = readFilesFromDepFile(dep)
    check reads.isErr
    check "no longer present" in reads.error

  test "a sandbox-rewritten exec path folds against the ORIGINAL system path":
    # §16.7.8 SIP redirection: a SIP-protected sub-target is redirected to its
    # CT_SANDBOX_TOOLS_DIR copy at spawn time, so the recorded exec path may be
    # the transient sandbox copy. The fold must record the dependency against the
    # ORIGINAL system binary identity.
    let sandbox = tmpDir("sandbox")
    defer: removeDir(sandbox)
    putEnv("CT_SANDBOX_TOOLS_DIR", sandbox)
    defer: delEnv("CT_SANDBOX_TOOLS_DIR")

    # Pick a SIP-protected system binary that exists on this host. /bin/sh is
    # present on every macOS / Linux host the runner targets.
    const original = "/bin/sh"
    if not fileExists(original):
      skip()
    else:
      # prepareSandboxCopy mirrors the original under the sandbox root and
      # returns the copy path — exactly what the spawn hook's SIP-rewrite uses.
      let sandboxCopy = ct_propagation.prepareSandboxCopy(original, sandbox)
      check sandboxCopy != original              # it WAS rewritten
      check sandboxCopy.startsWith(sandbox)

      # The depfile records the spawn at the SANDBOX path (what the hook saw).
      let dep = depFileFromRecords(@[spawnRec(sandboxCopy, 400)])
      let launched = launchedBinaryPathsFromDepFile(dep)
      # The fold maps it BACK to the original system path.
      check launched == @[original]

      # And the full ReadFile fold stats the ORIGINAL (it exists), not the copy.
      let reads = readFilesFromDepFile(dep)
      check reads.isOk
      check reads.value.len == 1
      check reads.value[0].path == original

  test "a changed launched binary re-runs EXACTLY its launcher (store + M4b)":
    # END-TO-END through the REAL store + invalidation + root-hash fold: two
    # tests each launch a different binary; a content change to one launched
    # binary re-runs EXACTLY that launcher, an unrelated change skips, and an
    # un-stat'able launched binary re-runs (fail-safe).
    let work = tmpDir("e2e")
    let sourceRoot = tmpDir("e2e_src")
    defer: (removeDir(work); removeDir(sourceRoot))
    writeFile(sourceRoot / "lib.rb", "def parse\n  1\nend\n")
    let compilerA = work / "compilerA"
    let compilerB = work / "compilerB"
    writeFile(compilerA, "A-V1")
    writeFile(compilerB, "B-V1")

    # Each test's launched-binary dep, captured from a spawn record.
    let aReads = readFilesFromDepFile(depFileFromRecords(@[spawnRec(compilerA, 1)]))
    let bReads = readFilesFromDepFile(depFileFromRecords(@[spawnRec(compilerB, 2)]))
    check aReads.isOk and aReads.value.len == 1
    check bReads.isOk and bReads.value.len == 1
    let aRf = aReads.value[0]
    let bRf = bReads.value[0]

    let strategies = backendStrategies(tbSourceInterpreted)
    let parseShallow = strategies.hasher.hashOf(
      ExecutedFunction(name: "parse", file: "lib.rb", defLine: 1), sourceRoot)
    let parse = CachedDep(fn: ExecutedFunction(name: "parse", file: "lib.rb",
      defLine: 1), shallow: parseShallow)

    let tests = @[
      StoreTest(testId: key64("t_runs_A"), testName: "t_runs_A",
                rootHash: rootHashOfDepsAndReadFiles(@[parse],
                  @[ReadFileDep(path: aRf.path, hash: aRf.hash)]),
                deps: @[parse],
                readFiles: @[(path: aRf.path, mtime: aRf.mtime)]),
      StoreTest(testId: key64("t_runs_B"), testName: "t_runs_B",
                rootHash: rootHashOfDepsAndReadFiles(@[parse],
                  @[ReadFileDep(path: bRf.path, hash: bRf.hash)]),
                deps: @[parse],
                readFiles: @[(path: bRf.path, mtime: bRf.mtime)]),
    ]
    let s = buildStore(tests)
    check s.isOk
    let store = s.value

    let aPath = aRf.path
    let bPath = bRf.path
    let aMtime = aRf.mtime
    let bMtime = bRf.mtime

    proc aChanged(path: string): Option[int64] {.gcsafe, raises: [].} =
      {.gcsafe.}:
        if path == aPath: some(aMtime + 1)   # the compiler changed
        elif path == bPath: some(bMtime)     # unchanged
        else: none(int64)
    proc allUnchanged(path: string): Option[int64] {.gcsafe, raises: [].} =
      {.gcsafe.}:
        if path == aPath: some(aMtime)
        elif path == bPath: some(bMtime)
        else: none(int64)
    proc aUnreadable(path: string): Option[int64] {.gcsafe, raises: [].} =
      {.gcsafe.}:
        if path == aPath: none(int64)        # vanished ⇒ fail-safe re-run
        elif path == bPath: some(bMtime)
        else: none(int64)

    proc mtimeSignal(probe: proc(path: string): Option[int64]
        {.gcsafe, raises: [].}): FileSignal =
      FileSignal(byHash: false, currentMtime: probe, currentHash: nil,
                 recordedHash: nil)

    # ARM 1: the launched compiler A changed ⇒ exactly its launcher re-runs.
    let r1 = invalidateShallow(store, tbSourceInterpreted, sourceRoot,
                               mtimeSignal(aChanged))
    check r1.isOk
    check key64("t_runs_A") in r1.value.rerun
    check key64("t_runs_B") notin r1.value.rerun
    check irReadFileChanged in r1.value.reasons[key64("t_runs_A")]

    # ARM 2: nothing changed ⇒ both skip.
    let r2 = invalidateShallow(store, tbSourceInterpreted, sourceRoot,
                               mtimeSignal(allUnchanged))
    check r2.isOk
    check r2.value.rerun.len == 0

    # ARM 3 (fail-safe): an un-stat'able launched binary ⇒ re-run its launcher.
    let r3 = invalidateShallow(store, tbSourceInterpreted, sourceRoot,
                               mtimeSignal(aUnreadable))
    check r3.isOk
    check key64("t_runs_A") in r3.value.rerun
    check key64("t_runs_B") notin r3.value.rerun
