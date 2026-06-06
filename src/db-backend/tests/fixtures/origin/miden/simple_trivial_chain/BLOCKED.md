# BLOCKED — miden / simple_trivial_chain

**Status:** `status: blocked` per M23 spec
(`Planned-Features/Value-Origin-Tracking.milestones.org`).

**Blocker:** There is no `miden_flow_dap_test.rs` in the tree today.
M23's Miden fixture is gated on the Miden recorder first shipping a
flow-DAP test of its own so the baseline source-map + variable-name
contract is documented and re-runnable.  The existing
`masm_flow_dap_test.rs` covers the MASM surface but does not exercise
the source-language layer the origin classifier consumes.

When the Miden recorder ships its flow-DAP baseline, this directory
will materialise a MASM (or higher-level Miden source) program along
the canonical 3-hop `a -> b -> c -> 10` trivial-chain shape:

```
push.10
loc_store.0     # a <- 10
loc_load.0
loc_store.1     # b <- a
loc_load.1
loc_store.2     # c <- b
```

with the same `ANSWERS.md` shape (3 hops, terminator = `Literal(felt,
value=10)`, all hops confidence >= 0.7) and a `regenerate.sh` that
drives `codetracer-miden-recorder`.

**Tracking:** the M23 `test_origin_miden_canonical_chain` test in
`src/db-backend/tests/origin_miden_dap_test.rs` reports BLOCKED with
this exact reason; it does NOT use the SKIP path because the blocker
is a recorder-baseline gap (not an environment availability issue).
