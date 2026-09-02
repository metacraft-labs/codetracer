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

// THE TEST SUITE, FOUR WAYS. The verdicts a `should_fail` runner can get wrong
// are not two but four, and a TALLY distinguishes none of them: 2 passed /
// 2 failed is also what a runner that inverted BOTH attributes reports, and
// what one that inverted NEITHER reports over a different program. So each
// expectation below is per test, by name.
//
// This is the one check in this file that would catch an inverted suite before
// it reached a user, and it runs against the module the deploy is about to
// publish rather than against a fixture.
const testFiles = {
  'suite/Nargo.toml': '[package]\nname = "suite"\ntype = "bin"\n',
  'suite/src/main.nr':
    'fn main() {}\n' +
    '\n#[test]\nfn passes() { assert(1 == 1); }\n' +
    '\n#[test]\nfn fails() { assert(1 == 2, "one is not two"); }\n' +
    '\n#[test(should_fail)]\nfn fails_as_asked() { assert(1 == 2); }\n' +
    '\n#[test(should_fail)]\nfn passes_when_it_should_not() { assert(1 == 1); }\n' +
    '\n#[test(should_fail_with = "not two")]\n' +
    'fn right_message() { assert(1 == 2, "one is not two"); }\n' +
    '\n#[test(should_fail_with = "some other reason")]\n' +
    'fn wrong_message() { assert(1 == 2, "one is not two"); }\n',
};
const testRequest = { files: testFiles, package_dir: 'suite' };
// RECORDING one of those tests. `record` is a different request from running —
// it compiles that one test through the instrumented `force_brillig` path and
// answers an artifact, running nothing — and the two halves are what makes
// "run this test" mean "step through it" rather than "see a verdict".
const recordRequest = {
  files: testFiles, package_dir: 'suite', record: 'passes',
};
const expectedVerdicts = {
  passes: 'pass',
  fails: 'fail',
  // An assertion that FIRED under `should_fail` is a PASS.
  fails_as_asked: 'pass',
  // A test that ran CLEAN under `should_fail` is a FAILURE.
  passes_when_it_should_not: 'fail',
  // `should_fail_with` is a substring match on the failure message, so the
  // wrong message is a failure even though the test did fail.
  right_message: 'pass',
  wrong_message: 'fail',
};

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
async function directTests() {
  const c = await load(compiler);
  const [rp, rl] = put(c, 'nv_alloc', JSON.stringify(testRequest));
  const ptr = c.nv_test_vfs(rp, rl);
  return JSON.parse(new TextDecoder().decode(
    new Uint8Array(c.memory.buffer, ptr, c.nv_result_len()).slice()));
}

