# Expected Origin Chain - javascript / object_destructuring

**Query targets:** `a` and `b` at the `console.log(a, b)` line.

**Expected chain for `a`:**

```
hop 0: target=a   rhs=obj.a   OriginKind=FieldAccess   classification="destructure"
                                                       source_variable=obj (field "a")
hop 1: target=obj rhs={ a: 11, b: 22 }  OriginKind=Computational
       operand_snapshots = [{ name: "a", value: 11 }, { name: "b", value: 22 }]
       terminator=Computational(expr="{ a: 11, b: 22 }")
```

**Expected chain for `b`:** identical except hop 0 has
`rhs=obj.b` and `source_variable=obj (field "b")`.

**Notes:**
- Per spec §7.2 JS override, `const { a, b } = obj` classifies as
  `FieldAccess` per target (one hop per LHS), with confidence >= 0.7.
- The classifier produces `FieldAccess` rather than `TrivialCopy`
  because the destructuring binding is observationally equivalent
  to `const a = obj.a; const b = obj.b;`.
