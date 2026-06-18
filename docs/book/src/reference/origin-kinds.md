# Origin Kinds Reference

This page enumerates the three closed enums that classify the rows of
an **origin chain**: `OriginKind` (per-hop classification),
`TerminatorKind` (why the backward walk stopped), and
`FrameTransitionKind` (the direction of a function-boundary crossing
on a hop). All three are part of the wire shape defined in spec §4.1
and travel verbatim across the DAP / MCP / CLI surfaces.

The canonical Rust definitions live in
`codetracer/src/db-backend/src/task.rs`; the Python mirror lives in
`python-api/codetracer/origin.py`.

For the user-facing walkthrough see
[Value Origin Tracking](../usage_guide/value-origin-tracking.md).

## `OriginKind`

Carried on every `OriginHop`. The classifier emits the variant that
best explains the dataflow step from the *previous* hop to *this* hop.

| Variant           | Meaning                                                                                                                        | Typical hop                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| `TrivialCopy`     | Source-level assignment that moves a value verbatim — `b = a`, `let y = x;`, `b := a`. Rendered de-emphasised in the chain.    | `b = a`                                                                    |
| `FieldAccess`     | RHS reads a field of a struct/object/record — `x = obj.field`.                                                                 | `x = obj.field`                                                            |
| `IndexAccess`     | RHS reads an element by index/key — `x = arr[i]`, `x = m["k"]`.                                                                | `x = arr[i]`                                                               |
| `Computational`   | RHS is an *expression* whose value derives from multiple sources — `r = a + b`, `s = fmt!("{x}+{y}", ...)`. Highlighted hop.   | `r = a + b`                                                                |
| `FunctionCall`    | RHS invokes a function whose return value is captured — `y = foo(...)`. When the chain *descends* into the callee, see below.  | `y = foo()`                                                                |
| `Literal`         | RHS is a literal value — `x = 10`, `name = "alice"`, `xs = []`.                                                                | `x = 10`                                                                   |
| `ReturnCapture`   | Hop captures the result of a function return (`await` / explicit return). Pairs with a `FrameTransitionKind::ReturnCapture`.   | `y = foo()` after `foo` returned                                           |
| `FunctionReturn`  | Reserved alias of `ReturnCapture` re-emitted on the callee side so future renderers can style the two halves separately.       | (callee-side mirror)                                                       |
| `ParameterPass`   | Hop crosses *into* a callee through a parameter binding. Pairs with a `FrameTransitionKind::ParameterPass`.                    | `def helper(a): ...` receiving the caller's argument                       |
| `CrossThreadCopy` | RR/MCR backends — the write that produced the value happened on a thread other than the querying thread. Confidence ≈ 0.6.    | Tagged with the cross-thread icon in the chain panel                       |
| `Unknown`         | The classifier could not parse the source line into a known shape. Treated as opaque; the chain typically terminates shortly. | Garbled / preprocessed line                                                |

Notes:

- `Computational` is the **classification of the hop**, not the
  reason the chain stopped. A computational hop can sit in the middle
  of a chain (the chain may keep walking the operands' own origins);
  it does not by itself end the walk. The chain ends when the walker
  produces a `Terminator` row — see below.
- `ParameterPass` / `ReturnCapture` hops are the only ones that carry
  a populated `FrameTransition`. All other hops have `frameTransition`
  set to `null`.
- The classifier returns `Unknown` (`confidence < 0.5`) for any line
  it cannot parse; the chain terminates with `TerminatorKind::UnknownSource`.

## `TerminatorKind`

The bottom row of every chain is a `Terminator`, not a hop. Its
`kind` is one of the variants below; the `expression` field carries
the terminator's source text and the `function` field carries the
containing function when known.

| Variant                  | Meaning                                                                                                                                                                                       |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Literal`                | Walked back to a literal RHS — `x = 10`, `x = "alice"`, `xs = []`. The chain's ultimate source is a constant inside the recording.                                                            |
| `Computational`          | Walked back to a computational expression whose operands are themselves terminal (literals, parameters, externals). The expression is the chain's "root cause" in user-code.                  |
| `ParameterAtRecordStart` | Walked back to a parameter binding at the recording boundary — the value entered the trace as a function argument, with no recorded caller. Common when recording starts mid-execution.       |
| `ReadFromExternal`       | Walked back to a read from outside the recording — a system call, file I/O, network response, environment variable, randomness source.                                                        |
| `RecordingStart`         | The backward walk reached the start of the trace without finding an earlier write. Typical for partial recordings.                                                                            |
| `UnknownSource`          | The classifier could not parse the source line (e.g. macro-expanded, preprocessor output, missing source).                                                                                    |
| `UnknownVariable`        | The queried variable could not be resolved at the requested step (e.g. typo, out-of-scope).                                                                                                   |
| `DepthLimit`             | The walker hit the per-request `max_hops` cap before reaching a natural terminator. Use `--lazy` + `continuationToken` to resume.                                                             |
| `OutOfBudget`            | The walker exhausted a backend-specific wall-clock or per-hop budget. Common on release-mode native traces where the assignment was elided by the optimiser. Often paired with `truncated: true`. |

The terminator's SVG icon in the GUI maps one-to-one to these
variants (see spec §3.2.2 for the icon-set table).

## `FrameTransitionKind`

When an `OriginHop` crosses a function boundary the
`frameTransition` field is populated with one of:

| Variant         | Meaning                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------- |
| `ParameterPass` | Chain descends *into* a callee. Rendered with the `↘` glyph on the hop's header line.                |
| `ReturnCapture` | Chain ascends *back into* the caller. Rendered with the `↗` glyph on the hop's header line.          |

Hops on the same `OriginKind` axis usually pair one-for-one:
`OriginKind::ParameterPass` carries `FrameTransitionKind::ParameterPass`;
`OriginKind::ReturnCapture` / `FunctionReturn` carry
`FrameTransitionKind::ReturnCapture`. Other hops carry no
`frameTransition`.

## See also

- [Value Origin Tracking](../usage_guide/value-origin-tracking.md) —
  user-facing walkthrough across all four surfaces (GUI, VS Code,
  CLI, MCP).
- [MCP tool reference](./mcp-tools.md) — `get_value_origin` /
  `resolve_variable_step` schemas (the same enums appear on the
  wire).
- [`ct` CLI reference](./ct_cli.md#ct-trace-origin) — `--format json`
  emits the canonical wire shape with these enum values.
- `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`
  §4.1 — the authoritative wire-schema definition.
