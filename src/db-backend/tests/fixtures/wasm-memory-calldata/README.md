# `wasm-memory-calldata` — host-supplied WebAssembly state

A real browser recording of a WebAssembly module whose **linear memory is
imported** and whose inputs are read out of that memory rather than taken
as arguments, plus the checks that replay it.

It exists because the sibling fixture
[`cross_process/account-balance-with-wasm`](../cross_process/account-balance-with-wasm/)
cannot exercise either of the two host-state records the boundary model
defines. Its `compute_balance(user_id, amount)` is a pure function of two
scalar arguments — the one module shape that needs neither
`WASM-Instrumentation-Layer.md` §3.3 (host-supplied initial state) nor
§3.4 (host mutation during a call). Every module whose host writes its
calldata into linear memory before calling an export needs both: that is
the shape every Stylus contract has, and the shape any `wasm-bindgen`-style
glue layer has.

## What the module does

[`wasm-src/lib.rs`](wasm-src/lib.rs) settles three ledger records.

```
LEDGER  ┌────────────┬───────────┬─────────┬─────────┐  x3
        │ account_id │ principal │ fee_bps │ settled │
        └────────────┴───────────┴─────────┴─────────┘
        + running_total
```

* `account_id` and `principal` are written by the **host**, before the
  first exported call. They are not in the `.wasm`. → **spec §3.3**
* `fee_bps` is written by the **host**, from inside `fetch_fee_bps` — an
  imported function that returns only a *status code* and delivers its
  real answer by writing into memory. → **spec §3.4**
* `settled` and `running_total` are written by the module.

`settle(index)` reads the first two out of memory, calls `fetch_fee_bps`,
reads the fee the host just wrote, settles, accumulates, and returns the
running total. The page calls it three times.

Two properties are deliberate:

* **The module genuinely depends on both records.** Withhold §3.3 and the
  very first host call is made with `account_id = 0` instead of `1001`;
  withhold §3.4 and the first call returns `250000` instead of `246250`.
  Both are hard divergences, not wrong-but-plausible traces —
  `verify.sh` proves it, and printing the two mismatches is the point of
  that script. A fixture whose module carried no state could not tell a
  working implementation from none, which is exactly the gap the M38
  review found in the snapshot tests.
* **The module carries state across calls.** The third call's answer
  depends on the first two having really happened, in memory, in order.

## The layout contract, and why it is a global

The page finds the block through the module's exported **global**
`LEDGER`, which `rust-lld` emits carrying the symbol's address. Asking for
the address through an exported *function* would look equivalent and is
not: the host write would then fall **between two top-level exported
calls**, and neither §3.3 (before the first call) nor §3.4 (during an
imported call) can anchor such a write. The producer detects that case —
for an imported global reassigned between two calls as well as for a
memory write — and reports it rather than dropping it; see
`unrepresentableWrites` in `browser_session.js`. The page fails loudly if
*any* `hostStateDiagnostics` counter is non-zero, checked as a set so a
counter added later cannot be silently ignored.

Reading a global crosses no recorded boundary, so the host can learn the
address and stage its calldata before the first call, which is precisely
what §3.3 describes.

## Files

| Path | What it is |
| --- | --- |
| `wasm-src/` | The Rust module. Built with `-C link-arg=--import-memory`, which is what makes `env.memory` an import. |
| `module/ledger_settle.wasm.zst` | The **original, uninstrumented** module. This is what the replay runs (spec §6.1); handing it the instrumented one is refused. It has to be *this* build — see below — and is committed compressed to stay under the repo's 500 KB per-file cap. `verify.sh` expands it into a temp directory. |
| `page/` | The page: plain ES modules, no bundler. Loads `browser_session.js` straight out of the instrumenter checkout, so the recording is made by the working tree's producer. |
| `page/ledger_settle.instrumented.wasm` | What the browser loaded. **Not committed**: it is only needed to re-record, and `regenerate.sh` rebuilds it together with a fresh recording, so the two cannot drift. Its `.manifest.json` *is* committed, because the manifest is what names the boundary edges. |
| `ledger-settle.ct/` | The committed recording, including `boundary_state.json`. |
| `expected-totals.json` | The three running totals the page observed. Ground truth for the replay check. |
| `serve.mjs`, `drive.mjs` | Static server and headless driver. |
| `regenerate.sh` | Re-records everything. Checks prerequisites **before** deleting anything. |
| `verify.sh` | Replays the committed recording and proves the two divergences. Rebuilds nothing. |

## Why the module is pinned and not rebuilt

