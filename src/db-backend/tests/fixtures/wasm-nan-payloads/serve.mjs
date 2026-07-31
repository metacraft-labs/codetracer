// NaN-payload demo (M52) — static file server.
//
// Deliberately a dozen lines of `node:http` rather than a bundler.  The
// page is plain ES modules, and the one thing it needs from outside its
// own directory is the instrumenter's `recorder-runtime/`, which this
// server mounts at `/recorder-runtime/`.
//
// Serving that directory *from the checkout* is the point: the recording
// this fixture commits is then produced by the working tree's
// `browser_session.js`, not by a copy of it frozen into a bundle. A
// producer regression shows up the next time the fixture is regenerated
// instead of hiding behind a stale artefact.
//
//     node serve.mjs [port]
//
// Environment:
//   CODETRACER_WASM_INSTRUMENTER_PATH  instrumenter checkout (default:
//                                      the sibling of the codetracer repo)

import * as http from "node:http";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE_DIR = path.join(HERE, "page");
const WORKSPACE_ROOT = path.resolve(HERE, "../../../../../..");
const INSTRUMENTER =
  process.env.CODETRACER_WASM_INSTRUMENTER_PATH ||
  path.join(WORKSPACE_ROOT, "codetracer-wasm-instrumenter");
const RUNTIME_DIR = path.join(INSTRUMENTER, "recorder-runtime");
const RUNTIME_PREFIX = "/recorder-runtime/";

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
};

/**
 * Resolve a request path to a file, refusing anything that escapes the
 * directory it is mounted under.
 *
 * @param {string} urlPath
 * @returns {string|null}
 */
function resolveFile(urlPath) {
  const clean = decodeURIComponent(urlPath.split("?")[0]);
  const [root, relative] = clean.startsWith(RUNTIME_PREFIX)
    ? [RUNTIME_DIR, clean.slice(RUNTIME_PREFIX.length)]
    : [PAGE_DIR, clean === "/" ? "index.html" : clean.replace(/^\//, "")];
  const resolved = path.resolve(root, relative);
  if (resolved !== root && !resolved.startsWith(root + path.sep)) return null;
  return resolved;
}

const port = Number(process.argv[2] || process.env.DEMO_PREVIEW_PORT || 4182);

const server = http.createServer((req, res) => {
  const file = resolveFile(req.url || "/");
  if (file === null || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end(`not found: ${req.url}`);
    return;
  }
  res.writeHead(200, {
    "Content-Type":
      CONTENT_TYPES[path.extname(file)] || "application/octet-stream",
    // The recording must reflect the tree, not a cached copy of it.
    "Cache-Control": "no-store",
  });
  fs.createReadStream(file).pipe(res);
});

server.listen(port, "127.0.0.1", () => {
  console.log(`[serve] http://127.0.0.1:${port} (page: ${PAGE_DIR})`);
  console.log(`[serve] /recorder-runtime/ -> ${RUNTIME_DIR}`);
});
