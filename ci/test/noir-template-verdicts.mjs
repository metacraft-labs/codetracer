// The wasm module's test VERDICTS, as `<name> <status>` lines, for comparison
// against `nargo test --format json`'s own.
//
// WHY THIS EXISTS SEPARATELY FROM `noir-wasm-worker/compare.mjs`
// -------------------------------------------------------------
// That file compares the module against ITSELF across the worker boundary, and
// against expectations written into the same repository as the module. Both are
// worth having and neither can catch the failure this one is for: the wasm
// runner and the `nargo` a developer runs locally disagreeing about the same
// program. `ci/test/noir-template-toolchain.sh` is the only harness with a real
// `nargo` on PATH, so the comparison lives there and this is its wasm half.
//
// The comparison it feeds is not "did they both say something". It is a
// line-for-line `diff` of two sorted verdict lists, and the arm that drives it
// deliberately adds a test that FAILS and a `should_fail` test that PASSES —
// because a program in which everything is green is one that a runner with the
// inversion backwards would also report as green.
//
// STATUS SPELLINGS ARE NORMALISED TO NARGO'S, here and not in the shell, so the
// mapping is beside the reason for it:
//
//   wasm            nargo (`JsonFormatter::test_end_async`)
//   pass            ok
//   fail            failed
//   compile-error   failed        (nargo emits `failed` for `CompileError` too)
//   skipped         ignored
//
// Usage:  node ci/test/noir-template-verdicts.mjs <project-dir> <package-name>
// Env:    CT_NOIR_WASM_COMPILER  path to noir_wasm.wasm
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, relative, sep } from 'node:path';

const [projectDir, packageName] = process.argv.slice(2);
const modulePath = process.env.CT_NOIR_WASM_COMPILER;

if (!projectDir || !packageName) {
  console.error('usage: noir-template-verdicts.mjs <project-dir> <package-name>');
  process.exit(2);
}
if (!modulePath) {
  console.error('CT_NOIR_WASM_COMPILER is not set');
  process.exit(2);
}

// The VFS keys the product uses: package directory as a PREFIX, `/`-separated,
// no leading slash. `platform/noir_build.noirVfsPath` is the one place that
// decides this and this mirrors it — a different spelling here would make the
// comparison a test of this script rather than of the module.
function collect(dir, into, prefix) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      collect(full, into, prefix);
      continue;
    }
    if (!entry.endsWith('.nr') && entry !== 'Nargo.toml' && entry !== 'Prover.toml') {
      continue;
    }
    const key = `${prefix}/${relative(projectDir, full).split(sep).join('/')}`;
    into[key] = readFileSync(full, 'utf8');
  }
}

const files = {};
collect(projectDir, files, packageName);

const bytes = readFileSync(modulePath);
// THE ARTEFACT NAMES ITSELF beside the verdicts it produced. This campaign has
// found several harnesses that measured stale or shared bytes and reported
// confidently about them; a comparison whose two sides came from different
// builds would look exactly like agreement.
console.error(`  module: ${modulePath} (${bytes.length} bytes, sha256 ` +
              `${createHash('sha256').update(bytes).digest('hex').slice(0, 16)})`);

const mod = await WebAssembly.compile(bytes);
const imports = {};
for (const { module: m, name } of WebAssembly.Module.imports(mod)) {
  imports[m] ??= {};
  imports[m][name] = () => { throw new Error(`reached ${m}.${name}`); };
}
const { exports } = await WebAssembly.instantiate(mod, imports);

const request = new TextEncoder().encode(
  JSON.stringify({ files, package_dir: packageName }));
const ptr = exports.nv_alloc(request.length);
new Uint8Array(exports.memory.buffer, ptr, request.length).set(request);
const resultPtr = exports.nv_test_vfs(ptr, request.length);
const resultLen = exports.nv_result_len();
const response = JSON.parse(new TextDecoder().decode(
  new Uint8Array(exports.memory.buffer, resultPtr, resultLen).slice()));

if (!response.ok) {
  console.error(`  the wasm module could not run the suite: ` +
                `${response.stage ?? '?'}/${response.kind ?? '?'} ` +
                `${response.message ?? ''}`);
  process.exit(1);
}

const toNargo = {
  pass: 'ok',
  fail: 'failed',
  'compile-error': 'failed',
  skipped: 'ignored',
};

const lines = (response.tests ?? []).map((t) => {
  const status = toNargo[t.status];
  if (!status) {
    console.error(`  the module answered an unknown status: ${t.status}`);
    process.exit(1);
  }
  return `${t.name} ${status}`;
});
lines.sort();
for (const line of lines) console.log(line);
