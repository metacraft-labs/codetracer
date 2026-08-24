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

import { DIFF_BODY, DIFF_BODY_LINES, DeepReviewPage } from "./page-objects/deepreview-page";

// ---------------------------------------------------------------------------
// Fixture paths
// ---------------------------------------------------------------------------

const fixturesDir = path.join(__dirname, "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const emptyReviewPath = path.join(fixturesDir, "empty-review.json");
const noCalltracePath = path.join(fixturesDir, "no-calltrace-review.json");
// RV-4 — real output of the MATERIALIZED collector (`replay-server
// review-collect`) over a real Noir recording, produced by
// `fixtures/regenerate-materialized-review.sh`.  Every other fixture in this
// directory is hand-written and shaped like the NATIVE collector's export;
// this one is the second collector's actual bytes, which is what makes the
// suite below an end-to-end review over a materialized recording rather than
// another test of the same document.
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

test.describe("DeepReview GUI - main features", () => {
  // Skip the entire suite if fixtures are missing (e.g. in a checkout
  // that hasn't pulled the test data yet).
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // Launch CodeTracer in DeepReview mode for each test in this suite.
  test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

  // -----------------------------------------------------------------------
  // Test 1: CLI argument parsing
  // -----------------------------------------------------------------------

  // Retargeted in DR-R8 from the deleted panel's own header
  // (`.deepreview-container` / `.deepreview-commit` / `.deepreview-stats`) to
  // the VCS panel, which DeepReview-GUI.md §2 makes the owner of "Session
  // title / stats" and §3 the owner of the Changed Files header that names
  // the reviewed commit.
  //
  // One assertion changed rather than moved: the panel's stats line read
  // "3 files | 2 recordings | 1542ms", and the VCS header's reads
  // "3 files +16 -10".  That is DR-R2's recorded decision — "The stats line
  // reports two numbers, not four" — because a review dataset's recording
  // count and collection time describe how the dataset was *made*, not what
  // the changeset is.  The two numbers that describe the changeset are
  // asserted here and in Test 24.
  //
  // Headless counterparts:
  //   test_vcs_changed_files_header_names_the_reviewed_commit in
  //   src/tests/gui/tests/vcs/vcs_view_test.nim, and
  //   test_review_entry_puts_the_commit_in_the_vcs_header in
  //   src/tests/gui/tests/deepreview/deepreview_entry_test.nim.
  test("Test 1: a review names its commit and its changeset in the VCS panel", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    await expect(dr.vcsPanel()).toBeVisible();

    // §3: "The section header shows the review's file count and ... the
    // commit it belongs to."  The fixture's commitSha, abbreviated.
    const commitText = await dr
      .vcsPanel()
      .locator(".vcs-changed-files-commit")
      .textContent();
    expect(commitText).toBeTruthy();
    expect(commitText).toContain("a1b2c3d4e5f6...");
    expect(commitText).toContain("3 files");

    // §2: "Session title / stats | The VCS panel header".
    const statsText = await dr.vcsReviewStats().textContent();
    expect(statsText).toContain("3 files");
    expect(statsText).toContain("+16 -10");
  });

  // -----------------------------------------------------------------------
  // Test 1b: A review over a dataset opens the EDITOR layout
  // -----------------------------------------------------------------------

  test("Test 1b: a dataset review opens the editor layout", async ({ ctPage }) => {
    // RV-2 (DeepReview-GUI.md §1.1): "`ct review` opens the editor layout, not
    // the debugging layout ... The editor layout omits the panels a dataset
    // cannot populate (EVENT LOG, CALLTRACE, TIMELINE, TERMINAL OUTPUT), so a
    // review does not present empty panels that imply missing data."
    //
    // This test used to assert the opposite — that all nine panels of the
    // DEBUGGING layout survived — as the end-to-end half of issue #610, whose
    // subject was a hard-coded three-panel preset that erased the user's
    // layout. That subject survives intact and is asserted below: nothing is
    // erased, the review's own three surfaces are all present, and no bespoke
    // review panel is installed. What changed is which layout is loaded in the
    // first place, and #610's guarantee is now carried by the editor layout
    // being a real user layout rather than a preset invented for reviews.
    //
    // Headless counterparts:
    //   src/tests/gui/tests/layout/review_layout_test.nim (which layout)
    //   src/tests/gui/tests/layout/deepreview_layout_test.nim (what a review
    //   does to whatever layout it is given)
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1000);

    const titles = await dr.layoutTabTitles();

    // DeepReview's three pillars, all present (DeepReview-GUI.md §7). The
    // Editor is the diff tab the review opened, asserted by its own tests.
    for (const expected of ["FILES", "VCS", "AGENT ACTIVITY"]) {
      expect(titles, `missing review panel: ${expected}`).toContain(expected);
    }

    // The panels `ct review` cannot fill are not on screen at all, rather
    // than on screen and empty.
    for (const absent of [
      "CALLTRACE",
      "EVENT LOG",
      "TIMELINE",
      "TERMINAL OUTPUT",
    ]) {
      expect(titles, `replay-only panel present in a review: ${absent}`).not.toContain(
        absent,
      );
    }

    // ...and NO review surface, because DeepReview introduces no panel of its
    // own (DeepReview-GUI.md §7: "There is no separate 'DeepReview mode' that
    // replaces the UI").  This assertion was `.toBe(1)` until DR-R8 deleted
    // the panel; it is the same guard pointed the other way.
    expect(titles.filter((t) => t === "DEEP REVIEW").length).toBe(0);

    // The mode switcher is the VCS panel's view mode toggle (§2: "Mode
    // switcher | The VCS panel's view mode toggle"), which DR-R1 made render
    // in review mode.
    await expect(dr.modeToggle()).toBeVisible();
  });

  // -----------------------------------------------------------------------
  // Test 1c: no selector of the deleted panel resolves
  // -----------------------------------------------------------------------

  // e2e_no_deepreview_panel_selectors_resolve.
  //
  // Test 1b asserts the review adds no TAB; this asserts it renders no
  // element of the deleted panel anywhere in the document, and — in the same
  // breath — that the Agent Activity panel, whose Content id has a nearly
  // identical name and which is the review's third pillar (§2.1), is still
  // there.  Falsifiable before DR-R8: all four selectors resolved.
  //
  // Since AA-1 the panel carries no roll-up either, so the second assertion
  // is now "present, and empty of one" rather than "present, and populated".
  //
  // Headless counterparts:
  //   test_review_startup_adds_no_review_panel in
  //   src/tests/gui/tests/layout/deepreview_layout_test.nim, and
  //   test_the_content_id_and_its_component_survive in
  //   src/tests/gui/tests/agent-activity-deepreview/agent_activity_rollup_removal_test.nim.
  test("Test 1c: no standalone DeepReview panel selector resolves", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    for (const selector of [
      ".deepreview-container",
      ".deepreview-file-list",
      ".deepreview-calltrace",
      ".deepreview-inline-value",
      // The panel's own header, diff renderer, sliders and mode toggle went
      // with it; each capability's new home is asserted by its own test.
      ".deepreview-header",
      ".deepreview-unified-diff",
      ".deepreview-slider",
      ".deepreview-mode-toggle",
    ]) {
      await expect(
        ctPage.locator(selector),
        `deleted DeepReview panel selector still resolves: ${selector}`,
      ).toHaveCount(0);
    }

    // The panel's test hooks went with it too — nothing may still be driving
    // a deleted surface from `window`.
    const hooks = await ctPage.evaluate(() =>
      [
        "__deepreviewSetViewMode",
        "__deepreviewSetExecution",
        "__deepreviewSetIteration",
        "__deepreviewSetTraceContext",
        "__deepreviewExpandAbove",
        "__deepreviewExpandBelow",
      ].filter((name) => typeof (window as never as Record<string, unknown>)[name] === "function"),
    );
    expect(hooks).toEqual([]);

    // ...and the OTHER DeepReview — the Agent Activity panel, a different
    // Content id with a nearly identical name — is still the review's third
    // pillar, now showing the session rather than a roll-up (§2.1, AA-1).
    await expect(dr.agentActivityPanel()).toBeVisible();
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
  });

  // -----------------------------------------------------------------------
  // Test 2: File list sidebar rendering
  // -----------------------------------------------------------------------

  test("Test 2: file list sidebar shows all files with correct basenames", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();
    expect(items.length).toBe(3);

    // The list must be VISIBLE when the review opens, not merely present in
    // the DOM. DeepReview-GUI.md §2 lists the "Modified Files panel" as a
    // shared workspace element whose purpose is to "Navigate within the
    // review set", drawn beside the review surface; §3 makes it "shared by
    // both DeepReview modes"; §5.2 states "Full Files Mode relies on the
    // Modified Files panel for cross-file navigation"; and §7's startup
    // sequence begins "1. The VCS panel populates with the changeset data".
    //
    // Regression: additive layout placement (issue #610 / M42a) left the VCS
    // panel as the *inactive* second tab behind FILES, so every
    // `.vcs-file-item` rendered under `display: none`. Reading textContent
    // still worked — which is why this test passed — but nothing could be
    // clicked, and Tests 5, 22 and DR-8 timed out on "element is not
    // visible". Fixed in viewmodel/viewmodels/deepreview_layout.nim
    // (`focusReviewFileList`); headless counterpart in
    // src/tests/gui/tests/layout/deepreview_layout_test.nim.
    await expect(dr.fileList()).toBeVisible();
    for (const item of items) {
      await expect(item.root).toBeVisible();
    }

    const expectedBasenames = ["main.rs", "utils.rs", "config.rs"];
    for (let i = 0; i < expectedBasenames.length; i++) {
      const name = await items[i].name();
      expect(name).toBe(expectedBasenames[i]);
    }

    const firstSelected = await items[0].isSelected();
    expect(firstSelected).toBe(true);

    const secondSelected = await items[1].isSelected();
    expect(secondSelected).toBe(false);
    const thirdSelected = await items[2].isSelected();
    expect(thirdSelected).toBe(false);
  });

  // -----------------------------------------------------------------------
  // Test 2b: Diff status indicators on file list items
  // -----------------------------------------------------------------------

  test("Test 2b: file list items show diff status indicators with correct labels", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();
    expect(items.length).toBe(3);

    // src/main.rs is Modified ("M")
    const mainStatus = await items[0].diffStatus();
    expect(mainStatus).toBe("M");

    // src/utils.rs is Added ("A")
    const utilsStatus = await items[1].diffStatus();
    expect(utilsStatus).toBe("A");

    // src/config.rs is Deleted ("D")
    const configStatus = await items[2].diffStatus();
    expect(configStatus).toBe("D");
  });

  // -----------------------------------------------------------------------
  // Test 2c: Diff status styling (colour classes)
  // -----------------------------------------------------------------------

  test("Test 2c: diff status indicators have correct colour classes", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();

    // VCS panel uses vcs-status-* classes instead of deepreview-diff-* classes.
    const mainClasses = await items[0].diffStatusClasses();
    expect(mainClasses).toContain("vcs-status-modified");

    const utilsClasses = await items[1].diffStatusClasses();
    expect(utilsClasses).toContain("vcs-status-added");

    const configClasses = await items[2].diffStatusClasses();
    expect(configClasses).toContain("vcs-status-deleted");
  });

  // -----------------------------------------------------------------------
  // Test 2d: Modified line counts
  // -----------------------------------------------------------------------

  test("Test 2d: file list items show added/removed line counts", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const items = await dr.fileItems();

    // src/main.rs: +8 / -3
    const mainLines = await items[0].diffLines();
    expect(mainLines).toContain("+8");
    expect(mainLines).toContain("-3");

    // src/utils.rs: +8 / -0 (UI omits zero counts)
    const utilsLines = await items[1].diffLines();
    expect(utilsLines).toContain("+8");
    expect(utilsLines).not.toContain("-");

    // src/config.rs: +0 / -7 (UI omits zero counts)
    const configLines = await items[2].diffLines();
    expect(configLines).not.toContain("+");
    expect(configLines).toContain("-7");
  });

  // -----------------------------------------------------------------------
  // Tests 3 and 4 were deleted with the panel (DR-R8)
  // -----------------------------------------------------------------------
  //
  // "Test 3: coverage decorations are applied to the editor" and "Test 4:
  // inline variable values appear as decorations" both drove the standalone
  // panel's private Monaco instance, and both were `test.skip` on M42b.
  //
  // Neither capability is lost, and neither belonged here:
  //
  //   * Coverage is the Agent Activity panel's (DeepReview-GUI.md §2.1,
  //     "Coverage summary ... Per-file coverage"), asserted by Test 25 below
  //     and by tests/agent-activity-deepreview/agent-activity-deepreview.spec.ts.
  //     The `deepreview-line-executed` / `-unreachable` Monaco decorations the
  //     deleted test looked for still exist, drawn by `ui/agent_workspace.nim`
  //     over the agent's workspace editor, and are located by
  //     tests/agentic-coding/page-objects/agentic-page.ts.
  //   * Inline values as `// x = 10` text comments are FORBIDDEN — §7: "The
  //     inline variable values MUST NOT be rendered as text comments ... they
  //     must use the standard CodeTracer Omniscience visual style".  Test 4
  //     asserted exactly the forbidden rendering.  The correct one is DR-R6's,
  //     blocked on M42b.

  // -----------------------------------------------------------------------
  // Test 5: File switching
  // -----------------------------------------------------------------------

  // e2e_review_click_opens_editor_tab — the rewrite of "Test 5: clicking a
  // file in the VCS panel updates selection" (DR-R1).
  //
  // The selection assertions are kept: they are still correct. What they were
  // missing is the part the reviewer actually needs — DeepReview-GUI.md §3:
  // "Clicking a file **opens it in the editor** ... Clicking must not merely
  // change a selection index". Before DR-R1 a click set
  // `deepReviewSelectedFileIndex` and returned, so every file in the review
  // could be clicked and nothing ever opened.
  //
  // Headless counterparts: test_vcs_open_action_in_review_mode_opens_diff_tab,
  // test_vcs_open_action_follows_view_mode_in_review_mode and
  // test_vcs_open_action_for_deleted_file in
  // src/tests/gui/tests/vcs/vcs_vm_test.nim.
  test("Test 5: clicking a file in the VCS panel opens it in the editor", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const firstItem = dr.fileItemByIndex(0);
    expect(await firstItem.isSelected()).toBe(true);

    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();

    await wait(1000);

    expect(await secondItem.isSelected()).toBe(true);
    expect(await firstItem.isSelected()).toBe(false);

    // ...and the click opened that file, in the representation the view-mode
    // toggle selects (Unified Diff is the default, VCS-Panel.md
    // `vcs.defaultView`).
    const secondTitle = DeepReviewPage.diffTabTitle("src/utils.rs");
    expect(await dr.layoutTabTitles()).toContain(secondTitle);
    expect(await dr.activeTabTitles()).toContain(secondTitle);
    await expect(dr.diffTabFor("src/utils.rs")).toBeVisible();

    await firstItem.click();
    await wait(1000);
    expect(await firstItem.isSelected()).toBe(true);

    const firstTitle = DeepReviewPage.diffTabTitle("src/main.rs");
    expect(await dr.activeTabTitles()).toContain(firstTitle);
    await expect(dr.diffTabFor("src/main.rs")).toBeVisible();

    // Re-opening a file that is already open focuses its tab instead of
    // opening a second one (DR-R1).
    await secondItem.click();
    await wait(1000);
    const titles = await dr.layoutTabTitles();
    expect(titles.filter((t) => t === secondTitle).length).toBe(1);
    expect(titles.filter((t) => t === firstTitle).length).toBe(1);
  });

  // e2e_review_opens_a_file_on_startup (DR-R1).
  //
  // DeepReview-GUI.md §7, "Transition into a Review", step 2: "The first
  // modified file opens in the editor with unified diff view." `--deepreview`
  // used to build the layout and stop, so a review began with an empty editor.
  //
  // Headless counterpart: test_review_start_opens_first_modified_file in
  // src/tests/gui/tests/deepreview/deepreview_vm_test.nim.
  test("Test 5b: a review opens its first modified file on startup", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const firstTitle = DeepReviewPage.diffTabTitle("src/main.rs");
    expect(await dr.layoutTabTitles()).toContain(firstTitle);
    expect(await dr.activeTabTitles()).toContain(firstTitle);

    // The tab shows that file's review diff, not an empty git diff.
    await expect(dr.diffTabFor("src/main.rs")).toBeVisible();

    // ...and the VCS panel's list agrees with the editor.
    expect(await dr.fileItemByIndex(0).isSelected()).toBe(true);

    // Exactly one document, for the first file only: startup opens the first
    // modified file, not the whole changeset.
    expect(await dr.diffTabs().count()).toBe(1);
  });

  // -----------------------------------------------------------------------
  // Tests 6 and 7 were deleted with the panel (DR-R8)
  // -----------------------------------------------------------------------
  //
  // "Test 6: execution slider navigates between function executions" and
  // "Test 7: loop slider is visible and navigable for files with loops" drove
  // `.deepreview-slider` through `window.__deepreviewSetExecution` /
  // `__deepreviewSetIteration`.  Both were `test.skip` on M42b.
  //
  // The sliders were the panel's execution-index and iteration selectors, and
  // DR-R8's inventory lists them as deleted "subject to DR-R6a's decision on
  // where the invocation selector lives".  DR-R6 is blocked on M42b — the
  // data behind them is not loaded at all — so there is nothing to retarget
  // them at yet, and a review's flow overlays are DR-R6's deliverable.

  // -----------------------------------------------------------------------
  // Tests 10-12: the review's unified diff, as a Monaco tab (DR-R4)
  // -----------------------------------------------------------------------
  //
  // e2e_review_unified_diff_shows_hunks_in_monaco.
  //
  // These three are the DR-R4 rewrite of "Test 10: unified diff shows file
  // headers", "Test 11: added and removed lines with correct classes" and
  // "Test 12: multiple file sections in a scrollable view".  All three used to
  // assert on the standalone panel's DOM diff (`deepreview-unified-*`
  // elements); they now assert on the editor tab a review opens, which
  // VCS-Panel.md and DeepReview-GUI.md §4 both require to be "the standard
  // CodeTracer Monaco editor".
  //
  // Test 12's premise changes with the surface: one tab per file means there
  // is no multi-file scroll to assert.  It becomes "opening a second file
  // yields a second tab, and both remain open", which is what §4.1 says
  // instead ("Each diff tab shows a single file... a review does not
  // concatenate every file into one scrolling document").
  //
  // Headless counterparts: test_diff_decorations_classify_added_removed_context,
  // test_diff_dual_line_numbers and test_diff_decorations_are_mode_agnostic in
  // src/tests/gui/tests/vcs/vcs_diff_decorations_test.nim.

  /// Open the review file at ``index`` and wait for its Monaco tab to render.
  async function openReviewDiffTab(
    dr: DeepReviewPage,
    index: number,
    filePath: string,
  ) {
    await dr.fileItemByIndex(index).click();
    const tab = dr.diffTabFor(filePath);
    await expect(tab).toBeVisible({ timeout: 20_000 });
    // The MODIFIED side is the one the unified diff view renders into: since
    // UD-1 the tab holds a `.monaco-diff-editor` with two code editors, and
    // the old revision's deleted lines are drawn as `.view-lines line-delete`
    // view zones inside this one.  Naming it explicitly is not just strict-mode
    // hygiene — an unscoped `.monaco-editor .view-lines` matches four elements
    // here, and one of them is the *other* revision.
    await expect(
      tab.locator(DIFF_BODY_LINES),
    ).toBeVisible({ timeout: 20_000 });
    return tab;
  }

  test("Test 10: the review's diff tabs are Monaco documents headed by their file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // DeepReview-GUI.md §4.1: "Each diff tab includes: A file header with path
    // and diff metadata".  All 3 files in the fixture have hunks, so each
    // opens a tab headed by that file.
    //
    // The header is DOM chrome above the editor since UD-2, not line 1 of the
    // model: with `hideUnchangedRegions` on, line 1 is exactly what a
    // collapsed run at the top of a file hides, so a header left in the model
    // would be visible only on files whose first change is near the top.
    for (const [index, filePath] of [
      [0, "src/main.rs"],
      [1, "src/utils.rs"],
      [2, "src/config.rs"],
    ] as [number, string][]) {
      const tab = await openReviewDiffTab(dr, index, filePath);
      // A real editor, not a DOM diff.
      // Two code editors since UD-1 — the diff editor's two sides — so the
      // one the unified view renders into is named rather than assumed.
      await expect(tab.locator(DIFF_BODY)).toBeVisible();
      const header = DeepReviewPage.fileHeaders(tab);
      await expect(header).toHaveCount(1, { timeout: 15_000 });
      await expect(header).toBeVisible();
      await expect(header.locator(".unified-diff-file-header-path")).toHaveText(
        filePath,
      );
    }
  });

  test("Test 11: the review's diff lines carry added / removed / context decorations", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // Per-file counts from sample-review.json.  The old test summed them
    // because one DOM view concatenated every file; with one tab per file the
    // same 16 added / 10 removed / 2 context lines are asserted where they
    // belong.
    //
    // UD-2 made the models the whole file, so the context lines RENDERED are
    // the ones `hideUnchangedRegions` leaves on screen rather than the two the
    // hunk itself carries — which is why main.rs's context is a floor and a
    // ceiling rather than an exact count.  The added and removed counts stay
    // exact: a change is never collapsed, so all of them are always on screen,
    // and that is the property this test is about.
    const expected: [number, string, number, number, number, number][] = [
      [0, "src/main.rs", 8, 3, 2, 25],
      [1, "src/utils.rs", 8, 0, 0, 0],
      [2, "src/config.rs", 0, 7, 0, 0],
    ];

    // UD-1 split the one model in two, so each class is counted on the side it
    // belongs to: additions exist only in the new revision, removals only in
    // the old one, and the context and the chrome exist identically in both
    // (which is what makes Monaco treat them as unchanged and draw them once).
    // Counting them unscoped would sum the two sides and silently accept a
    // build that put an addition in the old revision.
    for (const [
      index,
      filePath,
      added,
      removed,
      minContext,
      maxContext,
    ] of expected) {
      const tab = await openReviewDiffTab(dr, index, filePath);
      const modified = tab.locator(
        ".monaco-editor.modified-in-monaco-diff-editor .view-overlays",
      );
      const original = tab.locator(
        ".monaco-editor.original-in-monaco-diff-editor .view-overlays",
      );
      await expect
        .poll(async () => await modified.locator(".ct-diff-line-added").count(), {
          timeout: 15_000,
        })
        .toBe(added);
      expect(await modified.locator(".ct-diff-line-removed").count()).toBe(0);
      expect(await original.locator(".ct-diff-line-removed").count()).toBe(
        removed,
      );
      expect(await original.locator(".ct-diff-line-added").count()).toBe(0);
      const modifiedContext = await modified
        .locator(".ct-diff-line-context")
        .count();
      expect(modifiedContext).toBeGreaterThanOrEqual(minContext);
      expect(modifiedContext).toBeLessThanOrEqual(maxContext);
      const originalContext = await original
        .locator(".ct-diff-line-context")
        .count();
      expect(originalContext).toBeGreaterThanOrEqual(minContext);
      expect(originalContext).toBeLessThanOrEqual(maxContext);
      // Exactly one hunk per file in the fixture, rendered as a section
      // divider (VCS-Panel.md: "Hunk headers (@@ -N,M +N,M @@) shown as
      // section dividers") — on both sides, so it anchors the comparison
      // instead of reading as an inserted line.
      expect(await modified.locator(".ct-diff-line-hunk-header").count()).toBe(1);
      expect(await original.locator(".ct-diff-line-hunk-header").count()).toBe(1);

      // ...and the `+` / `-` gutter markers VCS-Panel.md requires, each in the
      // margin of the revision that has those lines.
      expect(
        await tab
          .locator(".modified-in-monaco-diff-editor .margin-view-overlays")
          .locator(".ct-diff-gutter-added")
          .count(),
      ).toBe(added);
      expect(
        await tab
          .locator(".original-in-monaco-diff-editor .margin-view-overlays")
          .locator(".ct-diff-gutter-removed")
          .count(),
      ).toBe(removed);
    }
  });

  // -----------------------------------------------------------------------
  // RV-5: the flow overlay, from the dataset.
  //
  // Tests 26 and 29-31 replace Tests 17 and 18 ("omniscience inline values
  // appear on unified diff lines" / "... match the flow data"), which DR-R8
  // deleted along with the standalone panel that hosted them.
  //
  // Those two tests were RIGHT about what to assert: they read the standard
  // `.deepreview-flow-values` chips — `flow-parallel-value-name` plus
  // `flow-parallel-value-box` — **by content** against the fixture (`<x>`,
  // `10`, `<y>`, `20`, `<result>`, `55`, `<trimmed>`).  They were never the
  // text-comment rendering §4.4 forbids; that was `deepreview-inline-value`, a
  // separate `after:`-content decoration built by
  // `ui/deepreview.buildInlineValueDecorations` as `"  // x = 10, y = 20"`,
  // which DR-R8 deleted and nothing has restored.
  //
  // So the content-level assertions are restored here rather than replaced by
  // counts: a count cannot distinguish the selected invocation's values from
  // another call's, which is the whole point of the selector.  The chips now
  // reach the line as Monaco injected text carrying the debugger's own classes
  // (§7, "Monaco decorations with the flow annotation classes"), driven by the
  // dataset rather than by a loaded recording.
  //
  // Tests 27, 28 and 31 are new coverage 17/18 never had: which *call*, and
  // which *pass through a loop*, the values describe.
  //
  // Headless counterparts:
  //   deepreview/deepreview_flow_adapter_test.nim  — the FlowUpdate
  //   deepreview/review_flow_overlay_test.nim      — the mapping, the values
  //                                                  and the two controls
  //   editor/flow_line_styles_test.nim             — the classes and the guard
  // -----------------------------------------------------------------------

  test("Test 26: a review's diff lines carry the standard Omniscience flow classes", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    const lines = tab.locator(DIFF_BODY_LINES);

    // `main`'s first invocation runs on lines 1-4 and 10; the hunk shows 2-11,
    // so four of those five lines are on screen and get `line-flow-hit`.  The
    // rest of the function's visible lines get `line-flow-skip`, because a
    // dataset is a finished window.
    await expect
      .poll(async () => await lines.locator(".line-flow-hit").count(), {
        timeout: 20_000,
      })
      .toBeGreaterThan(0);
    expect(await lines.locator(".line-flow-skip").count()).toBeGreaterThan(0);

    // §4.4: "Inline variable values MUST NOT be rendered as text comments."
    // The deleted panel drew `  // x = 10, y = 20` as an after-content
    // decoration with this class; neither may come back.
    expect(await tab.locator(".deepreview-inline-value").count()).toBe(0);
    const text = (await lines.innerText()) ?? "";
    expect(text).not.toContain("// x = ");

    // ...and §4.4's other half — "Preserve existing interaction patterns such
    // as loop sliders and inline values" — is not satisfied by an empty
    // overlay.  The values must actually be on the page, in the standard
    // classes.  Tests 29-31 assert *which* values; this asserts that the
    // rendering exists at all, which is what a review with zero chips failed.
    await expect
      .poll(
        async () => await DeepReviewPage.flowValueChips(tab).count(),
        { timeout: 20_000 },
      )
      .toBeGreaterThan(0);
    expect(await DeepReviewPage.flowValueNames(tab).count()).toBeGreaterThan(0);
    expect(await DeepReviewPage.flowValueBoxes(tab).count()).toBe(
      await DeepReviewPage.flowValueNames(tab).count(),
    );
    // The chips carry the debugger's own classes, so a normal-debugging
    // consumer looking for a flow value box finds a review's too (§7,
    // "the flow annotations in DeepReview look identical to flow annotations
    // during normal debugging").
    expect(
      await tab.locator(".view-lines .flow-parallel-value-box").count(),
    ).toBeGreaterThan(0);
    expect(
      await tab.locator(".view-lines .ct-omni-name").count(),
    ).toBeGreaterThan(0);
  });

  test("Test 29: the inline values are the ones the fixture recorded", async ({ ctPage }) => {
    // The content-level assertion the deleted Test 18 made, restored.  From
    // `sample-review.json`, `main` execution 0:
    //   line 2  x = 10
    //   line 3  x = 10, y = 20
    //   line 4  result = 55
    //   line 10 result = 55
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    await expect
      .poll(
        async () => await DeepReviewPage.flowValueChips(tab).count(),
        { timeout: 20_000 },
      )
      .toBeGreaterThan(0);

    const combined = await DeepReviewPage.flowValueText(tab);
    expect(combined).toContain("<x>");
    expect(combined).toContain("10");
    expect(combined).toContain("<y>");
    expect(combined).toContain("20");
    expect(combined).toContain("<result>");
    expect(combined).toContain("55");

    // And `src/utils.rs`'s own values, which live in a second tab now that a
    // review is the editor rather than one panel listing every file.
    const utils = await openReviewDiffTab(dr, 1, "src/utils.rs");
    await expect
      .poll(
        async () => await DeepReviewPage.flowValueChips(utils).count(),
        { timeout: 20_000 },
      )
      .toBeGreaterThan(0);
    const utilsText = await DeepReviewPage.flowValueText(utils);
    expect(utilsText).toContain("<trimmed>");
    expect(utilsText).toContain("hello world");
    // The collector truncated `input`, and the marker it cut with survives to
    // the screen rather than being silently dropped.
    expect(utilsText).toContain("<input>");
    expect(utilsText).toContain("...");
  });

  test("Test 30: stepping the selector switches the values, not just the classes", async ({ ctPage }) => {
    // Call 1 of `main` computes 55 from x = 10; call 2 computes 903 from
    // x = 42.  Asserting the values — rather than only the hit count, as
    // Test 28 does — is what proves the overlay follows the selector all the
    // way down to what was recorded.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    const selector = DeepReviewPage.invocationSelectors(tab).first();
    await expect(selector).toBeVisible({ timeout: 20_000 });
    await expect
      .poll(async () => await DeepReviewPage.flowValueText(tab), {
        timeout: 20_000,
      })
      .toContain("<x>");

    expect(await DeepReviewPage.flowValueText(tab)).toContain("10");
    expect(await DeepReviewPage.flowValueText(tab)).toContain("55");
    expect(await DeepReviewPage.flowValueText(tab)).not.toContain("42");

    await selector.locator(".review-invocation-next").click();
    await expect(selector.locator(".review-invocation-label")).toHaveText(
      "main: call 2 / 2",
      { timeout: 10_000 },
    );
    await expect
      .poll(async () => await DeepReviewPage.flowValueText(tab), {
        timeout: 20_000,
      })
      .toContain("42");
    const secondCall = await DeepReviewPage.flowValueText(tab);
    expect(secondCall).toContain("84");
    expect(secondCall).toContain("903");
    // Call 2 never reached line 10, so its `result = 55` strip is gone rather
    // than left behind from the previous invocation.
    expect(secondCall).not.toContain("55");

    await selector.locator(".review-invocation-prev").click();
    await expect(selector.locator(".review-invocation-label")).toHaveText(
      "main: call 1 / 2",
      { timeout: 10_000 },
    );
    await expect
      .poll(async () => await DeepReviewPage.flowValueText(tab), {
        timeout: 20_000,
      })
      .toContain("55");
  });

  test("Test 31: the loop control picks which pass through the loop is shown", async ({ ctPage }) => {
    // §4.4: "Preserve existing interaction patterns such as loop sliders and
    // inline values."  `compute` is the fixture's only looping function, on
    // lines 14-20.  Since UD-2 those lines are in the model from the start —
    // the model is the whole file — but they sit inside the run Monaco
    // collapses below the hunk, so the boundary is pressed to bring them on
    // screen first.  It recorded three passes over the header line 16:
    //   pass 1  i = 0, acc = 0
    //   pass 2  i = 1, acc = 1
    //   pass 3  i = 2, acc = 3
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    await expect
      .poll(async () => await DeepReviewPage.expansionBoundaries(tab).count(), {
        timeout: 20_000,
      })
      .toBeGreaterThan(0);
    await DeepReviewPage.expandAboveHandle(tab).click();

    const loop = DeepReviewPage.loopSelectors(tab).first();
    await expect(loop).toBeVisible({ timeout: 20_000 });
    await expect(loop.locator(".review-loop-label")).toHaveText(
      "iteration 1 / 3",
    );
    // It is an in-editor control, like the invocation selector above it and
    // like the loop slider it is modelled on — not a panel affordance.
    expect(await ctPage.locator(".review-loop-selector").count()).toBe(
      await DeepReviewPage.loopSelectors(tab).count(),
    );

    await expect
      .poll(async () => await DeepReviewPage.flowValueText(tab), {
        timeout: 20_000,
      })
      .toContain("<i>");
    expect(await DeepReviewPage.flowValueText(tab)).toContain("<acc>");
    const firstPassText = await DeepReviewPage.flowValueText(tab);
    const firstPassChips = await DeepReviewPage.flowValueChips(tab).count();

    await loop.locator(".review-loop-next").click();
    await expect(loop.locator(".review-loop-label")).toHaveText(
      "iteration 2 / 3",
      { timeout: 10_000 },
    );
    await loop.locator(".review-loop-next").click();
    await expect(loop.locator(".review-loop-label")).toHaveText(
      "iteration 3 / 3",
      { timeout: 10_000 },
    );
    // Pass 3 recorded `acc = 3` on the header, a value no other pass carries.
    await expect
      .poll(async () => await DeepReviewPage.flowValueText(tab), {
        timeout: 20_000,
      })
      .toContain("3");
    const thirdPassText = await DeepReviewPage.flowValueText(tab);
    expect(thirdPassText).not.toEqual(firstPassText);

    // The body line `acc += i;` ran on passes 1 and 2 only, so pass 3 leaves it
    // BARE rather than repeating pass 2's values under a "iteration 3 / 3"
    // label.  That is the property that makes one strip per line honest, and it
    // is visible as strictly fewer chips than pass 1 drew — the loop's header
    // still carries its pair, so this cannot pass by the whole overlay
    // vanishing.
    expect(await DeepReviewPage.flowValueChips(tab).count()).toBeLessThan(
      firstPassChips,
    );
    expect(thirdPassText).toContain("<i>");
    expect(thirdPassText).toContain("<acc>");

    // Clamped at the far end, exactly as the invocation selector is.
    await expect(loop.locator(".review-loop-next")).toBeDisabled();
    await loop.locator(".review-loop-prev").click();
    await expect(loop.locator(".review-loop-label")).toHaveText(
      "iteration 2 / 3",
      { timeout: 10_000 },
    );
  });

  test("Test 30: the review's diff editor wears CodeTracer's own Monaco theme", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");

    // DeepReview-GUI.md §5.3 — a review reuses the debugger's own surfaces
    // rather than restyling them, so the diff tab must look like every other
    // CodeTracer editor.
    //
    // Monaco stamps the ACTIVE theme's base onto the editor root as a class:
    // `vs-dark` for `codetracerDark` (whose `base` is `vs-dark`), and a bare
    // `vs` when the requested theme name was never registered and Monaco
    // silently fell back to its built-in light default. That fallback is what
    // the assertion below rules out: `initEditor` asks for `codetracerDark` by
    // NAME, and a name nobody defined is not an error in Monaco — it is a
    // light editor with a white minimap in a dark application.
    //
    // The class is the observable rather than a pixel because it is the one
    // artefact that distinguishes "the theme was applied" from "the theme was
    // requested": CSS forces `.monaco-editor { background: transparent }`, so
    // the editor's backdrop looks right either way and only Monaco's own
    // canvases (minimap, overview ruler) betray the fallback.
    //
    // Since UD-1 the tab holds a diff editor, so there are two code editors
    // and BOTH are asserted: a theme handed to `createDiffEditor` but not
    // propagated to one of its sides would put a light pane next to a dark
    // one, which is worse than a uniformly wrong theme because it looks
    // deliberate.
    const editorClasses = await tab
      .locator(".monaco-editor")
      .evaluateAll((nodes) => nodes.map((n) => n.className));
    expect(editorClasses.length).toBeGreaterThanOrEqual(2);
    for (const editorClass of editorClasses) {
      const classes = editorClass.split(/\s+/);
      expect(classes).toContain("vs-dark");
      expect(classes).not.toContain("vs");
    }
  });

  // -----------------------------------------------------------------------
  // UD-1: a real diff editor.
  //
  // Before UD-1 the tab was one Monaco editor over an assembled diff document
  // created with `language: "plaintext"` (`ui/unified_diff.nim`), and its own
  // comment said why: the document interleaved `@@` headers, `+`/`-` prefixes
  // and file dividers, which no tokenizer describes.  Two visible weaknesses
  // followed and are what these two scenarios pin:
  //
  //   * no syntax highlighting, because no tokenizer ran;
  //   * no word-level intra-line marking, because a single document has no
  //     "before" and "after" for Monaco to compare.
  //
  // Falsifiable before UD-1: the tab held no `.monaco-diff-editor` at all, its
  // only model's language id was `plaintext`, and `.char-insert` /
  // `.char-delete` had count 0 everywhere on the page.
  //
  // Headless counterparts: `the two models carry the file's own text, split by
  // revision`, `the language is resolved from the file path` and
  // `a partially changed line reaches Monaco as two comparable lines` in
  // src/tests/gui/tests/vcs/vcs_diff_decorations_test.nim — which can assert
  // what is HANDED to Monaco but not what Monaco then does with it, so the two
  // halves are split across the two lanes deliberately.

  test("UD-1: the diff tab is a diff editor over two models in the reviewed language", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");

    // Monaco's own diff editor, in the unified (inline) layout.
    await expect(tab.locator(".monaco-diff-editor")).toBeVisible({
      timeout: 20_000,
    });
    await expect(tab.locator(".monaco-diff-editor.side-by-side")).toHaveCount(0);

    // Both of its models carry the reviewed file's language, so a tokenizer
    // runs over each.  Read from Monaco rather than from the DOM because the
    // language id is the property under test; the DOM check below is what says
    // the tokenizer actually produced something.
    const languages = await ctPage.evaluate(() => {
      const monacoGlobal = (window as unknown as {
        monaco?: { editor: { getModels(): { getLanguageId(): string }[] } };
      }).monaco;
      if (!monacoGlobal) return null;
      return monacoGlobal.editor.getModels().map((m) => m.getLanguageId());
    });
    expect(languages).not.toBeNull();
    // `src/main.rs` — Rust, and at least two models because a diff editor has
    // an original and a modified side.
    expect((languages ?? []).filter((l) => l === "rust").length).toBeGreaterThanOrEqual(2);

    // ... and the tokenizer ran: Monaco paints each token class as `mtk<n>`,
    // and a plaintext model produces exactly one class for the whole document.
    const tokenClasses = await tab
      .locator(`${DIFF_BODY_LINES} span[class^='mtk']`)
      .evaluateAll((spans) =>
        Array.from(new Set(spans.map((s) => s.className))),
      );
    expect(tokenClasses.length).toBeGreaterThan(1);
  });

  test("UD-1: a partially changed line is marked word by word", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // `src/main.rs` changes `let y = x * 2;` into `let y = x * 3;` — one
    // character of one line.  That is the case a coloured diff and a good diff
    // disagree about: a coloured diff paints the whole line, a good one points
    // at the `2` and the `3`.  Monaco computes this itself once it owns both
    // sides, which is why UD-1 is a structural change and not a styling one.
    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");

    await expect
      .poll(async () => await tab.locator(".char-insert").count(), {
        timeout: 20_000,
      })
      .toBeGreaterThan(0);
    expect(await tab.locator(".char-delete").count()).toBeGreaterThan(0);

    // The marking must be *narrower than the line*: a `char-insert` spanning
    // the whole added line is Monaco reporting "everything changed", which is
    // exactly the state UD-1 replaces.  The changed line is 15 characters and
    // one of them differs, so the marked run is short.
    const markedWidths = await tab
      .locator(".char-insert")
      .evaluateAll((nodes) => nodes.map((n) => (n as HTMLElement).offsetWidth));
    const lineWidths = await tab
      .locator(".view-lines .view-line")
      .evaluateAll((nodes) => nodes.map((n) => (n as HTMLElement).offsetWidth));
    const widestLine = Math.max(...lineWidths, 1);
    expect(Math.min(...markedWidths)).toBeLessThan(widestLine);
  });

  test("Test 27: the invocation selector is an in-editor control above the function", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");

    // §7: "an in-editor control, modelled on the loop iteration selector — the
    // inline slider CodeTracer already renders immediately above the relevant
    // lines for a loop", NOT "a dropdown in a panel header".  So it must be
    // inside the editor tab, and there must be no such control in the VCS
    // panel.
    const selector = tab.locator(".review-invocation-selector");
    await expect(selector.first()).toBeVisible({ timeout: 20_000 });
    // Every control on the page is inside this editor tab: there is no copy of
    // it in a panel header, which is what §7 rules out.
    expect(await ctPage.locator(".review-invocation-selector").count()).toBe(
      await selector.count(),
    );
    await expect(
      selector.first().locator("xpath=ancestor::*[contains(@class,'monaco-editor')]").first(),
    ).toBeVisible();

    // `main` is recorded twice in the fixture, so the control counts two.
    await expect(selector.first().locator(".review-invocation-label")).toHaveText(
      "main: call 1 / 2",
    );

    // One control per function the document shows — and since UD-2 the
    // document is the whole file, so `compute` gets one too.  Before UD-2 the
    // model was a window around the hunk, `compute` (lines 14-20) was not in
    // it, and this counted exactly one.  That is a change in what the tab
    // *contains*, not in the rule: §7's control belongs above the function it
    // governs, and the second function is now in the tab.
    const labels = await selector.locator(".review-invocation-label").allTextContents();
    expect(labels).toEqual([
      "main: call 1 / 2",
      "compute: call 1 / 1 (4 called, 1 recorded)",
    ]);
  });

  test("Test 28: stepping the selector switches the rendered invocation", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    const selector = tab.locator(".review-invocation-selector").first();
    await expect(selector).toBeVisible({ timeout: 20_000 });

    const lines = tab.locator(DIFF_BODY_LINES);
    await expect
      .poll(async () => await lines.locator(".line-flow-hit").count(), {
        timeout: 20_000,
      })
      .toBeGreaterThan(0);
    const firstCallHits = await lines.locator(".line-flow-hit").count();

    // The first call reaches line 10; the second stops at line 4.  So moving to
    // the second invocation must draw strictly fewer hits — the visible proof
    // that the control changes which execution is on screen rather than merely
    // relabelling itself.
    await selector.locator(".review-invocation-next").click();
    await expect(selector.locator(".review-invocation-label")).toHaveText(
      "main: call 2 / 2",
      { timeout: 10_000 },
    );
    await expect
      .poll(async () => await lines.locator(".line-flow-hit").count(), {
        timeout: 20_000,
      })
      .toBeLessThan(firstCallHits);

    // And back: clamped at both ends, like the loop iteration slider.
    await selector.locator(".review-invocation-prev").click();
    await expect(selector.locator(".review-invocation-label")).toHaveText(
      "main: call 1 / 2",
      { timeout: 10_000 },
    );
    await expect
      .poll(async () => await lines.locator(".line-flow-hit").count(), {
        timeout: 20_000,
      })
      .toBe(firstCallHits);
  });

  test("Test 12: opening a second file yields a second tab, and both stay open", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // DeepReview-GUI.md §4.1: "Each diff tab shows a single file.  Cross-file
    // navigation is the Changed Files list; a review does not concatenate
    // every file into one scrolling document."
    await openReviewDiffTab(dr, 0, "src/main.rs");
    await openReviewDiffTab(dr, 1, "src/utils.rs");

    expect(await dr.diffTabs().count()).toBe(2);
    const titles = await dr.layoutTabTitles();
    expect(titles).toContain(DeepReviewPage.diffTabTitle("src/main.rs"));
    expect(titles).toContain(DeepReviewPage.diffTabTitle("src/utils.rs"));
    // The second file is the focused one; the first is still open behind it.
    expect(await dr.activeTabTitles()).toContain(
      DeepReviewPage.diffTabTitle("src/utils.rs"),
    );

    // Each tab holds its own file's diff, with the fixture's own hunk range —
    // not a shared, concatenated document.  Asserted one at a time because
    // GoldenLayout hides the inactive tab and Monaco renders no lines for a
    // hidden editor; re-selecting the first file also shows the tab was still
    // there rather than re-created.
    await expect(
      dr
        .diffTabFor("src/utils.rs")
        .locator(`${DIFF_BODY} .view-line`, { hasText: "@@ -0,0 +1,8 @@" })
        .first(),
    ).toBeVisible({ timeout: 15_000 });

    await openReviewDiffTab(dr, 0, "src/main.rs");
    expect(await dr.diffTabs().count()).toBe(2);
    await expect(
      dr
        .diffTabFor("src/main.rs")
        .locator(`${DIFF_BODY} .view-line`, { hasText: "@@ -2,5 +2,10 @@" })
        .first(),
    ).toBeVisible({ timeout: 15_000 });
  });

  test("Test 12b: a review's diff tab keeps hunk selection but not the mutating operations", async ({ ctPage }) => {
    // DeepReview-GUI.md §4.5: "In DeepReview mode the mutating operations
    // (stage, discard, move to commit) are disabled — the changeset is
    // immutable, per VCS-Panel.md 'DeepReview Mode: Commit operations:
    // Disabled (read-only view)' — while selection and copy-as-patch remain
    // available."
    //
    // Headless counterparts: "the mutating hunk operations are disabled for a
    // review" in src/tests/gui/tests/vcs/vcs_vm_test.nim, and "the diff tab
    // renders its hunk toolbar over the Monaco host" in
    // src/tests/gui/tests/views/isonim_views_test.nim.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");

    const header = dr.diffHunkHeaderLines().first();
    await expect(header).toBeVisible({ timeout: 15_000 });
    await header.click();

    await expect(tab.locator(".hunk-toolbar-count")).toHaveText(
      "1 hunk selected",
      { timeout: 10_000 },
    );
    // Copy stays.
    await expect(tab.locator(".hunk-toolbar-button").first()).toHaveText(
      "Copy as patch",
    );
    // Staging does not.
    await expect(
      tab.locator(".hunk-toolbar-button", { hasText: "Stage hunks" }),
    ).toHaveCount(0);
  });

  // -----------------------------------------------------------------------
  // Test 13: Mode toggle switches what a file click opens
  // -----------------------------------------------------------------------

  // Retargeted in DR-R8 from the deleted panel's two-button
  // `.deepreview-mode-toggle` (which swapped the panel's own DOM diff for its
  // own Monaco instance) to the VCS panel's view mode toggle, which is where
  // DeepReview-GUI.md §2 puts the mode switcher and what VCS-Panel.md, "View
  // mode toggle", defines it to do: "A switch at the top-right of the Changed
  // Files section controls what happens when a file is clicked".
  //
  // The subject is unchanged and no assertion is weakened: the toggle exists,
  // it moves, and the two positions produce the two representations §1
  // promises — a unified diff tab and the full file.  What changed is that
  // both representations are now ordinary EDITOR DOCUMENTS rather than two
  // states of one panel, which is the whole of DR-R4.
  //
  // Headless counterparts:
  //   test_vcs_panel_renders_view_mode_toggle_in_review_mode and "toggling the
  //   switch in review mode moves the view mode" in
  //   src/tests/gui/tests/vcs/vcs_view_test.nim;
  //   test_vcs_open_action_follows_view_mode_in_review_mode in
  //   src/tests/gui/tests/vcs/vcs_vm_test.nim.
  test("Test 13: the mode toggle switches between the diff tab and the file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // The toggle is present at all, and a review starts on Unified Diff
    // (§7 step 2: "The first modified file opens in the editor with unified
    // diff view").
    await expect(dr.modeToggle()).toBeVisible();
    await expect(dr.modeToggleButton()).toBeVisible();
    expect(await dr.isUnifiedDiffMode()).toBe(true);

    // Unified Diff position: clicking a file opens its diff document.
    await dr.fileItemByIndex(0).click();
    await expect(dr.diffTabFor("src/main.rs")).toBeVisible({ timeout: 20_000 });

    // Flip it: the switch reports the other position...
    await dr.switchToFullFiles();
    await wait(500);
    expect(await dr.isUnifiedDiffMode()).toBe(false);

    // ...and a click now resolves to the file itself rather than to a diff
    // document, so no `Diff:`-titled tab appears for the file just clicked.
    //
    // HONEST SCOPE: the source tab that *should* appear instead does not,
    // because `--deepreview` loads no recording and the editor has no source
    // text to open (M42b) — the same gap that keeps Tests 19-21 skipped.  The
    // assertion below is therefore the strongest one this harness can make,
    // and it is still falsifiable: it fails if the toggle stops changing what
    // a click opens.  That the Open File position resolves to
    // `voaSourceFile` with target `file:src/utils.rs` IS asserted, headlessly
    // and completely, by test_vcs_open_action_follows_view_mode_in_review_mode
    // in src/tests/gui/tests/vcs/vcs_vm_test.nim.
    await dr.fileItemByIndex(1).click();
    await wait(1500);
    const titles = await dr.layoutTabTitles();
    expect(titles).not.toContain(DeepReviewPage.diffTabTitle("src/utils.rs"));

    // Flip back: the switch returns, and so does the diff-opening behaviour.
    await dr.switchToUnifiedDiff();
    await wait(500);
    expect(await dr.isUnifiedDiffMode()).toBe(true);

    await dr.fileItemByIndex(1).click();
    await expect(dr.diffTabFor("src/utils.rs")).toBeVisible({ timeout: 20_000 });
  });

  // -----------------------------------------------------------------------
  // Tests 19-21: per-file diff overlays in Full Files Mode
  // -----------------------------------------------------------------------
  //
  // DeepReview-GUI.md §5.1: "Full Files Mode ... the normal CodeTracer editor
  // with complete file contents loaded and diff highlights applied to the
  // modified lines."
  //
  // Retargeted in DR-R8 from the deleted panel's own Monaco instance and its
  // `deepreview-diff-line-*` decorations to the STANDARD editor's, which
  // `ui/editor.nim`'s `deepReviewDiffStyleLines` draws as `line-diff-added` /
  // `line-diff-modified`.  That code has always been the specified home (§5.1
  // assigns the overlays to "The Editor, on the full file"); it simply never
  // fired, because before DR-R1 no editor tab was ever opened in review mode.
  //
  // Un-skipped in RV-11.  The reason they carried — "the overlays are drawn
  // over the file's real source text, and `--deepreview` mode loads no
  // recording to supply it" — turned out to name the wrong supplier.  A review
  // never needed a recording for the text: the dataset carries it, in
  // `DeepReviewFileData.sourceContent`, which is also the ONLY text whose line
  // numbering the hunks' `newLine` values actually index.  The index process
  // now serves a review tab from that field (`index/config.open`), so these
  // three run over the fixture's own bytes and need nothing on disk.
  //
  // The second half of the fix is `common/review_source_paths`: both overlays
  // used to compare the dataset's repo-relative `src/main.rs` against the
  // tab's path with `==`, which no dataset can ever satisfy.

  test("Test 19: diff decorations appear in Full Files Mode for modified file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.switchToFullFiles();
    await dr.fileItemByIndex(0).click();
    await wait(2000);

    // The first file (src/main.rs) has status "M" with both removed and
    // added lines, so the added lines should get "modified" (yellow)
    // decorations. The hunk has 8 added lines at newLine 3-10.
    const modifiedCount = await dr.editorDiffModifiedLines().count();
    expect(modifiedCount).toBeGreaterThan(0);
  });

  test("Test 20: added lines have green decoration class for purely added file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.switchToFullFiles();
    await wait(500);

    // Switch to the second file (src/utils.rs) which has status "A" — all
    // lines are purely added (no removals in the hunk), so they should get
    // the green "added" decoration class.
    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();
    await wait(1000);

    const addedCount = await dr.editorDiffAddedLines().count();
    expect(addedCount).toBeGreaterThan(0);

    // Verify at least one element actually has the correct CSS class.
    const firstAdded = dr.editorDiffAddedLines().first();
    const classes = await firstAdded.getAttribute("class");
    expect(classes).toContain("line-diff-added");
  });

  test("Test 21: diff decorations are removed when switching to a file without diff data", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.switchToFullFiles();
    await dr.fileItemByIndex(0).click();
    await wait(1000);

    // Start on the first file (src/main.rs, modified) — should have diff decorations.
    const initialModified = await dr.editorDiffModifiedLines().count();
    expect(initialModified).toBeGreaterThan(0);

    // Switch to the second file (src/utils.rs, added) — decorations should
    // change. The modified decorations from the first file should be gone.
    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();
    await wait(1000);

    // src/utils.rs is purely added, so it should have added decorations
    // but no modified decorations.
    const addedCount = await dr.editorDiffAddedLines().count();
    expect(addedCount).toBeGreaterThan(0);

    const modifiedCount = await dr.editorDiffModifiedLines().count();
    expect(modifiedCount).toBe(0);

    // Switch to the third file (src/config.rs, DELETED).  A deleted file has
    // no content in the new tree, so `vcs_vm.openActionFor` resolves it to the
    // diff tab that shows the removal even in Full Files mode — DR-R1 decided
    // that deliberately, and it is the one row whose click does not open a
    // source tab.
    //
    // So the invariant here is not "the page-wide decoration count drops to
    // zero" (it cannot: the utils.rs source tab is still the visible one, and
    // its own decorations are still correct).  It is the stronger statement
    // that the deleted file contributes NO full-file decorations of its own:
    // it opens a diff tab, adds no source tab, and leaves the editor's
    // decorations exactly as utils.rs left them.
    const sourceTabsBefore = await dr.sourceTabs().count();
    const thirdItem = dr.fileItemByIndex(2);
    await thirdItem.click();
    await expect(dr.diffTabFor("src/config.rs")).toBeVisible({ timeout: 20_000 });

    expect(await dr.sourceTabs().count()).toBe(sourceTabsBefore);
    expect(await dr.editorDiffAddedLines().count()).toBe(addedCount);
    expect(await dr.editorDiffModifiedLines().count()).toBe(0);
  });

  // -----------------------------------------------------------------------
  // Test 21b: §5.3's Omniscience overlay on the full file
  // -----------------------------------------------------------------------
  //
  // DeepReview-GUI.md §5.3: "The same Omniscience data from the associated
  // traces is overlaid on the file in its normal form ... Use the standard
  // Omniscience appearance ... Show overlays wherever DeepReview data exists
  // for the loaded file."
  //
  // Tests 19-21 cover §5.1's diff highlights.  This is §5.3, the *other* half,
  // and it had no end-to-end coverage at all — `reviewFlowStyleLines` was
  // asserted only through the shared headless suites and through RV-5's
  // reasoning that "the input is the same plan the diff tab renders".  It was
  // not: the proc returned an empty seq for every tab, and no test noticed.
  //
  // The overlay is asserted as a DIFFERENCE across opening the file rather
  // than as an absolute count, because the diff tab contributes its own
  // decorations to the same page and an absolute number could be satisfied
  // entirely by that tab.  A difference can only come from the new tab.
  test("Test 21b: the full file carries the flow overlay and its value chips", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();

    const flowLines = ctPage.locator("[class*='line-flow']");
    const valueChips = ctPage.locator(".review-flow-value");
    const flowBefore = await flowLines.count();
    const chipsBefore = await valueChips.count();

    await dr.switchToFullFiles();
    await dr.fileItemByIndex(0).click();
    await expect(dr.sourceTabs()).toHaveCount(1, { timeout: 20_000 });
    await wait(2000);

    // src/main.rs carries three recorded invocations (two of `main`, one of
    // `compute`) and 21 captured values, so opening it must add both kinds of
    // decoration — the shading §5.3 calls the standard Omniscience appearance,
    // and the inline value chips that come with it.
    expect(await flowLines.count()).toBeGreaterThan(flowBefore);
    expect(await valueChips.count()).toBeGreaterThan(chipsBefore);

    // The classes must be the debugger's own, not a review-specific style
    // (§5.3: "Do not create a separate DeepReview-specific inline style").
    const flowClasses = await flowLines.first().getAttribute("class");
    expect(flowClasses).toMatch(/line-flow-(hit|skip|unknown)/);
  });

  // -----------------------------------------------------------------------
  // Test 21d: the full file is read-only
  // -----------------------------------------------------------------------
  //
  // DeepReview-GUI.md §5.1: "Keep the review representation read-only by
  // default."
  //
  // This is not cosmetic, and it is the reason the requirement is asserted
  // through a real keystroke rather than by reading an option.  A review's
  // tab is served from the dataset's `sourceContent` and is NAMED BY THE
  // DATASET'S REPO-RELATIVE PATH, which is the only name a portable dataset
  // has.  An editable tab is therefore a dirty buffer whose save target
  // (`index/files.onSaveFile`) resolves against the index process's working
  // directory — wherever `ct review` was typed.  Measured before this was
  // fixed: editing the review's `src/main.nr` and pressing Ctrl+S overwrote
  // an unrelated `src/main.nr` sitting under the launch directory, with no
  // prompt and no error.
  test("Test 21d: the review's full file cannot be edited", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await dr.switchToFullFiles();
    await dr.fileItemByIndex(0).click();
    await expect(dr.sourceTabs()).toHaveCount(1, { timeout: 20_000 });
    await wait(1500);

    const lines = dr.sourceTabs().first().locator(".monaco-editor .view-lines");
    const before = (await lines.innerText()).trim();
    expect(before.length).toBeGreaterThan(0);

    // Type as a user would: click into the document, then send keys.
    await lines.click();
    await ctPage.keyboard.type("EDITED_BY_TEST");
    await wait(1000);

    expect((await lines.innerText()).trim()).toBe(before);
    // ...and nothing became dirty, so no save can ever be dispatched for it.
    const dirty = await ctPage.evaluate(() => {
      const open = (globalThis as any).data?.services?.editor?.open ?? {};
      return Object.keys(open).filter((k) => open[k] && open[k].changed);
    });
    expect(dirty).toEqual([]);
  });

  // -----------------------------------------------------------------------
  // Test 22: DR-6 - Mode switch preserves file selection
  // -----------------------------------------------------------------------

  // DeepReview-GUI.md §2: "Switching modes should preserve the current file
  // and the closest available location within that file whenever possible."
  // File selection is owned by the VCS panel, so this asserts that flipping
  // the view mode does not disturb it.
  //
  // Retargeted in DR-R8 from `window.__deepreviewSetViewMode` (a hook on the
  // deleted panel) to the VCS panel's real toggle.  Subject and assertions
  // unchanged.
  test("Test 22: mode switch preserves the selected file index", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // Select the second file (src/utils.rs).
    const secondItem = dr.fileItemByIndex(1);
    await secondItem.click();
    await wait(500);
    expect(await secondItem.isSelected()).toBe(true);

    // Switch to unified diff mode.
    await dr.switchToUnifiedDiff();
    await wait(500);

    // The second file should still be selected in the sidebar.
    expect(await secondItem.isSelected()).toBe(true);
    expect(await dr.fileItemByIndex(0).isSelected()).toBe(false);

    // Switch back to full files mode.
    await dr.switchToFullFiles();
    await wait(500);

    // The second file should still be selected.
    expect(await secondItem.isSelected()).toBe(true);
  });

  // -----------------------------------------------------------------------
  // Test 23: the trace context selector lives in the VCS panel header
  // -----------------------------------------------------------------------

  // e2e_review_trace_selector_lives_in_the_vcs_panel — the rewrite of
  // "Test 23: trace context selector is visible with correct options"
  // (DR-R2), retargeted from the standalone DeepReview panel's header to the
  // VCS panel's.
  //
  // DeepReview-GUI.md §2 assigns the control to the VCS panel header
  // ("Trace context selector | The VCS panel header, populated only in
  // DeepReview mode"), and §6 requires the selected context be changeable
  // "without leaving the review, from the selector in the VCS panel header".
  // Before DR-R2 the VCS panel rendered no select element in any mode.
  //
  // Headless counterparts:
  //   test_vcs_panel_renders_trace_selector_in_review_mode and
  //   test_vcs_trace_selector_change_updates_selection in
  //   src/tests/gui/tests/vcs/vcs_view_test.nim.
  test("Test 23: the trace context selector lives in the VCS panel header", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // The fixture has 2 trace contexts, so the selector should be visible —
    // in the VCS panel.
    await expect(dr.vcsTraceContextSelector()).toBeVisible();
    await expect(dr.vcsTraceContextSelect()).toBeVisible();

    // Verify the dropdown has the correct number of options.
    const options = dr.vcsTraceContextSelect().locator("option");
    const optionCount = await options.count();
    expect(optionCount).toBe(2);

    // Verify option labels match fixture data.
    const firstLabel = await options.nth(0).textContent();
    expect(firstLabel).toContain("latest passing run");

    const secondLabel = await options.nth(1).textContent();
    expect(secondLabel).toContain("previous run");

    // The selection is live: picking the second context is reflected by the
    // control. (What that selection re-draws is DR-R6's job and is blocked on
    // M42b — `--deepreview` loads no recording to switch to.)
    await dr.vcsTraceContextSelect().selectOption("1");
    await wait(500);
    expect(await dr.vcsTraceContextSelect().inputValue()).toBe("1");
  });

  // -----------------------------------------------------------------------
  // Test 24: the VCS panel header shows the session title and review stats
  // -----------------------------------------------------------------------

  // Companion of Test 23 and the second half of
  // e2e_review_trace_selector_lives_in_the_vcs_panel: the rewrite of
  // "Test 24: header bar displays the session title" (DR-R2), retargeted to
  // the VCS panel header, which DeepReview-GUI.md §2 makes the owner of the
  // "Session title / stats" review element.
  //
  // Headless counterpart: "the review stats render in the header" in
  // src/tests/gui/tests/vcs/vcs_view_test.nim.
  test("Test 24: the VCS panel header displays the session title and stats", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // The fixture has sessionTitle "DeepReview: parser cleanup".
    await expect(dr.vcsReviewTitle()).toBeVisible();
    const titleText = await dr.vcsReviewTitle().textContent();
    expect(titleText).toContain("DeepReview: parser cleanup");

    // ...and the changeset summary: 3 files, +16 -10 across the fixture's
    // three files (main.rs +8-3, utils.rs +8-0, config.rs +0-7).
    await expect(dr.vcsReviewStats()).toBeVisible();
    const statsText = await dr.vcsReviewStats().textContent();
    expect(statsText).toContain("3 files");
    expect(statsText).toContain("+16 -10");
  });

  // -----------------------------------------------------------------------
  // DR-R7: one launch, all three panels
  // -----------------------------------------------------------------------

  // e2e_ct_deepreview_launch_populates_all_three_panels.
  //
  // DeepReview-GUI.md §7, "Transition into a Review", is a list of five things
  // that happen when a review starts, and §1.1 makes the CLI the path an agent
  // uses: "Launching over a dataset must load the recordings the dataset
  // references and populate the three panels from them. A review that opens
  // with empty panels is a defect, not a degraded mode."
  //
  // Each of the three panels already has its own test above (Test 2 for the
  // changed-files list, Test 5b for the editor tab, and the Agent Activity
  // section in agent-activity-deepreview.spec.ts). This one asserts that ONE
  // launch reaches all three at once, which is the property DR-R7 makes true
  // of every launch path rather than only of this one.
  //
  // HONEST SCOPE: this test passes against the code as it stood before DR-R7
  // as well as after — DR-R1 and DR-R3 made the `--deepreview` path do all
  // three. It is a regression guard for the convergence, not new coverage of
  // it. What DR-R7 adds is that the other two launch paths reach the same
  // state, and neither is launchable from Playwright here: the agentic handoff
  // needs a live Agent Harbor server (agentic-coding/agentic-worktree.spec.ts)
  // and the diff-associated trace needs a recording made with
  // `ct record --with-diff`. Both are covered headlessly instead, in
  // src/tests/gui/tests/deepreview/deepreview_entry_test.nim
  // (test_all_launch_paths_reach_the_same_review_state) and
  // src/tests/gui/tests/agentic-coding/agentic_deepreview_m5_test.nim
  // (test_agentic_handoff_needs_no_deepreview_component).
  test("Test 25: one launch populates and focuses all three review panels", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    // Pillar 1 — the VCS panel: populated with the changeset, and the visible
    // tab of its stack (§2: "The VCS panel must be the visible tab of
    // whichever stack hosts it when a review starts").
    const activeTitles = await dr.activeTabTitles();
    expect(activeTitles).toContain("VCS");
    await expect(dr.vcsPanel()).toBeVisible();
    await expect(dr.vcsReviewStats()).toContainText("3 files");
    const files = await dr.fileItems();
    expect(files.length).toBe(3);

    // Pillar 2 — the Editor: the first modified file is open as a diff tab,
    // and it is the active tab of the editor area (§7 step 2).
    const firstTitle = DeepReviewPage.diffTabTitle("src/main.rs");
    expect(activeTitles).toContain(firstTitle);
    await expect(dr.diffTabFor("src/main.rs")).toBeVisible();

    // Pillar 3 — the Agent Activity panel: present, focused, and carrying no
    // roll-up (§2.1, AA-1).  No agent ran, so it has nothing to show — and
    // showing nothing is the point: the changeset's coverage is pillar 2's
    // business, on the Changed Files rows asserted above.
    expect(activeTitles).toContain("AGENT ACTIVITY");
    await expect(dr.agentActivityPanel()).toBeVisible();
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);

    // ...and all of it happened additively: nothing the editor layout
    // declares was displaced to make room for the review (issue #610).
    // FILES is the check that matters — `index/config.isValidLayoutConfig`
    // rejects a layout that lost it, so a review that dropped it would poison
    // the next ordinary launch too. STATE, CALLTRACE and EVENT LOG used to be
    // listed here; RV-2 moved the dataset launch onto the editor layout, which
    // does not declare them at all, so their absence is now the requirement
    // (asserted in Test 1b) rather than the regression.
    const allTitles = await dr.layoutTabTitles();
    for (const expected of ["FILES", "VCS", "AGENT ACTIVITY"]) {
      expect(allTitles, `missing standard panel: ${expected}`).toContain(
        expected,
      );
    }
  });

  // -----------------------------------------------------------------------
  // Tests 14-16: Context expansion in the diff tab (DR-R5, retargeted by UD-2)
  // -----------------------------------------------------------------------
  //
  // e2e_diff_tab_expand_reveals_context.
  //
  // DeepReview-GUI.md §4.2:
  //
  //   "The user can reveal surrounding unchanged lines around the changed
  //    regions.  Required controls: Expand surrounding context above a
  //    visible region / Expand surrounding context below a visible region /
  //    Repeated expansion loads more file content instead of merely
  //    uncovering lines that were already fetched."
  //
  // §4.3, which UD-2 delivers and the spec still marks "not implemented":
  //
  //   "Each currently visible context boundary exposes a draggable edge line.
  //    Dragging that boundary upward or downward increases the number of
  //    visible lines without forcing the user to repeatedly press expansion
  //    buttons."
  //
  // What changed under these tests
  // ------------------------------
  // DR-R5 made the expand control a LINE of the Monaco model reading "...
  // Expand 10 lines above", and these three tests clicked it and counted the
  // `.ct-diff-line-revealed` decorations that appeared.
  //
  // UD-2 removed both.  The models are the whole file now — which is what
  // makes the tokenizer see it from line 1, the blocker UD-1 recorded — and
  // Monaco's own `hideUnchangedRegions` collapses what is far from a change,
  // drawing a boundary widget with a drag handle at each end.  There are no
  // control lines to click and no revealed lines to count, because every line
  // is already in the document; what changes is which of them are on screen.
  //
  // So the assertions moved from "a control line exists and clicking it adds
  // decorated lines" to "a boundary exists, it says how much it is hiding,
  // and each gesture reduces that by the right amount and puts the right
  // line numbers in the gutter".  The line numbers are still asserted by
  // value, for the reason the DR-R5 comment gave: a count-only assertion
  // passes with every off-by-one it can make.
  //
  // Fixture geometry, from `sample-review.json` — src/main.rs is 25 lines
  // with one hunk covering new lines 2..11, so:
  //   above: the run above the hunk is three lines (file line 1, the `@@`
  //          divider and the hunk's own leading context line), far less than
  //          `contextLineCount + minimumLineCount`, so nothing is collapsed
  //          there and NO boundary is offered — the edge case, asserted
  //          through the UI that protects it;
  //   below: the run after the hunk is fifteen lines, of which three stay on
  //          screen as context, so file lines 14..25 are hidden behind one
  //          boundary.  Its two handles reveal from its top (lines just after
  //          the hunk) and from its bottom (the end of the file)
  //          independently.
  //
  // Headless counterparts: the "which lines a boundary hides" and "the
  // expansion menu's commands" suites in
  // src/tests/gui/tests/vcs/vcs_context_expansion_test.nim.

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

  test("Test 14: the diff tab offers a draggable, visible boundary at each collapsed region", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);

    // main.rs has exactly one collapsed region — below the hunk — and it
    // carries BOTH handles, so both of §4.2's required directions are offered
    // from it independently.
    await expect(DeepReviewPage.expandAboveHandle(tab)).toHaveCount(1);
    await expect(DeepReviewPage.expandBelowHandle(tab)).toHaveCount(1);

    // The affordance is there BEFORE any interaction.  Monaco's own handles
    // are `background-color: transparent` until `:hover`, so this is the
    // assertion that says the stylesheet's override is in force — without it
    // the gesture exists and nobody can see that it does.
    const painted = await DeepReviewPage.expandAboveHandle(tab).evaluate(
      (node: Element) => {
        const style = getComputedStyle(node);
        return {
          background: style.backgroundColor,
          cursor: style.cursor,
          height: node.getBoundingClientRect().height,
        };
      },
    );
    expect(painted.background).not.toBe("rgba(0, 0, 0, 0)");
    expect(painted.background).not.toBe("transparent");
    expect(painted.height).toBeGreaterThan(0);
    // ... and it says it can be dragged, which is §4.3's whole point.
    expect(painted.cursor).toMatch(/resize/);

    // Monaco's band between the handles names how much is hidden, which is
    // the "N lines" a reader needs before deciding to expand.
    await expect(DeepReviewPage.collapsedBands(tab).first()).toHaveText(
      /\d+ hidden lines/,
    );
    expect(await DeepReviewPage.hiddenLineCounts(tab)).toEqual([12, 12]);

    // Nothing is collapsed ABOVE the hunk: a three-line run is not worth a
    // gesture, so no boundary is drawn there and line 1 is simply on screen.
    expect(await DeepReviewPage.diffNewLineNumbers(tab)).toContain("1");
    expect(await DeepReviewPage.expansionBoundaries(tab).count()).toBe(2);
  });

  test("Test 15: pressing a boundary reveals the default increment", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);

    // Lines 14..25 are hidden, so none of their numbers is in the gutter —
    // while 13, the last line the boundary keeps as context, is.
    const before = await DeepReviewPage.diffNewLineNumbers(tab);
    expect(before).toContain("13");
    expect(before).not.toContain("14");
    expect(before).not.toContain("25");

    // A press without a drag is Monaco's own click-to-expand, by
    // `revealLineCount` — which this tab sets to `ContextExpandStep`, the
    // same ten lines DR-R5's button promised.
    await DeepReviewPage.expandAboveHandle(tab).click();

    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(tab))[0], {
        timeout: 15_000,
      })
      .toBe(2);

    // ... and it revealed the right ten: 14..23, from the TOP of the region,
    // which is the end nearest the hunk.
    const afterFirst = await DeepReviewPage.diffNewLineNumbers(tab);
    expect(afterFirst).toContain("14");
    expect(afterFirst).toContain("23");
    expect(afterFirst).not.toContain("24");
    // Unchanged lines, so the old revision's column agrees — line 23 of the
    // new revision is line 18 of the old one, five lines earlier, because the
    // hunk replaced three lines with eight.
    expect(await DeepReviewPage.diffOldLineNumbers(tab)).toContain("18");

    // §4.2's third required control: "Repeated expansion loads more file
    // content instead of merely uncovering lines that were already fetched."
    // Two lines remain, so a second press takes those two rather than
    // re-revealing the first ten.
    await DeepReviewPage.expandAboveHandle(tab).click();
    const afterSecond = await DeepReviewPage.diffNewLineNumbers(tab);
    expect(afterSecond).toContain("24");
    expect(afterSecond).toContain("25");

    // The region is exhausted, so the boundary goes: a reader cannot press
    // something that can no longer act.
    await expect
      .poll(async () => await DeepReviewPage.expansionBoundaries(tab).count(), {
        timeout: 15_000,
      })
      .toBe(0);
  });

  test("Test 16: dragging a boundary reveals lines, with the count following the gesture", async ({ ctPage }) => {
    // §4.3: "Dragging that boundary upward or downward increases the number
    // of visible lines without forcing the user to repeatedly press expansion
    // buttons."  Falsifiable before UD-2: `hideUnchangedRegions` was
    // `{ enabled: false }`, so no boundary was drawn and there was nothing to
    // drag.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);
    const handle = DeepReviewPage.expandAboveHandle(tab);
    const box = await handle.boundingBox();
    expect(box).not.toBeNull();

    const startX = box!.x + box!.width / 2;
    const startY = box!.y + box!.height / 2;
    // Monaco converts the vertical travel into lines at one line per
    // line-height, so a drag of three line-heights reveals about three lines —
    // "the count follows the gesture" rather than jumping by a fixed step.
    const lineHeight = await tab
      .locator(`${DIFF_BODY} .view-line`)
      .first()
      .evaluate((node: Element) => node.getBoundingClientRect().height);
    expect(lineHeight).toBeGreaterThan(0);

    await ctPage.mouse.move(startX, startY);
    await ctPage.mouse.down();
    // Several small steps rather than one jump: the handler reads `mousemove`,
    // and a single event from the start to the end would also be accepted by a
    // implementation that only listened for `mouseup`.
    for (let step = 1; step <= 6; step++) {
      await ctPage.mouse.move(startX, startY + (lineHeight * 3 * step) / 6);
    }
    await ctPage.mouse.up();

    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(tab))[0], {
        timeout: 15_000,
      })
      .toBeLessThan(12);

    const hidden = (await DeepReviewPage.hiddenLineCounts(tab))[0];
    // The drag revealed roughly the distance travelled — not the 10-line
    // click increment, which is what tells a drag apart from a click here.
    expect(12 - hidden).toBeGreaterThanOrEqual(2);
    expect(12 - hidden).toBeLessThanOrEqual(5);
    // ... and the lines it revealed are the ones nearest the hunk.
    expect(await DeepReviewPage.diffNewLineNumbers(tab)).toContain("14");
  });

  test("Test 16c: the boundary's context menu expands more, and to the file's edge", async ({ ctPage }) => {
    // The owner's third control: "a context menu offering more lines or the
    // whole file in that direction", both directions independently.  Monaco
    // has no menu on the boundary at all — this is entirely
    // `ui/diff_expansion.nim` over `viewmodels/diff_expansion_menu.nim`.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);

    await DeepReviewPage.expandAboveHandle(tab).click({ button: "right" });
    await expect(dr.expansionMenu()).toBeVisible({ timeout: 10_000 });
    // 12 lines hidden: more than the 10-line increment, not more than the
    // 50-line one, so two offers — the increment and the whole remainder.
    await expect(dr.expansionMenuItems()).toHaveText([
      "Expand 10 lines above",
      "Expand all 12 lines above",
    ]);

    // "The whole file in this direction": every remaining line of the region,
    // so the file's last line reaches the gutter and the boundary retires.
    await dr.expansionMenuItems().last().click();
    await expect(dr.expansionMenu()).toHaveCount(0);
    await expect
      .poll(async () => await DeepReviewPage.diffNewLineNumbers(tab), {
        timeout: 15_000,
      })
      .toContain("25");
    expect(await DeepReviewPage.diffNewLineNumbers(tab)).toContain("14");
    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(tab))[0] ?? 0, {
        timeout: 15_000,
      })
      .toBe(0);
  });

  test("Test 16d: the two directions are offered independently", async ({ ctPage }) => {
    // Each boundary has a handle at each end, and each menu names its own
    // direction and acts only on it.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);

    await DeepReviewPage.expandBelowHandle(tab).click({ button: "right" });
    await expect(dr.expansionMenu()).toBeVisible({ timeout: 10_000 });
    await expect(dr.expansionMenuItems()).toHaveText([
      "Expand 10 lines below",
      "Expand all 12 lines below",
    ]);

    // Ten lines from the BOTTOM of the region is the end of the file, not the
    // lines next to the hunk — which is what "independently" means.
    await dr.expansionMenuItems().first().click();
    await expect(dr.expansionMenu()).toHaveCount(0);
    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(tab))[0], {
        timeout: 15_000,
      })
      .toBe(2);

    // The discriminator, read at the TOP of the file where the viewport
    // already is: line 13 is still the last one before the boundary and 14 is
    // still hidden.  Pressing the *above* handle would have revealed 14 first
    // — that is what "independently" means.
    const numbers = await DeepReviewPage.diffNewLineNumbers(tab);
    expect(numbers).toContain("13");
    expect(numbers).not.toContain("14");

    // ... and the lines that DID come on screen are at the end of the file.
    await DeepReviewPage.scrollDiff(ctPage, tab, 2000);
    await expect
      .poll(async () => await DeepReviewPage.diffNewLineNumbers(tab), {
        timeout: 15_000,
      })
      .toContain("25");
    expect(await DeepReviewPage.diffNewLineNumbers(tab)).toContain("16");
  });

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

  test("Test 16f: Shift+F10 opens the boundary's menu from the keyboard", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTabWithBoundary(dr);
    await DeepReviewPage.expandAboveHandle(tab).focus();
    await ctPage.keyboard.press("Shift+F10");

    await expect(dr.expansionMenu()).toBeVisible({ timeout: 10_000 });
    // The menu takes focus, so it can be walked and chosen from without ever
    // touching the mouse.
    expect(
      await dr
        .expansionMenuItems()
        .first()
        .evaluate((node: Element) => node === document.activeElement),
    ).toBe(true);

    await ctPage.keyboard.press("Enter");
    await expect(dr.expansionMenu()).toHaveCount(0);
    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(tab))[0], {
        timeout: 15_000,
      })
      .toBe(2);
  });

  test("UD-2: the model is the whole file, so the tokenizer starts at line 1", async ({ ctPage }) => {
    // The blocker UD-1 recorded, closed at its cause: a Monaco model is
    // tokenized from its OWN line 1, and DR-R5's model began at the first
    // hunk.  Asserted against the live models rather than against the
    // document builder, because the builder is what the headless suite
    // already covers and this is the claim about what Monaco is given.
    //
    // Falsifiable before UD-2: main.rs's modified model held 16 lines of a
    // 25-line file and its first numbered line was the hunk's, not the
    // file's.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    await openMainDiffTab(dr);

    const shapes = await ctPage.evaluate(() =>
      (window as never as { monaco: any }).monaco.editor
        .getModels()
        .map((model: any) => ({
          language: model.getLanguageId(),
          lineCount: model.getLineCount(),
          first: model.getLineContent(1),
        })),
    );
    const rust = shapes.filter((m: any) => m.language === "rust");
    expect(rust.length).toBeGreaterThanOrEqual(2);
    // 25 source lines plus the one `@@` divider §4.1 requires.  Both sides:
    // the old revision is the new one with the hunk's old lines put back, and
    // this hunk replaces five lines with ten, so it is five lines shorter.
    const lineCounts = rust.map((m: any) => m.lineCount).sort((a: number, b: number) => a - b);
    expect(lineCounts).toEqual([21, 26]);
    // Line 1 of the model is line 1 of the file — not a file header, not a
    // `@@` divider, and not the middle of the hunk.
    for (const model of rust) {
      expect(model.first).toBe("fn main() {");
    }
  });

  test("Test 16b: expansion is per file, and resets when the tab closes", async ({ ctPage }) => {
    // DR-R5: "Expansion state resets when the tab is closed and does not leak
    // between files."  Since UD-2 the expansion lives in the *editor* —
    // Monaco's unchanged regions — and each diff tab has its own editor, so a
    // second file's tab must open collapsed however far the first was
    // expanded, and a reopened tab must start collapsed again.
    //
    // Headless counterparts: "a re-sync of the same diff rebuilds a
    // byte-identical document" and "a cleared panel produces no document" in
    // src/tests/gui/tests/vcs/vcs_vm_test.nim.  The first is what keeps the
    // "coming back finds it still expanded" case below true: a re-sync that
    // changed the document by one line would re-publish the models and
    // collapse everything.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const mainTab = await openMainDiffTabWithBoundary(dr);
    await DeepReviewPage.expandAboveHandle(mainTab).click();
    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(mainTab))[0], {
        timeout: 15_000,
      })
      .toBe(2);

    // A different file's tab has its own editor.  utils.rs is a wholly added
    // 8-line file, so it has no unchanged run at all and therefore no
    // boundary — which is also the honest answer for "nothing to expand".
    await dr.fileItemByIndex(1).click();
    const utilsTab = dr.diffTabFor("src/utils.rs");
    await expect(utilsTab).toBeVisible({ timeout: 20_000 });
    await expect(
      utilsTab.locator(DIFF_BODY_LINES),
    ).toBeVisible({ timeout: 20_000 });
    await expect(DeepReviewPage.expansionBoundaries(utilsTab)).toHaveCount(0);

    // ...and coming back finds main.rs still expanded: the tab kept its
    // editor, and re-syncing the same rows rebuilds the same document, so
    // nothing replaced the models under it.
    await dr.fileItemByIndex(0).click();
    await expect(mainTab.locator(DIFF_BODY_LINES)).toBeVisible({
      timeout: 20_000,
    });
    await expect
      .poll(async () => (await DeepReviewPage.hiddenLineCounts(mainTab))[0], {
        timeout: 15_000,
      })
      .toBe(2);

    // Closing the tab must drop its ViewModel, its source cache and its
    // editor, so reopening the same file starts collapsed.  This is the only
    // coverage of the `closeLayoutTab` -> `forgetUnifiedDiffTab` wiring: the
    // tab component is JS-only and cannot be reached headlessly, so without
    // these lines the test's own title would be asserting nothing.
    const mainTabHeader = ctPage
      .locator(".lm_tab")
      .filter({ hasText: /^Diff:\s*main\.rs/ })
      .first();
    await mainTabHeader.locator(".lm_close_tab").click();
    await expect(mainTabHeader).toHaveCount(0, { timeout: 20_000 });

    const reopened = await openMainDiffTabWithBoundary(dr);
    expect(await DeepReviewPage.hiddenLineCounts(reopened)).toEqual([12, 12]);
  });

  // -----------------------------------------------------------------------
  // Tests 17 and 18 were deleted with the panel (DR-R8)
  // -----------------------------------------------------------------------
  //
  // "Test 17: omniscience inline values appear on unified diff lines with
  // flow data" and "Test 18: omniscience inline values match the flow data
  // from the fixture" both located `.deepreview-flow-values` inside the
  // standalone panel's DOM diff.  That surface is gone, and it is not the
  // surface the spec asks for: §7 requires flow data on a review's diff to be
  // "rendered using the same visualization system as normal debugging
  // (`flowStyleLines`, `applyEventualStylesLines`)" — Monaco decorations on
  // the diff tab, not spans the review renders itself.
  //
  // Nothing converts `DeepReviewFunctionFlow` into a `FlowUpdate` yet, so no
  // line of the Monaco diff tab carries a flow annotation to assert on.  That
  // adapter is DR-R6, which is BLOCKED on M42b (`--deepreview` loads no
  // recording), and DR-R6 owns the rewritten tests.  Retargeting them now
  // would mean asserting a surface that does not exist; leaving them pointed
  // at the deleted panel would mean a suite that cannot pass.

  // -----------------------------------------------------------------------
  // Test 8 was deleted with the panel (DR-R8)
  // -----------------------------------------------------------------------
  //
  // "Test 8: call trace panel renders the tree with correct structure" drove
  // `.deepreview-calltrace`, the panel's own call-tree column, and was
  // already `test.skip`.
  //
  // DeepReview-GUI.md §2 assigns the call tree to "The existing CALLTRACE
  // panel", and DR-R8's inventory deletes the panel's column for exactly that
  // reason: "The CALLTRACE panel owns this."  That panel has its own suites;
  // it shows nothing in a CLI-launched review only because `--deepreview`
  // loads no recording (M42b) — the same reason this test was skipped.

});

