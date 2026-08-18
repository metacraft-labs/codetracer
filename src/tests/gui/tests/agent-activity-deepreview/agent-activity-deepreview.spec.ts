/**
 * E2E tests for DeepReview's third pillar: the Agent Activity panel.
 *
 * `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1:
 *
 *   "The Agent Activity panel is the third pillar, not an adjacent feature...
 *    In DeepReview mode the panel gains a DeepReview section showing:
 *    coverage summary, test results, per-file coverage, recent activity...
 *    The section is populated from the same review dataset that drives the
 *    VCS panel and the editor. It must not require a live agent session: a
 *    review launched from the CLI over an exported dataset must populate it
 *    too."
 *
 * These tests launch `ct review` over `sample-review.json` — no agent
 * process, no ACP session, no live notification stream — and assert that the
 * pane is nevertheless populated from the dataset.
 *
 * Headless counterparts (per the headless-first policy in
 * `codetracer-specs/Testing/Testing-Guidelines.md`):
 *   - src/tests/gui/tests/agent-activity-deepreview/
 *       agent_activity_deepreview_vm_test.nim   (population + selection)
 *   - src/tests/gui/tests/views/isonim_views_test.nim
 *       ("... review rendering (DR-R3)" and "... hosts the DeepReview
 *        section (DR-R3)")
 *   - src/tests/gui/tests/layout/deepreview_layout_test.nim
 *       ("the Agent Activity panel becomes the visible tab of its stack")
 */

import { test, expect, wait } from "../../lib/fixtures";
import * as path from "node:path";
import * as fs from "node:fs";

import { DeepReviewPage } from "../deepreview/page-objects/deepreview-page";

const fixturesDir = path.join(__dirname, "..", "deepreview", "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");

const fixturesExist = fs.existsSync(sampleReviewPath);

// Expected values are derived from sample-review.json:
//   src/main.rs    15 of 17 covered lines, has flow
//   src/utils.rs    5 of  7 covered lines, has flow
//   src/config.rs   0 of  0 covered lines, no flow
// => 20 covered / 4 uncovered => 83.3%
test.describe("DeepReview - the Agent Activity panel is the third pillar", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

  test("e2e_review_populates_the_agent_activity_deepreview_section", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1000);

    // The AGENT ACTIVITY panel is the visible tab of its stack. In the
    // bundled layout it sits behind CALLTRACE, so without the focus step
    // (Layout-System.md "DeepReview and the Layout", obligation 2) the
    // review's coverage summary comes up hidden.
    const activeTitles = await dr.activeTabTitles();
    expect(activeTitles).toContain("AGENT ACTIVITY");

    // ...and nothing was displaced to achieve it (issue #610 / obligation 1).
    const allTitles = await dr.layoutTabTitles();
    expect(allTitles).toContain("CALLTRACE");
    expect(allTitles.filter((t) => t === "AGENT ACTIVITY").length).toBe(1);

    // The section renders inside that panel rather than as a panel of its own,
    // and a review opens it rather than leaving it folded away.
    await expect(dr.reviewActivitySection()).toBeVisible();
    await expect(dr.reviewActivitySection()).not.toHaveClass(
      /activity-dr-collapsed/,
    );

    // Coverage summary for the changeset.
    const coverage = await dr.reviewActivityCoverageCard().textContent();
    expect(coverage).toContain("83.3%");
    expect(coverage).toContain("20 covered");
    expect(coverage).toContain("4 uncovered");

    // One coverage row per changed file, in the changeset's order.
    const rows = dr.reviewActivityFileRows();
    await expect(rows).toHaveCount(3);
    await expect(rows.nth(0)).toContainText("main.rs");
    await expect(rows.nth(0)).toContainText("15/17");
    await expect(rows.nth(1)).toContainText("utils.rs");
    await expect(rows.nth(1)).toContainText("5/7");
    await expect(rows.nth(2)).toContainText("config.rs");

    // Review entry left the coverage table on the same file as the VCS
    // panel's Changed Files list (§2.1, "two views of one selection").
    await expect(dr.reviewActivitySelectedFileRow()).toHaveCount(1);
    await expect(dr.reviewActivitySelectedFileRow()).toContainText("main.rs");
  });

  test("e2e_review_test_results_row_says_the_dataset_carries_none", async ({
    ctPage,
  }) => {
    // `DeepReviewData` has no test-result fields at all, so a CLI-launched
    // review has nothing to report here. "0/0 - all passing" would assert
    // that a suite ran and was green (DR-R3, "A data gap to record, not to
    // paper over").
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1000);

    const tests = await dr.reviewActivityTestsCard().textContent();
    expect(tests).toContain("not available for this dataset");
    expect(tests).not.toContain("all passing");
    expect(tests).not.toContain("0/0");
  });

  test("e2e_review_coverage_table_and_vcs_panel_share_one_selection", async ({
    ctPage,
  }) => {
    // §2.1: "Selecting a file in either the VCS panel or the per-file
    // coverage table should agree with the other; they are two views of one
    // selection."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1000);

    // VCS panel -> coverage table.
    const files = await dr.fileItems();
    expect(files.length).toBe(3);
    await files[1].click();
    await wait(500);
    await expect(dr.reviewActivitySelectedFileRow()).toContainText("utils.rs");

    // Coverage table -> VCS panel: clicking a coverage row is the same
    // navigation gesture, so it also opens the file (§3).
    await dr.reviewActivityFileRows().nth(0).click();
    await wait(500);
    await expect(dr.reviewActivitySelectedFileRow()).toContainText("main.rs");
    expect(await dr.activeTabTitles()).toContain("Diff: main.rs");
  });
});
