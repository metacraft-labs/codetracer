# BLOCKED — move / simple_trivial_chain

**Status:** `status: blocked` per M23 spec
(`Planned-Features/Value-Origin-Tracking.milestones.org`).

**Blocker:** The current `move_flow_dap_test.rs` notes that "All steps
are recorded at line 1; variable names use bytecode indices." Origin
queries on Move traces today would return `OriginKind::Unknown` with
confidence 0 because the recorder lacks the source-map data the
classifier consumes.

Adding the Move fixture body (the canonical 3-hop `a -> b -> c -> 10`
trivial chain) is gated on the Move recorder shipping source-map
support upstream. When that lands, the fixture mirrors its sibling
scenarios under `tests/fixtures/origin/<lang>/simple_trivial_chain/`
exactly:

```
fn compute(): u64 {
    let a: u64 = 10;
    let b: u64 = a;
    let c: u64 = b;
    c
}
```

with the same `ANSWERS.md` shape (3 hops, terminator = `Literal(u64,
value=10)`, all hops confidence >= 0.7) and a `regenerate.sh` that
drives `codetracer-move-recorder`.

**Tracking:** the M23 `test_origin_move_canonical_chain` test in
`src/db-backend/tests/origin_move_dap_test.rs` reports BLOCKED with
this exact reason; it does NOT use the SKIP path because the blocker
is a recorder feature gap (not an environment availability issue).
