## The `m0_three_funcs` recording: a CTFS `.ct` of the Ruby program
## `fixtures/m0_three_funcs/src/three_funcs.rb`, written through
## `codetracer-trace-format-nim`'s `MultiStreamTraceWriter` — the writer the
## native Ruby recorder uses — so the incremental engine's source path is
## exercised against the container production recorders emit.
##
## The recording is built at test time rather than committed, so it always
## matches the container version of the pinned trace-format checkout that also
## supplies the reader.
##
## What it records (the ground truth the tests assert against):
##
##   * one source path, `/fixtures/m0_three_funcs/src/three_funcs.rb` — the
##     engine strips the leading slash and resolves it under the test's
##     `sourceRoot`;
##   * the function table `main`, `used_a`, `used_b`, `unused_c`;
##   * calls to `main`, `used_a` and `used_b` only, each entering at its `def`
##     line (28, 16, 20), which is where the source hasher looks for the body;
##     `unused_c` is defined but never called, so it is never an executed
##     function.
##
## The trace directory also carries `trace_metadata.json` with
## `recorder_backend: "interpreter"`, which tells `detectBackend` this `.ct`
## comes from an interpreted recorder (source-text hashing) rather than a
## native one (instruction-byte hashing).

import std/[os, json]
import results

import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/call_stream
import codetracer_trace_types

const
  ThreeFuncsSourcePath* = "/fixtures/m0_three_funcs/src/three_funcs.rb"
  ThreeFuncsBundleName* = "three_funcs.ct"
  ThreeFuncsExecuted* = ["main", "used_a", "used_b"]
  ThreeFuncsUncalled* = "unused_c"

proc buildThreeFuncsTrace*(traceDir: string): Result[string, string] =
  ## Write the recording into `traceDir` (created if needed) and return
  ## `traceDir`.  Any writer failure is an `Err`.
  try:
    createDir(traceDir)
  except CatchableError as e:
    return err("createDir " & traceDir & ": " & e.msg)
  let bundle = traceDir / ThreeFuncsBundleName
  removeFile(bundle)
  var wRes = initMultiStreamWriter(bundle, ThreeFuncsSourcePath)
  if wRes.isErr:
    return err("initMultiStreamWriter: " & wRes.error)
  var w = wRes.get()
  w.metadata.workdir = "/fixtures/m0_three_funcs"

  let pRes = w.registerPath(ThreeFuncsSourcePath)
  if pRes.isErr:
    return err("registerPath: " & pRes.error)
  let src = pRes.get()

  var ids: array[4, uint64]
  for i, name in ["main", "used_a", "used_b", ThreeFuncsUncalled]:
    let r = w.registerFunction(name)
    if r.isErr:
      return err("registerFunction " & name & ": " & r.error)
    ids[i] = r.get()

  template step(line: uint64) =
    let s = w.registerStep(src, line, [])
    if s.isErr:
      return err("registerStep " & $line & ": " & s.error)

  template call(fnId: uint64) =
    let c = w.registerCall(fnId, [])
    if c.isErr:
      return err("registerCall: " & c.error)

  template ret() =
    let r = w.registerReturn()
    if r.isErr:
      return err("registerReturn: " & r.error)

  # main (def 28) -> used_a (def 16), used_b (def 20); unused_c never called.
  # Each call's first step is its `def` line, as the Ruby recorder records a
  # method's call event.
  call(ids[0]); step(28)
  step(29)
  call(ids[1]); step(16); step(17); ret()
  step(30)
  call(ids[2]); step(20); step(21); ret()
  ret()

  let cl = w.close()
  if cl.isErr:
    return err("close: " & cl.error)
  let bytes = w.toBytes()
  w.closeCtfs()
  try:
    writeFile(bundle, cast[string](bytes))
    writeFile(traceDir / "trace_metadata.json", $(%*{
      "recorder_backend": "interpreter",
      "program": ThreeFuncsSourcePath,
      "args": [],
      "workdir": "/fixtures/m0_three_funcs"}))
  except CatchableError as e:
    return err("write " & traceDir & ": " & e.msg)
  ok(traceDir)

var cachedTraceDir: string

proc threeFuncsTraceDir*(): string =
  ## The recording's trace directory, built once per process under the temp
  ## dir.  A build failure is a test-setup bug, so it raises.
  if cachedTraceDir.len == 0:
    let dir = getTempDir() / ("ct_m0_three_funcs_" & $getCurrentProcessId()) /
      "trace"
    let built = buildThreeFuncsTrace(dir)
    if built.isErr:
      raise newException(IOError, "building the m0_three_funcs recording: " &
        built.error)
    cachedTraceDir = built.value
  cachedTraceDir
