# Expected Origin Chain — nim / implicit_result

**Query target:** local `c` at the `echo c` line in `main`.

**Expected chain shape:**

```
hop 0: target=c        rhs=compute()  OriginKind=ReturnValue    source_variable=result(compute)
hop 1: target=result   rhs=42         OriginKind=Literal        terminator=Literal(int, value=42)
```

**Termination:** `Literal`. The implicit ``result`` Nim auto-injects
when a proc declares a return type is the cross-frame hop the walker
must traverse — it bridges the caller's binding into the callee.

**Notes:** Spec §6.3 ReturnValue — the implicit ``result`` is the
canonical Nim-side cross-frame hop.  A bare last-expression
(``proc compute(): int = 42``) is equivalent and should yield the
same chain shape; this fixture pins the explicit-``result`` form.
