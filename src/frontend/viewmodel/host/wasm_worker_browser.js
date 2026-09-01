// The wasm worker's script, for a BROWSER — the thing that was missing.
//
// NS3 landed the registry (`platform/wasm_registry.nim`), the protocol
// (`platform/wasm_worker.nim`), the transport and
// `newBrowserWasmHost(registry, scriptUrl)` in `host/web_browser.nim`. All of
// it is tested and none of it is reachable, and `newBrowserWasmHost`'s own doc
// comment says exactly why:
//
//   "Not called by `newBrowserBridge` yet, and that is the honest state: the
//   worker script that instantiates the Noir modules and drives their `nv_*` /
//   `ct_*` ABIs is not in the bundle"
//
// This is that script. It is the file `scriptUrl` points at.
//
// ## Why a separate asset rather than an inlined blob
//
// `new Worker(url)` wants a URL, and `newBrowserWasmHost` already takes one —
// the design decided this before the file existed. Inlining the script and
// constructing a `blob:` URL would work in a demo and fail in the product: a
// `Content-Security-Policy` worth setting rejects `worker-src blob:`, and a
// blob URL is uncacheable, so every reload re-parses it. As a real file it is
// an ordinary hashed static asset — the `ccStaticAsset` row
// `platform/web_deployment.nim` already defines.
//
// ## Why the wasm modules are FETCHED and not bundled
//
// They are ~16 MB (`noir_wasm`) and ~4.6 MB (`noir_tracer_wasm`). Base64 in a
// JS bundle inflates by a third and must be parsed as source before anything
// runs, which would put ~27 MB in front of first paint for a feature most
// sessions never use. Fetched, they are content-addressed immutable assets —
// `ccImmutable` in the same table — cached indefinitely after the first run and
// loaded lazily, on the first command that needs one.
//
// `WebAssembly.compileStreaming` is used for the same reason, and it is not
// merely faster: it compiles while the body is still arriving, so a 16 MB
// module never has to exist as one ArrayBuffer in the tab. The fallback below
// exists because `compileStreaming` REQUIRES `Content-Type: application/wasm`,
// and a host serving `.wasm` as `application/octet-stream` would otherwise fail
// with a TypeError that names nothing useful.
//
// ## The protocol is `ci/test/noir-wasm-worker/worker.mjs`'s, message for message
//
// That file is the node twin, driven by `ci/test/noir-wasm-worker-e2e.sh`,
// which compiles and traces a real Noir package through this protocol and
// through an in-process path and compares the two traces by digest AND for
// non-triviality. Keeping the two identical is what lets that e2e stand as
// evidence for this file: the halves that differ are `fetch` vs `readFileSync`
// and `self.onmessage` vs `parentPort.on`, and nothing else.
//
// TEXT IN, TEXT OUT, both directions, no exceptions. The Nim side's `deliver`
// takes a `string`. `wasm_worker.nim`'s header records what the alternative
// cost a sibling campaign: an engine that sent objects one way and JSON strings
// the other, and a reader that classified by message type and reported a
// timeout over an engine that had answered.
//
// ## SESSIONS — a run that does not end when it has answered once
//
// Everything above describes a compiler: one request, one answer, done. A
// development environment is not that shape. An Aztec node registers a
// contract, then executes a transaction against the world state that
// registration produced, then seals a block containing it — and each of those
// is a separate user action minutes apart, against state the previous one
// left behind. A worker whose only verbs are `compile` and `trace`, each
// posting `exit` in the same turn it was asked, cannot host it.
//
// The gap was never in the TYPES. `WasmHost.start` already hands back a
// `ProcessHandle` and streams through `onOutput`/`onExit`, and
// `wasm_worker.nim` already correlates by sequence and refuses to settle a run
// until an `exit` or a `failed` arrives for it. What was missing is that
// nothing on this side ever DECLINED to exit, so the handle referred to
// something already over. A session is therefore not a new concept bolted on;
// it is **a `start` run that has not exited yet**, and the only genuinely new
// verb is the one that was impossible before: main -> worker, mid-run.
//
//   start   (existing)   create a session; the run's `seq` IS its address
//   input   (NEW)        hand it one message
//   close   (NEW)        end it deliberately
//   exit / failed        (existing) the run is over, by either road
//
// ### An `input` carries its OWN sequence, and that is the load-bearing part
//
// The tempting shape is `{kind: 'input', seq: <the session>}`. It is wrong,
// and the reason is `failed`: on the Nim side a `failed` for sequence S
// *finishes run S*. An input refused because the session's queue is full would
// therefore KILL THE SESSION it was merely declining to accept — a
// backpressure signal that destroys the thing applying the pressure.
//
// So a delivery is its own one-shot run with its own sequence, and it settles
// with `exit 0` (accepted) or `failed` (refused, with a `fault`). The
// session's own traffic keeps flowing on the session's sequence, untouched.
// This also keeps the protocol honest about a distinction it would otherwise
// blur, and which `wasm_worker.nim`'s header names as the trap it exists to
// avoid: **accepting a message is not answering it**. Two facts, two
// sequences, and no future that resolves on an acknowledgement.
//
// ### Correlating a reply to an input is NOT this layer's job
//
// A session's replies arrive as ordinary `output` on the session's sequence —
// a stream, exactly like a process's stdout, with no request/response pairing.
// That is deliberate. `backend/worker_backend.nim` is this repository's
// request/response correlator, and it takes an injected `postProc(string)` and
// a `deliver(string)`: a text pipe. Point those two at a session's `input` and
// its `output` and a session that speaks DAP is correlated for free, with no
// second correlator in the tree. Baking DAP's envelope in HERE would have made
// that impossible for a session that speaks anything else — and an Aztec node
// speaks JSON-RPC, not DAP.
//
// ### Ordering, and the one that cannot be fixed at this layer
//
// `self.onmessage` is `async`, so two messages arriving while the first is
// awaiting run CONCURRENTLY, interleaving at every `await`. For independent
// one-shot runs that is fine and is why they are fast. For a session it is
// not: two `input`s to one session would race over the state that is the whole
// point of it existing. So each session owns a FIFO queue and drains it one at
// a time; per-session ordering is guaranteed, and across sessions it is not
// and does not need to be.
//
// ### A session lives for the PAGE, and that is a decision, not an omission
//
// Session state is worker memory. A navigation destroys the `Worker` and every
// session in it; there is no reconnect, no session id that survives a reload,
// and no attempt at one. Two reasons, and the second is the load-bearing one:
//
// 1. A `Worker` cannot outlive its document, so "the same session after a
//    reload" would mean re-creating the worker and REPLAYING enough to
//    reconstruct the state — which is a snapshot format, not a transport.
// 2. Making that this layer's job would put durability in the protocol, where
//    it would be wrong for every service that does not want it. A node's world
//    state belongs in the project store — `platform/store_volume.nim` and OPFS
//    already carry per-project state across reloads — and a service that wants
//    to survive a navigation writes there and reloads from there. The
//    transport should not learn what a block is.
//
// So the honest statement is: closing the tab ends the node, exactly as
// closing a terminal ends the node you started in it. Restoring it is the
// service's problem and a real one; it is simply not this file's.
//
// What the queue CANNOT fix, and this is measured rather than assumed: a
// synchronous call into a wasm module — `nv_compile_vfs` is one, and it takes
// about 2.5 s — blocks this worker's single thread entirely. No timer fires,
// no message is read, no session ticks, for the whole call. Nothing is LOST
// (the browser buffers the port and delivers in arrival order afterwards) but
// everything is DELAYED. A session that must produce blocks on a wall clock
// therefore cannot share a worker with a compiler; it needs its own. That is a
// deployment decision, not a protocol one, and the protocol is unchanged by
// it — which is why sessions are addressed by sequence within a worker rather
// than by a global id.

