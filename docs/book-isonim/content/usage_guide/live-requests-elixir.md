---
title: Live Requests — Elixir & Erlang
order: 9
---
# Live request tracking in Elixir and Erlang

Works with Phoenix and with plain Plug/Cowboy applications. Request spans
are published by a Plug in your endpoint pipeline, inside the recorded
process.

## Record your server

```bash
ct record --server --lang elixir -o ./trace -- mix phx.server
```

or, for a plain Plug application:

```bash
ct record --server --lang elixir -o ./trace -- mix run --no-halt
```

Flags after the program name are passed through unchanged. Stop with
`Ctrl-C`, which is a normal end.

## Watch requests arrive

In a second terminal:

```bash
ct replay -t ./trace
```

Send traffic and rows appear:

```bash
curl http://localhost:4000/users/7
```

Double-click a row to jump to the code that handled the request.

## Open a recording later

```bash
ct replay ./trace
```

## What gets recorded

- **The route from your router**, so parameterised routes group correctly.
- **Status and duration** per request.
- **Errors**, including the exception message.

## A note on BEAM concurrency

The BEAM serves each request in its own lightweight process. These map onto
*threads* within a single recording rather than separate recordings, so a
burst of concurrent requests is one recording containing many overlapping
intervals. The Request Panel shows them as separate rows even though they
ran at the same time, and the recording preserves which ones genuinely
overlapped.

:::note
Double-clicking a request row currently lands you at the request boundary
rather than inside your handler function for some `.ex` modules. The span
itself is correct — method, route, status and duration are all accurate, and
the recording contains the handler — but the seek target may be earlier than
you expect. Compiled `.exs` scripts are unaffected.
:::

## Requirements

Elixir 1.15 or newer, or Erlang/OTP 26 or newer for plain Erlang servers.
