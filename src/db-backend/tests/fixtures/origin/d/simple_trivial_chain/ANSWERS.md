# Expected Origin Chain — d / simple_trivial_chain

**Query target:** local `c` at the `writeln(c)` line.

**Expected behaviour:**

D is currently NOT in the classifier's `Lang` enum (no tree-sitter grammar
yet — see `codetracer/libs/origin-classifier/src/kinds.rs`). The RR
algorithm therefore routes through the "language not supported" path
and surfaces DAP error 6103 (`UnsupportedBackend`).

When tree-sitter-d lands and the classifier picks it up, the expected
chain shape will mirror C / Rust / Nim / Go:

```
hop 0: target=c   rhs=b      OriginKind=TrivialCopy   source_variable=b
hop 1: target=b   rhs=a      OriginKind=TrivialCopy   source_variable=a
hop 2: target=a   rhs=10     OriginKind=Literal       terminator=Literal(int, value=10)
```

**Termination (interim):** DAP error 6103 (UnsupportedBackend) with the
message `rr-driver: classifier does not support language for ...`.
