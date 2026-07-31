# Expected recordings — Account Balance cross-process demo

What the three recordings contain, and what an origin query on the
server's `balance` is expected to produce.

**This file describes recorded reality, not a design intention.**
Everything below was read back out of the committed `.ct` containers.
Re-run `regenerate.sh` after changing any demo source file and refresh
this document from the new recordings — the tests assert against the
source lines these recordings reference, so the two move together.

The tests do **not** parse this file. It exists so a human reviewing a
failure can tell at a glance whether the recordings or the algorithm
changed.

## The three recordings

### `frontend.ct` — browser JavaScript

Recorded by `@codetracer/vite-plugin` (instrumentation) into
`ct record-web` (transport + writer). Source attribution comes from the
manifest the plugin ships to the daemon.

| | |
| --- | --- |
| paths | `frontend/app.js` |
| functions | `<module>` @1, `submitBalance` @37, one arrow @80 |
| markers | 3 |

Execution reaches `submitBalance` with the recorded arguments `42`,
`100`, `"req-0001"`, and steps through the WASM call, the marker, and
the `fetch`.

Markers, in order:

| direction | boundary | key | shown |
| --- | --- | --- | --- |
| `send` | `js-wasm-realm` | `1` | `wasm export #1` |
| `recv` | `js-wasm-realm` | `2` | `wasm export #1` |
| `send` | `account-balance` | `req-0001` | `620` (names `result`) |

The first two are the call into WebAssembly and the return from it; the
third is the HTTP request to the server.

### `frontend-wasm.ct` — in-browser WebAssembly

Recorded by `ct-instrument` (bytecode rewriting) into the same
`ct record-web` daemon over a separate session, which is why it lands as
its own `.ct`.

| | |
| --- | --- |
| paths | `wasm-src/lib.rs` |
| functions | `compute_balance` @71 |
| markers | 2 (one pair for the single realm crossing) |

Function names come from the module's WASM `name` section; the source
file and line come from **DWARF**, read out of the module by
`ct-instrument`. `compute_balance` resolves to its declaration line
exactly.

The module's value stream is its **boundary** with the host: the
arguments of every exported call and the values it returns (see the
instrumentation-layer spec §§ 1–4). Nothing inside the module is
recorded, and nothing needs to be — a WebAssembly module is
deterministic given its imports, so the interior is reconstructed
offline by re-executing the same `.wasm` against this log (spec § 6).

Three steps, all on `lib.rs:71`, which is the only position the module
reports:

```
step 0   compute_balance entered
step 1   compute_balance:arg0 = 42
         compute_balance:arg1 = 100
step 2   compute_balance:ret0 = 620
```

The tuple positions are the binding names because that is all the
recording can honestly say: WebAssembly boundary signatures are
positional and carry no parameter names. Each tuple lands on a step of
its own so an origin walk can find the step at which a value first
appears.

`compute_balance` computes in locals through two private helpers
(`loyalty_bonus`, `amount_credit`) and writes nothing to linear memory.
Those helpers are not exports, so they do not appear here at all. An
earlier revision of this demo staged the computation through a
linear-memory ledger so that store instrumentation would have something
to observe; that model is withdrawn (spec §§ 2 and 11), and this
recording is the evidence that boundary capture works on code nobody
bent to suit it.

### `backend.ct` — Node.js server

Recorded by `codetracer-js-recorder record`, written as a CTFS
container (`backend.ct/server.ct`).

| direction | boundary | key | shown |
| --- | --- | --- | --- |
| `recv` | `account-balance` | `req-0001` | `620` (names `balance`) |

## How the boundaries pair

```
frontend.ct       send js-wasm-realm    key=1         ─┐
frontend-wasm.ct  recv js-wasm-realm    key=1         ─┘  JS calls into WASM

frontend-wasm.ct  send js-wasm-realm    key=2         ─┐
frontend.ct       recv js-wasm-realm    key=2         ─┘  WASM returns to JS

frontend.ct       send account-balance  key=req-0001  ─┐
backend.ct        recv account-balance  key=req-0001  ─┘  JS posts to the server
```

Pairing is string equality on `(boundary, key)` with opposite
directions. Verify with:

```bash
ct print --filter markers frontend.ct
ct print --filter markers frontend-wasm.ct
ct print --filter markers backend.ct/server.ct
```

## The expected origin query

**Query:** `balance`, at the `const balance = payload.balance;` line of
`backend/server.js`, with all three recordings loaded via
`session.toml`.

**Observed result** (read back from the committed recordings):

