# Expected Origin Chain - javascript / optional_chaining

**Query target:** local `x` at the `console.log(x)` line.

**Expected chain shape:**

```
hop 0: target=x   rhs=obj?.field   OriginKind=FieldAccess   confidence >= 0.7
                                                            source_variable=obj (field "field")
hop 1: target=obj rhs={ field: 42 } OriginKind=Computational
       operand_snapshots = [{ name: "field", value: 42 }]
       terminator=Computational(expr="{ field: 42 }")
```

**Notes:**
- Per spec §7.2 JS override, `x = obj?.field` classifies as `FieldAccess`
  with confidence >= 0.7 (slightly below 1.0 because the optional chain
  could short-circuit to `undefined`).
- When `obj` is non-null at the queried step, the chain crosses through
  the field access exactly as if the `?.` were a bare `.`.
