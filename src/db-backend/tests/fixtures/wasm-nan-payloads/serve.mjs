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

// Stand down when abandoned.
//
// This server is started with `setsid(1)` by the fixture regenerator, which
// puts it in its own session so it does not receive signals aimed at the
// regenerator's process group.  The consequence is that the regenerator's
// `EXIT` trap is the only thing able to reap it, and that trap cannot run
// when the regenerator is `SIGKILL`ed — a CI step timeout, `timeout(1)`
// escalation, an OOM kill.  Measured: five SIGKILL trials of the recording
// pipeline left five of these servers running with `ppid=1`.
//
// So it reaps itself, for the same reason and on the same terms as the
// `record-web` daemon's `--idle-timeout`.  The clock is reset by every
// request, and a recording only ever idles here between page loads, so ten
// minutes cannot interrupt work in progress.  `0` disables the watchdog.
const IDLE_TIMEOUT_MS = (() => {
  const raw = process.env.CT_SERVE_IDLE_TIMEOUT_MS;
  if (raw === undefined || raw === "") return 10 * 60_000;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) {
    // Never silently fall back to "no watchdog": that would restore the
    // leak while looking configured.
    console.error(`[serve] invalid CT_SERVE_IDLE_TIMEOUT_MS=${raw}; using default`);
    return 10 * 60_000;
  }
  return parsed;
})();

let lastActivity = Date.now();

function armIdleWatchdog() {
  if (IDLE_TIMEOUT_MS === 0) return;
  const every = Math.max(50, Math.min(IDLE_TIMEOUT_MS / 4, 5_000));
  const tick = setInterval(() => {
    if (Date.now() - lastActivity < IDLE_TIMEOUT_MS) return;
    clearInterval(tick);
    console.error(
      `[serve] no request for ${IDLE_TIMEOUT_MS}ms; exiting so this server ` +
        `does not outlive whatever started it`,
    );
    server.close(() => process.exit(0));
    // `close()` waits for open connections to end; do not hang on one.
    setTimeout(() => process.exit(0), 2_000).unref();
  }, every);
}

const server = http.createServer((req, res) => {
  lastActivity = Date.now();
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
  armIdleWatchdog();
  console.log(`[serve] http://127.0.0.1:${port} (page: ${PAGE_DIR})`);
  console.log(`[serve] /recorder-runtime/ -> ${RUNTIME_DIR}`);
});
