---
title: Live Requests — JavaScript
order: 10
---
# Live request tracking in JavaScript

Works with Express and other Node HTTP servers. Request spans are published
by middleware inside the recorded process.

## Record your server

```bash
ct record --server --lang javascript -o ./trace -- node server.js --port 3000
```

Flags after the program name reach Node unchanged. Stop with `Ctrl-C`.

## Watch requests arrive

In a second terminal:

```bash
ct replay -t ./trace
```

Send traffic:

```bash
curl http://localhost:3000/users/7
```

Double-click a row to jump into the route handler that served it.

## Open a recording later

```bash
ct replay ./trace
```

## What gets recorded

- **Route patterns** rather than concrete paths, so requests to one endpoint
  group together.
- **Status and duration** per request.
- **Errors**, including the message for requests that threw.

## Concurrent requests

Node serves requests concurrently on one thread, interleaving them at every
`await`. CodeTracer follows the asynchronous execution context, so each
request's span covers *its own* work rather than whatever happened to run
between its start and end. Two requests that overlap in wall-clock time
produce two correctly separated rows.

## Requirements

Node.js 20 or newer.

:::note
`ct record app.js` also works for ordinary, non-server scripts. If you have
used it before and found that recordings appeared empty, that was an import
resolution bug affecting `node_modules`; it is fixed.
:::

## Browser applications

This page covers server-side Node. To record a front-end application running
in a browser, see [Recording a browser
app](/usage_guide/recording-a-browser-app), which uses a different mechanism.
