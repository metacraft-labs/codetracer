# Value Origin Tracking

**Value Origin Tracking** answers the question "where did this value come
from?" by walking backward through the recorded execution. Starting from
a variable at a chosen step, CodeTracer follows assignments, parameter
passes, return captures, and field/index accesses until it reaches a
**terminator** — a computational expression (e.g. `a + b`), a literal, a
function parameter at the recording boundary, an external read, or one
of a handful of other well-defined stopping conditions. The result is an
**origin chain**: an ordered list of **hops**, each classified by the
kind of dataflow step it represents, ending in a terminator that
explains why the search stopped.

This is distinct from value _history_ (which lists the prior values a
variable held). History tells you "what values has this variable had?";
origin tracking tells you "what computation produced this particular
value?". The two compose well — pinning a historic value and then asking
for its origin is one of the canonical workflows.

The canonical specification with the full UI layout, wire protocol, and
backend semantics is at
[`codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`](https://github.com/metacraft-labs/codetracer-specs/blob/main/GUI/Debugging-Features/Value-Origin-Tracking.md).
This chapter distills the user-facing surfaces.

## When to use it

Origin tracking is most useful when:

- A variable has an unexpected value and you want to know which
  assignment line produced it, not just "what step set it last".
- A bug appears far from its root cause and you want to walk back across
  function boundaries without manually stepping out frame-by-frame.
- You are reviewing data flowing across a wrapper / forwarder /
  serialisation boundary and want to skip the trivial copies that
  shuttle the value around.
- An agent or replay script needs to programmatically explain how a
  value was computed.

If you only need "what was the previous value of this variable", the
value-history popover is faster. Origin tracking is the right tool when
you specifically care about the **source-level computation** that
produced the value, not the sequence of prior values.

## In the CodeTracer GUI

### The inline origin badge

Every row in the Variable State Pane carries a compact **inline origin
badge** to the right of the value. The badge shows a small icon for the
terminator kind (literal, computational expression, parameter at entry,
external read, etc.) and a truncated label with the terminator's source
expression:

```
total       137    [◎ a + b]
items       [..]   [◎ list literal]
ctx         {..}   [◎ param at entry]
```

The badge is pre-fetched together with the locals — no user gesture is
required to see it. When the backend deferred the chain (e.g. for
off-screen history rows), the badge renders as a low-contrast `[?]`
pill; clicking it issues a lazy lookup and replaces the placeholder in
place.

### Expanding the chain in place

Clicking the badge expands the row to show the full hop chain inline,
newest hop first, ending in the terminator. Each hop renders on two
short lines:

- a header line with a small pie-chart timeline indicator,
  `filename:line`, and one or two SVG icons (classification icon plus an
  optional `↘`/`↗` frame-transition arrow);
- the source line of the assignment, monospace.

Trivial-copy hops are de-emphasised; the computational origin hop is
highlighted with a subtle accent background. For computational hops a
chevron expands a per-operand snapshot table (`name = value` rows).

Clicking the badge again collapses the chain.

### The dedicated side panel

For deeper chains that crowd the narrow State Pane, right-clicking a
variable row exposes the **"Show value origin"** action. This opens the
same chain in a dedicated **Origin Chain Side Panel** with richer
layout: full file paths, taller per-hop rows, operand tables, and
breadcrumbs across previously-queried `(variable, step)` pairs.

The same panel can be opened directly from the keyboard with
`Ctrl+Shift+O` on Linux/Windows or `Cmd+Shift+O` on macOS (the default
binding for `codetracer.showValueOrigin`; rebind it through the
standard keybinding settings).

Inside the side panel you can:

- **Click a hop** to seek to that step (the editor pane scrolls and the
  call-trace pane opens the relevant frame).
- **Cmd/Ctrl-click a hop** to open the file at `(path, line)` in a new
  tab without changing the active step.
- **Click an operand** in an expanded computational hop to recursively
  query its origin at the origin step.
- **Right-click a hop → "Pin to scratchpad"** to drop the hop into the
  Scratchpad Pane for later comparison.
- **Right-click the chain → "Copy as markdown"** to serialise the chain
  for a bug report.

### Editor and scratchpad integration

While a chain is active a subtle gutter glyph appears on every editor
line that participates in the chain; hovering the glyph shows a hop
summary. Pinned chains in the Scratchpad Pane render as folded cards,
and pinning two chains side-by-side renders a unified diff of the hop
sequences (useful for "why is iteration 17 different from iteration
16?").

> **Note:** The Origin Chain Side Panel screenshot for this section is
> pending — the M5 Playwright capture suite runs end-to-end on
> recorder-equipped CI runners but SKIPs cleanly in dev shells without
> the Python recorder installed. See the M5 verification entries in
> [`Value-Origin-Tracking.milestones.org`](https://github.com/metacraft-labs/codetracer-specs/blob/main/Planned-Features/Value-Origin-Tracking.milestones.org)
> for the capture status.

## In VS Code

The CodeTracer VS Code extension embeds the same Origin Chain Panel
inside a webview. The same gestures apply:

- Inline origin badges render on every row of the embedded State Pane.
- `Ctrl+Shift+O` / `Cmd+Shift+O` invokes the
  `ct-vscode.showValueOrigin` command and opens the embedded panel.
- Right-clicking a variable row in the State Pane exposes the
  **"Show value origin"** entry.
- Clicking a hop dispatches an `OriginChainVM.onSeekToHop` event which
  the extension translates into a `ct/history-jump` followed by a VS
  Code editor reveal, so the active editor scrolls to the hop's
  `(path, line)`.

> **Note:** The animated screencast of the VS Code experience is pending
> — see the M7 verification entries for capture status.

## From a Python replay script

The Python replay-script API exposes value origin through
`trace.value_origin(...)`. The same script body runs through the MCP
`exec_script` tool and the `ct trace exec --script` CLI subcommand, so
agents and CLI users share a single workflow:

```python
# example.py — passed through `ct trace exec --script example.py <trace>`
chain = trace.value_origin("c", step=42, max_hops=8)

# Inspect the terminator
print(chain.terminator.kind)        # e.g. "Computational"
print(chain.terminator.expression)  # e.g. "a + b"

# Walk the hops (newest first)
for hop in chain.hops:
    print(hop.kind, hop.location.path, hop.location.line)

# Render it as plain text or markdown
print(chain.to_text())
print(chain.to_markdown())
```

`value_origin` returns a `codetracer.origin.OriginChain` dataclass that
mirrors the wire shape from spec §4.1 one-for-one
(`OriginHop`, `OperandSnapshot`, `Terminator`, `FrameTransition`,
`OriginMetrics`, plus the closed-enum types `OriginKind`,
`TerminatorKind`, `FrameTransitionKind`). The full signature is:

```python
trace.value_origin(
    expression: str,
    *,
    step: int | None = None,
    frame: int | None = None,
    max_hops: int = 16,
    lazy: bool = False,
    continuation_token: str | None = None,
) -> OriginChain
```

When `lazy=True` the backend may return early with a
`continuation_token`; pass it back on the next call to resume the walk.

The binding is implemented in `python-api/codetracer/trace.py` and the
dataclasses live in `python-api/codetracer/origin.py`.

## From the CLI

For one-shot queries from the terminal use `ct trace origin`:

```bash
ct trace origin <trace-path> --variable c --format text
```

Common flags:

- `--variable <NAME>` (required) — the identifier to query.
- `--step <N>` — query at a specific step id (defaults to current).
- `--frame <N>` — query within a specific DAP frame (defaults to the
  topmost frame).
- `--max-hops <N>` — limit the walk (default 16).
- `--format <json|markdown|text>` — choose the renderer (default
  `text`).
- `--lazy` — allow the backend to return a continuation token instead
  of walking the full chain.

The text renderer matches the ASCII layout from spec §3.2 (newest hop
first, terminator at the bottom, frame-transition glyphs inline). The
markdown renderer emits a fenced chain with a per-hop table — paste it
straight into a bug report. The JSON renderer pretty-prints the
canonical `OriginChain` wire shape so other tools can parse it.

For longer agent workflows that need to compose origin lookups with
locals/history/breakpoints, prefer
`ct trace exec --script <file.py> <trace-path>` and call
`trace.value_origin(...)` inside the script — the trace stays loaded
across multiple calls, and the classifier's pattern cache is reused.

See the [`ct` CLI reference](../reference/ct_cli.md#ct-trace-origin) for
the full flag table.

## From an MCP-capable agent

The CodeTracer MCP server registers two tools that surface origin
tracking to LLM agents directly:

- **`get_value_origin`** — one-shot lookup. Returns the canonical
  `OriginChain` JSON for `variable` at `step`/`frame`. Use this when you
  only need a single chain without authoring a script.
- **`resolve_variable_step`** — helper that maps a variable name to the
  most recent step at which it was assigned. Pair it with
  `get_value_origin` when you want the chain at the assignment site
  rather than the current step.

The **preferred** multi-step path is to send a Python script through the
existing `exec_script` MCP tool and call `trace.value_origin(...)`
inside it — that composes with `trace.locals()`, `trace.history()`,
breakpoints, and watchpoints, and reuses the loaded trace + pattern
cache across calls.

See the [MCP tool reference](../reference/mcp-tools.md) for the full
input/output schemas.

## Per-language coverage

Backward-walk support is rolled out per language and per recording
backend:

| Backend / Language                                | Status                                                                                                          |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Materialized DB — Python (`codetracer-python-recorder`) | Supported.                                                                                                      |
| Materialized DB — Ruby (`codetracer-ruby-recorder`)     | Supported.                                                                                                      |
| Materialized DB — JavaScript (`codetracer-js-recorder`) | Supported (with the granularity caveat from spec §6.1.4).                                                       |
| RR-driver — C / C++ / Rust / Nim / Go / D         | Planned (M11). Uses watchpoint + reverse-continue against `codetracer-native-backend`.                          |
| MCR — hybrid backend                              | Planned (M14). Uses the omniscient undo-map for the last mile and breakpoints for deeper prefixes.              |
| MCR — omniscient acceleration                     | Planned (M21, gated on the M10d–e omniscient DB).                                                               |

Origin chains across all backends produce the same response shape; only
the realistic maximum hop depth, the quality of `kind` classification,
and the recording-boundary behaviour differ between backends.

## Customising classification

CodeTracer ships with a built-in catalogue of language-specific patterns
that identify trivial copies, forwarders, and field/index accesses.
Projects can extend or override the catalogue without touching CodeTracer
itself.

Patterns live in TOML files. The classifier evaluates them in this
**precedence order**, first match wins:

1. **Trace-local overrides** — `meta_dat/origin-patterns/_overrides.toml`
   inside the trace folder. The recorder never writes this file; create
   it explicitly when you want to override an embedded library default
   for a specific trace.
2. **User-personal overrides** —
   `~/.config/codetracer/origin-patterns.toml`. Use this for judgement
   calls you want applied across every trace you replay.
3. **Embedded library patterns** — `meta_dat/origin-patterns/` inside the
   trace, populated automatically by the recorder from each library's
   `.codetracer/origin-patterns.toml`.
4. **Built-in catalogue** — the language-specific default patterns that
   ship with CodeTracer.

A typical project authors `.codetracer/origin-patterns.toml` at the
project root; the recorder picks it up and embeds it under
`meta_dat/origin-patterns/` so the patterns travel with the trace and
remain reproducible on any machine that opens it.

Pattern files use a single TOML schema across all four levels. See spec
§7.4 for the full schema reference. A common case is marking a wrapper
constructor as a trivial copy so the chain skips it:

```toml
[[trivial_copy]]
# Skip Wrapper.into() — it just unboxes the inner value.
language = "rust"
call_pattern = "Wrapper::into"
continuation = "self.inner"
```

All four surfaces above — the GUI, the VS Code embedded panel, the MCP
tools, and the CLI subcommand — honour the same precedence stack, so a
pattern added at any level applies uniformly to every caller.

## See also

- [`GUI/Debugging-Features/Value-Origin-Tracking.md`](https://github.com/metacraft-labs/codetracer-specs/blob/main/GUI/Debugging-Features/Value-Origin-Tracking.md)
  — the canonical specification (UI layout §3.2, preferences §3.7,
  classification rules §7, pattern schema §7.4).
- [`ct` CLI reference](../reference/ct_cli.md#ct-trace-origin) — full
  flag table for `ct trace origin`.
- [MCP tool reference](../reference/mcp-tools.md) — input/output
  schemas for `get_value_origin` and `resolve_variable_step`.
