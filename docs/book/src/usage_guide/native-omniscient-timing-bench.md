# Native omniscient timing benchmark

The `ct-bench native-omniscient-timing` subcommand measures the native
product path for a single ordinary C fixture under both MCR and RR.

For each backend, the benchmark records:

1. native program runtime (`native_ms`),
2. `ct record --backend <mcr|rr>` runtime (`record_ms`),
3. `trace omniscient-prep --trace-kind native` runtime (`prep_ms`),
4. trace and omniscient artifact sizes, and
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

RR currently has a wired native omniscient-prep product path. MCR recording
is measured by this benchmark, but MCR prep is reported through the `error`
column when the native prep subprocess rejects an MCR `.ct` container. That
is intentional: MCR slice/concurrency scaling belongs to the MCR-only
`slice-prep-speed` benchmark, while this benchmark compares the available
per-backend record/prep product path without inventing RR slices.
