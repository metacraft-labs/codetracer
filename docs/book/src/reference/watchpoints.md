# Watchpoints Reference

A **watchpoint** (a DAP *data breakpoint*) stops execution when a value
changes, rather than when a line is reached. This page states exactly
what CodeTracer's watchpoints do over a recording, and — just as
importantly — what they cannot do and why.

The canonical Rust definitions live in
`codetracer/libs/ct-data-breakpoints/src/lib.rs`. The backend
implementation is `Handler::set_data_breakpoints` /
`Handler::data_breakpoint_info` in
`codetracer/src/db-backend/src/dap_handler.rs`.

## What a watchpoint is here

A live debugger implements a data breakpoint with a *hardware watch
register*: the CPU traps on an access to an address. A recording has no
CPU and no registers. What it has is a table of the value each variable
held at each recorded step.

So the watchpoint CodeTracer offers is a **value-change watchpoint**:

> `continue` stops at the first later step at which the named variable's
> recorded value differs from the value it held at the previous step
> that recorded it.

Two rules keep that honest:

- **Coming into scope is not a change.** A variable appearing for the
  first time establishes the baseline without firing. Firing on it would
  stop on entry to every call that declares the name.
- **A step that does not record the variable leaves the watch
  undisturbed.** The variable is out of scope there, not changed to
  nothing. Dropping the baseline would make the next step that records
  it fire spuriously on re-entry.

Comparison is structural, so a compound value rebuilt with identical
contents does not count as a change. That is what a user *watching a
value* wants. A user watching an *address* would want the opposite, and
CodeTracer cannot offer that — see below.

## Setting one

From the Python API:

```python
wp_id = trace.add_watchpoint("counter")
trace.continue_forward()      # stops at the first change to `counter`
trace.remove_watchpoint(wp_id)
```

From a DAP client: `dataBreakpointInfo` (to ask whether a variable can
be watched) then `setDataBreakpoints`. The backend advertises
`supportsDataBreakpoints: true` in its `initialize` response, and
`dataBreakpointInfo` reports `accessTypes: ["write"]` — so a conforming
client never offers a `read` watchpoint it would only be refused for.

`setDataBreakpoints` has **replace semantics**, exactly like
`setBreakpoints`: each request defines the complete set, and an empty
`breakpoints` array clears it.

## Refusals

Every refusal comes from a closed set, carried on the wire as
`refusalCode` (an integer) and `refusal` (a stable token) beside the
human-readable message. Callers branch on the code; the message is for
people. The Python API surfaces both on the raised `TraceError`, as
`err.refusal` and `err.refusal_code`.

| Code | Token | Meaning |
| ---- | ----- | ------- |
| 6201 | `emptyDataId` | The `dataId` was empty or whitespace. A watchpoint has to name something. |
| 6202 | `expressionNotAWatchableVariable` | Not a plain identifier. A recording indexes values *by variable*, not by address or expression, so `obj.field`, `arr[0]`, `*ptr` and `counter + 1` cannot be watched — there is no evaluator behind the value table that could compute them at every step of a scan. |
| 6203 | `accessTypeNotRecorded` | A `read` or `readWrite` access type was requested. **This is the refusal that is intrinsic to replay rather than merely unimplemented** — see below. |
| 6204 | `conditionNotSupported` | A `condition` or `hitCondition` was supplied. Source breakpoints support conditions; the value-change scan has no evaluator wired into it yet. Refused rather than silently ignored, because a watchpoint that drops its condition stops in the wrong place and the user has no way to know. |
| 6205 | `variableNotInTrace` | A well-formed identifier, but not one this recording captured. Distinct from 6202 because the user's fix differs: a typo, versus watching something the recorder did not capture. |
| 6206 | `backendLacksValueHistory` | This replay backend keeps no per-step value table. Materialized recordings support watchpoints; MCR/emulator and recreator traces do not — they already refuse `load_history` for the same reason. |

An entry being refused does **not** fail the request: each entry in a
`setDataBreakpoints` array is answered individually with its own
`verified` flag, in request order. A refused entry is never installed.

### Why reads cannot be watched

This one is worth stating plainly, because it is not a gap that a future
release closes.

A recording samples **what each variable held** at each step. It does not
record that a value was *read*. A read leaves no trace in the data —
reading `x` changes nothing about `x` — so no amount of scanning
recovers it. `write` is the only access type a value table can answer,
and it answers it as "the value is now different", which is what a write
is observable as.

If you need read tracking, the mechanism is
[Value Origin Tracking](../usage_guide/value-origin-tracking.md), which
answers "where did this value come from" rather than "who touched this".

## Notes for contributors

The admission rules live in one place —
`ct_data_breakpoints::verdict` — and **both** the real replay backend
and the daemon's mock DAP backend call it.

That is not tidiness. For the whole life of this feature the only
implementation of `setDataBreakpoints` in the tree was the mock, which
answered `verified: true` unconditionally, while the real backend had no
arm for the command at all and refused everything with a free-text
fallthrough. A test double more capable than the component it stood in
for meant every test of the watchpoint path passed against something the
product could not do, and watchpoints were broken from the start without
one test going red.

If you add a rule, add it to `verdict` and add a case to
`conformance_cases()`. Both suites — `db-backend`'s
`conformance_cases_agree_with_the_real_backend` and `backend-manager`'s
`mock_matches_the_shared_data_breakpoint_verdict` — pick it up, and one
of them goes red if the two ever diverge again.
