# Expected Origin Chain — python / parameter_pass

**Query target:** local `local` at the `print(local)` line inside `receive`.

**Expected chain shape:**

```
hop 0: target=local   rhs=p              OriginKind=TrivialCopy   source_variable=p
hop 1: target=p       rhs=<arg-bind>     OriginKind=TrivialCopy   classification="parameter passing"
                                                                  source_variable=value (at call site `receive(value)`)
hop 2: target=value   rhs=7              OriginKind=Literal       terminator=Literal(int, value=7)
```

**Termination:** `Literal` at `value = 7` in `main`.

**Notes:**
- Hop 1 crosses a function boundary: the parameter `p` in `receive`'s
  frame binds to the argument `value` in `main`'s frame at the call site.
  Per spec §7.3, this is `TrivialCopy` with classification "parameter
  passing".
- The chain MUST follow the argument back into the caller's frame
  before terminating.
