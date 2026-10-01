# Expected Origin Chain — solana / simple_trivial_chain

**Query target:** local `c` at the trailing `core::hint::black_box(c)` in
`compute` (the test finds the line by its text).

**Expected chain shape:**

```
hop 0: target=c   rhs=b                        OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a                        OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=core::hint::black_box(10) OriginKind=FunctionCall
terminator: Computational (core::hint::black_box(10))
```

**Termination:** `Computational` at `let a: u64 = core::hint::black_box(10);`.

**Notes:**
- Solana programs are Rust source, so the classifier reuses the Rust
  row of spec §7.2: a bare identifier on the RHS classifies as `TrivialCopy`.
- Confidence at each copy hop should be at or above `0.7` (high).
- `a`'s initial value is `black_box(10)` rather than the literal `10`, and
  the terminator is therefore a call, not a `Literal`. With a literal the
  SBF backend folds the copies into immediate stores of 10 (measured with
  llvm-objdump on the platform-tools build, at `opt-level = 0` and
  `-Zmir-opt-level=0`), the binary holds no copy to record, and the chain
  stops at `b`. The two copy hops — what this fixture tests — are the same
  either way.
- The tail passes `c` by value to `black_box` so `c` keeps its own stack
  slot; a bare trailing `c` is the return place and has no DWARF location.
- The account-data write override per spec §7.2 (M23 Solana SBF row)
  only applies when the LHS receiver is an `AccountInfo::data` /
  `try_borrow_mut_data` slot; this fixture is local-only so the
  override path is inert.
