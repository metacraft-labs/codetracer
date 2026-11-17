/**
 * The Leo example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Leo recording (its entry, its call trace, its
 * values, stepping) is a scenario now:
 * src/tests/scenarios/languages/leo-recording-smoke.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { resolveRecorderTestProgram, hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-leo-recorder` binary is reachable.
 * Checks `CODETRACER_LEO_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasLeoRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_LEO_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-leo-recorder";
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
const leoRecorderAvailable = hasLeoRecorder();
// Test program lives in the codetracer-leo-recorder sibling repo.
const leoTestProgram = resolveRecorderTestProgram("leo", "leo/flow_test.leo");
// The Leo pipeline requires the `leo` compiler in addition to the recorder
// binary and test program.
const leoToolchainAvailable = hasToolOnPath("leo");
const leoPipelineAvailable = leoRecorderAvailable && leoTestProgram !== null && leoToolchainAvailable;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("leo_example — environment detection", () => {
  test("leo extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.leo")).toBe(true);
    expect(isDbBased("some/path/main.leo")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof leoRecorderAvailable).toBe("boolean");
    expect(typeof leoPipelineAvailable).toBe("boolean");
  });
});
