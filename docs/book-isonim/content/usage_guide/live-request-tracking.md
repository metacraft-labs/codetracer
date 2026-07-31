---
title: Live Request Tracking
order: 5
---
# Live request tracking

CodeTracer can record a running web server and show you its HTTP requests
as they arrive. Each request becomes a row in the **Request Panel**;
double-clicking a row jumps to the code that handled it, with the full
time-travelling debugger available from that point — step backwards into
the middleware that ran before your handler, or forwards into the query
that produced the response.

This works while the server is still running. You do not stop the server,
export anything, or convert a log: the recording is readable as it is
being written.

## The two things you will do

**Record a live server**, and watch requests arrive:

```bash
ct record --server --lang <lang> -o ./trace -- ./my-server   # terminal 1
ct replay -t ./trace                                         # terminal 2
```

`--server` tells CodeTracer the program outlives the command. Stopping it
with `Ctrl-C` is a normal end, not a crash. Everything else about
`ct record` is unchanged — `-o`, `--backend`, `--upload`, `--with-diff`
and `--export` all still apply.

Two parts of that command line are easy to leave out, and both are needed:

- **`--`** separates CodeTracer's own options from your server's. Without
  it, a flag meant for your program is read as one of CodeTracer's:
  `php -S localhost:8000` fails outright, and a flag that collides with one
  of CodeTracer's own is worse — it is quietly accepted and your server
  never starts.
- **`--lang`** names the language. CodeTracer normally infers it from the
  file you are recording, but a server is usually started through a
  launcher — `flask`, `rails`, `mix phx.server`, `php -S` — with no source
  file on the command line to infer from. Native servers are the exception:
  they need no `--lang`.

**Open a finished recording**, any time later:

```bash
ct replay ./my-server-recording
```

The Request Panel is populated the same way; the only difference is that
no new rows arrive.

:::note
`ct` is the only command you need. The individual language recorders are
implementation details — you do not install or invoke them separately, and
nothing in this guide asks you to.
:::

## Pick your language

You almost certainly care about one of these, not all of them. Each page
is self-contained: install, start your server under CodeTracer, and see
requests.

- [Python](/usage_guide/live-requests-python) — Flask, Django, FastAPI, any WSGI/ASGI app
- [Ruby](/usage_guide/live-requests-ruby) — Rails, Sinatra, any Rack app
- [PHP](/usage_guide/live-requests-php) — built-in server, php-fpm pools
- [Elixir & Erlang](/usage_guide/live-requests-elixir) — Phoenix, Plug/Cowboy
- [JavaScript](/usage_guide/live-requests-javascript) — Express and other Node servers
- [C, C++, Rust and other native servers](/usage_guide/live-requests-native)

## How your server gets recorded

You do not need this section to use the feature, but it explains why the
per-language pages differ, and why one of them has a caveat the others do
not.

A request span needs two things: the boundaries of the request, and the
place in the recording where it happened. CodeTracer gets these in one of
three ways, depending on what the language runtime offers.

| Shape | Languages | Where spans come from |
| --- | --- | --- |
| **Middleware** | Python, Ruby, JavaScript, Elixir, Erlang | The server's own middleware layer (WSGI/ASGI, Rack, Express, Plug) publishes each request from inside the recorded process. |
| **Per-worker** | PHP | The extension publishes from each worker process; CodeTracer is told the parent directory, because a pool writes one container per worker. |
| **Supervisor** | C, C++, Rust, Go, … | A native server has no middleware seam, so a separate supervisor binary discovers the requests. |

All three produce the same thing — one recording, with each request as an
interval inside it. A request is not a separate recording, and the panel is
not reading a log file alongside the trace. This matters in practice: because
requests are intervals of one recording, you can step from one request into
code that ran before it, and shared state is genuinely shared rather than
stitched together after the fact.

## Languages without a server story

Some languages have a recorder but nothing that usefully survives a
long-running process. `ct record --server` says so plainly rather than
recording a plain run and letting you discover the difference in the panel.
If you see that message, the language is not yet wired for live request
tracking — the recording you would get is still valid, it just has no
request spans.
