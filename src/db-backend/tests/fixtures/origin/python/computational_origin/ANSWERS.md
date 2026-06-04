# Expected Origin Chain — python / computational_origin

**Query target:** local `result` at the `print(result)` line of `main`.

**Expected chain shape:**

```
hop 0: target=result   rhs=a + b   OriginKind=Computational
       operand_snapshots = [
         { name: "a", value: 10, source_step: <step of `a = 10`> },
         { name: "b", value: 32, source_step: <step of `b = 32`> },
       ]
       terminator=Computational(expr="a + b")
```

**Termination:** `Computational` — the BinOp is the origin; we do **not**
recurse into `a` or `b` for the primary chain (their values are captured
as `operand_snapshots` and exposed via the "Show operands" affordance).

**Notes:**
- Per spec §7.2, a Python `BinOp` whose operator is `+` and whose
  operands are bare names is the canonical Computational origin shape.
- Confidence should be `High`.