'use strict';

const post = (message) => self.postMessage(JSON.stringify(message));

// Every declared import is stubbed to THROW rather than to no-op. The Noir
// modules are built to need none, so "reached no import" is a property worth
// measuring; a silent no-op stub would let a module that quietly depends on
// WASI produce wrong answers instead of an error naming the import.
const stubImports = (mod) => {
  const imports = {};
  for (const { module: m, name } of WebAssembly.Module.imports(mod)) {
    imports[m] ??= {};
    imports[m][name] = () => { throw new Error(`reached ${m}.${name}`); };
  }
  return imports;
};

// Supplied by a `configure` message rather than baked in: the bundle's asset
// URLs are content-addressed and so are not known when this file is written.
let moduleUrls = {};
const modules = new Map();

// THREE FAULTS, THREE SENTENCES — and they must never collapse into one.
//
// A sibling campaign lost hours to a single message that covered two different
// faults: a missing asset and a broken feature read identically, so the
// investigation started in the wrong half of the system and stayed there. The
// three states below are reached by different mistakes and fixed by different
// people, so `load` names which one it is:
//
//   NOT DELIVERED    this deployment ships no such module. The entry document
//                    declared no URL for it. Nobody is broken — the deployment
//                    is smaller than the product. The registry normally
//                    answers this before anything reaches the worker; if it
//                    gets here, the page and the registry disagree.
//   NOT SERVED       a URL was declared and the server does not have it. This
//                    is a BROKEN DEPLOY: the document promises bytes the
//                    publish directory lacks. `deployGuardDefects` exists to
//                    make this unreachable, and this message is what it looks
//                    like when the guard was bypassed.
//   BROKEN           the bytes arrived and are not a usable module — truncated,
//                    an HTML error page with a 200, or built against a
//                    different ABI. The only one of the three that is a bug in
//                    the module itself.
const NOT_DELIVERED = 'not-delivered';
const NOT_SERVED = 'not-served';
const BROKEN = 'broken';

