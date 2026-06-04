# Expected Origin Chain — go / return_capture

**Query target:** local `captured` at the `fmt.Println(captured)` line.

**Expected chain shape:**

```
hop 0: target=captured  rhs=compute()   OriginKind=TrivialCopy   classification="return capture"
hop 1: <inside compute frame>
       target=<return slot>  rhs=a + b   OriginKind=Computational
       operand_snapshots = [{ name: "a", value: 3 }, { name: "b", value: 4 }]
       terminator=Computational(expr="a + b")
```
