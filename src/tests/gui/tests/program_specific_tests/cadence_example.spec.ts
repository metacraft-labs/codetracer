/**
 * The Cadence example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Cadence recording (its entry, its call trace, its
 * values, stepping, a column breakpoint) is a scenario now:
 * src/tests/scenarios/languages/cadence-recording-smoke.yaml and cadence-column-breakpoint.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { resolveRecorderTestProgram } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-cadence-recorder` binary is reachable.
 * Checks `CODETRACER_CADENCE_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasCadenceRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_CADENCE_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-cadence-recorder";
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
const cadenceRecorderAvailable = hasCadenceRecorder();
// Test program lives in the codetracer-cadence-recorder sibling repo.
const cadenceTestProgram = resolveRecorderTestProgram("cadence", "cadence/flow_test.cdc");
const cadencePipelineAvailable = cadenceRecorderAvailable && cadenceTestProgram !== null;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("cadence_example — environment detection", () => {
  test("cdc extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.cdc")).toBe(true);
    expect(isDbBased("some/path/contract.cdc")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof cadenceRecorderAvailable).toBe("boolean");
    expect(typeof cadencePipelineAvailable).toBe("boolean");
  });
});