const loadFault = (kind, id, detail) => {
  const error = new Error(detail);
  error.ctFault = kind;
  error.ctModule = id;
  return error;
};

async function load(id) {
  if (modules.has(id)) return modules.get(id);
  const url = moduleUrls[id];
  if (!url) {
    throw loadFault(NOT_DELIVERED, id,
      `this deployment does not ship the \`${id}\` wasm module, so it was ` +
      `never fetched. Nothing is broken: the module is absent, not failing.`);
  }

  let response;
  try {
    response = await fetch(url);
  } catch (e) {
    // A network-level failure is still "not served" from the page's point of
    // view: the bytes did not arrive. Distinguished from a 404 only in the
    // detail, because the remedy — look at what the deployment published — is
    // the same.
    throw loadFault(NOT_SERVED, id,
      `\`${id}\` is declared at ${url} and the request for it did not ` +
      `complete: ${e && e.message ? e.message : e}`);
  }
  if (!response.ok) {
    throw loadFault(NOT_SERVED, id,
      `\`${id}\` is declared at ${url} and this deployment does not serve ` +
      `it (HTTP ${response.status}). The page and the published files ` +
      `disagree; the module itself has not been reached.`);
  }

  // A 200 IS NOT PROOF THE MODULE IS THERE, and on this product's own host it
  // frequently is not. Cloudflare Pages answers a request for an absent path
  // with the entry document — `HTTP 200`, `content-type: text/html` — which was
  // MEASURED against the live deployment, not assumed:
  //
  //   $ curl -sI https://web-codetracer.pages.dev/assets/noir_wasm.wasm
  //     HTTP/2 200
  //     content-type: text/html; charset=utf-8
  //
  // Without this branch that HTML reaches `WebAssembly.compile`, fails on the
  // magic word, and is reported as BROKEN — "the module was served and is not
  // usable" — when the truth is that it was never deployed. That is precisely
  // the conflation of a missing asset with a broken feature that cost a sibling
  // campaign hours, arriving through the CDN instead of through the code.
  //
  // So the response is classified before it is compiled. Streaming is kept for
  // the good case, which is the one that matters for a 16 MB module: a correct
  // `application/wasm` goes straight to `compileStreaming` and is never
  // buffered.
  const contentType = (response.headers && typeof response.headers.get === 'function'
    ? response.headers.get('content-type') : '') || '';
  const looksLikeWasm = contentType.includes('application/wasm');

  let exports;
  let buffered = null;
  if (!looksLikeWasm) {
    // Not advertised as wasm. It may still BE wasm (a host serving
    // `application/octet-stream`), so the magic word decides rather than the
    // header — a header alone would turn a misconfigured but working host into
    // a hard failure.
    buffered = await response.arrayBuffer();
    const magic = new Uint8Array(buffered, 0, Math.min(4, buffered.byteLength));
    const isWasm = magic.length === 4 && magic[0] === 0x00 && magic[1] === 0x61 &&
                   magic[2] === 0x73 && magic[3] === 0x6d;
    if (!isWasm) {
      throw loadFault(NOT_SERVED, id,
        `\`${id}\` is declared at ${url} and this deployment answered with ` +
        `${contentType || 'an unknown content type'} rather than a wasm ` +
        `module (${buffered.byteLength} bytes). A static host commonly serves ` +
        `its index page for a path it does not have, so this almost always ` +
        `means the module was not published — not that it is broken.`);
    }
  }

  // The bytes are here and they are wasm. Everything from this point on is the
  // module's own fault, and is reported as such.
  try {
    let mod;
    if (buffered !== null) {
      mod = await WebAssembly.compile(buffered);
    } else {
      try {
        mod = await WebAssembly.compileStreaming(response.clone());
      } catch (e) {
        // An engine without streaming compile. Not worth surfacing on its own:
        // the only observable difference is peak memory, and a genuinely bad
        // module fails the buffered path too — where it is reported as BROKEN,
        // below, rather than being blamed on the header.
        mod = await WebAssembly.compile(await response.arrayBuffer());
      }
    }
    ({ exports } = await WebAssembly.instantiate(mod, stubImports(mod)));
  } catch (e) {
    throw loadFault(BROKEN, id,
      `\`${id}\` was served from ${url} as a wasm module and is not a usable ` +
      `one: ${e && e.message ? e.message : e}`);
  }
  modules.set(id, exports);
  return exports;
}

