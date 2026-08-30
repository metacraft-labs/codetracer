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

| Step | Frame              | `.gd` line | Note                    |
| ---- | ------------------ | ---------- | ----------------------- |
| 0    | outer `_ready`     | 4          |                         |
| 1    | outer `_ready`     | 5          |                         |
| 2    | outer `_ready`     | 6          | call site `compute()`   |
| 3    | inner `compute`    | 11         | call site `scale()`     |
| 4    | inner-inner `scale`| 16         |                         |
| 5    | inner-inner `scale`| 17         |                         |
| 6    | inner `compute`    | 13         |                         |
| 7    | outer `_ready`     | 7          |                         |
| 8    | outer `_ready`     | 8          |                         |

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
