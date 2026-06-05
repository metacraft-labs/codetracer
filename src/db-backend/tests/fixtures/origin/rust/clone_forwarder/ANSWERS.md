# Expected Origin Chain — rust / clone_forwarder

**Query target:** local `b` at the `println!` line.

**Expected chain shape:**

```
hop 0: target=b   rhs=a.clone()   OriginKind=TrivialCopy   source_variable=a
hop 1: target=a   rhs=10          OriginKind=Literal       terminator=Literal(int, value=10)
```

**Termination:** `Literal`.

**Notes:** The classifier's built-in catalogue treats `.clone()` on a
primitive as a forwarder (spec §7.2 Rust row). The hop is
`TrivialCopy`, not `FunctionCall`.