function put(exports, alloc, str) {
  const bytes = new TextEncoder().encode(str);
  const ptr = exports[alloc](bytes.length);
  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

async function compileVfs(request) {
  const exports = await load('noir-compiler');
  const [ptr, len] = put(exports, 'nv_alloc', JSON.stringify(request));
  const resPtr = exports.nv_compile_vfs(ptr, len);
  const resLen = exports.nv_result_len();
  return JSON.parse(new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, resPtr, resLen).slice()));
}

async function traceArtifact(artifact, inputs) {
  const exports = await load('noir-tracer');
  const [aPtr, aLen] = put(exports, 'ct_alloc', JSON.stringify(artifact));
  const [iPtr, iLen] = put(exports, 'ct_alloc', inputs);
  const tPtr = exports.ct_trace(aPtr, aLen, iPtr, iLen, 0);
  const tLen = exports.ct_result_len();
  const isErr = exports.ct_result_is_error() !== 0;
  const text = new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, tPtr, tLen).slice());
  if (isErr) throw new Error(`tracing failed inside wasm: ${text.slice(0, 300)}`);
  return text;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------
//
// TWO MORE FAULTS, in the same field and for the same reason the three above
// are separate sentences. `fault` is carried beside the message so a reader
// BRANCHES rather than matching prose; adding values to a vocabulary a reader
// already switches on is additive, whereas a second field would be a parallel
// vocabulary — which is the shape this file's module-fault comment exists to
// forbid.
//
//   NO SESSION     the sequence addressed is not a live session. Either it
//                  never was one (a `compile` run's sequence, say), or it has
//                  since exited. The caller holds a stale handle; nothing is
//                  broken.
//   SESSION BUSY   the session is alive and its inbox is full. This is
//                  BACKPRESSURE and it is deliberately not a drop: a dropped
//                  message produces a session whose state silently diverges
//                  from what the caller believes it sent, which is a wrong
//                  answer rather than an error. Refusing tells the caller to
//                  slow down and leaves the session running.
const NO_SESSION = 'no-session';
const SESSION_BUSY = 'session-busy';

