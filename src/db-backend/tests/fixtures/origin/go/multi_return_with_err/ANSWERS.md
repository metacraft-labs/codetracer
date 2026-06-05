# Expected Origin Chain — go / multi_return_with_err

**Query target:** `a` at the `fmt.Println(a)` line.

**Expected chain shape:**

```
hop 0: target=a   rhs=foo()   OriginKind=ReturnCapture   source_variable=foo()$0
hop 1: terminator=Literal(int, value=42)
```

**Termination:** `Literal`.

**Notes:** Go's multi-return destructuring `a, err := foo()` produces
TWO ReturnCapture hops on a query of the *second* slot (`err`); a
query of the *first* slot (`a`) produces ONE ReturnCapture hop. The
M11 verification asserts that the chain depth is at least 1 and that
the first hop is `ReturnCapture`.
