# Expected Origin Chain — leo / simple_trivial_chain

**Query target:** local `c` at the `return c;` line in `compute`
(`main.leo` line 17).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10u32  OriginKind=Literal       terminator=Literal(u32, value=10)
```

**Termination:** `Literal` at `let a: u32 = 10u32`.

**Notes:**
- Leo bindings are `let <name>: <type> = <expr>;` and tree-sitter-leo
  reports them as `let_declaration`, so the classifier reuses the Rust
  splitter from spec §7.2.
- Confidence at each hop should be at or above `0.7` (high).
- The Leo record / circuit override per spec §7.2 (M23 Leo row) only
  applies when the LHS receiver is a `record` field; this fixture is
  local-only so the override path is inert.