// Bounded, and small enough that a caller which never reads its replies hits
// the wall in a bounded time rather than growing the worker's heap until the
// tab dies. The number is a policy, not a discovery; what matters is that one
// exists and that crossing it is legible.
const SESSION_QUEUE_LIMIT = 64;

const sessionFault = (kind, detail) => {
  const error = new Error(detail);
  error.ctFault = kind;
  return error;
};

// Keyed by the sequence of the `start` that opened it. There is no separate
// session id, deliberately: a second address space would have to be allocated,
// correlated and torn down alongside the one `wasm_worker.nim` already has,
// and every message would then carry two numbers that must agree. The run's
// sequence is already unique per worker, already routed, and already cleaned
// up by `finish` — so the session's address is the run's address.
//
// MORE THAN ONE MAY BE OPEN AT A TIME, and this Map is why. They are
// independent: no ordering is defined between two sessions, and neither can
// see the other's state. What they DO share is a thread — see the header on
// what a synchronous wasm call does to every session in the worker.
const sessions = new Map();

// A session speaks to its caller as ORDINARY OUTPUT on its own sequence. Not a
// new message kind: `wasm_worker.nim`'s `deliver` already routes `output` to
// the run's `onOutput`, and `startOnWorker` already streams it. One JSON value
// per line, so a reader can frame without knowing the payload's schema.
const emit = (session, value) =>
  post({ seq: session.seq, kind: 'output', stream: 'stdout',
         text: JSON.stringify(value) + '\n' });

function endSession(session, exitCode, note) {
  // Idempotent: a `close` racing a service that has already finished must not
  // post two `exit`s for one sequence. The Nim side ignores the second, but
  // relying on that would make this correct by someone else's accident.
  if (session.closed) return;
  session.closed = true;
  if (session.timer !== null) {
    clearInterval(session.timer);
    session.timer = null;
  }
  sessions.delete(session.seq);
  if (note) emit(session, note);
  post({ seq: session.seq, kind: 'exit', exitCode, signalled: false });
}

function liveSession(id, verb) {
  const session = sessions.get(id);
  if (!session || session.closed) {
    throw sessionFault(NO_SESSION,
      `\`${verb}\` addressed session ${id}, which is not running here. It ` +
      `either never opened or has already exited; ${sessions.size} ` +
      `session(s) are live in this worker.`);
  }
  return session;
}

async function drainSession(session) {
  // ONE MESSAGE AT A TIME, per session. `self.onmessage` is `async`, so
  // without this two inputs that arrive close together both start running and
  // interleave at every `await` — over the state that is the entire reason the
  // session exists. FIFO, because a development node's "register then call"
  // has an order and reordering it is a wrong answer, not a slow one.
  if (session.draining) return;
  session.draining = true;
  try {
    while (!session.closed && session.queue.length > 0) {
      const text = session.queue.shift();
      try {
        await session.handle(text);
      } catch (e) {
        // A HANDLER THAT THREW DOES NOT END THE SESSION. A malformed
        // transaction is not a reason to tear down the node that refused it —
        // and if it were, the caller could never learn which message did it,
        // because the session's exit carries no sequence of its own.
        emit(session, {
          error: { message: String(e && e.message ? e.message : e) } });
      }
    }
  } finally {
    session.draining = false;
  }
}

