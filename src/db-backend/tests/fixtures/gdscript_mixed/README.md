# `gdscript_mixed` fixture

`combined_trace.ct` is a **generator-produced** `.ct` container written by the
canonical Nim writer (`codetracer-trace-format-nim`, `multi_stream_writer` +
`span_stream`) — regenerate it with `./regenerate.sh` (inside the codetracer dev
shell). It backs `src/db-backend/tests/mixed_altitude_test.rs`, which exercises
the span-driven half of the implicit-language-switch design
(`codetracer-specs/Planned-Features/Mixed-Trace-Implicit-Switch.md`, principles
P1 / P3).

## What it contains

A **materialized GDScript program** (steps, calls, returns, one bundled `.gd`
source view) plus the **crossing spans** that bound each VM frame's steps:

| Step | Frame              | `.gd` line | Source text            |
| ---- | ------------------ | ---------- | ---------------------- |
| 0    | outer `_ready`     | 5          | `var total = 0`        |
| 1    | outer `_ready`     | 6          | `total += 1`           |
| 2    | outer `_ready`     | 7          | `total = compute(total)` — call site `compute()` |
| 3    | inner `compute`    | 12         | `var r = n * 2` — call site `scale()` |
| 4    | inner-inner `scale`| 17         | `var f = 30`           |
| 5    | inner-inner `scale`| 18         | `return x * f`         |
| 6    | inner `compute`    | 14         | `return r`             |
| 7    | outer `_ready`     | 8          | `print(total)`         |
| 8    | outer `_ready`     | 9          | `queue_free()`         |

The lines are 1-based lines of the bundled `.gd` source view (`extends Node` is
line 1). `committed_ct_fixture_line_readback_test.rs` reads that source view out
of the container and requires each step to land on the text in the last column,
so the table and the bytes cannot drift apart.

Two `span_type: "gdscript-frame"` crossing spans (span 2 nested inside span 1):

| span_id | frame     | start_step | end_step |
| ------- | --------- | ---------- | -------- |
| 1       | `compute` | 3          | 6        |
| 2       | `scale`   | 4          | 5        |

## What it deliberately is NOT

It carries **no native `tNNN` streams and no MCR replay**. A real combined
native+GDScript trace needs the MT14 substrate (patched Godot under `ct-mcr` on
Linux); the native-altitude REPLAY expectations stay `#[ignore]`-gated on MT14.
The db-backend altitude slice is green-able now against exactly this synthetic
VM-plus-spans container.
