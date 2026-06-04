# Expected Origin Chain — c / destructuring_or_index

C has no tuple destructuring; the language-appropriate analogue is
struct field access plus array index access.

**Query targets:** `first` and `indexed` at the `printf` line.

**Expected chain for `first`:**

```
hop 0: target=first   rhs=pair.first   OriginKind=TrivialCopy   classification="field"
                                                                source_variable=pair (field "first")
hop 1: target=pair    rhs={ 11, 22 }   OriginKind=Computational
       operand_snapshots = [{ name: "first", value: 11 },
                            { name: "second", value: 22 }]
       terminator=Computational(expr="{ 11, 22 }")
```

**Expected chain for `indexed`:**

```
hop 0: target=indexed  rhs=((int[]){11, 22})[1]   OriginKind=TrivialCopy   classification="index"
hop 1: target=<compound-literal>  rhs={11, 22}   OriginKind=Computational
       terminator=Computational(expr="{11, 22}")
```

**Notes:** `pair.first` is a TrivialCopy with classification "field"
(C analogue of destructuring). Compound-literal access is "index".
