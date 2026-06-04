# Expected Origin Chain — python / simple_trivial_chain

**Query target:** local `c` at the `print(c)` line (last statement of `main`).

**Expected chain shape:**

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
```

**Termination:** `Literal` at `a = 10`.

**Notes:**
- Every intermediate hop is `TrivialCopy` because the RHS is a bare `Name`
  reference per spec §7.1 (Python "bare name on RHS" rule).
- Confidence at each hop should be `High`.
