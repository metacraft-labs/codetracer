# Expected Origin Chain — ruby / destructuring_or_index

**Query targets:** `first` and `indexed` at the `puts` line.

**Expected chain for `first`:**

```
hop 0: target=first  rhs=pair[0]        OriginKind=TrivialCopy   classification="destructure"
hop 1: target=pair   rhs=[11, 22]       OriginKind=Computational
       operand_snapshots = [{ value: 11 }, { value: 22 }]
       terminator=Computational(expr="[11, 22]")
```

**Expected chain for `indexed`:**

```
hop 0: target=indexed  rhs=pair[1]      OriginKind=TrivialCopy   classification="index"
hop 1: same Computational terminator as `first`.
```
