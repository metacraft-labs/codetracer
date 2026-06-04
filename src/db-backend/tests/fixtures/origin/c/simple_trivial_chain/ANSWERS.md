# Expected Origin Chain — c / simple_trivial_chain

**Query target:** local `c` at the `printf("%d\n", c)` line.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
```

**Termination:** `Literal`.

**Notes:** Native-backend C recording requires DWARF debug info; the
`regenerate.sh` script compiles `main.c` with `-O0 -g` before driving the
native recorder.