// ---------------------------------------------------------------------------
// `session-probe` — the smallest service with a development node's SHAPE
// ---------------------------------------------------------------------------
//
// THIS IS NOT A NODE, and it is named so that nobody can mistake it for one.
// Hosting the Aztec node is downstream work with other agents moving toward
// it; what is needed HERE is proof that the mechanism above carries a real
// long-lived stateful service, and the honest way to get that is the smallest
// service that has every property the node has and none of its substance:
//
//   * state that accumulates across round trips, where a later call SUCCEEDS
//     ONLY BECAUSE an earlier one happened — `send` to an unregistered
//     contract is refused, so a `send` that works is evidence the `register`
//     from a previous round trip is still there;
//   * unsolicited output on a wall clock, because a node seals blocks whether
//     or not anyone is asking;
//   * a long operation, so ordering and backpressure can be measured rather
//     than argued about — in both flavours, since an `await` and a
//     synchronous wasm call do very different things to a worker's thread.
//
// A counter would have shown state. It would not have shown any of the rest.
const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

// A state root, so an assertion can be DISCRIMINATING. A test that checks a
// height sees the same number from a session that applied its transactions and
// from one that threw them away; a fold over every accepted operation differs
// the moment anything is missed, reordered or applied twice.
const fold = (root, text) => {
  let h = root >>> 0;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, FNV_PRIME) >>> 0;
  }
  return h >>> 0;
};
const rootHex = (h) => `00000000${h.toString(16)}`.slice(-8);

