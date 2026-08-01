# `wasm-parity-corpus` — the recording pipeline for the §10 parity corpus

Four real browser recordings of four WebAssembly modules, plus the scripts
that produce and check them. The recordings are consumed by
`codetracer-wasm-recorder`; this directory is where they are *made*.

## Why it exists

`Recording-Backends/WASM-Instrumentation-Layer.md` §10 states
cross-modality parity as a general property:

> Record module M in the browser, producing a boundary log. Re-execute M
> from that log in `codetracer-wasm-recorder`, producing trace A. Record M
> directly in `codetracer-wasm-recorder` with a live host, producing trace
> B. **A and B must be equal modulo timestamps.**

Until M45 it was demonstrated on one module — `balance_calc`, in
[`cross_process/account-balance-with-wasm`](../cross_process/account-balance-with-wasm/)
— whose only export is a pure function of its two scalar arguments. A pure
module is the weakest possible witness for a replay: its trace does not
depend on the state the call starts from, so the comparison cannot
distinguish a working entry state from none.

The complementary hole was on the other side. The recorder's other
state-carrying fixture, `grow_mem.wasm`, is a hand-written `.wat` with no
DWARF, so its `steps.dat`, `types.dat` and `events.dat` are zero bytes and
every byte-identity comparison over it compares empty streams. Trace
*content* was pinned on a stateless module and *state* on a contentless
one.

Every module here has both.

## The four modules

| Module | Recording | What it is for |
| --- | --- | --- |
| `loop_digest` | `loop-digest.ct` | Loops and a three-deep call nest, over a digest that folds into itself. |
| `pair_stats` | `pair-stats.ct` | A **multi-value** export — the boundary carries a result tuple. |
| `vault_apply` | `vault-apply.ct` | An **imported memory** the host stages (spec §3.3) and an import that answers by writing into it (spec §3.4). The shape every Stylus contract has. |
| `tick_ledger` | `tick-ledger.ct` | Twenty-four exported calls, so a replay spans several snapshots and several slices. |

All four carry state across exported calls: an export answers differently
to the same argument depending on what came before. All four are
`#![no_std]` Rust built with `-C debuginfo=2`.

Two module-specific notes — why `pair_stats` needs a hand-written
assembly wrapper and a link-arg filter, and why `vault_apply` imports its
memory and its function from *different* host modules — are written
against the code in `modules/pair_stats/wrap.s`,
`lld-explicit-exports` and `modules/vault_apply/lib.rs`, and summarised in
the consumer-side README at
`codetracer-wasm-recorder/cmd/wazero/testdata/boundary-log/parity-corpus/README.md`.

## Layout

```
regenerate.sh          re-records everything (needs a headless Chromium)
verify.sh              records from this tree (cached) and replays
serve.mjs              static server; mounts the instrumenter's
                       recorder-runtime/ from the checkout
drive.mjs              headless driver
page-shared/           index.html + harness.js, shared by all four pages
lld-explicit-exports   rust-lld wrapper used only by pair_stats
modules/<name>/
    lib.rs                       the module
    wrap.s                       pair_stats only
    page/app.js                  the page's own tier
    page/<name>.instrumented.wasm(+.manifest.json)
                                 what the browser loaded; built beside the
                                 page that serves it, not committed

produced into the gitignored target/test-recordings/, not committed:
modules/<name>/
    module/<name>.wasm           the ORIGINAL, uninstrumented module
    <program>.ct/                the browser recording
    expected.json                what the page observed
```

## Why each module is produced with its recording, not committed

The offline replay runs the **original, uninstrumented** module (spec
§6.1) and checks every recorded crossing against it, so a module compiled
by a different toolchain — with different export names, different import
indices, or (for `vault_apply`, whose `boundary_state.json` records
**absolute** linear-memory offsets) a different address for its `VAULT`
block — no longer describes the recording.

Each module and its recording are therefore **one artefact**. Both used to
be committed, which keeps them together — and also kept them together with
an instrumenter and a browser recorder that had since moved on, so the
replay went on succeeding about a pipeline that no longer existed.
`regenerate.sh` now writes each module beside the recording it belongs to,
and `scripts/materialize-recording.sh wasm-parity-corpus` re-runs it
whenever `ct-instrument` or the `record-web` binary changes.

They are written uncompressed: the zstd step existed only to squeeze each
~0.6 MB debug build under the repo's 500 KB cap on a *committed* file.

## The sibling repo's copies are captures, not a sync

`regenerate.sh` used to end by copying each fresh recording, module,
manifest and `expected.json` into
`codetracer-wasm-recorder/cmd/wazero/testdata/boundary-log/parity-corpus/`.
That stage is **gone**. It made the two repos agree by construction, and
the agreement then held after the producer changed, because the last sync
had frozen it — nothing ever asked whether the copies still described what
the pipeline emits.

That repo replays recordings it does not make, so it keeps its corpus as a
deliberately captured vector set (its Go suite must stand alone). What
checks the capture is now an explicit comparison there:
`just verify-vectors`, which records these four demos from *this* tree and
compares every crossing, value and format witness against the committed
vectors.

## Running

```bash
./verify.sh          # record from this tree (cached) and replay
./regenerate.sh      # re-record unconditionally (needs a headless Chromium)
./regenerate.sh vault_apply    # one module
```

`regenerate.sh` checks every prerequisite **before** deleting anything and
exits 75 (`EX_TEMPFAIL`) with the full list if one is missing. Nothing here
fabricates trace content: a plausible fake recording is far worse than an
absent one, because it makes the checks that consume it report success
without exercising anything.

## `vault_apply` also carries M44b

Its recording carries its spec §3.3 / §3.4 state twice: in the
`boundary_state.json` sidecar, which a batch replay reads at startup, and
as `wasm-host-state` `Event` records inside `trace.json`, which is the
only carrier a **streaming** consumer can use. `verify.sh` checks for
both. The two must agree — `LoadRecording` refuses a recording where they
do not, because picking one would serve two different programs to the two
drivers.
