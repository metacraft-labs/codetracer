# Expected Origin Chain - python / walrus_in_condition

**Query target:** local `n` at the `result = n` line inside `main`.

**Expected chain shape:**

```
hop 0: target=n   rhs=compute()   OriginKind=ReturnCapture   classification="return capture"
hop 1: <inside compute() frame>
       target=<return slot>   rhs=a + b   OriginKind=Computational
       operand_snapshots = [
         { name: "a", value: 3, source_step: <step of `a = 3`> },
         { name: "b", value: 4, source_step: <step of `b = 4`> },
       ]
       terminator=Computational(expr="a + b")
```

**Termination:** `Computational` at `return a + b` inside `compute`.

**Notes:**
- Per spec §7.2 Python override, `(n := compute())` classifies `n`'s
  origin as `ReturnCapture` (NOT TrivialCopy) - the walrus operator's
  binding shares the classifier behaviour of `n = compute()`.
- The first hop's OriginKind is `ReturnCapture` (the classifier's
  enum value for return capture). Hop 1 (inside `compute`'s frame)
  is `Computational`.
- Confidence: High at every hop.
