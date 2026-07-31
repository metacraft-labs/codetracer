// Cross-process origin demo — Vite configuration.
//
// This is the integration point the demo exists to exercise: the
// CodeTracer instrumenter runs as an ordinary Vite plugin, in the
// ordinary transform pipeline, over ordinary application source.
// Nothing pre-processes the app before Vite sees it.
//
// The plugin also owns the **manifest** — the table mapping the flat
// `siteId` integers the runtime reports back to `(path, line)`. Without
// the plugin in this config the page would still record, but every step
// would land on a placeholder path and the recording would be useless
// for source-level debugging.
import { defineConfig } from "vite";
import * as path from "node:path";
import * as url from "node:url";

const here = path.dirname(url.fileURLToPath(import.meta.url));

// Sibling-repo discovery, per
// `codetracer-specs/Testing/Test-Program-Layout.md`: an explicit
// environment variable wins, otherwise fall back to the standard
// side-by-side workspace layout. The demo lives inside the codetracer
// repo but consumes the recorder runtimes from their own repos, so it
// has to resolve them rather than vendoring copies that would drift.
const workspaceRoot = path.resolve(here, "../../../../../../../..");
const jsRecorder =
  process.env.CODETRACER_JS_RECORDER_PATH ??
  path.join(workspaceRoot, "codetracer-js-recorder");
const wasmInstrumenter =
  process.env.CODETRACER_WASM_INSTRUMENTER_PATH ??
  path.join(workspaceRoot, "codetracer-wasm-instrumenter");

// The plugin is loaded by absolute path rather than by package name.
// Vite loads this config file with plain Node resolution, which does not
// consult the `resolve.alias` table below, so a bare `@codetracer/...`
// specifier would only work if the package were installed into this
// directory's `node_modules`. Loading the sibling repo's build output
// directly keeps the demo exercising the working tree — the whole point
// of a fixture that lives next to the code it tests.
const backendOrigin = `http://127.0.0.1:${process.env.DEMO_BACKEND_PORT || 8080}`;

// Forward `POST /balance` to the Node backend that `regenerate.sh` — or a
// developer following README.md — starts under the recorder. The port is
// configurable because the default is a popular one, and a collision with
// an unrelated service on the developer's machine would otherwise fail
// the recording in a confusing way.
//
// The key is an anchored regular expression rather than the plain prefix
// `"/balance"`, because Vite matches a plain proxy key by **prefix**. A
// prefix key also forwards `/balance_calc.wasm` and
// `/balance_calc.wasm.manifest.json` — the two files `bootstrap.js` loads
// by name — to a server that answers anything but `POST /balance` with a
// 404, so the page loads, fails to instantiate the module, and sits on
// `pending` for ever. Only `vite dev` hits this: the built bundle renames
// the module to `/assets/balance_calc-<hash>.wasm` and inlines the
// manifest, so `vite preview` (what `regenerate.sh` drives) never asks
// for a path beginning with `/balance`.
const backendProxy = { "^/balance$": backendOrigin };

const { codetracerVitePlugin } = await import(
  url.pathToFileURL(path.join(jsRecorder, "packages/vite-plugin/dist/index.js"))
    .href
);

export default defineConfig({
  root: ".",
  // The recording daemon's port, baked into the bundle.
  //
  // A browser bundle cannot read the environment, and both recorder
  // runtimes resolve their WebSocket endpoint once at construction from
  // `globalThis.__codetracer_endpoint`, defaulting to a compiled-in
  // `ws://localhost:9230/ct-stream`. Substituting the port at build time
  // is what makes `DEMO_RECORD_WEB_PORT` actually reach the page —
  // otherwise moving the daemon would silently produce no recordings at
  // all, since a page that cannot connect still loads and runs.
  // `bootstrap.js` consumes this.
  define: {
    __CT_RECORD_WEB_PORT__: JSON.stringify(
      String(process.env.DEMO_RECORD_WEB_PORT || 9230),
    ),
  },
  resolve: {
    alias: {
      "@codetracer/runtime-browser": path.join(
        jsRecorder,
        "packages/runtime-browser/src/index.ts",
      ),
      "codetracer-wasm-instrumenter/recorder-runtime": path.join(
        wasmInstrumenter,
        "recorder-runtime",
      ),
    },
  },
  plugins: [
    codetracerVitePlugin({
      // `bootstrap.js` defines `window.__ct`; instrumenting it would
      // emit `__ct.step()` calls before the runtime exists.
      exclude: ["**/node_modules/**", "**/bootstrap.js"],
    }),
  ],
  server: {
    // `--host 127.0.0.1` on the command line is still worth passing: by
    // default Vite binds `localhost`, which on a dual-stack machine
    // resolves to `[::1]` only, so `http://127.0.0.1:5173` is refused.
    port: Number(process.env.DEMO_DEV_PORT || 5173),
    proxy: backendProxy,
  },
  preview: {
    port: Number(process.env.DEMO_PREVIEW_PORT || 4173),
    proxy: backendProxy,
  },
  build: {
    target: "es2022",
    outDir: "dist",
    emptyOutDir: true,
    // Keep the output readable. The recording references these files by
    // path and line; a minified single-line bundle would collapse every
    // recorded step onto line 1.
    minify: false,
  },
});
