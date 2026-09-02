/**
 * E2E tests for DeepReview's third pillar: the Agent Activity panel.
 *
 * `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1:
 *
 *   "The Agent Activity panel is the third pillar, not an adjacent
 *    feature... The primary thing the panel shows in a review is **the agent
 *    session that produced it**... There is no 'DeepReview section' in this
 *    panel. The coverage summary, test results row, per-file coverage table
 *    and notification feed that once formed one are removed outright."
 *
 * So what this suite asserts is that the pillar is *there* — present,
 * focused, materialised when a saved layout dropped it — and that it carries
 * no roll-up. Those are the two halves that can fail independently: a pillar
 * that is absent, and a pillar that is back to summarising the dataset.
 *
 * These tests launch `ct review` over `sample-review.json` — no agent
 * process, no ACP session, no live notification stream — so the panel has no
 * session to show either, and showing nothing is the correct behaviour.
 *
 * Headless counterparts (per the headless-first policy in
 * `codetracer-specs/Testing/Testing-Guidelines.md`):
 *   - src/tests/gui/tests/agent-activity-deepreview/
 *       agent_activity_rollup_removal_test.nim  (AA-1's deletion contract)
 *   - src/tests/gui/tests/views/isonim_views_test.nim
 *       ("IsoNim Agent Activity Panel — no DeepReview roll-up (AA-1)")
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
// Since AA-1 those numbers are read on the VCS panel's Changed Files rows,
// which is the only surface that reports them.
test.describe("DeepReview - the Agent Activity panel is the third pillar", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

  test("e2e_review_focuses_the_agent_activity_pillar_and_shows_no_rollup", async ({
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

    // The panel is there, and it carries no roll-up: not the section, not
    // the cards, not the per-file table, not the feed — and not the host div
    // the panel used to reserve for them, which was emitted unconditionally
    // and is therefore what a `.activity-dr-*` check alone would miss.
    await expect(dr.agentActivityPanel()).toBeVisible();
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);

    // The panel claims nothing about a run it never saw.  AA-1 deleted the
    // Tests card that used to say "not available for this dataset"; the rule
    // that card existed for is what outlives it and is asserted here — absent
    // data is never rendered as a zero that reads as success.
    const panelText = (await dr.agentActivityPanel().textContent()) ?? "";
    expect(panelText).not.toContain("all passing");
    expect(panelText).not.toContain("0/0");
    expect(panelText).not.toMatch(/\b0 passed\b/);
    // …and no aggregate either: the changeset's coverage percentage was the
    // roll-up's summary card, and it is per-file on the VCS rows now.
    expect(panelText).not.toContain("83.3%");
  });

  test("e2e_the_review_reports_per_file_coverage_on_the_changed_files_rows", async ({
    ctPage,
  }) => {
    // Where the deleted per-file coverage table's capability went.  It was
    // never the only home of the numbers — `review_entry.changedFileRows`
    // already put the same ratio on the VCS row (VCS-Panel.md, "Changed
    // Files") — which is what made the table safe to delete, and this is the
    // test that says so.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1000);

    const files = await dr.fileItems();
    expect(files.length).toBe(3);
    expect(await files[0].name()).toContain("main.rs");
    expect(await files[0].coverageBadge()).toBe("15/17");
    expect(await files[1].name()).toContain("utils.rs");
    expect(await files[1].coverageBadge()).toBe("5/7");
    // A file the dataset measured nothing for gets no badge at all: "0/0"
    // would read as "measured, and nothing ran".
    expect(await files[2].name()).toContain("config.rs");
    expect(await files[2].coverageBadge()).toBe("");
  });

  test("e2e_selecting_a_changed_file_opens_it_and_moves_only_one_selection", async ({
    ctPage,
  }) => {
    // What is left of §2.1's "two views of one selection" now that there is
    // one view.  The agreement had exactly two participants — the Changed
    // Files list and the coverage table — so deleting the table leaves the
    // list's own selection, which must still work and must still open the
    // file (§3, "clicking a file opens that file's review representation").
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1000);

    const files = await dr.fileItems();
    expect(files.length).toBe(3);
    await files[1].click();
    await wait(500);
    expect(await dr.activeTabTitles()).toContain("Diff: utils.rs");

    await files[0].click();
    await wait(500);
    expect(await dr.activeTabTitles()).toContain("Diff: main.rs");
    // …and no second view of the selection reappeared behind our back.
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
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
  //
  // It is GENERATED, not hand-written.  When that test goes red, regenerate:
  //   bash src/tests/gui/tests/deepreview/fixtures/regenerate-edit-layout-fixture.sh
  // Editing the JSON to make the test pass records today's answer instead of
  // re-deriving it, and the next pane added to `src/config/default_layout.json`
  // desynchronises it again — which is exactly how it went stale once.
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

    // ...and it is a real panel rather than a title with nothing behind it:
    // the panel's own container is present, with the prompt a session would
    // be typed into.  It carries no roll-up (AA-1).
    await expect(dr.agentActivityPanel()).toBeVisible();
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
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

    await expect(dr.agentActivityPanel()).toBeVisible();
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
  });
});
