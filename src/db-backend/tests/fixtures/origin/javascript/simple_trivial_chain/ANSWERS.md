# Expected Origin Chain — javascript / simple_trivial_chain

**Query target:** local `c` at the `console.log(c)` line.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(Number, value=10)
```

**Termination:** `Literal`. Bare-identifier RHS is `TrivialCopy` per
spec §7.1.
