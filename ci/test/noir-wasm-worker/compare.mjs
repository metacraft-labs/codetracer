// NS3: the same Noir program, compiled and traced BOTH ways, compared by digest.
//
// WHY A DIGEST AND NOT A COUNT. "27 events" is satisfied by any 27 events. A
// sibling campaign settled the equivalent question today by showing a
// container produced in a page was BYTE-IDENTICAL to the one node produces,
// which is what made "it worked" falsifiable. This does the same across the
// worker boundary: the direct path drives the two wasm modules in-process, the
// worker path drives them through `worker_threads` and the JSON protocol
// `platform/wasm_worker.nim` speaks, and the two traces must hash the same.
//
// AND THE TRACE MUST BE NON-TRIVIAL, asserted separately. This campaign has
// twice met the shape where everything reports ok over nothing: two wasm
// modules answering ok over a trace of ONE event and ZERO steps, and a DAP
// server answering success over a session with no trace open. Equal digests
// over two empty traces would be equally green and equally worthless.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const compiler = process.env.CT_NOIR_WASM_COMPILER;
const tracer = process.env.CT_NOIR_WASM_TRACER;

const files = {
  'proj/Nargo.toml': '[package]\nname = "hello"\ntype = "bin"\n',
  'proj/src/main.nr':
    'fn double(x: Field) -> Field { x + x }\n' +
    'fn main(x: Field) -> pub Field { let d = double(x); d + 1 }\n',
};
const compileRequest = { files, package_dir: 'proj', mode: 'debug' };
const inputs = 'x = "3"\n';

const digest = (s) => createHash('sha256').update(s).digest('hex').slice(0, 16);

// --- the direct path, in this process --------------------------------------
const stubImports = (mod) => {
  const imports = {};
  for (const { module: m, name } of WebAssembly.Module.imports(mod)) {
    imports[m] ??= {};
    imports[m][name] = () => { throw new Error(`reached ${m}.${name}`); };
  }
  return imports;
};
async function load(path) {
  const mod = await WebAssembly.compile(readFileSync(path));
  const { exports } = await WebAssembly.instantiate(mod, stubImports(mod));
  return exports;
}
function put(exports, alloc, str) {
  const bytes = new TextEncoder().encode(str);
  const ptr = exports[alloc](bytes.length);
  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}
async function directPath() {
  const c = await load(compiler);
  const [rp, rl] = put(c, 'nv_alloc', JSON.stringify(compileRequest));
  const cPtr = c.nv_compile_vfs(rp, rl);
  const response = JSON.parse(new TextDecoder().decode(
    new Uint8Array(c.memory.buffer, cPtr, c.nv_result_len()).slice()));
  if (!response.ok) throw new Error(`direct compile refused: ${response.message}`);

  const t = await load(tracer);
  const [ap, al] = put(t, 'ct_alloc', JSON.stringify(response.artifact));
  const [ip, il] = put(t, 'ct_alloc', inputs);
  const tPtr = t.ct_trace(ap, al, ip, il, 0);
  if (t.ct_result_is_error() !== 0) throw new Error('direct trace failed');
  return new TextDecoder().decode(
    new Uint8Array(t.memory.buffer, tPtr, t.ct_result_len()).slice());
}

// --- the worker path, over the protocol ------------------------------------
function workerRun(worker, seq, subcommand, stdin) {
  return new Promise((resolve, reject) => {
    let out = '';
    const onMessage = (raw) => {
      // BOTH DIRECTIONS LOGGED, because a boundary that speaks two shapes is
      // the failure this protocol is built against. `String(raw)` here mirrors
      // the browser transport's coercion.
      const message = JSON.parse(String(raw));
      if (message.seq !== seq) return;
      if (process.env.CT_WASM_WORKER_TRACE) {
        console.log(`    <- ${String(raw).slice(0, 90)}`);
      }
      if (message.kind === 'output') out += message.text;
      else if (message.kind === 'exit') {
        worker.off('message', onMessage);
        if (message.exitCode !== 0) reject(new Error(`exit ${message.exitCode}`));
        else resolve(out);
      } else if (message.kind === 'failed') {
        worker.off('message', onMessage);
        reject(new Error(message.message));
      }
    };
    worker.on('message', onMessage);
    const request = JSON.stringify({
      seq, kind: 'start', module: 'noir', command: 'nargo',
      args: [subcommand], workingDir: '', stdin,
    });
    if (process.env.CT_WASM_WORKER_TRACE) {
      console.log(`    -> ${request.slice(0, 90)}`);
    }
    worker.postMessage(request);
  });
}

async function workerPath() {
  const worker = new Worker(join(here, 'worker.mjs'), {
    workerData: { compiler, tracer },
  });
  try {
    const compiled = await workerRun(worker, 1, 'compile', JSON.stringify(compileRequest));
    const response = JSON.parse(compiled);
    if (!response.ok) throw new Error(`worker compile refused: ${response.message}`);
    return await workerRun(worker, 2, 'trace',
      JSON.stringify({ artifact: response.artifact, inputs }));
  } finally {
    await worker.terminate();
  }
}

// --- compare ---------------------------------------------------------------
let failures = 0;
const ok = (m) => console.log(`  [OK]     ${m}`);
const bad = (m) => { console.log(`  [FAILED] ${m}`); failures++; };

const direct = await directPath();
const viaWorker = await workerPath();

const dTrace = JSON.parse(direct);
const steps = dTrace.events.filter((e) => 'Step' in e).length;
const calls = dTrace.events.filter((e) => 'Call' in e).length;

console.log(`  direct: ${dTrace.events.length} events, ${steps} steps, ${calls} calls`);
console.log(`  digest direct=${digest(direct)} worker=${digest(viaWorker)}`);

if (dTrace.events.length > 1 && steps > 0 && calls > 0) {
  ok(`the trace is non-trivial (${dTrace.events.length} events, ${steps} steps)`);
} else {
  bad(`ONE-EVENT-ZERO-STEPS: ${dTrace.events.length} events, ${steps} steps — ` +
      'both modules can answer ok over a trace with nothing in it');
}
if (digest(direct) === digest(viaWorker)) {
  ok('the worker path produced a byte-identical trace to the direct path');
} else {
  bad('the worker path produced a DIFFERENT trace to the direct path');
}
if (dTrace.paths.length > 0 && dTrace.paths[0] === 'proj/src/main.nr') {
  ok("and it is positioned against the caller's own VFS path");
} else {
  bad(`paths were ${JSON.stringify(dTrace.paths)}`);
}

console.log(failures === 0
  ? '\nRESULT: OK — the worker path and the direct path agree, over a real trace'
  : `\nRESULT: FAILED — ${failures} check(s)`);
process.exit(failures === 0 ? 0 : 1);
