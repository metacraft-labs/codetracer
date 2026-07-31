---
title: Live Requests — Python
order: 6
---
# Live request tracking in Python

Works with any WSGI or ASGI application — Flask, Django, FastAPI and
anything else that speaks those protocols. Request spans are published by
the recorder's middleware from inside your server process, so there is no
proxy to configure and no code change to your handlers.

## Record your server

Start the server under CodeTracer instead of directly:

```bash
ct record --server --lang python -o ./trace -- flask --app app run --port 8000
```

Anything you would normally type after the program name still works —
flags included. This is the same invocation for Django (`manage.py
runserver`), Uvicorn, Gunicorn or a plain `python app.py`.

The command stays in the foreground while the server runs. Stop it with
`Ctrl-C`; that is a normal end, not a crash, and the recording is complete
when the process exits.

## Watch requests arrive

In a second terminal, with the server still running:

```bash
ct replay -t ./trace
```

The **Requests** panel docks itself as soon as the first request lands. Send
some traffic:

```bash
curl http://localhost:8000/api/users/7
```

A row appears for each request, showing method, route, status and duration.
Double-click one to jump to the handler that served it — from there the whole
time-travelling debugger is available: step backwards through the middleware
that ran before your view, or forwards into the ORM call that built the
response.

## Open a recording later

Nothing about the recording is temporary. To reopen it after the fact:

```bash
ct replay ./trace
```

The panel is populated identically; only the live updates are absent.

## What gets recorded

- **Route templates, not just paths.** A request to `/api/users/7` is
  labelled with the route it matched (`/api/users/<int:user_id>`), so all
  requests to one endpoint group together regardless of their parameters.
- **Status and duration** for every request, including ones that raised.
- **Errors.** A request that ends in an unhandled exception is marked as
  failed and carries the exception message.

## Requirements

Python 3.10 or newer. Nothing else — `ct` locates the Python recorder
itself. If it cannot, it tells you exactly what is missing and how to
install it rather than producing an empty recording.

:::note
If you have used CodeTracer's Python support before: request spans live
*inside* the recording now. There is no `session_manifest.jsonl` or other
sidecar file to keep next to the trace, and nothing to pass to the GUI
besides the recording itself.
:::
