# Origin-Metadata Modes Benchmark Fixture Corpus

This directory hosts the per-`TraceKind` benchmark fixtures that drive
the spec's §6.8.6.4 / §6.8.6.5 comparison-benchmark suite — one fixture
per `(TraceKind × language)` cell of the matrix:

| Subdirectory | TraceKind | Language | Role |
|---|---|---|---|
| `python_materialized/` | Materialized | Python | Drives the materialized indexer wall-clock + storage assertions. |
| `c_recreator/` | Recreator | C | Drives the native indexer wall-clock + storage assertions. |
| `browser_replay_emulator/` | Emulator | (WASM-replay of an MCR fixture) | Drives the emulator-mode lazy-trigger latency assertions. |

## Per-fixture convention

Each fixture directory ships:

- A canonical source program (`main.<ext>`) — the workload the recorder
  replays for the benchmark.
- `regenerate.sh` — the canonical re-recording entrypoint. The script
  is `set -euo pipefail`; it exits 0 once the recorded `.ct` artefact
  lands under `./trace/`. If the prerequisite recorder is missing the
  script exits 2 with a precise `SKIPPED: <recorder> not on PATH`
  sentinel so the M19 CI runner can surface the gap without churning.
- `MODES.md` — documents what the benchmark expects to measure on this
  fixture, the projected baseline + Mode 3 sizes, and the per-mode
  latency budgets the §6.8.6 deliverable enforces.

## Status

M19 ships the **fixture skeleton** + `MODES.md` documentation; the
recorded `.ct` artefacts plus the `cargo bench`-driven benchmark suite
at `src/db-backend/benches/origin_modes/` are recorder-integration
follow-ons (deferred per the milestone's landed-artefacts block — the
benchmark needs the per-language recorder catalogue from M23). Once
the recorder pipeline emits `originmeta.tc` / `varwrites.tc` /
`source_exprs.tc` end-to-end the benchmark harness lands by:

1. Running each `regenerate.sh` to produce the baseline `.ct` artefact
   (Mode 2 — no metadata streams).
2. Re-running the recorder with `--origin-metadata=on` (Mode 3) and
   `--origin-metadata=lazy` (Mode 3 lazy) to produce the matched
   artefacts.
3. Driving `ct/originChain` + `ct/originSummary` + `ct/load-history` +
   `ct/load-flow` against each artefact under criterion-controlled
   sample windows.
4. Emitting the per-fixture CSV + JSON reports under
   `target/origin-bench-reports/` per the spec's deliverable.

See `Value-Origin-Tracking.milestones.org` (M19 §Deliverables: the
"Comparison benchmark suite" entry) for the full deferred-deliverable
contract.