// ---------------------------------------------------------------------------
// Test suite: empty/missing data handling (Test 9)
// ---------------------------------------------------------------------------

test.describe("DeepReview GUI - empty data handling", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // -----------------------------------------------------------------------
  // Test 9a: Empty files array
  // -----------------------------------------------------------------------

  test.describe("empty files array", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: emptyReviewPath });

    // Retargeted in DR-R8 from the deleted panel's container and header to the
    // VCS panel, which owns the changed-files list and the review header
    // (DeepReview-GUI.md §2, §3).  Same subject: an empty review must load
    // without erroring and must say it has nothing in it.
    test("Test 9a: renders without errors when files array is empty", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.vcsPanel()).toBeVisible();
      // No error surface anywhere: the panel renders its empty state, not a
      // failure.
      await expect(ctPage.locator(".deepreview-error")).toHaveCount(0);
      await expect(dr.vcsPanel().locator(".vcs-error")).toHaveCount(0);

      // The Changed Files header still names the review's commit, which the
      // empty fixture carries even though it lists no files.
      const commitText = await dr
        .vcsPanel()
        .locator(".vcs-changed-files-commit")
        .textContent();
      expect(commitText).toBeTruthy();
      expect(commitText).toContain("0 files");

      const items = await dr.fileItems();
      expect(items.length).toBe(0);

      // `reviewStatsText` returns "" for a changeset with no files, so no
      // stats element is rendered rather than one reading "0 files +0 -0" —
      // see `vcs_vm.reviewStatsText`.
      await expect(dr.vcsReviewStats()).toHaveCount(0);
    });
  });

  // -----------------------------------------------------------------------
  // Test 9b: Missing call trace (null)
  // -----------------------------------------------------------------------

  test.describe("missing call trace", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: noCalltracePath });

    // -----------------------------------------------------------------------
    // Test 21c: a review that cannot supply a file's text says why
    // -----------------------------------------------------------------------
    //
    // The failure this replaces was silent: `index/config.open` logged
    // `error reading file directly ... ENOENT` and returned WITHOUT sending
    // `tab-load-received`, so no tab opened, nothing appeared, and the renderer
    // waited on a future that would never resolve.
    //
    // `no-calltrace-review.json`'s `src/lib.rs` carries an empty `sourceContent`
    // — the one case a dataset genuinely cannot serve — so it is the fixture
    // that reaches the branch.  The notice is a toast and auto-dismisses, so it
    // is sampled promptly after the click rather than after a long settle.
    test("Test 21c: a file the dataset carries no text for is reported, not swallowed", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();
      await dr.switchToFullFiles();
      await dr.fileItemByIndex(0).click();

      await expect(ctPage.locator("body")).toContainText("no source text", {
        timeout: 15_000,
      });
      await expect(ctPage.locator("body")).toContainText("src/lib.rs", {
        timeout: 15_000,
      });
    });

    // "Test 9b: renders without crash when callTrace is null" was deleted in
    // DR-R8 with the panel: it asserted `.deepreview-calltrace-empty`, the
    // panel's own "No call trace data" placeholder.  The call tree belongs to
    // the CALLTRACE panel (DeepReview-GUI.md §2), which has its own suites.
    // The no-crash half of its subject is covered by Test 9c below, which
    // launches over the very same `no-calltrace-review.json` fixture and
    // asserts the review still comes up populated.

    test("Test 9c: file without coverage shows '--' badge", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      const items = await dr.fileItems();
      expect(items.length).toBe(1);

      const badge = await items[0].coverageBadge();
      if (badge !== "") {
        expect(badge).toBe("--");
      }

      const name = await items[0].name();
      expect(name).toBe("lib.rs");
    });
  });
});

