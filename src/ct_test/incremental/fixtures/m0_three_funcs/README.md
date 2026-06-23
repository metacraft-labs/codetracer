# M0 fixture: `m0_three_funcs`

A tiny Ruby program (`src/three_funcs.rb`) plus a hand-built CodeTracer JSON
trace (`trace/`) used by the M0 tests of the Trace-Based-Incremental-Testing
prototype. Two sibling trace directories under
`tests/fixtures/` cover the defensive cases:

- `../m0_empty_calls/` — `Function` records but **no** `Call` records (the
  "empty call stream ⇒ empty executed set" test).
- `../m0_malformed/` — a truncated `trace.json` (the "malformed ⇒ Err, no
  crash" test).

## The program

`main` calls `used_a` and `used_b`. `unused_c` is defined but never called.
So the executed-function set is exactly `{main, used_a, used_b}` and
`unused_c` must be absent. Definition lines (1-based) are pinned in the source
comment: `used_a`=16, `used_b`=20, `unused_c`=24, `main`=28.

## Confirmed trace schema (not invented)

The reader targets the JSON trace form (`trace.json` + `trace_paths.json` +
`trace_metadata.json`). This is the form
`codetracer-trace-format/codetracer_trace_writer` emits when the events file
format is `Json`:

```rust
// non_streaming_trace_writer.rs
TraceEventsFileFormat::Json => {
    let json = serde_json::to_string(&self.events)?; // Vec<TraceLowLevelEvent>
    fs::write(path, json)?;
}
```

`TraceLowLevelEvent`
(`codetracer-trace-format/codetracer_trace_types/src/types.rs`) carries no
serde container attribute, so serde's default **externally-tagged** encoding
is used: each event becomes a single-key object `{"<Variant>": <payload>}`.
`trace.json` is the JSON array of those events.

### How the schema was confirmed

The real example recordings under `codetracer-example-recordings/` ship their
`trace.json` in the **binary** (capnp) form, not text JSON (first bytes
`c0 de 72 ac e2 …` = the capnp `HEADER`), so they cannot be read as text. To
get the ground-truth *text-JSON* shape, the exact writer
(`codetracer_trace_writer`, `TraceEventsFileFormat::Json`) was driven over a
representative `Vec<TraceLowLevelEvent>` built from the real
`codetracer_trace_types` structs. It produced:

```json
[{"Path":""},
 {"Path":"/tmp/prog.rb"},
 {"Function":{"path_id":1,"line":1,"name":"main"}},
 {"Function":{"path_id":1,"line":5,"name":"used_a"}},
 {"Call":{"function_id":0,"args":[]}},
 {"Call":{"function_id":1,"args":[]}},
 {"Return":{"return_value":{"kind":"None","type_id":0}}}]
```

The sibling text files were modeled on the real
`codetracer-example-recordings/ruby/flow_test/` recording:

- `trace_paths.json` is a JSON array of strings; the conventional first entry
  is the empty string `""` (verified: that recording's `trace_paths.json` is
  `["", "/tmp/ct-example-recordings-build/ruby_flow_test.rb"]`).
- `trace_metadata.json` is `{program, args, workdir}` (verified against that
  recording's `trace_metadata.json`). M0 does not read it; it is present for
  schema completeness and for later milestones.

### Field semantics relied on by the reader

- `{"Path": "<string>"}` — interns a source path. The 0-based ordinal of a
  `Path` event is its `path_id`, mirroring `trace_paths.json`.
- `{"Function": {"path_id": <int>, "line": <int>, "name": "<str>"}}` — a
  function-table entry; its 0-based ordinal among `Function` events is its
  `function_id`. The newtypes `PathId(usize)`, `Line(i64)`,
  `FunctionId(usize)` serialize as bare integers (serde transparent /
  newtype-struct default). `path_id` indexes `trace_paths.json`.
- `{"Call": {"function_id": <int>, "args": [...]}}` — a call to the function
  table entry at index `function_id`.

Executed functions = the `Function` records referenced by `Call` records, so
the call stream here references `function_id` 0/1/2 (`main`/`used_a`/`used_b`)
and never 3 (`unused_c`).
