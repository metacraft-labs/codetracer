# Expected Origin Chain — ruby / simple_trivial_chain

**Query target:** local `c` at the `puts c` line.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(Integer, value=10)
```

**Termination:** `Literal`.

**Notes:** Bare-name RHS is `TrivialCopy` per spec §7.1.
