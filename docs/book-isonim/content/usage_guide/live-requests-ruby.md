---
title: Live Requests — Ruby
order: 7
---
# Live request tracking in Ruby

Works with any Rack application — Rails, Sinatra, Roda and friends. Request
spans are published by Rack middleware running inside your server process,
so there is nothing to add to your controllers.

## Record your server

Start the server under CodeTracer instead of directly:

```bash
ct record --server --lang ruby -o ./trace -- rails server --port 3000
```

or, for a Sinatra app:

```bash
ct record --server --lang ruby -o ./trace -- ruby app.rb -p 4567
```

Flags after the program name are passed through unchanged. The command
stays in the foreground; stop it with `Ctrl-C`, which is a normal end.

## Watch requests arrive

In a second terminal, with the server still running:

```bash
ct replay -t ./trace
```

Send some traffic and the **Requests** panel fills in:

```bash
curl http://localhost:3000/users/7
```

Double-click a row to land in the action that handled it. Because the whole
server is one recording, you can step backwards out of your controller into
the Rack middleware stack that ran first — including middleware you did not
write.

## Open a recording later

```bash
ct replay ./trace
```

## What gets recorded

- **Route patterns**, so `/users/7` and `/users/9` group under the same
  endpoint.
- **Status and duration** per request.
- **Errors**, including the exception message for requests that raised.

## Requirements

Ruby 3.0 or newer.

:::caution
On macOS, install Ruby through [Homebrew](https://brew.sh) (`brew install
ruby`). The Ruby that ships with macOS is many years old and recording
against it fails.
:::

:::note
Rails applications are supported. If you tried Rails with CodeTracer some
time ago and hit a hang during boot, that was a recorder bug in integer
conversion on large values; it is fixed.
:::
