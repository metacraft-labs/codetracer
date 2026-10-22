/**
 * fixture-default-layout.spec.ts — the launch fixture opens a spec that says
 * nothing about the layout on THE LAYOUT THE PRODUCT ITSELF LAUNCHES ON.
 *
 * Issue (codetracer-pm):
 * `issues/2026-10-14-gui-test-fixture-defaults-every-launch-to-the-bundled-layout-the-product-calls-nobodys-layout.md`.
 * The fixture's default branch used to copy the bundled
 * `src/config/default_layout.json` verbatim into the run's saved layout, so
 * the index process found a saved file and loaded it as-is, and
 * `index/config.installModeDefault` never ran. That tree is the one
 * `index/mode_default_layout.nim` calls "nobody's layout": its third column
 * holds a standing TEST RESULTS stack and a CONSTRAINTS stack, and no
 * CodeTracer mode draws it. Every GUI spec that did not opt out measured it.
 *
 * Two launches of the real Electron app on the `calc` recording:
 *
 *   1. NO LAYOUT OPTION AT ALL — the arrangement on screen is the DEBUG
 *      MODE'S DEFAULT derived from the launched prefix's shipped
 *      `config/default_layout.json` (`lib/layout-stacks.debugDefaultStacks`:
 *      TESTS a tab of the FILES stack, no CONSTRAINTS anywhere), stack for
 *      stack, the runtime-inserted editor aside.
 *   2. `bundledLayout: true` — the opt-in for the specs whose subject is the
 *      raw bundled tree: the arrangement on screen IS that tree, CONSTRAINTS
 *      and the standalone TESTS stack included. This is the positive control:
 *      it shows the two launches differ, and that the first assertion would
 *      notice the bundled tree if the fixture installed it.
 *
 * No mocks: a real recording, the real `ct`, a real `replay-server`, the real
 * Electron app, and the real files the product reads.
 */

import * as path from "node:path";

import { codetracerInstallDir, expect, test } from "../../lib/fixtures";
import {
  ConstraintsContent,
  FilesystemContent,
  TestResultsContent,
  debugDefaultStacks,
  fileStacks,
  hasContent,
  launchedPrefix,
  shippedLayoutFile,
  stackContents,
  stackHolding,
  withoutEditor,
} from "../../lib/layout-stacks";

// THE RECORDING IS MADE BY THE RUN ITSELF, as in
// `plat45-desktop-remembers-own.spec.ts`; `PLAT45_CALC_TRACE` names an
// existing `calc` recording for a host whose recorder cannot record. Which
// recording of `calc` is open does not change the arrangement under test.
const calcProgram = "calc/main.py";
const calcTrace = process.env.PLAT45_CALC_TRACE ?? "";
const recording: { sourcePath: string; launchMode: "trace-folder" | "trace" } = calcTrace === ""
  ? { sourcePath: calcProgram, launchMode: "trace" }
  : { sourcePath: calcTrace, launchMode: "trace-folder" };

// Recording `calc` and starting the app on a contended host: the bound of
// `plat45-desktop-remembers-own.spec.ts`, which launches the same way.
const LaunchTimeoutMs = 300_000;
// The editor's first line is the sign the replay has loaded its layout.
const EditorReadyTimeoutMs = 90_000;

test.describe("the launch fixture's layout", () => {
  test.setTimeout(LaunchTimeoutMs);

  test.describe("a spec that sets no layout option", () => {
    test.use({ ...recording });

    test("opens the product's own first-run layout: the Debug mode's default", async ({ ctPage }) => {
      await ctPage.waitForSelector(".view-line", { timeout: EditorReadyTimeoutMs });
      const live = withoutEditor(await stackContents(ctPage));
      const expected = debugDefaultStacks(fileStacks(shippedLayoutFile(launchedPrefix())));

      // The two properties the issue names, stated on their own so a failure
      // says which one broke before the whole-tree comparison below does.
      expect(hasContent(live, ConstraintsContent), "CONSTRAINTS is placed: the fixture installed the bundled tree")
        .toBe(false);
      const testsStack = stackHolding(live, TestResultsContent);
      expect(testsStack, "TESTS is not placed at all").toBeDefined();
      expect(testsStack, "TESTS is not a tab of the FILES stack").toContain(FilesystemContent);

      expect(live).toEqual(expected);
    });
  });

  test.describe("a spec that opts in with bundledLayout", () => {
    test.use({ ...recording, bundledLayout: true });

    test("opens the bundled tree verbatim", async ({ ctPage }) => {
      await ctPage.waitForSelector(".view-line", { timeout: EditorReadyTimeoutMs });
      const live = withoutEditor(await stackContents(ctPage));
      // What the fixture copies for this option: the source tree's file.
      const bundled = fileStacks(path.join(codetracerInstallDir, "src", "config", "default_layout.json"));

      expect(hasContent(live, ConstraintsContent), "CONSTRAINTS is missing: the opt-in did not install the bundled tree")
        .toBe(true);
      expect(live).toContainEqual([TestResultsContent]);
      expect(live).toEqual(bundled);
      // And it is NOT the Debug mode's default — the two launches differ.
      expect(live).not.toEqual(debugDefaultStacks(bundled));
    });
  });
});
