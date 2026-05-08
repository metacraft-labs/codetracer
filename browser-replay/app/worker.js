// worker.js -- WebWorker that hosts the replay-server WASM and bridges
// DAP messages over postMessage.
//
// Responsibilities:
//   1. Load the wasm-bindgen package (db_backend.js + db_backend_bg.wasm)
//      from ./pkg/. The package must export the in-memory VFS bindings
//      (`vfs_write_file`, `vfs_file_exists`, `wasm_start`).
//   2. Accept either a "load-trace-from-gateway" message (M40 path) or a
//      "load-trace" message (legacy static-server path). Both end up writing
//      the fetched bytes into the WASM in-memory VFS.
//   3. Respond to "start" by calling `wasm_start()`, which transfers the
//      onmessage handler to the WASM-side DAP dispatcher.
//
// The WASM module is unmodified -- this worker is the integration point that
// adds the gateway URL and Authorization-bearer header to every fetch.

import init, {
  vfs_write_file,
  vfs_file_exists,
  wasm_start,
} from "./pkg/db_backend.js";

const wasmUrl = new URL("./pkg/db_backend_bg.wasm", import.meta.url);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Plain HTTP fetch into the VFS. Used by the legacy static-server path.
 */
async function fetchIntoVfs(url, vfsPath, headers = {}) {
  const response = await fetch(url, { headers });
  if (!response.ok) {
    throw new Error(`fetch ${url} failed: ${response.status} ${response.statusText}`);
  }
  const data = new Uint8Array(await response.arrayBuffer());
  vfs_write_file(vfsPath, data);
  return { bytes: data.byteLength, status: response.status };
}

/**
 * M40 gateway range fetch. Issues a `Range: bytes=0-` request so the gateway
 * answers with 206 PartialContent and a Content-Range header. The full
 * payload is staged into the VFS via `vfs_write_file`.
 *
 * Returns { bytes, status, contentRange } where status is the HTTP status
 * (typically 206).
 */
async function fetchRangeIntoVfs(rangeUrl, vfsPath, authToken) {
  const response = await fetch(rangeUrl, {
    headers: {
      Authorization: `Bearer ${authToken}`,
      Range: "bytes=0-",
      Accept: "application/octet-stream",
    },
  });
  if (response.status !== 206 && !response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`gateway range fetch ${rangeUrl} -> ${response.status} ${response.statusText} ${body}`);
  }
  const data = new Uint8Array(await response.arrayBuffer());
  vfs_write_file(vfsPath, data);
  return {
    bytes: data.byteLength,
    status: response.status,
    contentRange: response.headers.get("Content-Range") || "",
  };
}

/**
 * Walk a recording manifest and return the canonical list of object keys
 * the browser-replay client needs to fetch in order to materialise the
 * trace into the VFS.
 *
 * For M40 the gateway exposes:
 *   - /api/v1/observability/gateway/ranges/{traceId}/{**objectKey}
 *
 * which corresponds 1:1 to either a `mcrSlices[].sliceKey` or a
 * `shardedMcrSegments[].shards[].replicas[].objectKey` in the manifest.
 * Every replica points at the same payload bytes, so we only fetch the
 * first replica per shard.
 */
function listManifestObjectKeys(manifest) {
  const keys = [];
  if (Array.isArray(manifest.mcrSlices)) {
    for (const slice of manifest.mcrSlices) {
      if (slice && typeof slice.sliceKey === "string" && slice.sliceKey.length > 0) {
        keys.push(slice.sliceKey);
      }
    }
  }
  if (Array.isArray(manifest.shardedMcrSegments)) {
    for (const seg of manifest.shardedMcrSegments) {
      if (!Array.isArray(seg.shards)) continue;
      for (const shard of seg.shards) {
        if (!Array.isArray(shard.replicas) || shard.replicas.length === 0) continue;
        const primary = shard.replicas[0];
        if (primary && typeof primary.objectKey === "string" && primary.objectKey.length > 0) {
          keys.push(primary.objectKey);
        }
      }
    }
  }
  return keys;
}

/**
 * The gateway's range endpoint uses `{**objectKey}` -- the catch-all binding
 * forwards `/`-separated path segments into the route value. We URL-encode
 * each segment individually so embedded slashes survive intact.
 */
function encodeObjectKeyForGateway(objectKey) {
  return objectKey.split("/").map(encodeURIComponent).join("/");
}

/**
 * Convert an object key like
 *   "traces/<tenant>/<trace>/segments/segment_0000_replica_a.ct"
 * into a stable VFS file name. The CTFS reader doesn't care about the
 * directory layout -- it scans the trace folder for the magic bytes -- so
 * a flat hash-style file name is fine.
 */