async function directRecord() {
  const c = await load(compiler);
  const [rp, rl] = put(c, 'nv_alloc', JSON.stringify(recordRequest));
  const ptr = c.nv_test_vfs(rp, rl);
  return JSON.parse(new TextDecoder().decode(
    new Uint8Array(c.memory.buffer, ptr, c.nv_result_len()).slice()));
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

async function workerTests() {
  // A RED SUITE EXITS 1, which is `nargo test`'s own exit code and which
  // `workerRun` rejects on — so the text has to be collected from the rejection
  // rather than from a resolve. Treating exit 1 as "the run failed" here would
  // make this check unable to observe any failing test at all, which is the
  // half of the four-way fixture that matters most.
  const worker = new Worker(join(here, 'worker.mjs'), {
    workerData: { compiler, tracer },
  });
  try {
    return await new Promise((resolve, reject) => {
      let out = '';
      const onMessage = (raw) => {
        const message = JSON.parse(String(raw));
        if (message.seq !== 3) return;
        if (message.kind === 'output') out += message.text;
        else if (message.kind === 'exit') {
          worker.off('message', onMessage);
          resolve({ text: out, exitCode: message.exitCode });
        } else if (message.kind === 'failed') {
          worker.off('message', onMessage);
          reject(new Error(message.message));
        }
      };
      worker.on('message', onMessage);
      worker.postMessage(JSON.stringify({
        seq: 3, kind: 'start', module: 'noir', command: 'nargo',
        args: ['test'], workingDir: '', stdin: JSON.stringify(testRequest),
      }));
    });
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

// --- and the tests, both ways ----------------------------------------------
const directRun = await directTests();
const workerRunResult = await workerTests();
const workerRunBody = JSON.parse(workerRunResult.text);

console.log(`  tests: ok=${directRun.ok} passed=${directRun.passed} ` +
            `failed=${directRun.failed} skipped=${directRun.skipped}`);

if (directRun.ok) {
  ok('the suite RAN (`ok` means it ran, not that it was green)');
} else {
  bad(`the suite did not run: ${directRun.message}`);
}

const byName = Object.fromEntries(
  (directRun.tests || []).map((t) => [t.name, t.status]));
let verdictFailures = 0;
for (const [name, expected] of Object.entries(expectedVerdicts)) {
  if (byName[name] !== expected) {
    bad(`${name}: expected ${expected}, module said ${byName[name] ?? '<absent>'}`);
    verdictFailures++;
  }
}
if (verdictFailures === 0) {
  ok(`all ${Object.keys(expectedVerdicts).length} verdicts are the ones ` +
     '`nargo test` reaches, including both directions of `should_fail`');
}

// The digest again, over the whole run, so the two paths cannot differ in a
// field this file forgot to name.
if (digest(JSON.stringify(directRun)) === digest(JSON.stringify(workerRunBody))) {
  ok('the worker path produced a byte-identical test run to the direct path');
} else {
  bad('the worker path produced a DIFFERENT test run to the direct path');
}

// A RED SUITE EXITS NON-ZERO. `nargo test` does, and a CI script that shelled
// out to this worker and read the exit code would otherwise believe a suite
// with two failures had passed.
if (workerRunResult.exitCode === 1) {
  ok('a red suite exits 1 through the worker, as `nargo test` does');
} else {
  bad(`a red suite exited ${workerRunResult.exitCode} through the worker`);
}

// --- and the recording, which is what "run this test" actually produces ------
//
// THE STEP COUNT IS THE ASSERTION, not the artifact's existence. `vfs.rs`'s own
// header records the measurement this guards: an UNINSTRUMENTED compile of the
// same test yields an artifact that is present, well-formed, carries
// `debug_symbols`, and traces to ONE EVENT AND ZERO STEPS — with both modules
// reporting ok. A check that asserted "we got an artifact" would pass on exactly
// that, and the user would click Run test and land in a debugger with nothing to
// step.
const recorded = await directRecord();
if (recorded.ok && recorded.artifact) {
  ok('a test compiles to a traceable artifact');
  const t = await load(tracer);
  const [ap, al] = put(t, 'ct_alloc', JSON.stringify(recorded.artifact));
  // EMPTY INPUTS. A `#[test]` takes no arguments — the module refuses to record
  // one that does — so its ABI has nothing to encode. Sending the project's
  // `Prover.toml` here would encode `main`'s arguments against a test's ABI.
  const [ip, il] = put(t, 'ct_alloc', '');
  const tp = t.ct_trace(ap, al, ip, il, 0);
  const tl = t.ct_result_len();
  const text = new TextDecoder().decode(
    new Uint8Array(t.memory.buffer, tp, tl).slice());
  if (t.ct_result_is_error() !== 0) {
    bad(`the tracer refused the recorded test: ${text.slice(0, 200)}`);
  } else {
    const rTrace = JSON.parse(text);
    const rSteps = rTrace.events.filter((e) => 'Step' in e).length;
    const rCalls = rTrace.events.filter((e) => 'Call' in e).length;
    console.log(`  recorded: ${rTrace.events.length} events, ${rSteps} steps, ${rCalls} calls`);
    if (rTrace.events.length > 1 && rSteps > 0 && rCalls > 0) {
      ok(`the recorded test traces with ${rSteps} steps — a session opened over ` +
         'it has something to step');
    } else {
      bad(`ONE-EVENT-ZERO-STEPS over a recorded test: ${rTrace.events.length} ` +
          `events, ${rSteps} steps — this is what an uninstrumented compile ` +
          'produces, and both modules report ok over it');
    }
  }
} else {
  bad(`recording a test was refused: ${recorded.kind ?? '?'} ${recorded.message ?? ''}`);
}

// A RECORDING RUNS NOTHING, and a run records nothing. Asking for one must not
// silently do the other — a `record` that also ran the suite would compile every
// test twice, and a run that returned an artifact would let a caller trace the
// wrong program.
if ((recorded.tests || []).length === 0 && !directRun.artifact) {
  ok('recording and running are separate requests over the same tree');
} else {
  bad(`recording returned ${(recorded.tests || []).length} verdict(s) and the ` +
      `run returned ${directRun.artifact ? 'an' : 'no'} artifact`);
}

console.log(failures === 0
  ? '\nRESULT: OK — the worker path and the direct path agree, over a real ' +
    'trace, a real test run and a recorded test that steps'
  : `\nRESULT: FAILED — ${failures} check(s)`);
process.exit(failures === 0 ? 0 : 1);
