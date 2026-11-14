/**
 * The JavaScript example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a JavaScript recording (its entry, its call trace, its
 * values, stepping) is a scenario now:
 * src/tests/scenarios/languages/js-recording-smoke.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { resolveRecorderTestProgram } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-js-recorder` binary is reachable.
 * Checks `CODETRACER_JS_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasJsRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_JS_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-js-recorder";
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
const jsRecorderAvailable = hasJsRecorder();
// Test program lives in the codetracer-js-recorder sibling repo.
const jsTestProgram = resolveRecorderTestProgram("js", "js/flow_test.js");
const jsPipelineAvailable = jsRecorderAvailable && jsTestProgram !== null;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("js_example — environment detection", () => {
  // JavaScript is NOT classified as DB-based in the Nim backend (common_lang.nim).
  // The JS recorder is a standalone pipeline tool, similar to Solana.
  test("js extension is NOT classified as DB-based (JS uses pipeline detection)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.js")).toBe(false);
    expect(isDbBased("some/path/app.js")).toBe(false);
    // Sanity-check: DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof jsRecorderAvailable).toBe("boolean");
    expect(typeof jsPipelineAvailable).toBe("boolean");
  });
});
