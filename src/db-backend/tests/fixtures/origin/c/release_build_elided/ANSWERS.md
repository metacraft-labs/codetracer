# Expected Origin Chain — c / release_build_elided

**Query target:** local `c` at the `printf("%d\n", c)` line.

**Expected behaviour:**

Release-build elision means the intermediate `b = a` assignment is
gone from the binary; the watchpoint loop's per-hop wall-clock cap
trips before it can locate the assignment.

```
terminator = OutOfBudget
terminator.expression = "rr per-hop wall-clock cap (1500 ms) tripped; documentation: spec §6.3"
terminator.source_line = <pointer at spec §6.3>
```

**Termination:** `OutOfBudget`.

**Required by M11 test #15 — `test_origin_rr_release_build_yields_out_of_budget`:**

The chain's `terminator.kind` MUST equal `OutOfBudget` AND
`terminator.expression` MUST contain `spec §6.3` (the documentation
pointer the spec calls out).
