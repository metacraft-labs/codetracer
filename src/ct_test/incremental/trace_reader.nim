## The executed-function record shared by every incremental-testing backend,
## and the refusal of test-oracle output.
##
## An executed function is a `Function` record referenced by at least one
## `Call` record of a recorded run: the "runtime dependency" set §16.7.2 of
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md`
## describes. Each backend discovers that set from its own trace form — CTFS
## `.ct` containers (`ctfs_trace.nim`, `ctfs_seekable.nim`) and the native
## capture forms (`native_trace.nim`, `native_instrument.nim`).
##
## A `trace.json` event stream is never one of those forms. It is what the
## pure-Python and pure-Ruby test oracles write, to be compared against
## `ct print` of a production recording, and the engine refuses it with the
## same message every other CodeTracer entry point uses.

import std/os
import results

import ../../ct/trace/trace_kind

export results

type
  ExecutedFunction* = object
    ## A function that was executed (called) at least once in the trace.
    name*: string   ## Function name as recorded by the recorder.
    file*: string   ## Source file path the function was entered in.
    defLine*: int   ## 1-based definition line of the function.

const
  TestOracleTraceFile* = TestOracleTraceFileName
    ## `trace.json`: the file the pure-Python and pure-Ruby test oracles write.

proc refuseTestOracleOutput*(traceDir: string): Result[void, string] =
  ## `Err` with the shared test-oracle refusal when `traceDir` holds a
  ## `trace.json` event stream, `ok()` otherwise.
  let oracle = traceDir / TestOracleTraceFile
  if fileExists(oracle):
    return err(testOracleRefusal(oracle))
  ok()
