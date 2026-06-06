# Expected Origin Chain — aiken / simple_trivial_chain

**Query target:** local `c` at the trailing `c` expression in `compute`
(`main.ak` line 16).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(Int, value=10)
```

**Termination:** `Literal` at `let a = 10`.

**Notes:**
- Aiken bindings are `let <name> = <expr>` (untyped) and tree-sitter-aiken
  reports them as `let_declaration`, so the classifier reuses the Rust
  splitter from spec §7.2.
- Confidence at each hop should be at or above `0.7` (high).
- The Aiken pipeline-operator override per spec §7.2 (M23 Aiken row)
  recognises `value |> transform()` as a forwarder-style
  `Computational` whose first operand snapshot is `value`; this fixture
  uses only bare identifiers, so the override path is inert.
