// The ACIR opcode total of a Noir package, counted out of the ACIR ITSELF.
//
// Compiles the package with the shipping wasm module — the same
// `nv_compile_vfs` call `web_noir_build.nim` makes from a tab — and then
// counts the opcodes in the artifact's own bytecode.
//
// ## WHY THIS EXISTS BESIDE `noir-template-acir-count.mjs`, which answers the
// ## same question for the same reason and is not general
//
// That script counts entries in `debug_infos[0].acir_locations`, an
// opcode-INDEXED map of source locations, and guards the identity with a
// density check: the key set must be exactly `0..n-1` before its size may be
// called an opcode count. The guard is right and it is load-bearing, because
// the identity is NOT structural — it holds only when every opcode carries a
// source location, and compiler-synthesized opcodes do not.
//
// MEASURED, on the two templates this repo ships, through the pinned module:
//
//     hello_noir          17 opcodes, acir_locations 0..16   -> dense, 17
//     oracle_settlement  478 opcodes, acir_locations 16..477 -> NOT dense, 462
//
// The 16 missing entries are `BlackBoxFuncCall::RANGE` opcodes, one per
// witness of an integer-typed parameter, emitted by the compiler with no
// source position. `hello_noir`'s `main` takes two `Field`s, needs no range
// constraints, and so happens to have every opcode located. The demo's takes
// two `[u64; 7]`s and two `pub u64`s, and does not.
//
// So the older script is not wrong — it refuses, correctly, rather than
// reporting 462 as an opcode count — it is simply unable to answer for any
// circuit with an integer parameter. THE FIX IS NOT TO LOOSEN ITS PREDICATE.
// "Contiguous" still yields 462; `max + 1` assumes the LAST opcode is always
// located, which nothing guarantees. The fix is to stop measuring locations.
//
// ## What is actually counted
//
// `artifact.bytecode` is base64 of a gzipped ACIR program: one leading format
// byte, then MessagePack — not bincode; Noir 1.0.0-beta.26 changed this. The
// decoded shape is `[functions[], unconstrained_functions[]]`, and each
// circuit is `[name, opcodes[], private_parameters[], public_parameters[],
// return_values[], assert_messages[]]`. The total is `opcodes.length` summed
// over `functions`, which is the same set `nargo info --json` sums
// `programs[].functions[].opcodes` over.
//
// AND THE DECODE REFUSES RATHER THAN GUESSING. `end !== raw.length` is a hard
// error: a MessagePack reader that stops early returns a perfectly plausible
// structure from a prefix of the buffer, and a count taken from one would look
// exactly like a correct answer. Requiring the whole buffer to be consumed is
// what makes a misparse loud.
//
// Usage:
//   CT_NOIR_WASM_COMPILER=<noir_wasm.wasm> \
//     node ci/test/noir-acir-opcode-count.mjs <project-dir> <package-name>
// Prints the total to stdout; diagnostics to stderr.
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { join, relative, sep } from 'node:path';

const compiler = process.env.CT_NOIR_WASM_COMPILER;
const projectDir = process.argv[2];
const packageName = process.argv[3];

const refuse = (why) => { console.error(`  ${why}`); process.exit(1); };

if (!compiler) refuse('CT_NOIR_WASM_COMPILER is not set');
if (!projectDir || !packageName) {
  refuse('usage: noir-acir-opcode-count.mjs <project-dir> <package-name>');
}

