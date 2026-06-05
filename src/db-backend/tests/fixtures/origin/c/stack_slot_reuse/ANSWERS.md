# Expected Origin Chain — c / stack_slot_reuse

**Query target:** local `x` at the `printf("%d\n", x)` line.

**Expected chain shape:**

```
hop 0: target=x   rhs=42   OriginKind=Literal   terminator=Literal(int, value=42)
```

**Termination:** `Literal`.

**Required by M11 test #2 — `test_origin_rr_stack_slot_reuse_guard`:**

NO hop in the returned chain may carry `target=tmp` or
`source_text="int tmp = 7;"`. The guard MUST drop the spurious
inner-function write before emitting a hop.
