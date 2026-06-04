# Expected Origin Chain — go / destructuring_or_index

Go has no tuple destructuring; the language-appropriate analogue is
multiple-value return assignment plus slice index access.

**Query targets:** `first` and `indexed`.

**Expected chain for `first`:**

```
hop 0: target=first  rhs=<pair()-result-0>   OriginKind=TrivialCopy   classification="multi-return destructure"
                                                                      source_variable=pair() result 0
hop 1: <inside pair() frame>
       target=<return slot 0>   rhs=11   OriginKind=Literal
       terminator=Literal(int, value=11)
```

**Expected chain for `indexed`:**

```
hop 0: target=indexed  rhs=arr[1]       OriginKind=TrivialCopy   classification="index"
hop 1: target=arr      rhs=[]int{11, 22}   OriginKind=Computational
       terminator=Computational(expr="[]int{11, 22}")
```
