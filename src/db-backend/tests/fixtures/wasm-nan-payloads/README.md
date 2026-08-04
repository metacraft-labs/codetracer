# `wasm-nan-payloads` — float NaN payloads across the browser boundary (M52)

A WebAssembly module that computes with the three float values a
JavaScript host could not carry before M52, recorded in a real headless
Chromium through the real `record-web` daemon.

## The values, and why they are hard

| Value | Bits | Why a `Number` loses it |
| --- | --- | --- |
| `f32` signalling NaN | `0x7F800001` | The WebAssembly JS API leaves a NaN's payload implementation-defined across the WASM→JS conversion; the quiet bit here is clear, so quieting alone changes it. |
| `f64` payload NaN | `0x7FF80000DEADBEEF` | Same, plus `JSON.stringify(NaN)` is `null` — there is nothing left to record. |
| `-0.0` | `0x8000000000000000` | `String(-0)` is `"0"` and `JSON.stringify(-0)` is `0`. The sign is a bit no `==` can see. |

`Recording-Backends/WASM-Instrumentation-Layer.md` §7 makes a NaN
payload mismatch a replay **divergence**, so a recording that lost one
was not a faithful re-execution input.

## What was changed

The fix is producer-first. The instrumented module reinterprets a
boundary float to its integer bit pattern *before* the hook fires
(`__ct_emit_f32_bits(slot, i32)` / `__ct_emit_f64_bits(slot, i64)`, via
`i32.reinterpret_f32` / `i64.reinterpret_f64`), so nothing crosses into
JavaScript that a `Number` could damage.
`recorder-runtime/browser_session.js` records the bits as
`f32:0x<8 hex>` / `f64:0x<16 hex>` under the `Float` value kind.

## Layout

```
wasm-src/            the module (Rust, cdylib, dev profile — DWARF kept)
page/                index.html + app.js; plain ES modules, NOT bundled
serve.mjs            static server; mounts the instrumenter's
                     recorder-runtime/ from the checkout, so the recording
                     is made by the working tree's producer
drive.mjs            headless-Chromium driver (playwright from the
                     codetracer checkout's own node_modules)
regenerate.sh        the pipeline
verify.sh            replays the recording and checks the bit patterns
expected-bits.json   the four bit patterns this fixture exists for, as a
                     committed, hand-reviewed oracle. verify.sh reads them
                     from here and checks BOTH that the page asked for
                     them and that the recording carries them

produced into the gitignored target/test-recordings/, not committed:
nan-payloads.ct/     the recording
module/*.wasm        the ORIGINAL module the offline replay runs
observed-bits.json   what the page actually asked for, this run
```

Neither the recording nor the module is committed. They are one artefact —
the replay drives the *original, uninstrumented* module (spec §6.1), so it
has to be that build — and producing them in the same run is what keeps
them one. It matters more here than in any sibling fixture: what the checks
assert is the bit patterns the **browser producer** wrote, so a stored
recording could only ever confirm that some past producer agreed with
itself. `scripts/materialize-recording.sh wasm-nan-payloads` keys its cache
on `ct-instrument` and the `record-web` binary by content, so a change in
either re-records.

The genuine counter-example lives in the sibling repo:
`codetracer-wasm-recorder/.../nan-payloads/legacy-encoding.ct` was made by
a `ct-instrument` built **before** M52 and cannot be produced from any
current tree. That one is committed for the right reason, and must never
be regenerated.

## The page never touches a float

Every value `page/app.js` hands the module and every value it checks is
an integer bit pattern. That is deliberate: a JavaScript `Number` is
precisely what cannot hold these values, so a page that compared floats
would be asserting on the damaged copies and would pass whether or not
M52 worked.

## Running it

```bash
./verify.sh       # record from this tree (cached) and check the bits
./regenerate.sh   # re-record unconditionally  (exit 75 = prerequisite missing)
```

The assertions that gate CI live in the recorder, next to the replayer
they exercise: `codetracer-wasm-recorder/cmd/wazero/nan_payload_test.go`,
driven by a copy of this recording under
`cmd/wazero/testdata/boundary-log/nan-payloads/` — which also holds a
**pre-M52 recording of the same module** as the negative control.
