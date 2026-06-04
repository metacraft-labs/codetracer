# Expected Origin Chain — ruby / parameter_pass

**Query target:** local `local` at the `puts local` line inside `receive`.

**Expected chain shape:**

```
hop 0: target=local   rhs=p              OriginKind=TrivialCopy   source_variable=p
hop 1: target=p       rhs=<arg-bind>     OriginKind=TrivialCopy   classification="parameter passing"
                                                                  source_variable=value (at call site `receive(value)`)
hop 2: target=value   rhs=7              OriginKind=Literal       terminator=Literal(Integer, value=7)
```

**Termination:** `Literal`.

**Notes:** Hop 1 crosses a function boundary per spec §7.3.
