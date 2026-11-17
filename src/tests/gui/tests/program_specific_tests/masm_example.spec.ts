/**
 * The Miden assembly example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Miden assembly recording (its entry, its call trace, its
 * values, stepping) is a scenario now:
 * src/tests/scenarios/languages/masm-recording-smoke.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-miden-recorder` binary is reachable.
 * Checks `CODETRACER_MIDEN_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasMidenRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_MIDEN_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-miden-recorder";
  try {
    const result = childProcess.spawnSync(binary, ["--version"], {
      encoding: "utf-8",
      timeout: 5_000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

// Evaluated at collection time; the structural test below checks the probe does not throw.
const midenRecorderAvailable = hasMidenRecorder();
// The Miden recorder bundles miden-assembly as a Rust library for MASM files,
// but the full pipeline (especially Rust-via-midenc) needs the `miden` CLI.
// Check for `miden` as the toolchain availability indicator.
const midenToolchainAvailable = hasToolOnPath("miden");
const midenPipelineAvailable = midenRecorderAvailable && midenToolchainAvailable;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("masm_example — environment detection", () => {
  test("masm extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .masm files as DB-based
    // so they don't attempt RR recording when midenPipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("compute.masm")).toBe(true);
    expect(isDbBased("some/path/program.masm")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof midenRecorderAvailable).toBe("boolean");
    expect(typeof midenPipelineAvailable).toBe("boolean");
  });
});
