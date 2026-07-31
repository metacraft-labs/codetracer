---
title: Live Requests — Native Servers
order: 11
---
# Live request tracking in native servers

Covers servers written in C, C++, Rust, Go and other compiled languages —
including ones whose source you do not have, such as a stock `nginx`.

## How this differs from the other languages

Python, Ruby, PHP, JavaScript and Elixir all publish request spans from a
middleware layer inside the recorded process. A native server has no such
seam: there is no standard middleware interface to hook, and the server may
not be code you can modify at all.

So CodeTracer takes a different route. A supervisor discovers the requests
from the recording itself, rather than the server announcing them. You do
not need to link a library, recompile, or patch the binary.

## Record your server

```bash
ct record --server -o ./trace -- nginx -g 'daemon off;'
```

or your own binary:

```bash
ct record --server -o ./trace -- ./my-service --listen 127.0.0.1:8080
```

Flags after the program name are passed through unchanged. The server must
run in the foreground — for daemons, use whatever flag keeps them attached
(`-g 'daemon off;'` for nginx, `--nodaemonize` and similar elsewhere), so
that stopping the recording with `Ctrl-C` stops the server too.

## Watch requests arrive

In a second terminal:

```bash
ct replay -t ./trace
```

Send traffic and rows appear as requests are discovered.

## Open a recording later

```bash
ct replay ./trace
```

## What gets recorded

- **Method, path, status and duration** per request.
- The **position in the recording** where each request was served, so
  double-clicking a row seeks there.

Route *templates* are generally not available: without framework knowledge
there is nothing that says `/users/7` and `/users/9` are the same endpoint.
Rows are labelled with the concrete path instead.

## Requirements

Linux or macOS. Recording a native program uses CodeTracer's native
recording backend, which needs no changes to the program under test.

:::note
Because there is no middleware, request discovery depends on CodeTracer
recognising the server's protocol handling. Plain HTTP is supported. If your
server speaks HTTPS directly, terminate TLS in front of it (or point
CodeTracer at the plaintext side) — encrypted request boundaries are not yet
discovered.
:::
