---
title: Elixir & Erlang
order: 105
---
## Elixir & Erlang

CodeTracer supports Elixir 1.15 and newer, and Erlang/OTP 26 and newer.

The recorder is hosted in the
[codetracer-beam-recorder](https://github.com/metacraft-labs/codetracer-beam-recorder)
repo; `ct` finds it for you.

## How to record an Elixir program

```bash
ct run hello.exs
```

Arguments after the filename are passed through unchanged:

```bash
ct run script.exs --count 10
```

For a Mix project, record the command you would normally run:

```bash
ct record -o ./trace mix run -e 'MyApp.main()'
ct replay ./trace
```

## Recording a Phoenix or Plug application

Web applications are recorded as a running server. That has its own guide:
[Live requests — Elixir & Erlang](/usage_guide/live-requests-elixir).

In short:

```bash
ct record --server --lang elixir -o ./trace -- mix phx.server
```

Then `ct replay -t ./trace` in another terminal shows requests as they
arrive.

## BEAM processes in a recording

Elixir code tends to spawn many lightweight processes. These are recorded as
*threads* within a single recording rather than as separate recordings, so
message passing between them stays visible in one place, and you can follow
work as it moves from one process to another.
