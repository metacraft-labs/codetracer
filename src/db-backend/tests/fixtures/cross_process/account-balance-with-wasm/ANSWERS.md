# Fixture A' — "Account Balance with WASM" expected chain shape

> Three-tracer variant of Fixture A, per
> `codetracer-specs/Planned-Features/Cross-Tracer-Origin-Test.audit.md`
> § TCT-M4. This file documents the expected `OriginChain` shape
> so the per-fixture tests can assert against a single source of
> truth.

## Query

- **Variable:** `balance`
- **Step:** the step at which `balance = payload["balance"]` is
  assigned inside `balance_handler` on the backend.
- **Trace:** the backend recording (`role = "backend"`).

## Architecture (three trace recordings)

Boundary crossings are 0-based, walk most-recent-first per
`OriginChain.hops`, and the chain spans three sibling traces:

```
backend.ct  ──HTTP──>  frontend.ct  ──js-wasm-realm──>  frontend-wasm.ct
   (role=backend)        (role=frontend-js)              (role=frontend-wasm)
```

Note the recursion depth: the M29 composer first hops `backend →
frontend-js` (HTTP boundary) and then **recursively** re-tests the
tail of the frontend-js continuation against frontend-js's own
receive markers, hopping again into `frontend-wasm` (the js-wasm-
realm boundary). Per TCT-M3 (`SiblingChainResolver` recursive
walk; bounded by `MAX_BOUNDARY_HOPS = 8`).

## Expected chain (mode 1)

| # | Side | Kind | Target / Source | Location |
| - | ---- | ---- | --------------- | -------- |
| 0 | backend       | TrivialCopy                                              | `balance` ← `payload["balance"]`        | `backend/server.py:43`  |
| 1 | backend       | TrivialCopy (collapsed FunctionCall via §14.3 serialization-aware rule, JSON decode) | `payload` ← `await request.json()`      | `backend/server.py:42`  |
| 2 | backend       | ReturnCapture (terminator on this side; cross-process boundary marker carries hop) | `request body` ← HTTP recv               | `backend/server.py:42` (boundary auto-marker) |
| 3 | frontend-wasm | ReturnCapture                                            | `<return>` ← `compute_balance(user_id, amount)` | `wasm-src/lib.rs:44` |
| 4 | frontend-wasm | Computational                                            | `user_term + amount_term`               | `wasm-src/lib.rs:42-43` |
| 5 | frontend-wasm | ReturnCapture (collapsed via §14.3 across the js-wasm-realm boundary, paired send marker on JS side) | WASM export return ← realm-boundary | `wasm-src/lib.rs:41` (boundary auto-marker) |
| 6 | frontend-js   | Computational (call site captures the two argument operands) | `result` ← `compute_balance(userId, amount)` | `frontend/app.js:46`    |
| 7 | frontend-js   | TrivialCopy (terminal leaf 1)                            | `userId` ← `42`                         | `frontend/app.js:31`    |
| 8 | frontend-js   | TrivialCopy (terminal leaf 2)                            | `amount` ← `100`                        | `frontend/app.js:32`    |

The chain has **two terminal leaves** because the
`compute_balance` call has two operand inputs feeding the
arithmetic — each operand is walked back to its own source-line
literal independently. The Origin Chain Panel renders this as two
branches converging at hop 6.

## Cross-process spans

```jsonc
[
  { "recordingId": "<be>",   "role": "backend",       "firstHopIndex": 0, "lastHopIndex": 2 },
  { "recordingId": "<fw>",   "role": "frontend-wasm", "firstHopIndex": 3, "lastHopIndex": 5 },
  { "recordingId": "<fjs>",  "role": "frontend-js",   "firstHopIndex": 6, "lastHopIndex": 8 }
]
```

Three spans (one per recording). Per TCT-M3 acceptance: the
composer's `cross_process_spans.len()` is `>= 2`. Here it is
exactly `3`.

## Boundary-crossing hop transitions

**Hop 2 → hop 3** (backend → frontend-wasm via HTTP):

```jsonc
{
  "direction": "recv",
  "boundaryId": "account-balance-with-wasm",
  "matchKeyValue": "620",
  "displayVariableValue": "620",
  "description": "POST /balance handler",
  "correlatedRecordingId": "<fjs>",
  "correlatedStepId": <step at which the JS-side send marker fires>
}
```

The HTTP receive lands in the `frontend-js` trace's send-marker
step. From there the composer **recursively** hops a second time
into the `frontend-wasm` trace via the js-wasm-realm boundary.

**Hop 5 → hop 6** (frontend-wasm → frontend-js via js-wasm-realm):

```jsonc
{
  "direction": "recv",
  "boundaryId": "js-wasm-realm",
  "matchKeyValue": "<monotonic correlation token, decimal>",
  "displayVariableValue": "compute_balance",
  "description": "WASM export return -> JS call site",
  "correlatedRecordingId": "<fjs>",
  "correlatedStepId": <step at which the JS-side call site fires>
}
```

## Terminators

Two terminators, one per terminal leaf:

- **Hop 7:** `Computational` (sub-kind: source-line literal,
  numeric); expression `42`.
- **Hop 8:** `Computational` (sub-kind: source-line literal,
  numeric); expression `100`.

Both carry per-hop confidence ≥ 0.7 on Mode 1 and ≥ 0.9 on Mode 3
per the standard cross-mode parity floor.

## Concrete payload value

Per `wasm-src/lib.rs`:

```
compute_balance(42, 100)
  = 42 * 10 + 100 * 2
  = 420 + 200
  = 620
```

So the backend's `balance` variable holds `620` and the
`matchKeyValue` on the HTTP boundary marker is `"620"`. This gives
the round-trip smoke a concrete expected payload for the
regenerator + integration test to assert against.

## Notes

- The full chain is verified by the M29 cross-process E2E tests
  under
  `codetracer/src/db-backend/tests/cross_process_origin_test.rs`
  (the three-trace headless DAP entry is Batch 5 Agent 5.2 per the
  Value-Origin Closure Plan); the recursive `SiblingChainResolver`
  is already unit-pinned by
  `cross_process_origin::tests::sibling_chain_resolver_walks_two_boundaries`.
- The synthetic fixture form (this dir) is independent of the
  recorder-driven regeneration; `regenerate.sh` is the
  recorder-driven path and is honestly gated on recorder
  availability per its own prereq check.
