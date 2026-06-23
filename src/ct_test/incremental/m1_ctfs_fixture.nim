## Self-contained modern split-stream CTFS `.ct` fixture builder for the M1
## seekable-executed-function tests.
##
## Writes a real multi-stream `.ct` via `codetracer-trace-format-nim`'s
## `MultiStreamTraceWriter` (the SAME writer the native / native-Ruby recorders
## use), so the M1 tests exercise the production reader against a production
## bundle — not a hand-rolled stand-in.  The bundle carries:
##
##   * several functions, EACH called at least once (so the executed set is the
##     non-trivial subset of the function table), plus one function that is
##     DEFINED but never called (it must NOT appear in the executed set);
##   * enough steps, written with a deliberately SMALL exec-stream chunk size,
##     that the step stream spans MANY chunks — so a test can prove the seekable
##     read only inflates a BOUNDED handful of step chunks (the call-entry ones)
##     rather than the whole stream;
##   * the dedicated `calls.dat` call stream (the writer sets `has_call_stream`),
##     so the seekable reader's `calls.dat`/`calls.idx` path is taken.
##
## Each function's FIRST call enters at a step on a distinct (path, line), so the
## best-effort def-file / def-line resolution has a concrete site to recover and
## the matches-ct-print parity check is meaningful.

import std/os
import results

import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/call_stream
import codetracer_trace_writer/cbor
import codetracer_trace_types

type
  M1Fixture* = object
    ## A generated fixture and the ground-truth it was built from.
    path*: string                 ## absolute `.ct` path
    executedNames*: seq[string]   ## names that WERE called (sorted)
    uncalledName*: string         ## a defined-but-never-called function name

proc encodeInt(v: int): seq[byte] =
  var enc = CborEncoder.init()
  enc.encodeCborValueRecord(ValueRecord(kind: vrkInt, intVal: v, intTypeId: TypeId(0)))
  enc.getBytes()

proc buildM1Fixture*(outPath: string;
    columnAware: bool = false): Result[M1Fixture, string] =
  ## Build the fixture at `outPath`.  Returns the path plus the ground-truth
  ## executed / uncalled function names.  Uses a small exec chunk size so the
  ## step stream is multi-chunk (see module docs).
  ##
  ## Layout: function `f0`..`f3` are each called once; `unused` is defined (its
  ## name is interned via a value/varname site is NOT enough — we intern it as a
  ## function id but never emit a `call` for it).  Steps walk a single source
  ## file `prog.rb`; each call enters at a distinct line.
  ##
  ## When `columnAware` is set the writer opts into column-aware step encoding
  ## (`enableColumnAwareSteps`) and registers the path with a per-line
  ## line-length table, so the exec stream stores byte-offset
  ## `global_position_index` values — exactly the shape the PRODUCTION Python
  ## recorder emits.  This exercises the reader's `decodeGlobalPositionIndex`
  ## def-line resolution path (distinct from the line-only `resolveGli` path),
  ## guarding the column-aware regression the line-only fixture cannot catch.
  removeFile(outPath)  # ensure a clean write
  var wRes = initMultiStreamWriter(outPath, "m1_demo", chunkSize = 8)
  if wRes.isErr:
    return err("initMultiStreamWriter: " & wRes.error)
  var w = wRes.get()
  w.metadata.workdir = "/workspace/m1"

  if columnAware:
    w.enableColumnAwareSteps()

  # A per-line line-length table covering well past the highest line we touch
  # (line 40), so column-aware GLI byte offsets resolve back to the right line.
  var lineLengths: seq[uint32] = @[]
  for _ in 0 ..< 64:
    lineLengths.add 80'u32  # 80 addressable columns per line (ample)
  let pRes =
    if columnAware: w.registerPath("/workspace/m1/prog.rb", lineLengths)
    else: w.registerPath("/workspace/m1/prog.rb")
  if pRes.isErr:
    return err("registerPath: " & pRes.error)
  let p0 = pRes.get()

  # Function table: f0..f3 will be called; `unused` will NOT.
  var fnIds: seq[uint64] = @[]
  let names = @["f0", "f1", "f2", "f3"]
  for n in names:
    let r = w.registerFunction(n)
    if r.isErr: return err("registerFunction " & n & ": " & r.error)
    fnIds.add r.get()
  let unusedRes = w.registerFunction("unused")
  if unusedRes.isErr: return err("registerFunction unused: " & unusedRes.error)

  let vnRes = w.registerVarname("x")
  if vnRes.isErr: return err("registerVarname: " & vnRes.error)
  let vnX = vnRes.get()
  let tRes = w.registerType("int")
  if tRes.isErr: return err("registerType: " & tRes.error)
  let tInt = tRes.get()

  # Emit a run with 4 calls, each entering at a distinct line, separated by
  # filler steps so the step stream spans several 8-event chunks.  The call's
  # entry_step is the step index at which we register the call.
  var stepIdx = 0
  let callLines = @[10'u64, 20, 30, 40]  # def line per function f0..f3
  for ci in 0 ..< fnIds.len:
    # Many filler steps before each call so the step stream spans FAR more
    # chunks than there are calls.  With chunkSize = 8 and ~16 filler steps per
    # call, the four call-entry steps land in at most four distinct chunks while
    # the whole step stream is ~17 chunks — so a bounded seekable read inflating
    # only the call-entry chunks is strictly fewer inflations than a
    # whole-stream scan, making the bounded-decompression assertion meaningful.
    for f in 0 ..< 16:
      let vals = @[VariableValue(varnameId: vnX, typeId: tInt,
        data: encodeInt(stepIdx))]
      let sr = w.registerStep(p0, uint64(100 + stepIdx), vals)
      if sr.isErr: return err("registerStep filler: " & sr.error)
      inc stepIdx
    # The call-entry step sits on the function's definition line.
    let entryVals = @[VariableValue(varnameId: vnX, typeId: tInt,
      data: encodeInt(stepIdx))]
    let esr = w.registerStep(p0, callLines[ci], entryVals)
    if esr.isErr: return err("registerStep entry: " & esr.error)
    let cr = w.registerCall(fnIds[ci], @[
      CallArg(varnameId: vnX, value: encodeInt(ci))])
    if cr.isErr: return err("registerCall: " & cr.error)
    inc stepIdx
    # Return immediately so the call's exit_step is well-defined.
    let rr = w.registerReturn(encodeInt(ci))
    if rr.isErr: return err("registerReturn: " & rr.error)

  let cl = w.close()
  if cl.isErr: return err("close: " & cl.error)
  let bytes = w.toBytes()
  w.closeCtfs()
  try:
    writeFile(outPath, cast[string](bytes))
  except CatchableError as e:
    return err("writeFile " & outPath & ": " & e.msg)

  ok(M1Fixture(
    path: outPath,
    executedNames: @["f0", "f1", "f2", "f3"],
    uncalledName: "unused"))
