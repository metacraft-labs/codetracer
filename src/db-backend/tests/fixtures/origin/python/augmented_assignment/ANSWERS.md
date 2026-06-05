# Expected Origin Chain - python / augmented_assignment

**Query target:** local `total` at the `print(total)` line of `main`.

**Expected chain shape:**

```
hop 0: target=total   rhs=total + i   OriginKind=Computational
       operand_snapshots = [
         { name: "total", value: 0, source_step: <step of `total = 0`> },
         { name: "i",     value: 5, source_step: <step of `i = 5`> },
       ]
       terminator=Computational(expr="total + i")
```

**Termination:** `Computational` - per spec §7.2 Python override,
augmented assignment `total += i` is equivalent to `total = total + i`
and classified as Computational (NOT TrivialCopy).

**Notes:**
- Hop count: 1.
- Confidence: High.
