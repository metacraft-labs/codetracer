# Expected Origin Chain — ruby / computational_origin

**Query target:** local `result` at the `puts result` line.

**Expected chain shape:**

```
hop 0: target=result   rhs=a + b   OriginKind=Computational
       operand_snapshots = [
         { name: "a", value: 10 },
         { name: "b", value: 32 },
       ]
       terminator=Computational(expr="a + b")
```

**Termination:** `Computational` — Ruby `+` send on integer literals is
the canonical Computational shape per spec §7.2 (Ruby treats the call
`a.+(b)` as computational because the receiver is bound to a value
and the message is not in the trivial-copy catalogue).
