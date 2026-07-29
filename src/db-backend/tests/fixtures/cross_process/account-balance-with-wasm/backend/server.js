// Cross-process origin demo — Node.js server tier.
//
// Recorded by `codetracer-js-recorder record`, which instruments this
// file with the same SWC pass the browser tier uses and writes a CTFS
// trace through the native addon.
//
// Ordinary application code: a `node:http` server with no framework and
// no CodeTracer-specific machinery beyond the single
// `__ct.markCorrelation` call that declares where a value enters this
// process. That call is the documented public API — CodeTracer installs
// no protocol shims, so the program itself has to say which identifier
// correlates it with its caller.
//
// The server exits on its own after handling one request so the
// recorder can finalise the trace without a signal; a long-lived server
// would work too, but a self-terminating one keeps the demo
// deterministic.

const http = require("node:http");

/** Boundary id shared with the browser tier's send marker. */
const BOUNDARY_HTTP = "account-balance";

const PORT = Number(process.env.DEMO_BACKEND_PORT || 8080);

/** Accumulated balances, keyed by request id. */
const stored = {};

/**
 * Read the whole request body.
 *
 * @param {import("node:http").IncomingMessage} req
 * @returns {Promise<string>}
 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => {
      data += chunk;
    });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

/**
 * Handle one balance submission.
 *
 * The origin chain the demo asserts on starts at `balance` here and
 * walks backwards: to `payload.balance`, through the `JSON.parse`
 * decode (which the origin classifier recognises as a forwarding
 * serialiser call rather than a computation), and out across the HTTP
 * boundary into the browser recording.
 *
 * @param {string} raw JSON request body.
 */
function handleBalance(raw) {
  const payload = JSON.parse(raw);

  // Declare the crossing. `payload.requestId` is the same identifier the
  // browser passed to its `send` marker, which is what pairs the two
  // recordings. Placed immediately before the binding it explains so the
  // marker sits on the chain's boundary-crossing hop.
  __ct.markCorrelation(
    "recv",
    BOUNDARY_HTTP,
    payload.requestId,
    String(payload.balance),
    "balance",
  );

  const balance = payload.balance;
  stored[payload.requestId] = balance;
  return { stored: true, balance };
}

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST" || !req.url.startsWith("/balance")) {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
    return;
  }
  const raw = await readBody(req);
  const result = handleBalance(raw);
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(result));

  // One request is all the demo needs. Closing here lets the recorder
  // finalise the trace on a normal process exit.
  server.close();
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`demo backend listening on http://127.0.0.1:${PORT}`);
});

// Safety valve: if the browser tier never manages to send its request,
// exit anyway rather than holding the port forever. A recorded process
// that outlives its harness is worse than a failed run — the next
// attempt fails to bind and the failure looks unrelated to its cause.
const IDLE_TIMEOUT_MS = Number(process.env.DEMO_BACKEND_TIMEOUT_MS || 120000);
const idleTimer = setTimeout(() => {
  console.error("demo backend: no request within the idle timeout; exiting");
  process.exit(2);
}, IDLE_TIMEOUT_MS);
// Do not let the timer itself keep the event loop alive once the
// request has been served.
idleTimer.unref();