function vfsFileNameForObjectKey(objectKey) {
  return objectKey.replace(/[^a-zA-Z0-9._-]/g, "_");
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

(async () => {
  await init(wasmUrl);
  // `_start` (console_error_panic_hook + wasm_logger) runs automatically via
  // wasm_bindgen(start).

  self.onmessage = async (event) => {
    const msg = event.data;

    // -------------------------------------------------------------------
    // M40 path: fetch the recording manifest from the codetracer-ci
    // gateway, then fetch each referenced payload via Range requests.
    // -------------------------------------------------------------------
    if (msg && msg.type === "load-trace-from-gateway") {
      const { gatewayBaseUrl, traceId, authToken, traceFolder } = msg;
      try {
        if (!gatewayBaseUrl || !traceId || !authToken) {
          throw new Error("load-trace-from-gateway requires gatewayBaseUrl, traceId, authToken");
        }
        const manifestUrl = `${gatewayBaseUrl}/api/v1/observability/gateway/manifests/${encodeURIComponent(traceId)}`;
        const manifestResponse = await fetch(manifestUrl, {
          headers: {
            Authorization: `Bearer ${authToken}`,
            Accept: "application/json",
          },
        });
        const manifestStatus = manifestResponse.status;
        if (!manifestResponse.ok) {
          const body = await manifestResponse.text().catch(() => "");
          throw new Error(`gateway manifest fetch failed: ${manifestStatus} ${manifestResponse.statusText} ${body}`);
        }
        const manifestPayload = await manifestResponse.json();
        const manifest = manifestPayload && manifestPayload.recordingManifest;
        if (!manifest) {
          throw new Error("gateway manifest response missing recordingManifest field");
        }

        const keys = listManifestObjectKeys(manifest);
        if (keys.length === 0) {
          throw new Error("recording manifest contains no fetchable mcrSlices or shardedMcrSegments");
        }

        const folder = traceFolder || "trace";
        const files = [];
        const rangeStatuses = [];
        for (const objectKey of keys) {
          const rangeUrl = `${gatewayBaseUrl}/api/v1/observability/gateway/ranges/${encodeURIComponent(traceId)}/${encodeObjectKeyForGateway(objectKey)}`;
          const fileName = vfsFileNameForObjectKey(objectKey);
          const vfsPath = `${folder}/${fileName}`;
          const result = await fetchRangeIntoVfs(rangeUrl, vfsPath, authToken);
          files.push({
            objectKey,
            vfsPath,
            bytes: result.bytes,
            source: "gateway-range",
            status: result.status,
            contentRange: result.contentRange,
          });
          rangeStatuses.push(String(result.status));
        }

        self.postMessage({
          type: "trace-loaded",
          manifestStatus,
          rangeStatuses,
          manifestUrl,
          files,
        });
      } catch (err) {
        self.postMessage({
          type: "trace-load-error",
          error: String(err && err.message ? err.message : err),
        });
      }
      return;
    }

    // -------------------------------------------------------------------
    // Legacy static-server path (kept for compatibility with the old
    // wasm-testing harness that fetches by URL, no auth header).
    // -------------------------------------------------------------------
    if (msg && msg.type === "load-trace") {
      const files = msg.files;
      if (!Array.isArray(files) || files.length === 0) {
        self.postMessage({
          type: "trace-load-error",
          error: 'load-trace requires a non-empty "files" array',
        });
        return;
      }
      try {
        const results = [];
        for (const { url, vfsPath } of files) {
          const r = await fetchIntoVfs(url, vfsPath);
          results.push({ vfsPath, bytes: r.bytes, source: "static" });
        }
        self.postMessage({ type: "trace-loaded", files: results, manifestStatus: 0, rangeStatuses: [] });
      } catch (err) {
        self.postMessage({ type: "trace-load-error", error: String(err) });
      }
      return;
    }

    if (msg && msg.type === "vfs-write") {
      try {
        vfs_write_file(msg.path, msg.data);
        self.postMessage({ type: "vfs-ack", path: msg.path, ok: true });
      } catch (err) {
        self.postMessage({ type: "vfs-ack", path: msg.path, ok: false, error: String(err) });
      }
      return;
    }

    if (msg && msg.type === "vfs-exists") {
      const exists = vfs_file_exists(msg.path);
      self.postMessage({ type: "vfs-exists-result", path: msg.path, exists });
      return;
    }

    if (msg && msg.type === "start") {
      // Hands the worker over to the WASM-side DAP dispatcher.
      wasm_start();
      return;
    }

    // eslint-disable-next-line no-console
    console.warn("[browser-replay worker] unexpected message before start", msg);
  };

  self.postMessage({ type: "wasm-loaded" });
})();
