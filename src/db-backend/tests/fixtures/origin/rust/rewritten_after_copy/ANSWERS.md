# Expected Origin Chain — rust / rewritten_after_copy

**Query target:** local `c` at the `println!` line.

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(i32, value=10)
```

**Termination:** `Literal`.

**What it tells apart:** `b` is written twice, once before `c` copies it
(`let mut b = a`) and once after (`b = 7`). The walk follows `b` back from
the point of the copy, so it finds `b = a`. A walk that followed `b` back
from the `println!` instead finds `b = 7` and ends the chain at the literal
7. That is what a continued chain does when it does not resume at the point
the cut-off walk stopped at (spec §5.3.1, "A replay walk's continuation"):
`test_origin_rr_cut_off_chain_continues_from_where_it_stopped` cuts the
chain off after each hop and continues it.
