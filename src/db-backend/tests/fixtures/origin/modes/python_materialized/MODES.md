# Modes Benchmark — python_materialized

**TraceKind:** Materialised (`codetracer-python-recorder`)
**Workload:** `main.py` — accumulator loop, `ITERATIONS = 1024`.

## Projected per-mode shape

| Mode | Streams emitted | Indexer wall-clock | Compressed size (approx) |
|---|---|---|---|
| 2 (`--origin-metadata=off`) | none | n/a | baseline `S` |
| 3 (`--origin-metadata=on`) | `varwrites.tc`, `originmeta.tc`, `source_exprs.tc` | ≤ 1 s | ≤ `1.05 * S` |
| 3 lazy (`--origin-metadata=lazy`) | `varwrites.tc` only at record-end; metadata on first query | ≤ 5 ms first query | ≤ `1.01 * S` at upload |

## Budgets the benchmark suite asserts (spec §6.8.6)

* Materialised Mode 3 indexer wall-clock ≤ 1 s on a 1 M-step fixture
  (this fixture is 1 K iterations × ~16 steps/loop ≈ 16 K steps; the
  benchmark also runs against a 1 M-step variant in CI).
* Materialised Mode 3 compressed storage overhead ≤ 5 % of the
  baseline.
* `ct/originSummary` p50 ≤ 60 µs in Mode 3.
* `ct/originChain` p50 ≤ 200 µs on a 10-hop chain in Mode 3.
* `ct/load-history` over a 10 000-entry history ≤ 700 ms in eager
  Mode 3.

## Expected dominant origin chain

Querying `accum` at the `print(accum)` line yields a chain dominated by
`TrivialCopy` forwards (`forwarded = accum`, `accum = chain_step(...)`)
and `Computational` hops (`bumped = forwarded + idx`). The chain stops
at the literal `accum = 0` initialisation at the top of `main`.

## Status

Fixture skeleton landed with M19; recorded `.ct` artefacts + the
benchmark harness land with the recorder-integration follow-on per the
M19 milestone's deferred deliverable list.
