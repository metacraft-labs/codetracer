# Fixture A — "Account Balance" expected chain shape

> Per Cross-Process Origin E2E Test Design doc §3.1. This file
> documents the expected `OriginChain` shape so per-fixture tests
> can assert against a single source of truth.

## Query

- **Variable:** `balance`
- **Step:** the step at which `balance = payload.balance` is assigned
  on the frontend.
- **Trace:** the frontend recording (`role = "frontend"`).

## Expected chain

Hop indices are 0-based and walk most-recent-first per
`OriginChain.hops`.

| # | Side | Kind | Target / Source | Location |
| - | ---- | ---- | ---------------- | -------- |
| 0 | frontend | TrivialCopy | `balance` ← `payload.balance` | `frontend/app.js:4` |
| 1 | frontend | TrivialCopy (collapsed from FunctionCall via §14.3 serialisation-aware rule) | `payload` ← `response.json()` | `frontend/app.js:3` |
| 2 | backend | TrivialCopy | `payload` ← `web.json_response(payload)` | `backend/server.py:6` |
| 3 | backend | Computational | `payload` ← `{"balance": db_row.balance}` | `backend/server.py:5` |
| 4 | backend | FieldAccess | `db_row.balance` ← `db_row.balance` | `backend/server.py:5` |
| 5 | backend | ReturnCapture (terminator: Computational external IO read) | `db_row` ← `await db.fetch_one(...)` | `backend/server.py:4` |

## Cross-process spans

```jsonc
[
  { "recordingId": "<fe>", "role": "frontend", "firstHopIndex": 0, "lastHopIndex": 1 },
  { "recordingId": "<be>", "role": "backend",  "firstHopIndex": 2, "lastHopIndex": 5 }
]
```

## Boundary-crossing hop transition

Populated on the receive-side tail hop (index 1):

```jsonc
{
  "direction": "recv",
  "boundaryId": "balance-request",
  "matchKeyValue": "user-42",
  "displayVariableValue": "user-42",
  "description": "GET /api/balance handler",
  "correlatedRecordingId": "<be>",
  "correlatedStepId": <step at which the backend's send marker fires>
}
```

## Terminator

- **Kind:** `Computational`
- **Expression:** `db.fetch_one(...)` (sub-kind: external/IO read at boundary)

## Notes

- Per-hop confidence floor is ≥ 0.7 on Mode 1 and ≥ 0.9 on Mode 3.
- The full chain is verified by the M29 cross-process E2E tests
  under `codetracer/src/db-backend/tests/cross_process_origin_test.rs`
  (synthesised fixture form pending the recorder-driven fixture
  infrastructure; see the M29 PROPERTIES defer list).
