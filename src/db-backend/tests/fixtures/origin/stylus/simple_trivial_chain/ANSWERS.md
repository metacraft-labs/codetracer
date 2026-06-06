# Expected Origin Chain — stylus / simple_trivial_chain

**Query target:** local `c` at the trailing `c` expression in `compute`
(`main.rs` line 15).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(u32, value=10)
```

**Termination:** `Literal` at `let a: u32 = 10`.

**Notes:**
- Stylus contracts compile via the Rust toolchain so the classifier
  reuses the Rust row of spec §7.2: bare identifier on RHS classifies
  as `TrivialCopy`, integer literal classifies as `Literal`.
- Confidence at each hop should be at or above `0.7` (high).
- The Solidity-style storage-write vs memory-write override per spec
  §7.2 (M23 Stylus/EVM row) only applies when the LHS is a contract
  storage attribute; this fixture exercises local variables only, so
  the override path is inert and the chain shape is identical to the
  pure-Rust fixture (`rust/simple_trivial_chain` would terminate the
  same way if we had one).