// --- minimal MessagePack reader -------------------------------------------
// Enough for an ACIR program and no more. It is here rather than pulled from
// npm because `ci/test` runs on a bare node with no install step, and because
// a decoder that only has to read one shape can afford to throw on everything
// else instead of coercing it.
function decodeMsgpack(buf, start = 0) {
  let p = start;
  const str = (n) => { const s = buf.toString('utf8', p, p + n); p += n; return s; };
  const bin = (n) => { const s = buf.subarray(p, p + n); p += n; return s; };
  const arr = (n) => { const a = new Array(n); for (let i = 0; i < n; i++) a[i] = rd(); return a; };
  const map = (n) => {
    const o = {};
    for (let i = 0; i < n; i++) { const k = rd(); o[String(k)] = rd(); }
    return o;
  };
  function rd() {
    const b = buf[p++];
    if (b <= 0x7f) return b;
    if (b >= 0xe0) return b - 256;
    if ((b & 0xf0) === 0x80) return map(b & 0x0f);
    if ((b & 0xf0) === 0x90) return arr(b & 0x0f);
    if ((b & 0xe0) === 0xa0) return str(b & 0x1f);
    switch (b) {
      case 0xc0: return null;
      case 0xc2: return false;
      case 0xc3: return true;
      case 0xc4: { const n = buf.readUInt8(p); p += 1; return bin(n); }
      case 0xc5: { const n = buf.readUInt16BE(p); p += 2; return bin(n); }
      case 0xc6: { const n = buf.readUInt32BE(p); p += 4; return bin(n); }
      case 0xca: { const v = buf.readFloatBE(p); p += 4; return v; }
      case 0xcb: { const v = buf.readDoubleBE(p); p += 8; return v; }
      case 0xcc: return buf[p++];
      case 0xcd: { const v = buf.readUInt16BE(p); p += 2; return v; }
      case 0xce: { const v = buf.readUInt32BE(p); p += 4; return v; }
      case 0xcf: { const v = buf.readBigUInt64BE(p); p += 8; return v; }
      case 0xd0: { const v = buf.readInt8(p); p += 1; return v; }
      case 0xd1: { const v = buf.readInt16BE(p); p += 2; return v; }
      case 0xd2: { const v = buf.readInt32BE(p); p += 4; return v; }
      case 0xd3: { const v = buf.readBigInt64BE(p); p += 8; return v; }
      case 0xd9: { const n = buf[p++]; return str(n); }
      case 0xda: { const n = buf.readUInt16BE(p); p += 2; return str(n); }
      case 0xdb: { const n = buf.readUInt32BE(p); p += 4; return str(n); }
      case 0xdc: { const n = buf.readUInt16BE(p); p += 2; return arr(n); }
      case 0xdd: { const n = buf.readUInt32BE(p); p += 4; return arr(n); }
      case 0xde: { const n = buf.readUInt16BE(p); p += 2; return map(n); }
      case 0xdf: { const n = buf.readUInt32BE(p); p += 4; return map(n); }
      default: throw new Error(`unsupported msgpack byte 0x${b.toString(16)} at ${p - 1}`);
    }
  }
  const value = rd();
  return { value, end: p };
}

// --- the package, as the browser sees it ----------------------------------
// Keys are `<packageName>/<relative>`, mirroring `noir_build.noirVfsPath`, so
// this drives the module over the same virtual filesystem a tab does.
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

const moduleBytes = readFileSync(compiler);
console.error(`  module: ${compiler} (${moduleBytes.length} bytes, sha256 ` +
  `${createHash('sha256').update(moduleBytes).digest('hex').slice(0, 16)})`);

const wasmModule = await WebAssembly.compile(moduleBytes);
const { exports } = await WebAssembly.instantiate(wasmModule, stubImports(wasmModule));

const files = collect(projectDir, {}, projectDir);
if (Object.keys(files).length === 0) refuse(`no Noir sources under ${projectDir}`);

const request = JSON.stringify({ files, package_dir: packageName, mode: 'program' });
const requestBytes = new TextEncoder().encode(request);
const requestPtr = exports.nv_alloc(requestBytes.length);
new Uint8Array(exports.memory.buffer, requestPtr, requestBytes.length).set(requestBytes);
const responsePtr = exports.nv_compile_vfs(requestPtr, requestBytes.length);
const response = JSON.parse(new TextDecoder().decode(
  new Uint8Array(exports.memory.buffer, responsePtr, exports.nv_result_len()).slice()));
if (!response.ok) refuse(`the shipping compiler refused the package: ${response.message}`);

const artifact = response.artifact;
if (!artifact || typeof artifact.bytecode !== 'string') {
  refuse('the artifact carries no `bytecode`, so there is no ACIR to count');
}

const raw = gunzipSync(Buffer.from(artifact.bytecode, 'base64'));
// The leading byte is the serialization format tag; MessagePack starts after it.
const { value, end } = decodeMsgpack(raw, 1);
if (end !== raw.length) {
  refuse(`the ACIR decode consumed ${end} of ${raw.length} bytes; refusing to ` +
    'report a count taken from a prefix of the program');
}
if (!Array.isArray(value) || !Array.isArray(value[0])) {
  refuse('the decoded ACIR is not [functions, unconstrained_functions]');
}
const [functions, unconstrained] = value;
if (functions.length === 0) {
  refuse('the program has no constrained circuits, which is not a count of zero');
}

let total = 0;
for (const circuit of functions) {
  const [name, opcodes] = circuit;
  if (!Array.isArray(opcodes)) refuse(`circuit "${name}" carries no opcode list`);
  total += opcodes.length;
  console.error(`  circuit "${name}": ${opcodes.length} opcodes`);
}
console.error(`  unconstrained functions: ${unconstrained?.length ?? 0}`);
console.log(String(total));
