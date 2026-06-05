# Expected Origin Chain — c / cross_thread_copy

**Query target:** local `local` at the `printf("%d\n", local)` line.

**Expected chain shape (the key assertion is the cross-thread hop):**

```
hop 0: target=local      rhs=atomic_load(&g_shared)   OriginKind=TrivialCopy        source_variable=g_shared (confidence>=0.9)
hop 1: target=g_shared   rhs=99                       OriginKind=CrossThreadCopy    source_variable=99       (confidence=0.6)
hop 2: terminator=Literal(int, value=99)
```

**Termination:** `Literal`.

**Required by M11 test #3 — `test_origin_rr_cross_thread_copy_tagged`:**

At least one hop in the returned chain MUST carry
`kind=CrossThreadCopy` with `confidence == 0.6` (per spec §6.3
"Cross-thread guard"). The algorithm switches the replay session to
the writing thread before reading the source line for the next hop.
