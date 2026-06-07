# GUI-feature latency matrix benchmark (P4)

The `ct-bench gui-ops` subcommand drives the P4 benchmark — a
backend × platform × language × operation matrix of wall-clock
latencies.

The bench measures the V1 set of 11 user-triggered operations:

- `ct/load-locals`
- `ct/load-history(1K)` + `ct/load-history(10K)`
- `ct/load-flow`
- `ct/originChain`
- `ct/originSummary(batch)`
- `tracepoint-eval`
- `jump-to-line` + `jump-to-call`
- `reverse-step` (RR / MCR / TTD only)
- `watchpoint` (RR / MCR / TTD only)

…against five backends (`materialized`, `rr`, `mcr-omniscient`,
`mcr-no-omniscient`, `ttd`) across three platforms (`linux`, `macos`,
`windows`) and 2 default languages (`python`, `c_plus_plus`).

## Matrix shape

The campaign's V1 measurements ship for:

- Python materialized + Linux.
- C++ RR + Linux.
- C++ MCR-with-omniscient + Linux.
- C++ MCR-without-omniscient + Linux.

Every other cell — including TTD (Windows-only) and the macOS /
Windows columns — is reported as `PENDING` so the matrix is visible
to capacity planners. The Markdown report renders each pending cell
as the literal string `PENDING`.

## How to invoke

```bash
just bench-gui-ops
just bench-gui-ops --backends=materialized,rr
just bench-gui-ops --operations=ct/load-locals,ct/originChain
just bench-gui-ops --languages=python
```

Output lands in
`src/codetracer-bench/target/codetracer-bench/gui-ops-latency/`.

## Reading the report

Each row in the report is an operation; each column is a
`<backend>-<platform>-<language>` triple. Cell content is either:

- `p50=X.XXms p95=Y.YYms` — the measured numbers, or
- `PENDING` — the cell is intentionally not measured.

## Driver wiring

The per-cell measurement loop spawns a `replay-server dap-server
--stdio` subprocess against a pre-recorded fixture, sends one DAP
request per operation, and times each round-trip with
`std::time::Instant`. The driver iterates 100× per cell by default
(configurable via `--iterations`) and reports the p50 / p95 of the
resulting distribution.

The campaign currently ships the driver scaffolding; the per-cell DAP
plumbing is a separate post-P4 follow-on once the headless DAP
harness stabilises. Until then every cell renders as PENDING with
the precise sentinel:

```
dap-driver pending: <backend> <language> <operation>
```

…which surfaces the deferred state honestly per the campaign's
"every unmeasured cell shows up explicitly" requirement.

## Tracepoint benchmark extension

The campaign also asks for the existing `tracepoint_interpreter`
benchmark to emit through the matrix format. The current state: the
benchmark file is not present in
`codetracer/src/db-backend/benches/`. The
`tracepoint_benchmark_emits_matrix_format` verification test SKIPs
with that observation so the gap is visible — once the benchmark
file lands, wiring it through the matrix format reuses this crate's
`BenchReport` shape.
