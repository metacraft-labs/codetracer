/**
 * The Circom example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Circom recording (its entry, its call trace, its
 * values, stepping) is a scenario now:
 * src/tests/scenarios/languages/circom-recording-smoke.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { resolveRecorderTestProgram, hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-circom-recorder` binary is reachable.
 * Checks `CODETRACER_CIRCOM_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasCircomRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_CIRCOM_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-circom-recorder";
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
const circomRecorderAvailable = hasCircomRecorder();
// Test program lives in the codetracer-circom-recorder sibling repo.
const circomTestProgram = resolveRecorderTestProgram("circom", "circom/flow_test.circom");
// The Circom pipeline requires the `circom` compiler in addition to the
// recorder binary and test program.
const circomToolchainAvailable = hasToolOnPath("circom");
const circomPipelineAvailable = circomRecorderAvailable && circomTestProgram !== null && circomToolchainAvailable;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("circom_example — environment detection", () => {
  test("circom extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.circom")).toBe(true);
    expect(isDbBased("some/path/circuit.circom")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof circomRecorderAvailable).toBe("boolean");
    expect(typeof circomPipelineAvailable).toBe("boolean");
  });
});
