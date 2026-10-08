# Expected Origin Chain — stylus / simple_trivial_chain

**Program:** the Stylus contract in `src/lib.rs`; its `compute()` method
binds `a = 10`, `b = a`, `c = b` and returns `c`.

**Recording:** `evm_trace.json` is the `stylusTracer` capture of a
`compute()` transaction on a Nitro dev node (`regenerate.sh`). The test
builds the contract's debug wasm and replays it with
`wazero run -stylus evm_trace.json`; the replay is the materialized trace.

**Query target:** local `c` at `core::hint::black_box(&c);`
(`src/lib.rs` line 25), after `c` is bound.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   line 24   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   line 23   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       line 22   terminator=Literal
```

**Termination:** `Literal` at `let a: u32 = 10;`.

**Notes:**
- Stylus contracts are Rust, so the classifier uses the Rust row of spec
  §7.2: a bare identifier on the RHS is `TrivialCopy`, an integer literal
  is `Literal`. Confidence at each hop should be at or above `0.7`.
- `black_box(&c)` keeps the three locals in the debug build's DWARF.
  Without it, MIR copy propagation folds `b` and `c` into one stack slot,
  `let c: u32 = b;` emits no instruction, and the line has no step.
- The contract-storage overrides of the Stylus/EVM row of spec §7.2 only
  apply when the LHS is a storage field; this fixture writes locals only.
