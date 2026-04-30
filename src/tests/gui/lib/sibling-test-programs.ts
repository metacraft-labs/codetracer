/**
 * Sibling recorder repo test program discovery.
 *
 * Test programs belong in their canonical recorder repos (not in
 * codetracer/test-programs/). This module resolves paths to test programs
 * in sibling recorder repos using a three-tier fallback:
 *
 *   1. Environment variable (e.g. CODETRACER_CIRCOM_RECORDER_PATH)
 *   2. Relative path from the codetracer repo (../codetracer-<name>/)
 *   3. Graceful failure with a diagnostic message
 *
 * See: codetracer-specs/Testing/Test-Program-Layout.md
 */

import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

// The codetracer repo root (parent of tsc-ui-tests/).
const currentDir = path.resolve();
const codetracerRepoRoot = path.dirname(currentDir);

// The workspace root (parent of the codetracer repo).
const workspaceRoot = path.dirname(codetracerRepoRoot);

/**
 * Registry of recorder repos and their env var names.
 *
 * Each entry maps a short recorder name to:
 *   - repoDir: the directory name of the sibling recorder repo
 *   - envVar: the environment variable that overrides the path
 */
const RECORDER_REPOS: Record<string, { repoDir: string; envVar: string }> = {
  circom:  { repoDir: "codetracer-circom-recorder",  envVar: "CODETRACER_CIRCOM_RECORDER_PATH" },
  aiken:   { repoDir: "codetracer-cardano-recorder",  envVar: "CODETRACER_AIKEN_RECORDER_PATH" },
  cairo:   { repoDir: "codetracer-cairo-recorder",    envVar: "CODETRACER_CAIRO_RECORDER_PATH" },
  cadence: { repoDir: "codetracer-flow-recorder",     envVar: "CODETRACER_CADENCE_RECORDER_PATH" },
  leo:     { repoDir: "codetracer-leo-recorder",       envVar: "CODETRACER_LEO_RECORDER_PATH" },
  tolk:    { repoDir: "codetracer-ton-recorder",       envVar: "CODETRACER_TOLK_RECORDER_PATH" },
  polkavm: { repoDir: "codetracer-polkavm-recorder",   envVar: "CODETRACER_POLKAVM_RECORDER_PATH" },
  evm:     { repoDir: "codetracer-evm-recorder",       envVar: "CODETRACER_EVM_RECORDER_PATH" },
  solana:  { repoDir: "codetracer-solana-recorder",     envVar: "CODETRACER_SOLANA_RECORDER_PATH" },
  fuel:    { repoDir: "codetracer-fuel-recorder",       envVar: "CODETRACER_FUEL_RECORDER_PATH" },
  move:    { repoDir: "codetracer-move-recorder",       envVar: "CODETRACER_MOVE_RECORDER_PATH" },
  miden:   { repoDir: "codetracer-miden-recorder",      envVar: "CODETRACER_MIDEN_RECORDER_PATH" },
  js:      { repoDir: "codetracer-js-recorder",         envVar: "CODETRACER_JS_RECORDER_PATH" },
  wasm:    { repoDir: "codetracer-wasm-recorder",       envVar: "CODETRACER_WASM_RECORDER_PATH" },
  python:  { repoDir: "codetracer-python-recorder",     envVar: "CODETRACER_PYTHON_RECORDER_PATH" },
  ruby:    { repoDir: "codetracer-ruby-recorder",       envVar: "CODETRACER_RUBY_RECORDER_PATH" },
};

/**
 * Resolves the root directory of a sibling recorder repo.
 *
 * Tier 1: Check the environment variable for this recorder.
 * Tier 2: Check the relative path from the workspace root.
 *
 * Returns null if the recorder repo is not found.
 */
export function findRecorderRepo(recorderName: string): string | null {
  const entry = RECORDER_REPOS[recorderName];
  if (!entry) {
    return null;
  }

  // Tier 1: Environment variable.
  // The env var may point to either a repo directory or a binary inside
  // target/release/. When it's a file, resolve to the repo root by
  // walking up past target/release/.
  const envValue = process.env[entry.envVar] ?? "";
  if (envValue.length > 0 && fs.existsSync(envValue)) {
    if (fs.statSync(envValue).isDirectory()) {
      return envValue;
    }
    // Binary path like <repo>/target/release/<binary> — go up to <repo>
    const repoDir = path.resolve(envValue, "..", "..", "..");
    if (fs.existsSync(path.join(repoDir, "test-programs"))) {
      return repoDir;
    }
  }

  // Tier 2: Relative path from workspace root.
  const siblingPath = path.join(workspaceRoot, entry.repoDir);
  if (fs.existsSync(siblingPath)) {
    return siblingPath;
  }

  return null;
}

/**
 * Resolves an absolute path to a test program in a sibling recorder repo.
 *
 * @param recorderName - Short name of the recorder (e.g. "circom", "aiken")
 * @param programPath - Path relative to the recorder's test-programs/ directory
 *                      (e.g. "circom/flow_test.circom")
 * @returns Absolute path to the test program, or null if not found.
 *
 * @example
 *   // Returns "/home/user/metacraft/codetracer-circom-recorder/test-programs/circom/flow_test.circom"
 *   resolveRecorderTestProgram("circom", "circom/flow_test.circom")
 */
export function resolveRecorderTestProgram(
  recorderName: string,
  programPath: string,
): string | null {
  const repoRoot = findRecorderRepo(recorderName);
  if (!repoRoot) {
    return null;
  }

  const fullPath = path.join(repoRoot, "test-programs", programPath);
  if (fs.existsSync(fullPath)) {
    return fullPath;
  }

  // Check if it's a directory (e.g. Noir project directories).
  if (fs.existsSync(fullPath) && fs.statSync(fullPath).isDirectory()) {
    return fullPath;
  }

  return null;
}

/**
 * Returns true if a recorder's sibling repo and the specified test program
 * are both available. Useful for test skip guards.
 */
export function hasRecorderTestProgram(
  recorderName: string,
  programPath: string,
): boolean {
  return resolveRecorderTestProgram(recorderName, programPath) !== null;
}

/**
 * Returns true if the given tool is available on PATH.
 *
 * Uses `which` to locate the binary. Returns false when the tool is not
 * found or `which` exits with a non-zero status.
 */
export function hasToolOnPath(tool: string): boolean {
  try {
    const result = childProcess.spawnSync("which", [tool], {
      encoding: "utf-8",
      timeout: 5_000,
      stdio: "pipe",
    });
    return result.status === 0 && result.stdout.trim().length > 0;
  } catch {
    return false;
  }
}
