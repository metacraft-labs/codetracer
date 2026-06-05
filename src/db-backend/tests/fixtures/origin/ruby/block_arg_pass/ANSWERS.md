# Expected Origin Chain - ruby / block_arg_pass

**Query target:** local `inside` at the `puts inside` line inside the block.

**Expected chain shape:**

```
hop 0: target=inside  rhs=x              OriginKind=TrivialCopy   source_variable=x
hop 1: target=x       rhs=<block-arg>    OriginKind=ParameterPass classification="parameter passing"
                                                                  source_variable=xs[0] at the call site
hop 2: target=xs      rhs=[42]           OriginKind=Computational
       operand_snapshots = [{ value: 42 }]
       terminator=Computational(expr="[42]")
```

**Termination:** `Computational` at the array literal `[42]`.

**Notes:**
- Per spec §7.2 Ruby override, the block argument `x` in `xs.each { |x| }`
  classifies as `ParameterPass` - the same shape as a function parameter
  binding - and continues back at the iterator source `xs`.
- Confidence: High at hops 0 and 2; >= 0.7 at hop 1 (block-arg pass has
  slightly lower confidence than a direct function call per the §7.2
  override table).
