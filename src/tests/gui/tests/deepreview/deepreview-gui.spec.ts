/**
 * E2E tests for the DeepReview GUI (M3: Local .dr file loading).
 *
 * These tests verify that ``ct review <path>`` correctly loads a DeepReview
 * JSON export file and renders it in the CodeTracer GUI.  (That command
 * replaced the retired ``ct --deepreview <path>`` option; the fixture in
 * ``lib/fixtures.ts`` launches the shipping spelling, so this suite is the
 * end-to-end coverage of it.)
 *
 * Headless counterparts live in
 * ``src/tests/gui/tests/deepreview/``, ``src/tests/gui/tests/vcs/``,
 * ``src/tests/gui/tests/layout/`` and
 * ``src/tests/gui/tests/agent-activity-deepreview/``; per
 * ``codetracer-specs/Testing/Testing-Guidelines.md`` every GUI test here has
 * one.
 *
 * The tests launch CodeTracer in DeepReview mode using a JSON fixture and
 * interact with the three panels a review lives in — the VCS panel, the
 * Editor, and the Agent Activity panel.  DeepReview has no panel of its own
 * (DeepReview-GUI.md §7); the standalone one was deleted in DR-R8.
 *
 * Prerequisites:
 *   - A working ``ct`` Electron build (set CODETRACER_E2E_CT_PATH or use
 *     the default dev build path).
 *   - The JSON fixture files in ``tests/deepreview/fixtures/``.
 */

import { test, expect, wait } from "../../lib/fixtures";
import * as path from "node:path";
import * as fs from "node:fs";

import {
  DIFF_BODY_LINES,
  DeepReviewPage,
} from "./page-objects/deepreview-page";

// ---------------------------------------------------------------------------
// Fixture paths
// ---------------------------------------------------------------------------

const fixturesDir = path.join(__dirname, "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const emptyReviewPath = path.join(fixturesDir, "empty-review.json");
const noCalltracePath = path.join(fixturesDir, "no-calltrace-review.json");
// RV-4 — real output of the MATERIALIZED collector (`replay-server
// review-collect`) over a real Noir recording, produced by
// `fixtures/regenerate-materialized-review.sh`.  The review DOCUMENTS in this
// directory are otherwise hand-written and shaped like the NATIVE collector's
// export; this one is the second collector's actual bytes, which is what makes
// the suite below an end-to-end review over a materialized recording rather
// than another test of the same document.
//
// (`edit-layout-without-agent-activity.json` is generated too, by
// `fixtures/regenerate-edit-layout-fixture.sh`, but it is a LAYOUT rather than
// a review document and no test in this file reads it.)
const materializedReviewPath = path.join(fixturesDir, "materialized-review.json");

// ---------------------------------------------------------------------------
// Skip guard: the fixtures must exist for the tests to be meaningful.
// ---------------------------------------------------------------------------

const fixturesExist =
  fs.existsSync(sampleReviewPath) &&
  fs.existsSync(emptyReviewPath) &&
  fs.existsSync(noCalltracePath) &&
  fs.existsSync(materializedReviewPath);

// Note: expected values in assertions below are derived from the fixture
// data in sample-review.json. If the fixture changes, update the assertions.

// ---------------------------------------------------------------------------
// Test suite: main DeepReview features (uses sample-review.json)
// ---------------------------------------------------------------------------


test.describe("DeepReview GUI - a boundary handle from the keyboard", () => {
  // The rest of this suite is ported to the scenario pack
  // (src/tests/scenarios/deepreview/). This test stays until its scenarios,
  // deepreview/boundary-is-operable-from-the-keyboard.yaml and
  // deepreview/boundary-shift-enter-reveals-the-rest.yaml, have passed.
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");
  test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

  /// Open src/main.rs's diff tab and wait for Monaco to render its lines.
  async function openMainDiffTab(dr: DeepReviewPage) {
    await dr.fileItemByIndex(0).click();
    const tab = dr.diffTabFor("src/main.rs");
    await expect(tab).toBeVisible({ timeout: 20_000 });
    await expect(tab.locator(DIFF_BODY_LINES)).toBeVisible({
      timeout: 20_000,
    });
    return tab;
  }

  /// The tab, once Monaco has collapsed its unchanged regions and
  /// `ui/diff_expansion.nim` has stamped the boundaries it drew.
  async function openMainDiffTabWithBoundary(dr: DeepReviewPage) {
    const tab = await openMainDiffTab(dr);
    await expect
      .poll(async () => await DeepReviewPage.expansionBoundaries(tab).count(), {
        timeout: 20_000,
      })
      .toBeGreaterThan(0);
    return tab;
  }

  test("Test 16e: the boundary is reachable and operable without a mouse", async ({ ctPage }) => {
    // A drag-only control excludes people outright.  Monaco gives `div.top`
    // no `role` and neither handle a `tabindex`, so before UD-2 a reader
    // without a mouse could not reach the boundary at all.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);
    const handle = DeepReviewPage.expandAboveHandle(tab);

    // Focusable, named, and announced as a button.
    await expect(handle).toHaveAttribute("role", "button");
    await expect(handle).toHaveAttribute("tabindex", "0");
    await expect(handle).toHaveAttribute(
      "aria-label",
      /Show 10 more lines above/,
    );
    await handle.focus();
    expect(
      await handle.evaluate((node: Element) => node === document.activeElement),
    ).toBe(true);

    // Enter reveals the same increment a press does ...
    await ctPage.keyboard.press("Enter");
    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(tab))[0], {
        timeout: 15_000,
      })
      .toBe(2);

    // ... and Shift+Enter takes the rest of the file in that direction, which
    // is the keyboard equivalent of the menu's last item.
    await DeepReviewPage.expandAboveHandle(tab).focus();
    await ctPage.keyboard.press("Shift+Enter");
    await expect
      .poll(async () => await DeepReviewPage.expansionBoundaries(tab).count(), {
        timeout: 15_000,
      })
      .toBe(0);
    // The file's last line is now reachable.  Scrolled to, because Monaco
    // renders only the viewport and the whole file no longer fits in it.
    await DeepReviewPage.scrollDiff(ctPage, tab, 2000);
    await expect
      .poll(async () => await DeepReviewPage.diffNewLineNumbers(tab), {
        timeout: 15_000,
      })
      .toContain("25");
  });
});
