# Expected Origin Chain — python / return_capture

**Query target:** local `captured` at the `print(captured)` line of `main`.

**Expected chain shape:**

```
hop 0: target=captured  rhs=compute()   OriginKind=TrivialCopy   classification="return capture"
hop 1: <inside compute() frame>
       target=<return slot>  rhs=a + b   OriginKind=Computational
       operand_snapshots = [
         { name: "a", value: 3, source_step: <step of `a = 3`> },
         { name: "b", value: 4, source_step: <step of `b = 4`> },
       ]
       terminator=Computational(expr="a + b")
```

**Termination:** `Computational` at `return a + b` inside `compute`.

**Notes:**
- Hop 0 is a `TrivialCopy` per spec §7.3 (return capture): the call
  expression `compute()` is recognized as a forwarder of its return value.
- The chain crosses into the callee's frame at the `return` statement.
- The Computational hop carries operand snapshots, matching the
  `computational_origin` scenario's shape.
