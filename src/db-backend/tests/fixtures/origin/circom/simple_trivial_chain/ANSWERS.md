# Expected Origin Chain — circom / simple_trivial_chain

**Query target:** signal `out` at the `out <== c;` line in `FlowTest`
(`main.circom` line 27).

**Expected chain shape:**

```
hop 0: target=out  rhs=c   OriginKind=TrivialCopy   source_variable=c
hop 1: target=c    rhs=b   OriginKind=TrivialCopy   source_variable=b
hop 2: target=b    rhs=a   OriginKind=TrivialCopy   source_variable=a
hop 3: target=a    rhs=10  OriginKind=Literal       terminator=Literal(field element, value=10)
```

**Termination:** `Literal` at `a <== 10;`.

**Notes:**
- Circom's `<==` signal-assignment operator is a TrivialCopy in the M23
  Circom override (spec §7.2). The override is triggered by the
  language-specific `signal_assignment` / `=>` / `<==` tree-sitter
  node kind so the universal table's "unknown" fallthrough does not
  drop confidence to 0.
- Confidence at each hop should be at or above `0.7` (high).
- Output signals (`signal output out`) are not special-cased; they are
  classified by the RHS exactly like inner signals.
