# Fixture B — "Form Submission Error" expected chain shape

> Per Cross-Process Origin E2E Test Design doc §3.2.

## Goal

Trace the origin of the `msg` argument passed to `showError(msg)`
on the frontend across the network boundary into the backend's
template-literal validation message. The terminator is a
`Computational` hop with operand snapshots for `errs.length` +
`errs.join(", ")`.

## Files

- `frontend/form.js` — declares the send marker around the
  `fetch("/api/submit", …)` call.
- `backend/node/server.js` — declares the receive marker on the
  request handler entry.

## Expected chain

Hop indices walk most-recent-first from the frontend's
`showError(msg)` call site:

| # | Side | Kind | Target / Source | Location |
| - | ---- | ---- | ---------------- | -------- |
| 0 | frontend | TrivialCopy | `msg` ← `result.message` | `frontend/form.js:8` |
| 1 | frontend | TrivialCopy (§14.3 collapsed JSON.parse) | `result.message` ← `result` | `frontend/form.js:7` |
| 2 | backend | TrivialCopy (§14.3 collapsed JSON.stringify) | `result.message` ← `message` | `backend/node/server.js:6` |
| 3 | backend | Computational (template literal; terminator) | `message` ← `` `Validation failed: ${errs.length} field(s) (${errs.join(", ")})` `` | `backend/node/server.js:5` |

## Cross-process spans

Two spans (frontend, backend) per the canonical Fixture B shape.

## Boundary-crossing hop transition

Populated on the receive-side tail hop with `boundaryId =
"form-error"`. Operand snapshots on hop 3 carry the runtime values
of `errs.length` and `errs.join(", ")`.

## Terminator

- **Kind:** `Computational`
- **Sub-kind:** template literal with ≥ 2 operands.

## Status

This fixture's `frontend/` + `backend/` skeletons + `record.sh` +
recorder-driven regeneration land in the M29 follow-on alongside
Fixture A's. See the M29 PROPERTIES status for the explicit defer
list.
