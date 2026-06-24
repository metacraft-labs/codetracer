# Slice generation speed + concurrent processing speedup bench (P3)

The `ct-bench slice-prep-speed` subcommand drives the P3 benchmark.
Slices are an MCR concept. For a fixed program (default: the P2
`mid_length_compute` fixture in the selected language), the current
driver records K independent MCR-shaped trace directories as a
slice-prep/concurrency proxy for K ∈ {1, 2, 4, 8, 16}, then runs the
omniscient-prep subprocess against each trace at concurrency
C ∈ {1, 2, 4, 8}.

The bench measures three things:

1. **Trace size overhead** — `(trace_size(K=N) / trace_size(K=1)) - 1`,
   ideally close to zero.
2. **Per-slice prep wall-clock** — `mean(per-slice times)` at each
   K × C cell.
3. **Coordinator reduce wall-clock** — approximated as
   `total_wall_clock − per_slice_wall_clock` and reported per cell.

## How to invoke

```bash
# Default — full 5×4 = 20 cell matrix.
just bench-slice-prep-speed

# Narrower run.
just bench-slice-prep-speed --slice-counts=1,2 --prep-concurrency=1,2

# Different native language through the MCR-compatible ct record path.
just bench-slice-prep-speed --language=c_plus_plus
```

## Reading the report

The CSV columns are `slice_count`, `prep_concurrency`,
`per_slice_wall_clock_ms`, `coordinator_wall_clock_ms`,
`total_wall_clock_ms`, `trace_size_bytes`.

The campaign's headline numbers are:

- "K=16 trace size within 10 % of K=1" — derived by computing
  `(trace_size_bytes(K=16) - trace_size_bytes(K=1)) /
  trace_size_bytes(K=1)` and comparing to 0.10.
- "speedup vs. linear" — `(total_wall_clock_ms(K, C=1) / C) /
  total_wall_clock_ms(K, C)` for each `(K, C)` cell.

Operators chart these from the CSV.

## SKIP discipline

The bench skips narrowly when:

- the per-language recorder is not on PATH, or
- the `ct` (or `replay-server`) binary is not on PATH.

In either case the bench writes the skip reason to stderr and emits
an empty report; operators can spot the missing dependency in the log.
