// replay-worker.js -- the Noir Studio bundle's host for the replay engine.
//
// ## Why this exists next to `worker.js` rather than instead of it
//
// `browser-replay/app/worker.js` is the engine's own harness. It resolves the
// wasm-bindgen package with a STATIC `import ... from "./pkg/db_backend.js"`
// and the wasm with `new URL("./pkg/db_backend_bg.wasm", import.meta.url)`,
// which makes the worker's own location the asset base. BlockTracer depends
// on exactly that — `hydrate/fetch-engine.sh` copies `worker.js`,
// `pkg/db_backend.js` and `pkg/db_backend_bg.wasm` to its own origin and the
// deploy workflow asserts those three paths have not moved.
//
// The Studio cannot use it, for one reason that is not a preference: it does
// not know at build time where the engine's bytes will be served from. The
// URLs come out of the entry document's deployment descriptor at run time
// (`declaredModuleUrls`), because `noir-studio-signed-out.sh` asserts the
// bundle has zero network egress sites and so the descriptor is read from the
// DOM rather than fetched. A static `import` cannot take a URL that is only
// known once the page has loaded.
//
// So this worker takes the same two files and is told where they are:
// `configure` carries `moduleUrls`, keyed by the manifest's asset ids, and the
// glue is brought in with a dynamic `import()`.
//
// ## The protocol, which is `viewmodel/backend/worker_backend.nim`'s
//
// Inbound (main -> worker), all structured-clone objects:
//
//   {type: "configure", moduleUrls: {"replay-engine-glue": url,
//                                    "replay-engine": url}}
//   {type: "vfs-write", path, data}      data is a Uint8Array
//   {type: "vfs-exists", path}
//   {type: "start"}
//   ...and, after `start`, DAP requests, which the wasm side owns.
//
// Outbound (worker -> main):
//
//   {type: "wasm-loaded"}                configure succeeded
//   {type: "worker-error", error}        configure failed, by name
//   {type: "vfs-ack", path, ok[, error]}
//   {type: "vfs-exists-result", path, exists}
//   "ready"                              posted by `wasm_start()` itself
//
// `WorkerBackend.deliver` classifies inbound traffic by shape: a bare string
// becomes a `worker-status` control message, a `type: "response"` settles a
// pending request, anything else is control. `onControl` is how the bootstrap
// sequence above is awaited, and `worker-error` additionally marks the backend
// failed so every pending and future `send` completes with `success: false`
// instead of hanging.

let engine = null;

/**
 * Report a failure the way `WorkerBackend` can act on.
 *
 * Not a `throw`. An exception inside `onmessage` reaches `self.onerror` and
 * the main thread sees an `ErrorEvent` with, in most browsers, a message of
 * "Script error." — the caller would know the engine did not come up and not
 * why. `worker-error` carries the reason and trips `markWorkerFailed`, so a
 * session that cannot instantiate the engine says so rather than waiting for
 * a `wasm-loaded` that will never arrive.
 */
function failed(error) {
  self.postMessage({
    type: "worker-error",
    error: String((error && error.message) || error),
  });
}

async function configure(moduleUrls) {
  const glueUrl = moduleUrls && moduleUrls["replay-engine-glue"];
  const wasmUrl = moduleUrls && moduleUrls["replay-engine"];
  // NAMED SEPARATELY, because "the engine did not load" is a sentence that
  // covers both a deployment that shipped neither file and one that shipped
  // the wasm without the glue — and only the second is a packaging bug
  // somebody has to go and fix.
  if (!glueUrl) {
    throw new Error(
      "no url was declared for `replay-engine-glue`; this deployment ships " +
        "no wasm-bindgen glue, so the engine's bytes cannot be imported",
    );
  }
  if (!wasmUrl) {
    throw new Error(
      "no url was declared for `replay-engine`; the glue is present and the " +
        "engine's wasm is not",
    );
  }
  const module = await import(/* webpackIgnore: true */ glueUrl);
  await module.default(wasmUrl);
  // Asserted rather than assumed: the package must export the in-memory VFS
  // bindings. A build with `--no-default-features` and the wrong feature set
  // produces a module that imports and then has no `vfs_write_file`, and the
  // first symptom would be a `TypeError` inside a trace load.
  for (const name of ["vfs_write_file", "vfs_file_exists", "wasm_start"]) {
    if (typeof module[name] !== "function") {
      throw new Error(
        `the replay engine at ${glueUrl} exports no ${name}; it was not built ` +
          "with the browser-transport feature",
      );
    }
  }
  engine = module;
}

self.onmessage = async (event) => {
  const msg = event.data;

  if (msg && msg.type === "configure") {
    try {
      await configure(msg.moduleUrls);
      self.postMessage({ type: "wasm-loaded" });
    } catch (err) {
      failed(err);
    }
    return;
  }

  if (!engine) {
    failed(
      `received '${msg && msg.type}' before configure; the engine is not loaded`,
    );
    return;
  }

  if (msg.type === "vfs-write") {
    try {
      engine.vfs_write_file(msg.path, msg.data);
      self.postMessage({ type: "vfs-ack", path: msg.path, ok: true });
    } catch (err) {
      self.postMessage({
        type: "vfs-ack",
        path: msg.path,
        ok: false,
        error: String(err),
      });
    }
    return;
  }

  if (msg.type === "vfs-exists") {
    self.postMessage({
      type: "vfs-exists-result",
      path: msg.path,
      exists: engine.vfs_file_exists(msg.path),
    });
    return;
  }

  if (msg.type === "start") {
    // Hands the worker over to the wasm-side DAP dispatcher: `wasm_start()`
    // replaces `self.onmessage`, so nothing below this line runs again.
    engine.wasm_start();
    return;
  }

  failed(`unexpected message '${msg.type}' before start`);
};
