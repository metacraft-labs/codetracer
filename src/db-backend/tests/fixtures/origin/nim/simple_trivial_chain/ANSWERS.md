# Expected Origin Chain — nim / simple_trivial_chain

**Query target:** local `c` at the `echo c` line.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
```

**Termination:** `Literal`. Bare-identifier RHS is `TrivialCopy`.

**Notes:** `int: Copy` so the bare-name `let` is a value copy at AST
level; no copy hooks fire on a POD value type.
