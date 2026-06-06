# Expected Origin Chain — sway / simple_trivial_chain

**Query target:** local `c` at the trailing `c` expression in `compute`
(`main.sw` line 19).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(u64, value=10)
```

**Termination:** `Literal` at `let a: u64 = 10`.

**Notes:**
- Sway bindings are `let <name>: <type> = <expr>` and tree-sitter-sway
  reports them as `let_declaration`, so the classifier reuses the Rust
  splitter from spec §7.2.
- Confidence at each hop should be at or above `0.7` (high).
- FuelVM storage-write override (M23 Sway row of spec §7.2) only fires
  when the LHS receiver is a `storage.<field>` access; this fixture is
  local-only so the override path is inert.
