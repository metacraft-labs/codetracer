# Native omniscient timing benchmark

The `ct-bench native-omniscient-timing` subcommand measures the native
product path for a single ordinary C fixture under both MCR and RR.

For each backend, the benchmark records:

1. native program runtime (`native_ms`),
2. `ct record --backend <mcr|rr>` runtime (`record_ms`),
3. `trace omniscient-prep` runtime (`prep_ms`),
4. trace, total prep artifact, `memwrites.tc`, `linehits.tc`, and
   origin-metadata sizes, and
5. ratios relative to native runtime and recording time.

The default fixture is
`src/codetracer-bench/fixtures/product-omniscient/rr_c_arbitrary/main.c`.
It has multiple functions, heap/global/stack writes, and filesystem I/O,
so RR records real events instead of a single trivial execution window.

## How to invoke

```bash
just bench-native-omniscient-timing
just bench-native-omniscient-timing --runs=3
just bench-native-omniscient-timing --backends=rr
```

Output lands in
`src/codetracer-bench/target/codetracer-bench/native-omniscient-timing/`.

## Current interpretation

The benchmark uses the same `ct trace omniscient-prep` invocation helper as
the size and slice-prep benchmarks. It does not force `--trace-kind`; the
product command detects materialized/MCR versus native/RR traces and routes
to the existing implementation for that trace shape. MCR slice/concurrency
scaling remains in the MCR-only `slice-prep-speed` benchmark, while this
benchmark compares per-backend record/prep time for one ordinary fixture.

The size columns deliberately distinguish the files emitted by the product
prep path for the selected backend. Backend-specific production stays behind
the component command reached through `ct trace omniscient-prep`; the benchmark
only times that user-facing request path and reports the artifacts it creates.