```
spans:  backend        hops 0..1
        frontend-js    hops 2..2
        frontend-wasm  hops 3..3

hops:   [0] FieldAccess   backend/server.js:72   balance <- payload.balance
        [1] TrivialCopy   backend/server.js:64   payload <- JSON.parse(raw)
        [2] FunctionCall  frontend/app.js:43     result  <- wasm.compute_balance(userId, amount)
        [3] Unknown       wasm-src/lib.rs:71     compute_balance:ret0
```

Reading it as a story: the chain starts in `backend.ct` and walks back
from `balance` to where the request payload entered the process. That
tail lands on the `recv account-balance` marker, so the composer crosses
into `frontend.ct` at the matching `send` and continues on `result` —
the binding the marker named. `result` traces back to the
`compute_balance` call, which carries the `recv js-wasm-realm` marker,
so the walk crosses once more into `frontend-wasm.ct`.

There it resumes on `compute_balance:ret0`. That name is not declared by
the page: the value crossing out of a WebAssembly export *is* its
result, so the recorder names the crossing binding from the result it
just recorded. (Contrast the HTTP boundary, where `app.js` has to name
`result` explicitly — a program can hand any of its bindings across, so
only the program knows which.)

And there it stops. The walk does notice that the WebAssembly frame was
itself entered across the realm boundary — `frontend-wasm.ct`'s `recv
js-wasm-realm` marker sits at step 1, one step from the `ret0` hop at
step 2, inside the ±1-step window the composer matches markers to hops
with — but that marker's counterpart is the `send` in `frontend.ct`,
the recording the walk had just arrived from. Following it would
re-cross the boundary it had just entered through and ask the
JavaScript side to explain a value it has already explained. The value
that entered (`compute_balance`'s arguments) is not the value that left,
and relating the two means executing the module's interior, which is
what the offline replay of spec § 6 is for. So the walk declines, and
the chain closes in `frontend-wasm.ct`.

### The trailing span this chain used to have (M36b)

Until M36b the chain carried a fourth span — an empty `frontend-js` —
and closed with the terminator `unknownVariable / key`. Both came from
the same place, and the mechanism is worth stating because the outcome
alone made it look cosmetic.

The composer resumes a walk in the sibling recording on the binding the
matched `send` marker names, which is the marker's `show_text` field.
The JS-side realm markers carry no `show_text`: `browser_session.js`
names the crossing binding only on the side that *sends* a value it has
itself recorded, and the JavaScript side of a module *entry* has no
binding to name — the arguments came from an expression, not from a
variable the page declared. (M35 gave the export's outbound edge a real
name, `compute_balance:ret0`, and M39 gave the import edge its own
spelling, but that spelling lives in `show_value`. The producer is
right; nothing on the page can name this one.)

The composer used to fall back to `key_text` — which is not a binding
at all but the label of the correlation *key* expression, and which is
the literal string `key` for every marker a recorder synthesises. So it
crossed back into `frontend.ct` and asked it for the origin of a
variable named `key`. No program has one, so the sibling returned no
hops, the span was empty, and the chain closed reporting a failed
lookup for a name the program never had.

Two fixes, both in `db-backend/src/cross_process_origin.rs`. An absent
`show_text` now means "the sender named no binding", which terminates
the continuation cleanly instead of manufacturing a variable; and the
composer refuses a marker pair that would return the walk to the
recording it just arrived from over the same boundary. On this fixture
the second fires first, so the span is gone rather than merely honest.
`the_chain_terminates_in_the_wasm_recording_rather_than_on_a_name_no_marker_used`
in `cross_process_three_trace_dap_test.rs` pins the result.

**Asserted by the tests:**

- `crossProcessSpans.len() >= 2` — the walk left the server recording.
- `crossProcessSpans[0].role == "backend"` — it starts where the query did.
- `frontend-js` **and** `frontend-wasm` appear among the span roles —
  both boundaries walked in a single query.
- At least one hop carries a populated `correlationTransition`, and
  every such hop names both its boundary and the recording it correlates
  with. Without this the UI has a boundary it cannot draw.
- At least one hop resolves to `app.js` — the user-visible payoff: a
  value observed on the server, explained by front-end source.
- At least one hop resolves to `lib.rs`, and the `frontend-wasm` span
  indexes a real hop rather than being a placeholder.

And, since M36b, in a second test:

- **No** span is a placeholder, the **last** span is `frontend-wasm`,
  and no span re-enters the recording the previous one came from over
  the same boundary.
- The terminator is not `unknownVariable`, and its expression is not
  `key`. A chain that reports a failed lookup for a name no marker
  supplied is not a shorter chain — it is a wrong one, and the
  property assertions above cannot tell the two apart.

Exact hop counts are deliberately **not** asserted. They shift with
classifier tuning without the feature being any less correct, so pinning
them would make ordinary improvements look like regressions. The
properties above are the contract.
