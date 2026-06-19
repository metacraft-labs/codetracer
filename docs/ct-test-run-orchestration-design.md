# ct_test Parallel-Run + Partition Orchestration — Design

Status: design (pre-implementation). Consolidates the standalone `ct-test`
repo's high-level test-run orchestration into codetracer's `src/ct_test`
cross-language framework, layered on the provider model and the shared process
runner (`process_exec` → `runquota_process`).

## Goal & layering

Move the **high-level orchestration** — parallel execution, `--partition`
sharding, result aggregation, JSON summary — into `src/ct_test`. Keep the
**low-level process scheduling** (launch, output capture, runquota lease
negotiation) in `runquota_process`, reached through `process_exec.execCaptured`.
ct_test owns *what to run and how to aggregate*; runquota_process owns *how to
launch*.

## Current state

- **Standalone `ct-test` / `apps/ct-test-runner`**: a Nim-test-*binary* runner.
  Process-per-test worker pool (`--threads N` worker threads pulling from a
  single `Lock`-protected queue; main thread joins on a barrier), `--partition
  file:<path>` allow-list filter, and a JSON summary (total / executed /
  skipped-by-partition / passed / failed, threads, wall time). Operates by
  scanning a bin dir, probing each binary for the `--list-json` protocol, and
  running it whole or per-protocol-test.
- **`src/ct_test` (codetracer)**: the cross-language provider framework.
  `runCtTest` exposes only `test discover`. Providers declare capabilities
  (`discover-project/file`, `locate-tests`, `run-project/file/single`,
  `record-*`) and return `seq[TestEvent]`. **No run / parallel / partition
  orchestration exists.**

## Design

### CLI surface

Extend `runCtTest` with a `test run` verb:

```
ct-test test run --workspace <root> [--file <f>]
                 [--partition file:<path>] [--threads N]
                 [--json] [--summary <path>]
```

1. **Enumerate** the candidate tests via the providers' `discover` /
   `locate-tests` (qualified ids from the `TestCatalog` / `TestItem` model).
2. **Filter** by the partition allow-list (`--partition file:` = one qualified
   id per line; `--shard k/N` reserved, mapping to the same allow-list).
3. **Run** each selected test via its owning provider's `run-single`
   (falling back to `run-file` when `canRunSingle` is false), each subprocess
   launched through `process_exec.execCaptured` (runquota_process).
4. **Aggregate** the per-test `seq[TestEvent]` into a run result + JSON summary:
   total discovered, executed, skipped-by-partition, passed, failed, wall time,
   threads.

### Parallelism

Port the standalone worker-pool shape onto the provider model:

- A `Lock`-protected queue of `RunUnit` (one per selected test, carrying the
  provider id + `TestScope`).
- `N` worker threads (`--threads`, default = CPU count; `REPRO_TEST_THREADS`
  override, matching the standalone) each pull a `RunUnit` and call the owning
  provider's `run-single`, appending the returned events to a `Lock`-guarded
  results seq.
- The main thread joins on a barrier and then aggregates.

Process scheduling is **not** reimplemented here: every `run-single` launches
its subprocess through `execCaptured`, so output bounds, wall-time/peak-mem
accounting, and (when a session is configured) runquota lease governance are
uniform. (A single-thread `runquota_process` async-poll variant —
`launchProcess` + `pollCompletion` for N concurrent processes from one thread —
is a future refinement; the thread pool is the faithful port and the providers'
`run` is synchronous today.)

### Partition / CI-sharding integration

`--partition file:<path>` keeps the standalone's format (one fully-qualified
test id per line) so reprobuild's `repro test --shard k/N`
(reprobuild-specs/CI-Sharding.md) can synthesise a partition file and drive the
consolidated runner unchanged — preserving the reprobuild ↔ ct-test
composition. Tests discovered but absent from the partition count as
`skipped_by_partition` (not executed, not failed). Per CI-Sharding.md the
*intelligence* (cost model, bin-packing) stays in `repro test`; ct_test only
consumes the resulting allow-list.

### What moves vs. stays

- **Moves into `src/ct_test`**: the orchestration — queue, worker pool,
  partition filter, summary writer — adapted from `apps/ct-test-runner` to
  operate on the provider model instead of raw test binaries.
- **Stays in `runquota_process`**: launch, capture, lease negotiation (via
  `execCaptured`).
- **Not moved verbatim**: the standalone runner's binary-oriented bits
  (`scanTestBinaries`, the `--list-json` protocol probe). The consolidated
  runner is enumeration/provider-oriented. The standalone `ct-test` repo can
  keep its binary runner for the pure-Nim-binary path (CI-Sharding.md keeps
  `ct-test-runner` usable standalone) or later delegate to the consolidated
  one.

## Tests (no skips, no weakened assertions)

- **Unit**: partition-file parsing + filtering; summary aggregation; worker-pool
  determinism (fixed `--threads` ⇒ stable executed/skip/pass/fail counts).
- **Integration**: `ct-test test run` over an existing multi-test language
  fixture, with and without a partition file, asserting the exact
  executed/skipped/passed/failed counts and the per-test event kinds. Reuses the
  fixtures already in `src/ct_test/fixtures`.

## Milestones

1. `RunUnit` enumeration + partition parse/filter + summary types (pure;
   unit-tested in isolation).
2. Worker-pool execution via `provider.run-single` + `execCaptured`.
3. `test run` CLI wiring + JSON summary output.
4. CI-sharding partition-file compatibility + the integration test.
