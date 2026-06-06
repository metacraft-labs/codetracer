# Expected Origin Chain — cairo / simple_trivial_chain

**Query target:** local `c` at the trailing `c` expression in `main`
(`main.cairo` line 14).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(felt252, value=10)
```

**Termination:** `Literal` at `let a: felt252 = 10`.

**Notes:**
- Cairo bindings are `let <name>: <type> = <expr>`; the universal-table
  Rust splitter recognises this shape as `let_declaration` because
  Cairo's tree-sitter grammar reuses the Rust-family `let_declaration`
  rule name. The classifier walks the RHS exactly like the Rust row of
  spec §7.2: bare identifier → `TrivialCopy`, integer literal →
  `Literal`.
- Confidence at each hop should be at or above `0.7` (high).
- The felt-vs-pointer overrides documented in spec §7.2 (M23 Cairo row)
  apply only when the source line accesses a `Box<T>` / pointer
  receiver; this fixture is felt-only so the override path is inert
  here. The pointer scenario is reserved for future Cairo fixtures.
