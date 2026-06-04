# Expected Origin Chain — javascript / parameter_pass

**Query target:** local `local` at the `console.log(local)` line inside `receive`.

**Expected chain shape:**

```
hop 0: target=local   rhs=p              OriginKind=TrivialCopy   source_variable=p
hop 1: target=p       rhs=<arg-bind>     OriginKind=TrivialCopy   classification="parameter passing"
                                                                  source_variable=value (at `receive(value)`)
hop 2: target=value   rhs=7              OriginKind=Literal       terminator=Literal(Number, value=7)
```

**Termination:** `Literal`. Hop 1 crosses function boundary per spec §7.3.