const flagValue = (args, name, fallback) => {
  for (const arg of args || []) {
    if (typeof arg === 'string' && arg.startsWith(`${name}=`)) {
      const parsed = Number(arg.slice(name.length + 1));
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return fallback;
};

function sealBlock(session, state, cause) {
  const txCount = state.mempool;
  state.mempool = 0;
  state.height += 1;
  state.sealed += txCount;
  state.root = fold(state.root, `block:${state.height}:${txCount}`);
  emit(session, {
    event: 'block', number: state.height, txCount, cause,
    stateRoot: rootHex(state.root) });
}

function openProbeSession(session, request) {
  const tickMs = flagValue(request.args, '--tick-ms', 0);
  const state = {
    height: 0, sealed: 0, mempool: 0, contracts: [],
    root: FNV_OFFSET,
    // TWO COUNTERS, AND THE PAIR IS THE MEASUREMENT. `serial` is stamped when
    // a handler STARTS and `finished` when it emits its reply, so
    // `serial === finished` on every reply is exactly the statement "nothing
    // else ran in between" — which is what per-session serialisation means and
    // the only thing that distinguishes it from merely receiving in order.
    //
    // One counter is not enough, and the first draft proved it: with only the
    // start stamp, removing the drain guard changed nothing observable,
    // because dispatch happens in arrival order either way. The reordering is
    // in the COMPLETIONS, so a completion has to be counted.
    serial: 0,
    finished: 0,
  };
  session.state = state;

  session.handle = async (text) => {
    const line = text.trim();
    if (line.length === 0) return;
    const message = JSON.parse(line);
    state.serial += 1;
    const reply = { id: message.id === undefined ? null : message.id,
                    serial: state.serial };

    if (message.method === 'register') {
      const name = String((message.params || {}).name || '');
      if (name.length === 0) {
        reply.error = { message: 'register needs a `name`' };
      } else if (state.contracts.indexOf(name) >= 0) {
        reply.error = { message: `\`${name}\` is already registered` };
      } else {
        state.contracts.push(name);
        state.root = fold(state.root, `register:${name}`);
        reply.result = { contract: name, contracts: state.contracts.length };
      }
    } else if (message.method === 'send') {
      const params = message.params || {};
      const contract = String(params.contract || '');
      // THE ROUND-TRIP PROOF. This refusal is what makes a later success
      // mean something: a worker that lost the session between calls, or
      // opened a fresh one per message, lands here every time.
      if (state.contracts.indexOf(contract) < 0) {
        reply.error = {
          message: `no contract \`${contract}\` in this session; ` +
                   `registered: [${state.contracts.join(', ')}]` };
      } else {
        state.mempool += 1;
        state.root = fold(state.root, `tx:${contract}:${params.call || ''}`);
        reply.result = { queued: state.mempool, height: state.height };
      }
    } else if (message.method === 'status') {
      reply.result = {
        height: state.height, sealed: state.sealed, mempool: state.mempool,
        contracts: state.contracts.slice(), stateRoot: rootHex(state.root) };
    } else if (message.method === 'seal') {
      sealBlock(session, state, 'requested');
      reply.result = { number: state.height, stateRoot: rootHex(state.root) };
    } else if (message.method === 'stall') {
      const params = message.params || {};
      const ms = Number(params.ms) || 0;
      const blocking = params.mode === 'blocking';
      if (blocking) {
        // A SYNCHRONOUS WASM CALL, modelled. `nv_compile_vfs` is exactly this
        // from the event loop's point of view: it returns a value and it
        // returns the thread with it. Nothing else in this worker runs.
        const until = Date.now() + ms;
        while (Date.now() < until) { /* deliberately spinning */ }
      } else {
        await new Promise((resolve) => setTimeout(resolve, ms));
      }
      reply.result = { stalled: ms, mode: blocking ? 'blocking' : 'await' };
    } else {
      reply.error = {
        message: `the session probe has no method \`${message.method}\`` };
    }

    state.finished += 1;
    reply.finished = state.finished;
    emit(session, reply);
  };

  if (tickMs > 0) {
    session.timer = setInterval(() => {
      // SYNCHRONOUS, and not merely because it is short. It mutates the same
      // state `handle` does, and JS interleaves only at an `await` — so a
      // tick that awaited anything could seal a block from a half-applied
      // transaction. There is no lock here because there does not need to be
      // one, and that is a property to keep rather than to rediscover.
      if (state.mempool === 0) return;
      sealBlock(session, state, 'tick');
    }, tickMs);
  }

  // The first thing a caller hears. `startOnWorker` resolves its handle
  // WITHOUT waiting for the worker, so without this the caller holds a handle
  // and no evidence the session on the other end exists.
  emit(session, {
    event: 'ready', service: session.name, session: session.seq, tickMs });
}

// The table. A subcommand in here opens a session; everything else keeps the
// one-shot routing below, unchanged.
const SERVICES = { 'session-probe': openProbeSession };

function openSession(seq, name, request) {
  const session = {
    seq, name, queue: [], draining: false, closed: false,
    timer: null, handle: null, state: null };
  sessions.set(seq, session);
  try {
    SERVICES[name](session, request);
  } catch (e) {
    // A service that could not start is a session that never opened. Ending
    // it here rather than leaving it in the Map is what makes the next
    // `input` say `no-session` instead of finding a half-built object.
    sessions.delete(seq);
    session.closed = true;
    throw e;
  }
  return session;
}

self.onmessage = async (event) => {
  // `String(...)` for the same reason the Nim transport coerces: the protocol
  // is text, and a structured-clone object arriving here would be a silent
  // second shape — the asymmetry `wasm_worker.nim`'s header forbids.
  let request;
  try {
    request = JSON.parse(String(event.data));
  } catch (e) {
    post({ seq: 0, kind: 'failed', message: `worker got a non-JSON request: ${e.message}` });
    return;
  }

  const seq = request.seq;
  try {
    // The bundle tells the worker where its modules live, once, before any run.
    // An ordinary protocol message rather than `workerData` (browsers have no
    // such thing) or a query string (which would put the URLs into the worker
    // script's own cache key).
    if (request.kind === 'configure') {
      moduleUrls = request.moduleUrls || {};
      post({ seq, kind: 'output', stream: 'stdout', text: '' });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
      return;
    }
    // ONE MESSAGE INTO A RUNNING SESSION. The acknowledgement below is posted
    // for THIS message's sequence and says only that the session accepted it;
    // whatever the session has to say arrives later, as output on the
    // session's own sequence. Keeping those two facts on two sequences is what
    // lets a refusal — a full inbox — be reported without ending the session,
    // and it is why `input` does not reuse the session's sequence.
    if (request.kind === 'input') {
      const session = liveSession(request.session, 'input');
      if (session.queue.length >= SESSION_QUEUE_LIMIT) {
        throw sessionFault(SESSION_BUSY,
          `session ${session.seq} already has ${session.queue.length} ` +
          `message(s) waiting, which is its limit of ${SESSION_QUEUE_LIMIT}. ` +
          `The message was NOT accepted and nothing was dropped; send it ` +
          `again once the session has caught up.`);
      }
      session.queue.push(String(request.text === undefined ? '' : request.text));
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
      // NOT awaited, and that is the whole point of the two sequences: the
      // acknowledgement is about acceptance, and awaiting the drain would
      // silently turn it into a claim about completion — the "chain of
      // agreements" shape `wasm_worker.nim`'s header forbids. A floating
      // promise is safe here because `drainSession` catches per message and
      // resets `draining` in a `finally`; the `catch` is the backstop for a
      // `postMessage` that itself throws.
      drainSession(session).catch((e) => post({
        seq: session.seq, kind: 'failed',
        message: `the session's queue could not be drained: ` +
                 String(e && e.message ? e.message : e) }));
      return;
    }

    // ENDING IT DELIBERATELY. `terminate` exists and kills the whole worker,
    // taking every other session and every in-flight compile with it; that is
    // the right verb for "stop everything" and the wrong one for "I am done
    // with this node". This is the other one.
    if (request.kind === 'close') {
      const session = liveSession(request.session, 'close');
      endSession(session, 0, { event: 'closed', session: session.seq });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
      return;
    }

    if (request.kind !== 'start') {
      post({ seq, kind: 'failed', message: `unknown request kind ${request.kind}` });
      return;
    }

    const sub = (request.args || []).find((a) => !a.startsWith('-'));
    // A SESSION SUBCOMMAND OPENS A SESSION AND DOES NOT EXIT. Placed before
    // the one-shot chain rather than inside it, so that chain stays exactly as
    // it was — it is gated in CI and two other agents are working in it.
    if (Object.prototype.hasOwnProperty.call(SERVICES, sub)) {
      openSession(seq, sub, request);
      return;
    }
    if (sub === 'compile') {
      const response = await compileVfs(JSON.parse(request.stdin));
      post({ seq, kind: 'output', stream: 'stdout', text: JSON.stringify(response) });
      // The exit code follows the RESPONSE, not the fact that the call
      // returned. A compiler reporting `ok: false` has failed, and resolving
      // its run as a success is the "chain of agreements" shape this
      // protocol's header names.
      post({ seq, kind: 'exit', exitCode: response.ok ? 0 : 1, signalled: false });
    } else if (sub === 'trace') {
      const payload = JSON.parse(request.stdin);
      const text = await traceArtifact(payload.artifact, payload.inputs);
      post({ seq, kind: 'output', stream: 'stdout', text });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
    } else {
      // Case 3 of `wasm_registry.nim`'s five: a module is registered but was
      // not built with this subcommand. Distinct from "no module at all",
      // which the registry answers before anything reaches this worker.
      post({ seq, kind: 'failed', message: `no wasm build for subcommand ${sub}` });
    }
  } catch (e) {
    // `fault` is carried as its own field rather than being spelled into the
    // message, so a reader can BRANCH on which of the three it was without
    // matching prose. `wasm_worker.nim`'s `deliver` ignores fields it does not
    // know, so this is additive to the protocol.
    const message = String(e && e.message ? e.message : e);
    const fault = (e && e.ctFault) || '';
    post(fault
      ? { seq, kind: 'failed', message, fault, module: (e && e.ctModule) || '' }
      : { seq, kind: 'failed', message });
  }
};
