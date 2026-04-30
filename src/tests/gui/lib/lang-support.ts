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
  "small", // Small
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
 * Returns true if the source path uses a DB-based recorder (no RR needed).
 * Returns false if RR recording is required.
 */
export function isDbBased(sourcePath: string): boolean {
  // Check folder markers first.
  const fs = require("node:fs");
  const path = require("node:path");
  const resolvedPath = path.resolve(sourcePath);

  if (fs.existsSync(resolvedPath) && fs.statSync(resolvedPath).isDirectory()) {
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
