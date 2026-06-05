# Expected Origin Chain — c / pointer_deref_chain

**Query target:** local `b` at the `printf("%d\n", b)` line.

**Expected chain shape:**

```
hop 0: target=b   rhs=*p     OriginKind=IndexAccess   source_variable=p
hop 1: target=p   rhs=&a     OriginKind=IndexAccess   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
```

**Termination:** `Literal`.

**Notes:** Pointer deref classifies as `IndexAccess` per the universal
table (spec §7.1). The chain depth is 3 (pointer indirection adds one
hop over the plain trivial-copy fixture).
