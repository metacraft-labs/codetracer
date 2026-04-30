import { test } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";

/**
 * Smoke tests for the Lean Sudoku Solver (lean_sudoku_solver).
 *
 * DISABLED: Lean compiles to C but the generated C code has no #line
 * directives, so DWARF debug info maps to .c files, not .lean source.
 * Source-level breakpoints and stepping don't work until upstream adds
 * #line support (leanprover/lean4#12921).
 *
 * Tracking issue: https://github.com/metacraft-labs/codetracer/issues/535
 *
 * The build+record+DAP-connect pipeline works — see
 * src/db-backend/tests/lean_flow_integration.rs for headless tests.
 */
// TODO(skipped): All 5 tests skipped. Lean compiles to C but the generated C code has no #line
//   directives, so DWARF debug info maps to .c files, not .lean source files. Source-level
//   breakpoints and stepping do not work. Upstream issue: leanprover/lean4#12921.
//   Tracking: https://github.com/metacraft-labs/codetracer/issues/535
//   Hypothesis: This is blocked on upstream Lean compiler changes. Once lean4 adds #line
//   directives to generated C code, DWARF will map back to .lean files and these tests can be enabled.
test.describe("LeanSudoku", () => {
  test.fixme(true, "Lean C codegen lacks #line directives — no source-level debugging (codetracer#535)");
  test.use({ sourcePath: "lean_sudoku_solver/Main.lean", launchMode: "trace" });

  test("editor loads (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("event log populated", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("call trace (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("variable inspection (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });

  test("output (event log fallback)", async ({ ctPage }) => {
    await helpers.assertEventLogPopulated(ctPage);
  });
});
