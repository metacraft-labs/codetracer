---
title: Live Requests — PHP
order: 8
---
# Live request tracking in PHP

Works with the built-in development server and with php-fpm pools. Request
spans are published by the CodeTracer PHP extension from inside each worker
process, so no framework integration is needed — Laravel, Symfony, WordPress
and plain PHP all record the same way.

## Record the built-in server

```bash
ct record --server --lang php -o ./trace -- php -S 127.0.0.1:8000 -t public/
```

Flags after the program name go to PHP unchanged, so this is exactly the
`php -S` command you already use. The recording stays in the foreground;
stop it with `Ctrl-C`.

## Record a php-fpm pool

```bash
ct record --server --lang php -o ./trace -- php-fpm --nodaemonize
```

A pool runs several worker processes, and each one writes its own container.
CodeTracer handles this for you: `-o` names a *parent directory*, the workers
write into it, and the panel shows the requests from all of them together.
You do not need to know which worker served which request.

## Watch requests arrive

In a second terminal:

```bash
ct replay -t ./trace
```

Then send traffic:

```bash
curl 'http://127.0.0.1:8000/index.php?id=7'
```

Rows appear as requests complete. Double-click one to jump into the code that
served it.

## Open a recording later

```bash
ct replay ./trace
```

## What gets recorded

- **The framework and route**, when CodeTracer can identify them.
- **Status and duration** per request.
- **Errors**, including the message for requests that ended in a fatal error
  or uncaught exception.

## Requirements

PHP 8.1 or newer. The CodeTracer extension is loaded for you — you do not
need to edit `php.ini` or pass `-d extension=…` yourself.

:::note
If you used an early version of CodeTracer's PHP support: the standalone
`CodeTracerSpan` PHP class and its JSONL sidecar are gone. Request metadata
is written into the recording itself, so there is no second file to keep
alongside the trace and nothing to pass to the GUI but the recording.
:::
