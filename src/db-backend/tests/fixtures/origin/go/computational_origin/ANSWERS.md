# Expected Origin Chain — go / computational_origin

**Query target:** local `result` at the `fmt.Println(result)` line.

**Expected chain shape:**

```
hop 0: target=result   rhs=a + b   OriginKind=Computational
       operand_snapshots = [
         { name: "a", value: 10 },
         { name: "b", value: 32 },
       ]
       terminator=Computational(expr="a + b")
```
