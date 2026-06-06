# Fixture C — "Distributed Loop Computation" expected chain shape

> Per Cross-Process Origin E2E Test Design doc §3.3.

## Goal

Trace the origin of the frontend's `runJob()` return value (which
multiplies the backend's accumulated total by 100). The chain
crosses the network boundary into the backend's accumulator loop.
Stress-tests `Computational` hops on **both** sides of the
boundary.

## Files

- `frontend/compute.js` — declares the send marker around the
  POST `/api/sum` fetch call.
- `backend/python/server.py` — declares the receive marker on the
  `sum_handler` entry.

## Expected chain (excerpt)

| # | Side | Kind | Target / Source | Location |
| - | ---- | ---- | ---------------- | -------- |
| 0 | frontend | Computational | `<return>` ← `total * 100` | `frontend/compute.js:N` |
| 1 | frontend | TrivialCopy | `total` ← `{ total } = response.json()` | `frontend/compute.js:N-1` |
| 2 | frontend | TrivialCopy (§14.3 collapsed JSON.parse) | `total` ← `total` | `frontend/compute.js:N-2` |
| 3 | backend | TrivialCopy (§14.3 collapsed JSON.stringify) | `total` ← `accumulator` | `backend/python/server.py:M` |
| 4 | backend | Computational (terminator: last iteration of the loop) | `accumulator + item` | `backend/python/server.py:M-1` |

## Cross-process spans

Two spans (frontend, backend); the frontend span spans the
`total * 100` computational hop down through the `response.json()`
decode, the backend span spans the `accumulator` loop.

## Operand snapshots

The backend's terminator hop carries operand snapshots for the
running `accumulator` value (pre-final-add) and the final `item`.

## Status

This fixture's `frontend/` + `backend/` skeletons + recorder-
driven regeneration land in the M29 follow-on. See the M29
PROPERTIES status for the explicit defer list.
