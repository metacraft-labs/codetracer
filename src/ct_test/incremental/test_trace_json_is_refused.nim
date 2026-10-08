## The incremental engine reads interpreted-language recordings from their CTFS
## `.ct` container, and refuses a `trace.json` event stream as test-oracle
## output — the same refusal `ct print`, `ct replay` and the debugger give.
##
## No mocks: the recording is written by the production CTFS writer
## (`m0_three_funcs_trace`), the `trace.json` folder is a real directory on
## disk, and every assertion goes through the engine's public entry points
## (`detectBackend`, `record`, `decide`, `readExecutedFunctionsCtfs`).

import std/[unittest, os, strutils, times, tables]

import engine
import m0_three_funcs_trace
import ../../ct/trace/trace_kind  # TestOracleOutputError

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"
  testId = "fixture::three_funcs"

var counter = 0

proc freshDir(prefix: string): string =
  inc counter
  result = getTempDir() / (prefix & $(epochTime() * 1_000_000.0).int64 & "_" &
    $counter)
  createDir(result)

proc makeSourceRoot(): string =
  result = freshDir("ct_tjson_src_")
  let dst = result / relSourcePath
  createDir(dst.parentDir)
  copyFile(fixturesDir / "m0_three_funcs" / "src" / "three_funcs.rb", dst)

proc oracleOnlyDir(): string =
  ## A folder holding what the pure Ruby recorder writes: `trace.json` plus its
  ## path and metadata sidecars, and no `.ct`.
  result = freshDir("ct_tjson_oracle_")
  writeFile(result / "trace.json", """[{"Path":""},""" &
    """{"Function":{"path_id":0,"line":1,"name":"main"}},""" &
    """{"Call":{"function_id":0,"args":[]}}]""")
  writeFile(result / "trace_paths.json", """[""]""")
  writeFile(result / "trace_metadata.json",
    """{"program":"main.rb","args":[],"workdir":"/"}""")

suite "interpreted recordings are read from .ct; trace.json is refused":
  test "the m0_three_funcs recording is a .ct read as an interpreted trace":
    let dir = threeFuncsTraceDir()
    check fileExists(dir / ThreeFuncsBundleName)
    check not fileExists(dir / "trace.json")
    let backend = detectBackend(dir)
    check backend.isOk
    check backend.value == tbSourceInterpreted
    let fns = backendStrategies(tbSourceInterpreted).discovery.discover(dir)
    check fns.isOk
    var byName: Table[string, ExecutedFunction]
    for f in fns.value:
      byName[f.name] = f
    check byName.len == 3
    check byName["main"].defLine == 28
    check byName["used_a"].defLine == 16
    check byName["used_b"].defLine == 20
    check byName["used_a"].file == ThreeFuncsSourcePath
    check ThreeFuncsUncalled notin byName

  test "recording and deciding against the .ct skips an unchanged test":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    let rec = record(cache, testId, threeFuncsTraceDir(), root)
    check rec.isOk
    check cache.entries[testId].deps.len == 3
    for dep in cache.entries[testId].deps:
      check dep.shallow != shallowHash("")  # a real body, not "missing"
    check decide(testId, threeFuncsTraceDir(), root, cache).kind ==
      idSkipUnchanged

  test "detectBackend refuses a trace.json folder as test-oracle output":
    let dir = oracleOnlyDir()
    let res = detectBackend(dir)
    check res.isErr
    check TestOracleOutputError in res.error

  test "detectBackend refuses it even when its metadata names a backend":
    let dir = oracleOnlyDir()
    writeFile(dir / "trace_metadata.json",
      """{"recorder_backend":"interpreter"}""")
    let res = detectBackend(dir)
    check res.isErr
    check TestOracleOutputError in res.error

  test "record refuses a trace.json folder with the oracle message":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    let rec = record(cache, testId, oracleOnlyDir(), root)
    check rec.isErr
    check TestOracleOutputError in rec.error
    check testId notin cache.entries

  test "decide re-runs a cached test whose trace is now a trace.json":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTraceDir(), root).isOk
    let d = decide(testId, oracleOnlyDir(), root, cache)
    check d.kind == idRerunFailSafe
    check TestOracleOutputError in d.reason

  test "the CTFS reader refuses a trace.json folder by name":
    let res = readExecutedFunctionsCtfs(oracleOnlyDir())
    check res.isErr
    check TestOracleOutputError in res.error
