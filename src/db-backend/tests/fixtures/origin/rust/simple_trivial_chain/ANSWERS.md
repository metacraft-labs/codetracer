# Expected Origin Chain — rust / simple_trivial_chain

**Query target:** local `c` at the `println!` line.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(i32, value=10)
```

**Termination:** `Literal`. Bare-identifier RHS is `TrivialCopy`.

**Notes:** `i32: Copy` so the bare-name move is a value copy at MIR
level; no `Clone` call is involved.
