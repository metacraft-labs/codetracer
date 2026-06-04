# Expected Origin Chain — rust / destructuring_or_index

**Query targets:** `first` and `indexed`.

**Expected chain for `first`:**

```
hop 0: target=first  rhs=pair.0         OriginKind=TrivialCopy   classification="destructure"
                                                                 source_variable=pair (element 0)
hop 1: target=pair   rhs=(11, 22)       OriginKind=Computational
       terminator=Computational(expr="(11, 22)")
```

**Expected chain for `indexed`:**

```
hop 0: target=indexed  rhs=arr[1]       OriginKind=TrivialCopy   classification="index"
                                                                 source_variable=arr (index 1)
hop 1: target=arr      rhs=[11, 22]     OriginKind=Computational
       terminator=Computational(expr="[11, 22]")
```
