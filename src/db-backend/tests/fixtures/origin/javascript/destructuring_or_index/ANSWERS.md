# Expected Origin Chain — javascript / destructuring_or_index

**Query targets:** `first` and `indexed` at the `console.log(...)` line.

**Expected chain for `first`:**

```
hop 0: target=first  rhs=pair[0]        OriginKind=TrivialCopy   classification="destructure"
hop 1: target=pair   rhs=[11, 22]       OriginKind=Computational
       operand_snapshots = [{ value: 11 }, { value: 22 }]
       terminator=Computational(expr="[11, 22]")
```

**Expected chain for `indexed`:** identical except hop 0 uses
classification `"index"`.
