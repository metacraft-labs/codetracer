# Modes Benchmark — browser_replay_emulator

**TraceKind:** Emulator (browser-replay of an MCR artefact)
**Workload:** existing emulator-mode MCR fixture replayed in-browser.
The benchmark suite reuses the WASM-instrumenter's representative
contract from `codetracer-wasm-instrumenter/tests/fixtures/origin/`
(any small contract that produces ≥ 1 K writes is sufficient — the
benchmark target is the post-upload artefact size).

## Projected per-mode shape

| Mode | Streams emitted at upload | Trigger | First-query latency |
|---|---|---|---|
| 2 (`--origin-metadata=off`) | none | n/a | n/a |
| 3 (`--origin-metadata=on`) | `originmeta.tc`, `source_exprs.tc` produced eagerly | record-end | n/a |
| 3 lazy (`--origin-metadata=lazy`) | none at upload; per-interval on first query | first DAP origin query | ≤ 60 µs after warmup |

## Budgets the benchmark suite asserts (spec §6.8.6)

* Emulator-mode default is `lazy` per `default_mode_for_trace_kind`
  (the heuristic prefers small uploads since the browser-replay
  artefact is downloaded by every viewer).
* `ct/originChain` Mode 3 lazy p50 ≤ 200 µs after the first per-interval
  populate (eager Mode 3 also satisfies the budget but at the cost
  of upload size).
* Eager-mode `ct/load-history` over a 10 000-entry history ≤ 700 ms.

## Workload selection

This directory does NOT ship its own `main.<ext>` — the emulator
benchmark replays an existing MCR fixture. The benchmark harness
points at:

* `../../../wasm-replay/account-balance/` (when M22 has shipped the
  WASM-replay fixture catalogue), or
* the M23 browser-replay fixture catalogue for a per-language
  contract.

## Status

`MODES.md` skeleton landed with M19; the actual fixture pointer +
benchmark harness land with M22 / M23. The lazy-mode default for the
Emulator `TraceKind` is pinned by the in-tree heuristic
(`test_origin_metadata_default_heuristic_emulator_picks_lazy`).
