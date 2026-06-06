# Recording a browser app

CodeTracer's browser recorder (M26) captures the same execution-flow
events the Node.js recorder captures — `Step`, `Call`, `Return`,
`Assignment`, `Value`, correlation markers — and streams them to a
local daemon over WebSocket.  The daemon converts the newline-delimited
JSON stream to a CTFS `.ct` file you can load in the CodeTracer GUI or
debug from the CLI just like any other recording.

This guide walks through three deployment shapes:

1. **Vite dev-server** — the recommended flow for everyday development.
2. **AOT CLI** — `codetracer-js-recorder instrument` produces a
   drop-in static bundle.
3. **Webpack / esbuild / Rollup** — thin wrapper packages that share the
   same SWC instrumentation visitor.

The wire format and policy are specified in
[Value-Origin-Tracking.md §14.4](../../../../../codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md);
this guide is the operational counterpart.

## 1. Vite dev-server

Install the plugin alongside your existing Vite setup:

```bash
npm install --save-dev @codetracer/vite-plugin
```

Add it to your `vite.config.ts`:

```ts
import { defineConfig } from "vite";
import codetracer from "@codetracer/vite-plugin";

export default defineConfig({
  plugins: [
    codetracer({
      // Optional — defaults to ws://localhost:9230/ct-stream
      endpoint: "ws://localhost:9230/ct-stream",
    }),
  ],
});
```

Start the daemon receiver in another terminal (the M26 receiver entry
point lives in `backend-manager`'s `browser_stream_receiver` module —
see the streaming-recording runbook for the host-process choice that
matches your deployment).  Then run `vite` as usual; every transformed
module is instrumented, and the page emits events to the daemon
automatically.

Hot Module Replacement keeps working: only the changed module is
re-instrumented, mirroring Vite's default HMR behaviour.

## 2. AOT CLI (`codetracer-js-recorder instrument --browser`)

For static hosting (CI smoke tests, GitHub Pages, edge deploys) the CLI
produces a drop-in instrumented bundle plus a small browser-runtime
bootstrap stub:

```bash
codetracer-js-recorder instrument ./src \
  --out ./dist-instrumented \
  --browser \
  --endpoint "ws://localhost:9230/ct-stream"
```

The output directory contains:

- The instrumented `.js` / `.ts` files mirroring the input tree.
- `codetracer.manifest.json` — the merged manifest the daemon needs
  to lower events into CTFS.
- `codetracer-runtime.js` — the browser-runtime bootstrap.  Add it to
  your `index.html` before any instrumented bundle loads:

  ```html
  <script src="./codetracer-runtime.js"></script>
  ```

The runtime opens a WebSocket to the configured endpoint, buffers events
in memory, and flushes on a 256-event threshold + on the `pagehide` /
`beforeunload` page-lifecycle events.

## 3. Webpack / esbuild / Rollup

Each bundler has its own plugin package, all wrapping the same
`@codetracer/instrumenter-core` visitor used by the Vite plugin.  The
output is byte-for-byte identical regardless of which bundler runs the
visitor — the per-bundler smoke tests pin this contract.

```ts
// webpack.config.js
const { CodetracerWebpackPlugin } = require("@codetracer/webpack-plugin");
// (loader integration: see the package README)

// rollup.config.mjs
import codetracerRollup from "@codetracer/rollup-plugin";
export default { plugins: [codetracerRollup()] };

// build.mjs (esbuild)
import { build } from "esbuild";
import codetracerEsbuild from "@codetracer/esbuild-plugin";
await build({ plugins: [codetracerEsbuild()] });
```

## Correlation markers (no protocol shims)

The browser recorder **does not** intercept `fetch`, `XMLHttpRequest`,
`WebSocket`, or `window.postMessage`.  Cross-process correlation rides
on the M25 user-placed marker mechanism: you place a marker at the
boundary in your own code, and the recorder evaluates it through the
same tracepoint surface it uses for any other event.

```ts
// In your page code, just before encoding the request body:
__ct.markCorrelation("send", "outbound", requestId, { kind: "balance-fetch" });

// In your backend (Node, Python, Ruby — any recorder), just after
// decoding the request:
ct.mark_correlation_recv(request_id, request_body, boundary="inbound")
```

The send/recv pair joins at trace load time, and a `ct originChain`
query on the response value traverses both recordings end-to-end.
See [Correlation-Markers.md](../../../../../codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md)
for the full marker grammar.

## Troubleshooting

- **Events do not appear.** Check the daemon is listening on the
  configured endpoint (`ws://localhost:9230/ct-stream` by default) and
  that `window.__codetracer_endpoint` matches.  The runtime silently
  degrades to a no-op when the WebSocket cannot connect — the page
  itself is never broken.
- **Source maps are missing in devtools.** Pass `sourceMaps: true` to
  the Vite plugin (the default) and `--source-maps` to the CLI.  The
  instrumenter chains through any existing input source map.
- **Recording disabled in production.** Either omit the plugin from
  your prod build config or set `window.__codetracer_endpoint = null`
  before the runtime loads — the browser runtime exposes a `disabled`
  option for explicit control during local testing.
