# Expected Origin Chain — python / destructuring_or_index

**Query targets:** `first` and `indexed` at the `print(...)` line.

**Expected chain for `first`:**

```
hop 0: target=first  rhs=pair[0]        OriginKind=TrivialCopy   classification="destructure"
                                                                 source_variable=pair (element 0)
hop 1: target=pair   rhs=(11, 22)       OriginKind=Computational
       operand_snapshots = [{ name: "<tuple-elt-0>", value: 11 },
                            { name: "<tuple-elt-1>", value: 22 }]
       terminator=Computational(expr="(11, 22)")
```

**Expected chain for `indexed`:**

```
hop 0: target=indexed  rhs=pair[1]      OriginKind=TrivialCopy   classification="index"
                                                                 source_variable=pair (index 1)
hop 1: same Computational terminator as the `first` chain.
```

**Notes:**
- Per spec §7.3, the binding `first, second = pair` decomposes into two
  TrivialCopy hops with classification "destructure"; the index access
  `pair[1]` is a TrivialCopy with classification "index".
- The container literal `(11, 22)` is the Computational terminator;
  primitive element values appear in `operand_snapshots`.
