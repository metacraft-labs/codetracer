// worker.js — WebWorker that hosts the WASM DAP server.
//
// Lifecycle:
//   1. Main thread creates this worker.
//   2. Worker loads and initialises the WASM module (`init`).
//   3. Worker waits for optional VFS file payloads from the main thread
//      (messages with `type: "vfs-write"`).
//      Alternatively, `{ type: "load-trace" }` fetches trace files from an
//      HTTP server and pushes them into the VFS automatically — this is the
//      primary path for pure client-side replay where the server is a dumb
//      static file server.
//   4. When the main thread sends `{ type: "start" }`, the worker calls
//      `wasm_start()` which sets up the DAP `onmessage` handler.
//   5. After that, every subsequent `postMessage` from the main thread is
//      a DAP request that the Rust code handles directly.

import init, {
  vfs_write_file,
  vfs_file_exists,
  wasm_start
} from './pkg/db_backend.js';

const wasmUrl = new URL('./pkg/db_backend_bg.wasm', import.meta.url);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Fetch a file from an HTTP URL and write it into the in-memory VFS.
 *
 * @param {string} url        — HTTP(S) URL to fetch.
 * @param {string} vfsPath    — Virtual path inside the VFS (e.g. "trace/trace.ct").
 * @returns {Promise<number>} — The number of bytes written.
 */
async function fetchIntoVfs(url, vfsPath) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`fetch ${url} failed: ${response.status} ${response.statusText}`);
  }
  const data = new Uint8Array(await response.arrayBuffer());
  vfs_write_file(vfsPath, data);
  return data.byteLength;
}

(async () => {
  // --- Phase 1: Initialise WASM ------------------------------------------
  await init(wasmUrl);
  // `_start` (console_error_panic_hook + wasm_logger) runs automatically via
  // wasm_bindgen(start).

  // --- Phase 2: Bootstrap message handler --------------------------------
  // Before calling wasm_start() we accept VFS file uploads, HTTP-based trace
  // loading, and a "start" signal.  Once started, `wasm_start()` replaces
  // `onmessage` with the DAP handler and posts "ready" back to the main
  // thread.
  self.onmessage = async (event) => {
    const msg = event.data;

    if (msg && msg.type === 'vfs-write') {
      // Write a file into the in-memory VFS.
      // `msg.path`  — virtual path string  (e.g. "trace/metadata.json")
      // `msg.data`  — Uint8Array of raw file bytes
      try {
        vfs_write_file(msg.path, msg.data);
        self.postMessage({ type: 'vfs-ack', path: msg.path, ok: true });
      } catch (err) {
        self.postMessage({ type: 'vfs-ack', path: msg.path, ok: false, error: String(err) });
      }
      return;
    }

    if (msg && msg.type === 'vfs-exists') {
      // Check whether a VFS path exists (useful for debugging).
      const exists = vfs_file_exists(msg.path);
      self.postMessage({ type: 'vfs-exists-result', path: msg.path, exists });
      return;
    }

    // -----------------------------------------------------------------------
    // load-trace: Fetch trace files from a dumb HTTP server into VFS.
    //
    // This is the key message for client-side WASM replay. The main thread
    // tells the worker which trace files to fetch, the worker downloads them
    // via fetch() and pushes them into the VFS. No server-side logic needed.
    //
    // Message shape:
    //   {
    //     type: "load-trace",
    //     // Required: array of { url, vfsPath } objects.  CTFS is the only
    //     // supported materialized-trace format (see
    //     // Trace-Files/CTFS-Migration-Guide.md §3e), so the canonical
    //     // shape is a single `.ct` container per trace folder.
    //     files: [
    //       { url: "/traces/trace.ct", vfsPath: "trace/trace.ct" },
    //     ],
    //   }
    // -----------------------------------------------------------------------
    if (msg && msg.type === 'load-trace') {
      const files = msg.files;
      if (!Array.isArray(files) || files.length === 0) {
        self.postMessage({
          type: 'trace-load-error',
          error: 'load-trace requires a non-empty "files" array',
        });
        return;
      }

      try {
        const results = [];
        for (const { url, vfsPath } of files) {
          const bytes = await fetchIntoVfs(url, vfsPath);
          results.push({ vfsPath, bytes });
        }
        self.postMessage({ type: 'trace-loaded', files: results });
      } catch (err) {
        self.postMessage({ type: 'trace-load-error', error: String(err) });
      }
      return;
    }

    if (msg && msg.type === 'start') {
      // Transition to DAP mode — wasm_start() installs its own onmessage
      // handler and posts "ready".
      wasm_start();
      return;
    }

    // Fallback: if we receive something unexpected before start, log it.
    console.warn('[worker] unexpected message before start:', msg);
  };

  // Let the main thread know the WASM module is loaded and ready for VFS
  // uploads.
  self.postMessage({ type: 'wasm-loaded' });
})();
