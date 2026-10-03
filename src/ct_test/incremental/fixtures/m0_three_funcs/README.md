# M0 fixture: `m0_three_funcs`

A tiny Ruby program (`src/three_funcs.rb`) used by the incremental-testing
suites as the interpreted-language case.

## The program

`main` calls `used_a` and `used_b`. `unused_c` is defined but never called.
So the executed-function set is exactly `{main, used_a, used_b}` and
`unused_c` must be absent. Definition lines (1-based) are pinned in the source
comment: `used_a`=16, `used_b`=20, `unused_c`=24, `main`=28.

## The recording

The recording is a CTFS `.ct` container built at test time by
`../../m0_three_funcs_trace.nim` (`threeFuncsTraceDir()`), through
`codetracer-trace-format-nim`'s `MultiStreamTraceWriter` — the writer the
native Ruby recorder uses. Building it at test time keeps it on the container
version of the pinned trace-format checkout, which also supplies the reader.

It records the source path `/fixtures/m0_three_funcs/src/three_funcs.rb`
(the engine strips the leading slash and resolves it under the test's
`sourceRoot`), the function table `main`, `used_a`, `used_b`, `unused_c`, and
calls to the first three only. Each call's first step is the function's `def`
line, which is where the source hasher reads the body from.

The trace directory carries `trace_metadata.json` with
`recorder_backend: "interpreter"`, so `detectBackend` reads the `.ct` as an
interpreted recording (source-text hashing) rather than a native one.

A `trace.json` event stream is not a recording: it is the output of the
pure-Python and pure-Ruby test oracles, and the engine refuses it
(`test_trace_json_is_refused.nim`).
