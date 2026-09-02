// noir-template-acir-count.mjs — the template's ACIR opcode count, measured by
// THE ENGINE THAT SHIPS.
//
// ## Why this exists, and why `nargo info` cannot do its job
//
// The Constraints pane describes a circuit the BROWSER compiles. Until now the
// number it ships was checked against whatever `nargo` was on `PATH`, which is
// the flake's `noir` pin — and `ci/deploy/noir-wasm.pin` says in as many words
// that the flake pin "is NOT this one". The two pins are different compilers,
// and the opcode count is not the same across them.
//
// So the old check was guaranteed to enforce a number the browser will not
// produce, and to push any correction toward the truth back out again as
// "drift". Together with the provenance check beside it — which reads a
// docstring and confirms a CLAIM about which command produced the number — the
// gate certified a wrong value twice and called it agreement.
//
// This measures the same quantity from the wasm module the deploy publishes.
// That makes the constant correct-by-construction against the only compiler
// whose answer a user can see, rather than correct-by-luck against one nobody
// runs in a tab.
//
// ## Why the count of `acir_locations` IS the opcode count
//
// The identity was measured, not assumed, and in three representations that
// agree on one compiler: `nargo info --json`'s total, the row count of
// `nargo compile --print-acir`, and the number of `acir_locations` entries in
// the artifact's debug info. One opcode, one printed row, one debug entry.
// Only the VALUE is compiler-scoped; the relationship is structural.
//
// `acir_locations` is an opcode-INDEXED map, so its size is the count only
// while its keys are the dense range. A sparse map would make the size a lower
// bound that still looked like an answer, so contiguity is asserted below
// rather than trusted — an unchecked assumption here would reintroduce exactly
// the failure this file replaces.
//
// ## Mode
//
// `program`, the default, which is UNINSTRUMENTED. `debug` mode compiles the
// instrumented `force_brillig` path, where every function carries unconstrained
// bytecode and the ACIR is not the circuit — measured, that mode answers zero
// entries. A count taken there would describe a build no user is shown.
//
// Usage:  noir-template-acir-count.mjs <project-dir> <package-name>
// Env:    CT_NOIR_WASM_COMPILER  path to noir_wasm.wasm
// Output: the count, alone, on stdout. Provenance on stderr.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { inflateRawSync, inflateSync } from 'node:zlib';
import { join, relative, sep } from 'node:path';

const [projectDir, packageName] = process.argv.slice(2);
const modulePath = process.env.CT_NOIR_WASM_COMPILER;

if (!projectDir || !packageName) {
  console.error('usage: noir-template-acir-count.mjs <project-dir> <package-name>');
  process.exit(2);
}
if (!modulePath) {
  console.error('CT_NOIR_WASM_COMPILER is not set');
  process.exit(2);
}

// The VFS keys the product uses: package directory as a PREFIX, `/`-separated,
// no leading slash. Mirrors `platform/noir_build.noirVfsPath`, and is spelled
// the same way as `noir-template-verdicts.mjs` beside it, so the two harnesses
// present the module with one filesystem rather than two.
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
// THE ARTEFACT NAMES ITSELF beside the number it produced, for the same reason
// the verdict harness does: a count whose module came from a different build
// than the deploy's would look exactly like agreement.
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
  JSON.stringify({ files, package_dir: packageName, mode: 'program' }));
const ptr = exports.nv_alloc(request.length);
new Uint8Array(exports.memory.buffer, ptr, request.length).set(request);
const resultPtr = exports.nv_compile_vfs(ptr, request.length);
const resultLen = exports.nv_result_len();
const response = JSON.parse(new TextDecoder().decode(
  new Uint8Array(exports.memory.buffer, resultPtr, resultLen).slice()));

if (!response.ok) {
  console.error(`  the wasm module could not compile the template: ` +
                `${response.stage ?? '?'}/${response.kind ?? '?'} ` +
                `${response.message ?? ''}`);
  process.exit(1);
}
if (!response.artifact || response.artifact.debug_symbols === undefined) {
  console.error('  the module answered without an artifact carrying debug_symbols');
  process.exit(1);
}

// `ProgramDebugInfo::serialize_compressed_base64_json`. Raw deflate is what the
// artefact actually carries; the zlib-wrapped attempt is a fallback so a change
// in framing fails loudly here rather than becoming a wrong count.
const packed = Buffer.from(response.artifact.debug_symbols, 'base64');
let decoded;
try {
  decoded = inflateRawSync(packed);
} catch {
  try {
    decoded = inflateSync(packed);
  } catch (err) {
    console.error(`  debug_symbols did not inflate: ${err.message}`);
    process.exit(1);
  }
}

const doc = JSON.parse(decoded.toString('utf8'));
const infos = Array.isArray(doc) ? doc : doc.debug_infos;
if (!Array.isArray(infos) || infos.length === 0) {
  console.error('  debug_symbols carried no debug_infos');
  process.exit(1);
}

// The FIRST entry, matching `noir_anchor_producer.nim`. Multi-circuit programs
// are out of scope there and here; merging opcode indices from different
// circuits would produce a total that is confidently wrong.
const locations = infos[0].acir_locations;
if (!locations || typeof locations !== 'object') {
  console.error('  the first debug_info carried no acir_locations map');
  process.exit(1);
}

const indices = Object.keys(locations).map(Number).sort((a, b) => a - b);
// EMPTY IS NOT ZERO. `[].every()` is vacuously true, so an empty map would sail
// through the density check below and print `0` -- a number indistinguishable
// from a real count of nothing. `debug` mode produces exactly that: it compiles
// the instrumented `force_brillig` path, where no function carries ACIR at all.
// A harness that answered `0` there would report a circuit with no opcodes and
// be believed.
//
// THIS GUARD WAS MISSING FROM THE FIRST VERSION OF THIS FILE. The density check
// below was written precisely to stop a number that merely RESEMBLES a count
// from being printed, and it let the emptiest such number through -- the defect
// this file exists to remove, reintroduced inside the repair. Universal
// quantification over an empty set is vacuously true, and "for all" over
// nothing is the shape behind a large share of the wrong answers this campaign
// has found: a check that passes because it examined no cases reads exactly
// like one that passed because every case held.
//
// It became visible only because the module was BUILT and run in both modes.
// Reading the Rust showed a correct contiguity check and would have shown one
// forever; `debug` mode answering zero is what turned an unexercised branch
// into a measured one.
if (indices.length === 0) {
  console.error('  acir_locations is empty, which is not a count of zero: this ' +
                'artifact carries no ACIR (the instrumented force_brillig path ' +
                'does that). Refusing to report a number.');
  process.exit(1);
}
const dense = indices.every((v, i) => v === i);
if (!dense) {
  console.error('  acir_locations is not the dense opcode range, so its size is ' +
                'not the opcode count; refusing to report a number that would ' +
                'look like one');
  process.exit(1);
}

console.log(indices.length);
