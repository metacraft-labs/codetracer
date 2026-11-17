/**
 * The Move example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Move recording (its entry, its call trace, its
 * values, stepping, a column breakpoint) is a scenario now:
 * src/tests/scenarios/languages/move-recording-smoke.yaml and move-column-breakpoint.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-move-recorder` binary is reachable.
 * Checks `CODETRACER_MOVE_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasMoveRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_MOVE_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-move-recorder";
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
const moveRecorderAvailable = hasMoveRecorder();
// The Move pipeline requires both the recorder binary and the `aptos` CLI
// (or `sui` CLI) for compiling/replaying Move programs.
const moveToolchainAvailable = hasToolOnPath("aptos") || hasToolOnPath("sui");
const movePipelineAvailable = moveRecorderAvailable && moveToolchainAvailable;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("move_example — environment detection", () => {
  test("move extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .move files as DB-based
    // so they don't attempt RR recording when movePipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.move")).toBe(true);
    expect(isDbBased("some/path/module.move")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof moveRecorderAvailable).toBe("boolean");
    expect(typeof movePipelineAvailable).toBe("boolean");
  });
});