The sibling fixture `cross_process/account-balance-with-wasm` commits no
`.wasm` at all — its `balance_calc` is a pure function of its scalar
arguments, so any build of it satisfies the recording.

This one cannot do that. `boundary_state.json` records **absolute**
linear-memory offsets, because the host staged its calldata at whatever
address `rust-lld` gave the `LEDGER` symbol. A module compiled by a
different toolchain puts `LEDGER` somewhere else and the committed
recording stops describing it. Measured: rebuilding from this same
`wasm-src/` moves the block and the replay diverges at the first host
call, reading `principal` where `account_id` should be.

So the recording and that exact binary are one artefact, and the binary is
committed. It is committed compressed because the repo caps a file at
500 KB and a debug build is ~1.5 MB — 1.5 MB of DWARF, which is precisely
what the replay turns into per-line steps and locals, so stripping it
would remove the thing this fixture exists to prove.

## The recording

`ledger-settle.ct/boundary_state.json`, in the schema
`codetracer-wasm-recorder/internal/boundarylog/hoststate.go` reads:

```json
{
  "version": 1,
  "initial": {
    "memories": [{
      "module": "env", "name": "memory", "minPages": 2, "maxPages": 4,
      "data": [{ "offset": 67296, "bytesB64": "<38 bytes, base64>" }]
    }],
    "globals": [], "tables": []
  },
  "mutations": [
    { "afterCrossing": 1, "memoryWrites": [{ "offset": 67304, "bytesB64": "lg==" }], … },
    { "afterCrossing": 3, "memoryWrites": [{ "offset": 67320, "bytesB64": "GQ==" }], … },
    { "afterCrossing": 5, "memoryWrites": [{ "offset": 67336, "bytesB64": "hAM=" }], … }
  ]
}
```

Three things are worth reading off it.

* **The §3.3 record is 38 bytes, not a memory image.** It is a diff
  against the memory as it stood when the page registered it — after
  `WebAssembly.instantiate`, so the module's own data segments (which the
  replayer applies from the `.wasm`) are not in it. What remains is
  exactly the host's contribution.
* **Each §3.4 write is one or two bytes.** A fee of 150 is `0x96`; the
  record stops at the last byte that changed rather than padding out to
  the `u32`, let alone to a page. See the "byte-exact runs, not pages"
  section of `host_state.js` for why.
* **`afterCrossing` is `[1, 3, 5]`.** Crossing 0 is the first `settle`,
  crossing 1 the `fetch_fee_bps` inside it, crossing 2 the second
  `settle`, and so on. The producer predicts the number the replayer's
  assembler will assign; if it predicted wrongly the mutation would be
  applied at the wrong call, and the replay would diverge.

## Running the checks

```bash
./verify.sh          # replays the committed recording; rebuilds nothing
./regenerate.sh      # re-records from scratch (needs a headless Chromium)
```

`verify.sh` prints, among other things:

```
[verify] 3/4 withholding the §3.3 initial state
[verify]     ok: … import argument 0 mismatch at crossing #1 …
[verify]       recorded: i32:1001
[verify]       actual:   i32:0
[verify] 4/4 withholding the §3.4 host mutations
[verify]     ok: … exported return value 0 mismatch at crossing #0 …
[verify]       recorded: i32:246250
[verify]       actual:   i32:250000
```

## One expected diagnostic

The replay prints

```
Error constructing DWARF data. Tracing will not work: decoding dwarf
section info at offset 0x0: too short
```

That is **not** about `ledger_settle.wasm`, whose DWARF is complete and
whose materialised trace does carry per-line steps and locals. It comes
from the tiny module `internal/boundarylog/provider.go` synthesises to
*define* the imported memory — wazero's `HostModuleBuilder` can only
export functions, so anything else needs a real module. That module has no
DWARF sections, and the decoder reports the fact for every module it
compiles. `internal/testing/maintester/dwarfwarn.go` already exists to
filter the same message out of the recorder's own tests.

Any recording with a host-supplied memory will show it. It is noise, not a
failure — but do not let it hide a real one. `verify.sh` fails if the
replay produces no CTFS container, and then insists on six strings that
only DWARF-driven stepping can put there. The load-bearing one is
`fee_for`: it is a private helper that **no boundary crossing mentions**,
so it can only have come from the offline re-execution walking the
module's interior. `settle` alone would prove nothing — it is an export
name the recording already carries.

The message itself is worth suppressing at source one day, since "Tracing
will not work" is false for the guest and the module it is really about is
one CodeTracer synthesises rather than one the user supplied. That is a
change to `internal/wasm/binary/decoder.go`'s DWARF-less path in
`codetracer-wasm-recorder`, not to anything here.
