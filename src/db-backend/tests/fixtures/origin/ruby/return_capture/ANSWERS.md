# Expected Origin Chain — ruby / return_capture

**Query target:** local `captured` at the `puts captured` line.

**Expected chain shape:**

```
hop 0: target=captured  rhs=compute   OriginKind=TrivialCopy   classification="return capture"
hop 1: <inside compute frame>
       target=<return slot>  rhs=a + b   OriginKind=Computational
       operand_snapshots = [{ name: "a", value: 3 }, { name: "b", value: 4 }]
       terminator=Computational(expr="a + b")
```

**Termination:** `Computational` at the `compute` method's last expression.

**Notes:** Ruby's implicit return of the last expression in the method
body is treated identically to an explicit `return` per spec §7.3.
