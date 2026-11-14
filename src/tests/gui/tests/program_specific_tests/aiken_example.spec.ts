/**
 * The Aiken example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Aiken recording (its entry, its call trace, its
 * values, stepping) is a scenario now:
 * src/tests/scenarios/languages/aiken-recording-smoke.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { resolveRecorderTestProgram } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-aiken-recorder` binary is reachable.
 * Checks `CODETRACER_AIKEN_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasAikenRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_AIKEN_RECORDER_PATH ?? "";
  // ct's paths.nim maps LangAiken to `codetracer-cardano-recorder` (Aiken
  // is Cardano's smart-contract language and ships inside the Cardano
  // recorder repo).  Match that lookup rather than expecting a separate
  // codetracer-aiken-recorder binary that doesn't exist.
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-cardano-recorder";
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
const aikenRecorderAvailable = hasAikenRecorder();
// Test program lives in the codetracer-aiken-recorder sibling repo.
const aikenTestProgram = resolveRecorderTestProgram("aiken", "aiken/flow_test.ak");
const aikenPipelineAvailable = aikenRecorderAvailable && aikenTestProgram !== null;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("aiken_example — environment detection", () => {
  test("ak extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.ak")).toBe(true);
    expect(isDbBased("some/path/validator.ak")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof aikenRecorderAvailable).toBe("boolean");
    expect(typeof aikenPipelineAvailable).toBe("boolean");
  });
});
