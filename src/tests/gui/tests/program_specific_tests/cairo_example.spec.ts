/**
 * The Cairo example's language detection, checked without launching the
 * application: the file extension's classification and the recorder probe.
 *
 * What a user sees of a Cairo recording (its entry, its call trace, its
 * values, stepping, a column breakpoint) is a scenario now:
 * src/tests/scenarios/languages/cairo-recording-smoke.yaml and cairo-column-breakpoint.yaml.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect } from "../../lib/fixtures";
import { resolveRecorderTestProgram, hasToolOnPath } from "../../lib/sibling-test-programs";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-cairo-recorder` binary is reachable.
 * Checks `CODETRACER_CAIRO_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasCairoRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_CAIRO_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-cairo-recorder";
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
const cairoRecorderAvailable = hasCairoRecorder();
// Test program lives in the codetracer-cairo-recorder sibling repo.
const cairoTestProgram = resolveRecorderTestProgram("cairo", "cairo/flow_test.cairo");
// The Cairo pipeline requires the `scarb` build tool (Cairo's package manager
// and compiler frontend) in addition to the recorder binary and test program.
const cairoToolchainAvailable = hasToolOnPath("scarb");
const cairoPipelineAvailable = cairoRecorderAvailable && cairoTestProgram !== null && cairoToolchainAvailable;

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("cairo_example — environment detection", () => {
  test("cairo extension is classified as DB-based (no RR required)", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.cairo")).toBe(true);
    expect(isDbBased("some/path/program.cairo")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    expect(typeof cairoRecorderAvailable).toBe("boolean");
    expect(typeof cairoPipelineAvailable).toBe("boolean");
  });
});
