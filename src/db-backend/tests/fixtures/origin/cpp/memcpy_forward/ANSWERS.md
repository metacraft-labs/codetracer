# Expected Origin Chain — cpp / memcpy_forward

**Query target:** local `dst` at the `std::printf("%d\n", dst)` line.

**Expected chain shape:**

```
hop 0: target=dst   rhs=memcpy(&dst,&src,sizeof(int))   OriginKind=TrivialCopy   source_variable=src
hop 1: target=src   rhs=42                              OriginKind=Literal       terminator=Literal(int, value=42)
```

**Termination:** `Literal`.

**Notes:** The classifier's built-in catalogue treats `memcpy(dst, src, n)`
as a forwarder (spec §7.2 row). The hop is `TrivialCopy`, not
`FunctionCall`, because the catalogue rule overrides the universal
classification table.
