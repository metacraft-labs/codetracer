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

    // The AGENT ACTIVITY panel is the visible tab of its stack
    // (Layout-System.md "DeepReview and the Layout", obligation 2), so the
    // review's coverage summary is not hidden behind a sibling.
    const activeTitles = await dr.activeTabTitles();
    expect(activeTitles).toContain("AGENT ACTIVITY");

    // ...and nothing was displaced to achieve it (issue #610 / obligation 1):
    // exactly one AGENT ACTIVITY panel, not a second one materialised for the
    // review.
    const allTitles = await dr.layoutTabTitles();
    expect(allTitles.filter((t) => t === "AGENT ACTIVITY").length).toBe(1);

    // RV-2: a dataset review opens the EDITOR layout, so CALLTRACE — which
    // this test used to assert was still present, back when the debugging
    // layout was loaded — must be gone. The panel is the third pillar's
    // stack-mate in the debugging layout only; the pillar itself survives the
    // switch, which is the conflict RV-2 had to resolve and is exactly what
    // the assertions above check.
    expect(allTitles).not.toContain("CALLTRACE");

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

// ---------------------------------------------------------------------------
// The pillar over a layout a PREVIOUS session left behind
// ---------------------------------------------------------------------------

/**
 * Every test above launches into a freshly-created `XDG_CONFIG_HOME`
 * (`lib/fixtures.ts`), so `default_edit_layout.json` does not exist and the
 * review loader takes its fallback: the bundled DEBUGGING layout, sanitised.
 * That layout declares an Agent Activity panel, so the third pillar is always
 * there and the suite above cannot fail for the reason a real user's review
 * fails.
 *
 * Since RV-2 the dataset launch reads `default_edit_layout.json`, and edit
 * mode WRITES that same file through a sanitiser whose hidden set contains
 * `Content.AgentActivity` (`index/config.editModeHiddenContentIds`). One
 * folder opened in edit mode, ever, and the file a review reads holds FILES
 * and VCS and nothing else — no Agent Activity panel to focus, and
 * `focusReviewActivityPane` silently does nothing.
 *
 * These tests launch over a pre-existing file (`editLayoutPath` fixture
 * option) so that case is reachable at all.
 */
test.describe("DeepReview - the third pillar survives a persisted edit layout", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // Byte-for-byte what `index/window.onSaveConfig` writes when an editing
  // session ends — asserted to be exactly that, and kept from drifting, by
  // `test_the_e2e_fixture_is_what_edit_mode_actually_writes` in
  // src/tests/gui/tests/layout/review_layout_test.nim.
  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: sampleReviewPath,
    editLayoutPath: path.join(fixturesDir, "edit-layout-without-agent-activity.json"),
  });

  test("e2e_review_over_a_saved_edit_layout_still_has_agent_activity", async ({
    ctPage,
  }) => {
    // DeepReview-GUI.md §2.1: "The Agent Activity panel is the third pillar,
    // not an adjacent feature." Layout-System.md, "DeepReview and the
    // Layout", obligation 4: "Absent panels are materialised, not
    // substituted."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const allTitles = await dr.layoutTabTitles();
    for (const expected of ["FILES", "VCS", "AGENT ACTIVITY"]) {
      expect(allTitles, `missing review pillar: ${expected}`).toContain(expected);
    }
    // Materialised once, not once per launch step.
    expect(allTitles.filter((t) => t === "AGENT ACTIVITY").length).toBe(1);

    // ...and it is populated from the dataset, which is what makes it a
    // pillar rather than an empty tab that happens to carry the right title.
    await expect(dr.reviewActivitySection()).toBeVisible();
    await expect(dr.reviewActivityCoverageCard()).toContainText("83.3%");
    await expect(dr.reviewActivityFileRows()).toHaveCount(3);
  });

  test("e2e_the_materialised_pillar_does_not_hide_the_vcs_panel", async ({
    ctPage,
  }) => {
    // The trap. The saved edit layout is FILES + VCS in ONE stack, so a
    // pillar added as a tab of "an existing stack" lands next to the VCS
    // panel — and since the activity pane is focused last, it would cover it.
    // DeepReview-GUI.md §2 requires the VCS panel to be the visible tab of
    // whichever stack hosts it when a review starts, and Test 25 in
    // deepreview-gui.spec.ts asserts exactly that.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const activeTitles = await dr.activeTabTitles();
    expect(activeTitles).toContain("VCS");
    expect(activeTitles).toContain("AGENT ACTIVITY");
    await expect(dr.vcsPanel()).toBeVisible();
    await expect(dr.vcsReviewStats()).toContainText("3 files");

    // Nothing the saved layout declared was erased to make room (issue #610).
    const allTitles = await dr.layoutTabTitles();
    expect(allTitles).toContain("FILES");
    // ...and the editor layout's exclusions still hold: materialising the
    // pillar must not drag the debugging layout back in.
    for (const absent of ["CALLTRACE", "EVENT LOG", "TIMELINE", "TERMINAL OUTPUT"]) {
      expect(allTitles, `replay-only panel present in a review: ${absent}`).not.toContain(
        absent,
      );
    }
  });
});

test.describe("DeepReview - a buried Agent Activity panel is brought to the front", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // HONEST SCOPE: unlike the two tests above, this one passes against the
  // code as it stood before this fix as well as after —
  // `focusReviewActivityPane` already existed. It is here because the
  // assertion it strengthens was VACUOUS everywhere else: in every other
  // review layout the Agent Activity panel ends up alone in its stack, where
  // `expect(activeTitles).toContain("AGENT ACTIVITY")` holds no matter what
  // the focus code does. This layout puts the panel BEHIND `FILES` in a
  // shared stack, so the assertion can only pass if the stack was really
  // retargeted — and `expect(activeTitles).not.toContain("FILES")` is the
  // half that proves it.
  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: sampleReviewPath,
    editLayoutPath: path.join(fixturesDir, "edit-layout-agent-activity-buried.json"),
  });

  test("e2e_a_buried_agent_activity_panel_becomes_the_visible_tab", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const activeTitles = await dr.activeTabTitles();
    // The panel shares a stack with FILES and is the SECOND tab, so exactly
    // one of the two can be visible and the review must choose the pillar.
    expect(activeTitles).toContain("AGENT ACTIVITY");
    expect(activeTitles).not.toContain("FILES");
    // The VCS panel has a stack of its own here, so both pillars are visible.
    expect(activeTitles).toContain("VCS");

    // Focus, not relocation: FILES is still there, still in the pillar's
    // stack, and no second Agent Activity panel was materialised beside the
    // one the layout already declared.
    const allTitles = await dr.layoutTabTitles();
    expect(allTitles).toContain("FILES");
    expect(allTitles.filter((t) => t === "AGENT ACTIVITY").length).toBe(1);

    await expect(dr.reviewActivitySection()).toBeVisible();
    await expect(dr.reviewActivityCoverageCard()).toContainText("83.3%");
  });
});
