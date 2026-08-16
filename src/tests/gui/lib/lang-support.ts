/**
 * Language detection and recording backend classification.
 *
 * Mirrors the Lang enum and IS_DB_BASED array from src/common/common_lang.nim.
 * DB-based languages use their own recorders; all others require RR.
 */

/** File extension → whether the language uses a DB-based recorder. */
const DB_BASED_EXTENSIONS = new Set([
  "py",    // PythonDb
  "rb",    // RubyDb
  "nr",    // Noir
  "wasm",  // RustWasm / CppWasm
  "sol",   // Solidity / EVM recorder
  "masm",  // Miden / MASM recorder
  "sw",    // Sway / Fuel recorder
  "move",    // Move recorder
  "pvm",     // PolkaVM recorder
  "cairo",   // Cairo recorder
  "circom",  // Circom recorder
  "leo",     // Leo / Aleo recorder
  "tolk",    // Tolk / TON recorder
  "ak",      // Aiken / Cardano recorder
  "cdc",     // Cadence / Flow recorder
]);

/** Folder markers that indicate a DB-based project. */
const DB_BASED_FOLDER_MARKERS: Record<string, boolean> = {
  "Nargo.toml": true, // Noir
  "Forc.toml": true,  // Sway / Fuel projects
  "Move.toml": true,    // Move projects
  "program.json": true, // Leo / Aleo projects
  "aiken.toml": true,   // Aiken / Cardano projects
  "flow.json": true,    // Cadence / Flow projects
};

/**
 * Resolves a `sourcePath` the way the Playwright fixtures do before recording.
 *
 * `test.use({ sourcePath })` accepts either an absolute path (used by specs
 * that pull programs out of sibling recorder repos) or a path relative to
 * `codetracer/test-programs/` (e.g. `"noir_space_ship/"`).  `launchTraceElectron`
 * / `launchTraceWeb` in `lib/fixtures.ts` join the relative form onto
 * `testProgramsPath`, so any classification of the same string has to apply the
 * identical rule — resolving against `process.cwd()` instead makes every
 * relative folder look non-existent, which silently downgrades folder-marker
 * languages (Noir, Sway, Move, Leo, Aiken, Cadence) to "needs RR" and skips
 * their whole suite.
 *
 * The base directory is derived from this file's own location rather than from
 * the process CWD so that it is correct no matter where Playwright is invoked
 * from: `<repo>/src/tests/gui/lib` → four levels up is the repo root.
 */
export function resolveTestProgramPath(sourcePath: string): string {
  const path = require("node:path");
  if (path.isAbsolute(sourcePath)) {
    return sourcePath;
  }
  const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");
  return path.join(repoRoot, "test-programs", sourcePath);
}

/**
 * Returns true if the source path uses a DB-based recorder (no RR needed).
 * Returns false if RR recording is required.
 */
export function isDbBased(sourcePath: string): boolean {
  // Check folder markers first.
  const fs = require("node:fs");
  const path = require("node:path");
  const resolvedPath = resolveTestProgramPath(sourcePath);

  if (fs.existsSync(resolvedPath) && fs.statSync(resolvedPath).isDirectory()) {
    // A folder that already contains a `.ct` CTFS container is a
    // pre-recorded trace (e.g. the BEAM canonical_flow fixtures recorded
    // by codetracer-beam-recorder, or any materialized trace bundle).
    // It is opened via `launchMode: "trace-folder"` and never needs an
    // RR recording pass — treat it as DB-based.
    for (const entry of fs.readdirSync(resolvedPath)) {
      if (entry.toLowerCase().endsWith(".ct")) {
        return true;
      }
    }
    for (const marker of Object.keys(DB_BASED_FOLDER_MARKERS)) {
      if (fs.existsSync(path.join(resolvedPath, marker))) {
        return DB_BASED_FOLDER_MARKERS[marker];
      }
    }
  }

  // Check file extension.
  const ext = path.extname(sourcePath).replace(/^\./, "").toLowerCase();
  return DB_BASED_EXTENSIONS.has(ext);
}

/**
 * Returns true if recording this source path requires RR backend support.
 */
export function requiresRR(sourcePath: string): boolean {
  return !isDbBased(sourcePath);
}