// ---------------------------------------------------------------------------
// Test suite: DR-8 comprehensive workflow (uses all 3 fixtures)
// ---------------------------------------------------------------------------

test.describe("DeepReview comprehensive workflow", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  // -----------------------------------------------------------------------
  // Full workflow: exercises the entire feature end-to-end
  // -----------------------------------------------------------------------

  test.describe("full workflow", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

    // Retargeted in DR-R8, step by step, from the deleted panel to the three
    // panels a review actually lives in.  Every step of the original survives
    // and none is weakened; three change surface:
    //
    //   * Step 1-2 (session title) moves from `.deepreview-session-title` to
    //     the VCS panel header (§2, "Session title / stats").
    //   * Steps 5-6 (hunks with added/removed counts) move from the panel's
    //     `deepreview-unified-line-*` DOM to the Monaco diff tab's whole-line
    //     decorations (§4, DR-R4).  The counts are per FILE now rather than
    //     summed across the changeset, because a review opens one diff
    //     document per file rather than one scrolling list of all of them —
    //     so the assertion is 8 added / 3 removed for src/main.rs instead of
    //     16 / 10 across three files, and it is checked for the second file
    //     too so the total is still accounted for.
    //   * Steps 7-8 (context expansion) move to the diff tab's expand control
    //     lines (§4.2, DR-R5).
    //
    // Step 9 (Omniscience inline values) is dropped rather than retargeted:
    // the panel drew them itself, §7 forbids that rendering, and the correct
    // one — Monaco flow decorations from a `FlowUpdate` — does not exist yet.
    // DR-R6 owns it and is blocked on M42b.  This is recorded here rather
    // than silently: it is the one assertion of this test that has no home
    // today.
    test("DR-8: full end-to-end workflow through all DeepReview features", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();
      await wait(1000);

      // Step 1-2: the review names itself in the VCS panel header.
      await expect(dr.vcsReviewTitle()).toBeVisible();
      const titleText = await dr.vcsReviewTitle().textContent();
      expect(titleText).toContain("DeepReview: parser cleanup");

      // Step 3: the VCS panel lists 3 files with the right diff statuses.
      const items = await dr.fileItems();
      expect(items.length).toBe(3);

      const expectedStatuses = ["M", "A", "D"];
      for (let i = 0; i < items.length; i++) {
        const status = await items[i].diffStatus();
        expect(status).toBe(expectedStatuses[i]);
      }

      // Verify the first file is selected by default.
      expect(await items[0].isSelected()).toBe(true);

      // Step 4: click the second file and verify the selection moves.
      await wait(500);

      const secondItem = dr.fileItemByIndex(1);
      await secondItem.click();
      await wait(500);

      expect(await secondItem.isSelected()).toBe(true);
      expect(await dr.fileItemByIndex(0).isSelected()).toBe(false);

      // Step 5: a review starts in Unified Diff mode, and a click opened the
      // file's diff as a Monaco document.
      expect(await dr.isUnifiedDiffMode()).toBe(true);
      const utilsTab = dr.diffTabFor("src/utils.rs");
      await expect(utilsTab).toBeVisible({ timeout: 20_000 });

      // Step 6: hunks render with the right added/removed line counts.
      // src/utils.rs is a pure addition: +8, -0.
      await expect(
        DeepReviewPage.diffTabAddedLines(utilsTab),
      ).toHaveCount(8, { timeout: 15_000 });
      await expect(DeepReviewPage.diffTabRemovedLines(utilsTab)).toHaveCount(0);
      await expect(
        DeepReviewPage.diffHunkHeaderLinesIn(utilsTab),
      ).toHaveCount(1);

      // ...and src/main.rs is a modification: +8, -3, in one hunk.
      await dr.fileItemByIndex(0).click();
      const mainTab = dr.diffTabFor("src/main.rs");
      await expect(mainTab).toBeVisible({ timeout: 20_000 });
      await expect(
        DeepReviewPage.diffTabAddedLines(mainTab),
      ).toHaveCount(8, { timeout: 15_000 });
      await expect(DeepReviewPage.diffTabRemovedLines(mainTab)).toHaveCount(3);
      await expect(
        DeepReviewPage.diffHunkHeaderLinesIn(mainTab),
      ).toHaveCount(1);

      // Step 7-8: expanding the boundary below the hunk brings hidden lines
      // on screen, and they arrive as ordinary context lines — DR-R5's rule
      // that expansion adds no fourth, inert line kind, which UD-2 makes
      // structural: they were context lines of the document all along.
      await expect
        .poll(
          async () =>
            await DeepReviewPage.expansionBoundaries(mainTab).count(),
          { timeout: 15_000 },
        )
        .toBeGreaterThan(0);
      const hiddenBefore = (
        await DeepReviewPage.hiddenLineCounts(mainTab)
      )[0];
      expect(hiddenBefore).toBeGreaterThan(0);

      await DeepReviewPage.expandAboveHandle(mainTab).click();

      await expect
        .poll(
          async () => (await DeepReviewPage.hiddenLineCounts(mainTab))[0] ?? 0,
          { timeout: 15_000 },
        )
        .toBeLessThan(hiddenBefore);
      await expect(
        DeepReviewPage.diffTabContextLines(mainTab).first(),
      ).toBeAttached();

      // Step 10: switch trace context from the VCS panel header.
      await expect(dr.vcsTraceContextSelect()).toBeVisible();
      const options = dr.vcsTraceContextSelect().locator("option");
      expect(await options.count()).toBe(2);
      await dr.vcsTraceContextSelect().selectOption("1");
      await wait(500);
      expect(await dr.vcsTraceContextSelect().inputValue()).toBe("1");

      // ...and the third pillar is still there, still without a roll-up.
      await expect(dr.agentActivityPanel()).toBeVisible();
      await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
    });
  });

  // -----------------------------------------------------------------------
  // Empty review data: no crash, no file items, editor shows empty state
  // -----------------------------------------------------------------------

  test.describe("empty review data", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: emptyReviewPath });

    test("DR-8: empty review loads without crash and shows empty state", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      // Verify no crash: the review's navigation surface is up and no error
      // is showing.
      await expect(dr.vcsPanel()).toBeVisible();
      await expect(dr.vcsPanel().locator(".vcs-error")).toHaveCount(0);
      await expect(ctPage.locator(".deepreview-error")).toHaveCount(0);

      // Verify no file items in the VCS panel...
      const items = await dr.fileItems();
      expect(items.length).toBe(0);

      // ...and that the header reports it rather than leaving the count blank.
      const commitText = await dr
        .vcsPanel()
        .locator(".vcs-changed-files-commit")
        .textContent();
      expect(commitText).toContain("0 files");

      // An empty review opens no editor document either — §7 step 2 has no
      // first modified file to open.  Covered headlessly by "an empty review
      // opens nothing" in deepreview_vm_test.nim.
      await expect(dr.diffTabs()).toHaveCount(0);
    });
  });

  // -----------------------------------------------------------------------
  // No calltrace review data: everything works except calltrace is empty
  // -----------------------------------------------------------------------

  test.describe("no calltrace review data", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: noCalltracePath });

    test("DR-8: no-calltrace review loads and shows file in VCS panel", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      // Verify the review renders without errors.
      await expect(dr.vcsPanel()).toBeVisible();
      await expect(dr.vcsPanel().locator(".vcs-error")).toHaveCount(0);
      await expect(ctPage.locator(".deepreview-error")).toHaveCount(0);

      // Verify the VCS panel file list works (1 file in the fixture).
      const items = await dr.fileItems();
      expect(items.length).toBe(1);

      const name = await items[0].name();
      expect(name).toBe("lib.rs");

      // Note: the call tree belongs to the CALLTRACE panel
      // (DeepReview-GUI.md §2), and a dataset launch loads no recording, so
      // RV-2 keeps that panel out of the layout entirely rather than showing
      // it empty. This assertion was `toContain("CALLTRACE")` while the
      // dataset launch still opened the debugging layout; the fixture's point
      // — a review with no calltrace data loads and works — is unchanged and
      // is asserted above.
      const titles = await dr.layoutTabTitles();
      expect(titles).not.toContain("CALLTRACE");
      expect(titles).toContain("VCS");
    });
  });

  // -----------------------------------------------------------------------
  // RV-4: a review over a MATERIALIZED (CTFS) recording
  // -----------------------------------------------------------------------

  test.describe("a materialized-trace review", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: materializedReviewPath });

    // The milestone's third verification entry, end to end: `ct review` over a
    // dataset the db-backend collector produced from a real materialized
    // recording. DeepReview-GUI.md §1.1: "DeepReview is not an rr-only
    // feature. Every language that produces a materialized trace — Python,
    // Ruby, JavaScript, Noir, and the rest — must be reviewable."
    //
    // Before RV-4 this dataset could not exist: `ct review collect` over
    // materialized recordings refused with "does not support this trace kind
    // yet".
    test("RV-4: a dataset collected from a materialized recording opens a review", async ({
      ctPage,
    }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.vcsPanel()).toBeVisible();
      await expect(dr.vcsPanel().locator(".vcs-error")).toHaveCount(0);
      await expect(ctPage.locator(".deepreview-error")).toHaveCount(0);

      // The one file of the collected changeset, named the way the patch
      // names it.
      const items = await dr.fileItems();
      expect(items.length).toBe(1);
      expect(await items[0].name()).toBe("main.nr");
      expect(await items[0].diffStatus()).toBe("M");

      // Coverage came from the recording, not from a placeholder: the badge
      // reports covered-of-total for the file — ten lines, every one of them
      // executed, because the collector writes a record only for a line it
      // observed.
      const coverage = await items[0].coverageBadge();
      expect(coverage).toBeTruthy();
      expect(coverage).toContain("10/10");

      // …and the review is on the editor layout RV-2 established, so no panel
      // a dataset cannot populate is shown.
      const titles = await dr.layoutTabTitles();
      expect(titles).toContain("VCS");
      expect(titles).not.toContain("CALLTRACE");
      expect(titles).not.toContain("EVENT LOG");
    });

    // The trace-context selector is the VCS panel's "which run am I looking
    // at" control (DeepReview-GUI.md §3). It is only offered when there is a
    // choice (`vcs_vm.hasTraceContextChoice`), which is why the fixture holds
    // TWO recordings. The native exporter emits no contexts at all, so no
    // other fixture in this directory can exercise this control from a
    // collector's real output.
    test("RV-4: the review names the recording it was collected from", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.vcsTraceContextSelector()).toBeVisible();
      const options = await dr.vcsTraceContextSelect().locator("option").allTextContents();
      expect(options.map((o) => o.trim())).toEqual(["run-1", "run-2"]);
    });

    // RV-4 deliverable 4, at the surface a user sees.  The card that used to
    // say "not available for this dataset" went with the roll-up (AA-1), and
    // the rule it encoded is what survives it: absent data is never rendered
    // as a zero that reads as success.  So the assertion is now that the
    // review shows nothing about tests at all — not "0/0", not "all passing",
    // not a green pill — because it knows nothing about them.
    test("RV-4: a materialized review claims nothing about tests it never saw", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.agentActivityPanel()).toBeVisible();
      await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);

      const panelText = (await dr.agentActivityPanel().textContent()) ?? "";
      expect(panelText).not.toContain("all passing");
      expect(panelText).not.toContain("0/0");
      expect(panelText).not.toMatch(/\b0 passed\b/);
      // …and the coverage the dataset DOES carry is where it belongs: on the
      // VCS panel's Changed Files row, which is the surface that survived.
      const files = await dr.fileItems();
      expect(files.length).toBeGreaterThan(0);
      expect(await files[0].coverageBadge()).toBe("10/10");
    });
  });
});
