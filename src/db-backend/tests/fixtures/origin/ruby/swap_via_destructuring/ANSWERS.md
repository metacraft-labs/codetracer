# Expected Origin Chain - ruby / swap_via_destructuring

**Query target:** local `a` at the `puts a` line (after the swap).

**Expected chain shape for `a`:**

```
hop 0: target=a   rhs=b   OriginKind=TrivialCopy   source_variable=b
                                                   classification="destructure"
hop 1: target=b   rhs=2   OriginKind=Literal       terminator=Literal(Integer, value=2)
```

**Expected chain shape for `b` (analogous):**

```
hop 0: target=b   rhs=a   OriginKind=TrivialCopy   source_variable=a
                                                   classification="destructure"
hop 1: target=a   rhs=1   OriginKind=Literal       terminator=Literal(Integer, value=1)
```

**Termination:** `Literal` at the original `a = 1` / `b = 2` assignments.

**Notes:**
- Per spec §7.2 Ruby override, `a, b = b, a` decomposes into two
  TrivialCopy hops (one per target) with classification "destructure".
- The chain for `a` crosses *the swap step* and lands on the *pre-swap*
  value of `b` (which is the literal `2`). Confidence at each hop is High.
