# Expected Origin Chain — solana / simple_trivial_chain

**Query target:** local `c` at the trailing `c` expression in `compute`
(`main.rs` line 14).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(u64, value=10)
```

**Termination:** `Literal` at `let a: u64 = 10`.

**Notes:**
- Solana programs are Rust source, so the classifier reuses the Rust
  row of spec §7.2: bare identifier on RHS classifies as `TrivialCopy`,
  integer literal classifies as `Literal`.
- Confidence at each hop should be at or above `0.7` (high).
- The account-data write override per spec §7.2 (M23 Solana SBF row)
  only applies when the LHS receiver is an `AccountInfo::data` /
  `try_borrow_mut_data` slot; this fixture is local-only so the
  override path is inert.
