# Expected Origin Chain — noir / simple_trivial_chain

**Query target:** local `c` at the `println(c);` line in `main`
(`main.nr` line 16).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(Field, value=10)
```

**Termination:** `Literal` at `let a: Field = 10`.

**Notes:**
- Noir is a Rust-syntax-derived language, so the classifier reuses the
  Rust splitter from spec §7.2: bare identifier on RHS classifies as
  `TrivialCopy`, integer literal classifies as `Literal`.
- Confidence at each hop should be at or above `0.7` (high).
- The `unconstrained fn` override per spec §7.2 (M23 Noir row) only
  applies to bodies of unconstrained functions, where the recorder
  emits `Value` events but not `Assignment` events; this fixture's
  `main` is constrained, so the override path is inert.
