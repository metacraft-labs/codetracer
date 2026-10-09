// Compile and TRACE a Noir package through the two pinned wasm modules, and
// report what is actually in the trace.
//
// The headless twin of what a tab does on Run: `web_noir_build.startNoirRun`
// issues an `nbmDebug` compile through the worker and chains a trace over the
// resulting artifact with the project's `Prover.toml` as `inputs`. This makes
// the same two calls in-process, so a demo can be shown to trace WITHOUT
// standing up a browser — the browser arm still exists and is the one that
// proves the renderer paints it.
//
// ## `debug`, not `program`, and it is not a preference
//
// `noir_build.NoirBuildMode`: program mode is what Build uses and reports
// warnings; debug mode is `force_brillig` and is the ONLY artifact a tracer can
// walk. A `program`-mode artifact traces to one event and zero steps — the
// exact shape that has twice let every check in this area report ok over
// nothing.
//
// ## What it prints, and why each line is separate
//
//   container <n> / steps <n> / calls <n>  the recording's size
//   nontrivial yes|no                      a CTFS `.ct` && steps > 0 && calls > 0
//   wrongprice yes|no                      the recording carries the wrong price
//   assertion yes|no                       the recording carries the refusal
//
// ## The answer is a `.ct` container
//
// The tracer answers `{container, paths, source_views, steps, calls, ...}`:
// the recording as a base64 CTFS `.ct` container, with step and call counts
// beside it (the same shape `noir-wasm-worker/compare.mjs` reads). The source
// text travels in `source_views`, NOT in the container, so a string found in
// the container's bytes was recorded by the run, not read from the program's
// source. The container's streams are zstd frames, so the strings are looked
// for in every frame the container's bytes hold, decompressed (a frame magic
// that turns up inside compressed data simply fails to decode and is skipped).
//
// The last two are the ones a caller must check. Non-triviality is satisfied
// by ANY program that runs, so on its own it cannot tell this demo's trace
// from the starter's — and telling those two apart is the entire job of the
// gate that calls this.
//
// Usage:
//   CT_NOIR_WASM_COMPILER=... CT_NOIR_WASM_TRACER=... \
//     node ci/test/noir-demo-trace.mjs <project-dir> <package-name>
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const compiler = process.env.CT_NOIR_WASM_COMPILER;
const tracer = process.env.CT_NOIR_WASM_TRACER;
const projectDir = process.argv[2];
const packageName = process.argv[3];

const refuse = (why) => { console.error(`  ${why}`); process.exit(1); };
if (!compiler || !tracer) refuse('CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER is not set');
if (!projectDir || !packageName) {
  refuse('usage: noir-demo-trace.mjs <project-dir> <package-name>');
}

function collect(dir, files, root) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) { collect(full, files, root); continue; }
    const keep = name.endsWith('.nr') || name === 'Nargo.toml' || name === 'Prover.toml';
    if (!keep) continue;
    files[`${packageName}/${relative(root, full).split(sep).join('/')}`] =
      readFileSync(full, 'utf8');
  }
  return files;
}

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

const files = collect(projectDir, {}, projectDir);
const inputs = files[`${packageName}/Prover.toml`];
// A `bin` package with no Prover.toml has nothing to encode against its ABI,
// and the tracer refuses. Say so here rather than letting it look like a
// tracer failure.
if (inputs === undefined) refuse(`${packageName} ships no Prover.toml, so there is nothing to run`);

const c = await load(compiler);
const [rp, rl] = put(c, 'nv_alloc', JSON.stringify({
  files, package_dir: packageName, mode: 'debug',
}));
const cPtr = c.nv_compile_vfs(rp, rl);
const compiled = JSON.parse(new TextDecoder().decode(
  new Uint8Array(c.memory.buffer, cPtr, c.nv_result_len()).slice()));
if (!compiled.ok) refuse(`the shipping compiler refused the package: ${compiled.message}`);

const t = await load(tracer);
const [ap, al] = put(t, 'ct_alloc', JSON.stringify(compiled.artifact));
const [ip, il] = put(t, 'ct_alloc', inputs);
const tPtr = t.ct_trace(ap, al, ip, il, 0);
const raw = new TextDecoder().decode(
  new Uint8Array(t.memory.buffer, tPtr, t.ct_result_len()).slice());
// A FAILING ASSERTION IS NOT A TRACER ERROR, and this demo depends on the
// difference: the program under trace refuses, and the trace of it is exactly
// what the visitor is meant to walk. `ct_result_is_error` reports that the
// TRACER could not answer.
if (t.ct_result_is_error() !== 0) refuse(`the tracer could not answer: ${raw.slice(0, 400)}`);

const CTFS_MAGIC = [0xc0, 0xde, 0x72, 0xac, 0xe2];
const trace = JSON.parse(raw);
const bytes = typeof trace.container === 'string'
  ? Buffer.from(trace.container, 'base64') : Buffer.alloc(0);
const isContainer = CTFS_MAGIC.every((b, i) => bytes[i] === b);
const steps = trace.steps ?? 0;
const calls = trace.calls ?? 0;
const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const frames = [];
if (isContainer) {
  for (let at = bytes.indexOf(ZSTD_MAGIC); at >= 0; at = bytes.indexOf(ZSTD_MAGIC, at + 1)) {
    try { frames.push(zstdDecompressSync(bytes.subarray(at))); } catch { /* not a frame */ }
  }
}
const log = frames.map((f) => f.toString('latin1')).join('\n');

console.log(`container ${bytes.length}`);
console.log(`frames ${frames.length}`);
console.log(`steps ${steps}`);
console.log(`calls ${calls}`);
console.log(`nontrivial ${isContainer && steps > 0 && calls > 0 ? 'yes' : 'no'}`);
console.log(`wrongprice ${log.includes('settled price: 242990') ? 'yes' : 'no'}`);
console.log(
  `assertion ${log.includes('the published price is not the median of this round') ? 'yes' : 'no'}`);
