# Expected Origin Chain - javascript / array_destructuring

**Query targets:** `a` and `b` at the `console.log(a, b)` line.

**Expected chain for `a`:**

```
hop 0: target=a   rhs=arr[0]   OriginKind=IndexAccess   classification="destructure"
                                                        source_variable=arr (index 0)
hop 1: target=arr rhs=[11, 22] OriginKind=Computational
       operand_snapshots = [{ value: 11 }, { value: 22 }]
       terminator=Computational(expr="[11, 22]")
```

**Expected chain for `b`:** identical except hop 0 has
`rhs=arr[1]` and `source_variable=arr (index 1)`.

**Notes:**
- Per spec §7.2 JS override, `const [a, b] = arr` classifies as
  `IndexAccess` per target with confidence >= 0.7.
- The classifier produces `IndexAccess` rather than `TrivialCopy`
  because the destructuring binding is observationally equivalent
  to `const a = arr[0]; const b = arr[1];`.
