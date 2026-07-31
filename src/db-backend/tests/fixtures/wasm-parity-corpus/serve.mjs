// Parity corpus — static file server.
//
// Deliberately a page of `node:http` rather than a bundler. The pages
// are plain ES modules and mount three roots:
//
//   /recorder-runtime/  the instrumenter checkout's `recorder-runtime/`
//   /shared/            this fixture's `page-shared/`
//   /                   the module's own `page/` (with `index.html` and
//                       `app.js` resolved from `page-shared/` when the
//                       module does not override them)
//
// Serving `recorder-runtime/` *from the checkout* is the point: the
// recordings this fixture commits are then produced by the working
// tree's `browser_session.js` and not by a copy of it frozen into a
// bundle, so a producer regression shows up the next time the corpus is
// regenerated instead of hiding behind a stale artefact.
//
//     node serve.mjs <port> <module-name>
//
// Environment:
//   CODETRACER_WASM_INSTRUMENTER_PATH  instrumenter checkout (default:
//                                      the sibling of the codetracer repo)

import * as http from "node:http";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SHARED_DIR = path.join(HERE, "page-shared");
const WORKSPACE_ROOT = path.resolve(HERE, "../../../../../..");
const INSTRUMENTER =
  process.env.CODETRACER_WASM_INSTRUMENTER_PATH ||
  path.join(WORKSPACE_ROOT, "codetracer-wasm-instrumenter");
const RUNTIME_DIR = path.join(INSTRUMENTER, "recorder-runtime");

const RUNTIME_PREFIX = "/recorder-runtime/";
const SHARED_PREFIX = "/shared/";

const port = Number(process.argv[2] || process.env.CORPUS_PREVIEW_PORT || 4182);
const moduleName = process.argv[3];
if (!moduleName) {
  console.error("usage: node serve.mjs <port> <module-name>");
  process.exit(2);
}
const PAGE_DIR = path.join(HERE, "modules", moduleName, "page");

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
};

/**
 * Resolve `relative` under `root`, refusing anything that escapes it.
 *
 * @param {string} root
 * @param {string} relative
 * @returns {string|null}
 */
function under(root, relative) {
  const resolved = path.resolve(root, relative);
  if (resolved !== root && !resolved.startsWith(root + path.sep)) return null;
  return resolved;
}

/**
 * Map a request path to a file.
 *
 * @param {string} urlPath
 * @returns {string|null}
 */
function resolveFile(urlPath) {
  const clean = decodeURIComponent(urlPath.split("?")[0]);
  if (clean.startsWith(RUNTIME_PREFIX)) {
    return under(RUNTIME_DIR, clean.slice(RUNTIME_PREFIX.length));
  }
  if (clean.startsWith(SHARED_PREFIX)) {
    return under(SHARED_DIR, clean.slice(SHARED_PREFIX.length));
  }
  const relative = clean === "/" ? "index.html" : clean.replace(/^\//, "");
  const own = under(PAGE_DIR, relative);
  if (own !== null && fs.existsSync(own)) return own;
  // `index.html` is shared by all four pages; only `app.js` and the
  // instrumented module differ, and those live in the module's `page/`.
  return under(SHARED_DIR, relative);
}

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
  console.log(`[serve] /shared/           -> ${SHARED_DIR}`);
  console.log(`[serve] /recorder-runtime/ -> ${RUNTIME_DIR}`);
});
