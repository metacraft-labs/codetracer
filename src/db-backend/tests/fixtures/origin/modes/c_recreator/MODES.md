# Modes Benchmark — c_recreator

**TraceKind:** Recreator (`ct-native-replay`)
**Workload:** `main.c` — accumulator loop, `ITERATIONS = 1024`,
compiled at `-O2 -g`.

## Projected per-mode shape

| Mode | Streams emitted | Indexer wall-clock | Compressed size (approx) |
|---|---|---|---|
| 2 (`--origin-metadata=off`) | `memwrites.tc`, `linehits.tc` | n/a | baseline `S` |
| 3 (`--origin-metadata=on`) | adds `originmeta.tc`, `source_exprs.tc` | 30–90 % of M10f pass | ≤ `1.25 * S` |
| 3 lazy (`--origin-metadata=lazy`) | metadata produced per-interval on demand | per-interval ≤ 90 % overhead | ≤ baseline at upload |

## Budgets the benchmark suite asserts (spec §6.8.6)

* Native Mode 3 indexer wall-clock overhead between 30 % and 90 % on
  top of Mode 2 (CI fails on regression > 1.9×).
* Native Mode 3 compressed storage overhead ≤ 25 % of the baseline
  omniscient log.
* `ct/originChain` Mode 3 p50 ≤ 200 µs on the 10-hop scenario.
* `ct/originSummary` Mode 3 p50 ≤ 60 µs.

## Expected dominant origin chain

Querying `accum` at the `printf` line walks back through the
`chain_step(accum, i)` return capture into the loop's accumulating
`accum = chain_step(...)` write. Each hop pair (forward + return) is
two `TrivialCopy` writes plus one `Computational` (`forwarded + idx`).
The chain terminates at the initial `accum = 0` literal.

## Status

Fixture skeleton landed with M19; recorded `.ct` artefacts + the
benchmark harness land with the recorder-integration follow-on.
