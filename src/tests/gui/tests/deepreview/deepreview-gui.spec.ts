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

import { DeepReviewPage } from "./page-objects/deepreview-page";

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
  // breath — that the Agent Activity panel's DeepReview section, whose name
  // is nearly identical and which is the review's third pillar (§2.1), is
  // still there.  Falsifiable before DR-R8: all four selectors resolved.
  //
  // Headless counterparts:
  //   test_review_startup_adds_no_review_panel in
  //   src/tests/gui/tests/layout/deepreview_layout_test.nim, and
  //   test_agent_activity_deepreview_survives_the_deletion in
  //   src/tests/gui/tests/agent-activity-deepreview/agent_activity_deepreview_vm_test.nim.
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

    // ...while the OTHER DeepReview — the Agent Activity panel's section, a
    // different Content id with a nearly identical name — is still rendered
    // and still populated (§2.1).
    await expect(dr.reviewActivitySection()).toBeVisible();
    await expect(dr.reviewActivityCoverageCard()).toContainText("83.3%");
    await expect(dr.reviewActivityFileRows()).toHaveCount(3);
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
    await expect(tab.locator(".monaco-editor .view-lines")).toBeVisible({
      timeout: 20_000,
    });
    return tab;
  }

  test("Test 10: the review's diff tabs are Monaco documents headed by their file", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    // DeepReview-GUI.md §4.1: "Each diff tab includes: A file header with path
    // and diff metadata".  All 3 files in the fixture have hunks, so each
    // opens a tab whose document is headed by that file.
    for (const [index, filePath] of [
      [0, "src/main.rs"],
      [1, "src/utils.rs"],
      [2, "src/config.rs"],
    ] as [number, string][]) {
      const tab = await openReviewDiffTab(dr, index, filePath);
      // A real editor, not a DOM diff.
      await expect(tab.locator(".monaco-editor")).toBeVisible();
      const header = tab.locator(".monaco-editor .view-line", {
        hasText: filePath,
      });
      await expect(header.first()).toBeVisible({ timeout: 15_000 });
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
    const expected: [number, string, number, number, number][] = [
      [0, "src/main.rs", 8, 3, 2],
      [1, "src/utils.rs", 8, 0, 0],
      [2, "src/config.rs", 0, 7, 0],
    ];

    for (const [index, filePath, added, removed, context] of expected) {
      const tab = await openReviewDiffTab(dr, index, filePath);
      const overlays = tab.locator(".view-overlays");
      await expect
        .poll(async () => await overlays.locator(".ct-diff-line-added").count(), {
          timeout: 15_000,
        })
        .toBe(added);
      expect(await overlays.locator(".ct-diff-line-removed").count()).toBe(
        removed,
      );
      expect(await overlays.locator(".ct-diff-line-context").count()).toBe(
        context,
      );
      // Exactly one hunk per file in the fixture, rendered as a section
      // divider (VCS-Panel.md: "Hunk headers (@@ -N,M +N,M @@) shown as
      // section dividers").
      expect(await overlays.locator(".ct-diff-line-hunk-header").count()).toBe(1);

      // ...and the `+` / `-` gutter markers VCS-Panel.md requires.
      const margin = tab.locator(".margin-view-overlays");
      expect(await margin.locator(".ct-diff-gutter-added").count()).toBe(added);
      expect(await margin.locator(".ct-diff-gutter-removed").count()).toBe(
        removed,
      );
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
    const lines = tab.locator(".monaco-editor .view-lines");

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
    // lines 14-20, so it reaches the tab after one "expand below" click.  It
    // recorded three passes over the header line 16:
    //   pass 1  i = 0, acc = 0
    //   pass 2  i = 1, acc = 1
    //   pass 3  i = 2, acc = 3
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    await expect(DeepReviewPage.expandBelowLine(tab)).toHaveCount(1, {
      timeout: 20_000,
    });
    await DeepReviewPage.expandBelowLine(tab).click();

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
    // `compute` is not on screen in this hunk and gets no control at all.
    await expect(selector.first().locator(".review-invocation-label")).toHaveText(
      "main: call 1 / 2",
    );
    expect(await selector.count()).toBe(1);
  });

  test("Test 28: stepping the selector switches the rendered invocation", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openReviewDiffTab(dr, 0, "src/main.rs");
    const selector = tab.locator(".review-invocation-selector").first();
    await expect(selector).toBeVisible({ timeout: 20_000 });

    const lines = tab.locator(".monaco-editor .view-lines");
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
        .locator(".monaco-editor .view-line", { hasText: "@@ -0,0 +1,8 @@" })
        .first(),
    ).toBeVisible({ timeout: 15_000 });

    await openReviewDiffTab(dr, 0, "src/main.rs");
    expect(await dr.diffTabs().count()).toBe(2);
    await expect(
      dr
        .diffTabFor("src/main.rs")
        .locator(".monaco-editor .view-line", { hasText: "@@ -2,5 +2,10 @@" })
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
  // Still `test.skip`, for the reason they were skipped before and not for a
  // new one: the overlays are drawn over the file's real source text, and
  // `--deepreview` mode loads no recording to supply it (M42b).  Restore them
  // with the trace plumbing.  They are kept rather than deleted precisely
  // because the capability survived the deletion — deleting them would drop
  // the only end-to-end coverage §5.1 will ever have.

  test.skip("Test 19: diff decorations appear in Full Files Mode for modified file", async ({ ctPage }) => {
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

  test.skip("Test 20: added lines have green decoration class for purely added file", async ({ ctPage }) => {
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

  test.skip("Test 21: diff decorations are removed when switching to a file without diff data", async ({ ctPage }) => {
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

    // Switch to the third file (src/config.rs, deleted) — all lines are
    // removed, so there should be no diff decorations at all (removed
    // lines have no position in the new file).
    const thirdItem = dr.fileItemByIndex(2);
    await thirdItem.click();
    await wait(1000);

    const deletedAdded = await dr.editorDiffAddedLines().count();
    const deletedModified = await dr.editorDiffModifiedLines().count();
    expect(deletedAdded).toBe(0);
    expect(deletedModified).toBe(0);
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

    // Pillar 3 — the Agent Activity panel: its DeepReview section is visible,
    // expanded, and showing this changeset's coverage (§2.1). No agent ran:
    // the dataset alone fills it.
    expect(activeTitles).toContain("AGENT ACTIVITY");
    await expect(dr.reviewActivitySection()).toBeVisible();
    await expect(dr.reviewActivityCoverageCard()).toContainText("83.3%");
    await expect(dr.reviewActivityFileRows()).toHaveCount(3);

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
  // Tests 14-16: Context expansion in the diff tab (DR-R5)
  // -----------------------------------------------------------------------

  // e2e_diff_tab_expand_reveals_context — the rewrite of "Test 14: expand
  // buttons are visible around hunks", "Test 15: clicking expand above
  // reveals additional context lines" and "Test 16: clicking expand below".
  //
  // Same three scenarios, retargeted from the standalone DeepReview panel's
  // `deepreview-expand-*` DOM to the Monaco diff tab, which is where
  // DeepReview-GUI.md §4.2 puts them:
  //
  //   "The user can reveal surrounding unchanged lines around the changed
  //    regions.  Required controls: Expand surrounding context above a
  //    visible region / Expand surrounding context below a visible region /
  //    Repeated expansion loads more file content instead of merely
  //    uncovering lines that were already fetched."
  //
  //   "Context expansion is incremental loading.  Newly revealed lines become
  //    normal code lines in the diff tab and can receive Omniscience overlays
  //    when matching DeepReview data exists."
  //
  // The old tests asserted only that *some* lines appeared; these assert
  // WHICH — the revealed line numbers and their text — because the arithmetic
  // being migrated is the clamping at a file's first and last line, and a
  // count-only assertion passes with every off-by-one it can make.
  //
  // Falsifiable against the ported code: before DR-R5 the diff tab had no
  // expand controls at all (the capability lived only in `ui/deepreview.nim`,
  // the panel DR-R8 deletes), so every locator below found nothing.
  //
  // Fixture geometry, from `sample-review.json` — src/main.rs has one hunk at
  // new lines 2..11 in a 25-line file, so:
  //   above: exactly ONE hidden line (line 1, "fn main() {"), after which no
  //          further expansion above is possible;
  //   below: lines 12..25 hidden, so one step reveals 12..21 and a further
  //          step is still offered.
  // That asymmetry is deliberate — it exercises the clamp in one direction
  // and the "more remains" branch in the other within a single fixture.
  //
  // Headless counterparts:
  //   test_context_expansion_window_reveals_lines_above_and_below and
  //   test_context_expansion_clamps_at_file_boundaries in
  //   src/tests/gui/tests/vcs/vcs_context_expansion_test.nim;
  //   test_context_expansion_state_is_per_hunk_and_per_file in
  //   src/tests/gui/tests/vcs/vcs_vm_test.nim.

  /// Open src/main.rs's diff tab and wait for Monaco to render its lines.
  async function openMainDiffTab(dr: DeepReviewPage) {
    await dr.fileItemByIndex(0).click();
    const tab = dr.diffTabFor("src/main.rs");
    await expect(tab).toBeVisible({ timeout: 20_000 });
    await expect(tab.locator(".monaco-editor .view-lines")).toBeVisible({
      timeout: 20_000,
    });
    return tab;
  }

  test("Test 14: the diff tab offers expand controls around a hunk with hidden neighbours", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTab(dr);

    // VCS-Panel.md, "Unified Diff View (Editor Integration)": "Context
    // expansion controls (Expand N lines above/below)".  Both directions are
    // offered: main.rs's hunk has one hidden line above it and fourteen below.
    await expect(DeepReviewPage.expandAboveLine(tab)).toHaveCount(1, {
      timeout: 15_000,
    });
    await expect(DeepReviewPage.expandBelowLine(tab)).toHaveCount(1);

    // The control names how much a click reveals, and the number is the step
    // the ViewModel actually advances by (`ContextExpandStep`).
    await expect(DeepReviewPage.expandAboveLine(tab)).toHaveText(
      /Expand\s+10\s+lines\s+above/,
    );
    await expect(DeepReviewPage.expandBelowLine(tab)).toHaveText(
      /Expand\s+10\s+lines\s+below/,
    );

    // Nothing is revealed until a control is pressed.
    await expect(DeepReviewPage.revealedDecorations(tab)).toHaveCount(0);
  });

  test("Test 15: clicking expand above reveals the lines preceding the hunk", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTab(dr);

    // The hunk starts at new line 2, so line 1 is not in the diff and its
    // number is absent from the gutter before expanding.
    const before = await DeepReviewPage.diffLineNumbers(tab);
    expect(before).not.toContain("1 1");

    await DeepReviewPage.expandAboveLine(tab).click();

    // Exactly one line exists above the hunk, so exactly one is revealed —
    // the clamp, asserted through the UI it protects.
    await expect(DeepReviewPage.revealedDecorations(tab)).toHaveCount(1, {
      timeout: 15_000,
    });

    // ...and it is the right one: line 1 of src/main.rs, by number and by
    // text.  A revealed line is unchanged, so it carries the same old and new
    // number.
    const after = await DeepReviewPage.diffLineNumbers(tab);
    expect(after).toContain("1 1");
    await expect(
      // Monaco renders runs of spaces as U+00A0, so the regex uses `\s`
      // rather than a literal space (the same trap DR-R4 hit on `@@`).
      tab.locator(".monaco-editor .view-line", { hasText: /fn\s+main\(\)\s+\{/ }),
    ).toHaveCount(1);

    // §4.2: "Newly revealed lines become normal code lines in the diff tab"
    // — the revealed line is decorated as context, not as a fourth kind, so
    // it is eligible for the Omniscience overlay DR-R6 draws on context lines.
    await expect(
      tab.locator(".view-overlays .ct-diff-line-context.ct-diff-line-revealed"),
    ).toHaveCount(1);

    // Nothing further is hidden above, so the control is gone — a user cannot
    // press a button that can no longer act.
    await expect(DeepReviewPage.expandAboveLine(tab)).toHaveCount(0);
  });

  test("Test 16: clicking expand below reveals further content on each click", async ({ ctPage }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const tab = await openMainDiffTab(dr);

    await DeepReviewPage.expandBelowLine(tab).click();

    // The hunk ends at new line 11 and the file has 25 lines, so one step
    // reveals lines 12..21.
    await expect(DeepReviewPage.revealedDecorations(tab)).toHaveCount(10, {
      timeout: 15_000,
    });
    const afterFirst = await DeepReviewPage.diffLineNumbers(tab);
    expect(afterFirst).toContain("12 12");
    expect(afterFirst).toContain("21 21");
    expect(afterFirst).not.toContain("22 22");
    // Line 12 of main.rs is the closing brace of `fn main`.
    await expect(
      tab.locator(".view-overlays .ct-diff-line-revealed"),
    ).toHaveCount(10);

    // §4.2's third required control: "Repeated expansion loads more file
    // content instead of merely uncovering lines that were already fetched."
    // Four lines remain (22..25), so a second click reveals those four rather
    // than re-revealing the first ten.
    await DeepReviewPage.expandBelowLine(tab).click();
    await expect(DeepReviewPage.revealedDecorations(tab)).toHaveCount(14, {
      timeout: 15_000,
    });
    const afterSecond = await DeepReviewPage.diffLineNumbers(tab);
    expect(afterSecond).toContain("22 22");
    expect(afterSecond).toContain("25 25");

    // The file is exhausted, so the control disappears.
    await expect(DeepReviewPage.expandBelowLine(tab)).toHaveCount(0);
  });

  test("Test 16b: expansion is per hunk and per file, and resets when the tab closes", async ({ ctPage }) => {
    // DR-R5: "Expansion state resets when the tab is closed and does not leak
    // between files."  Each diff tab owns its own `VCSVM`, so a second file's
    // tab must open unexpanded however far the first was expanded.
    //
    // Headless counterpart: "closing the tab resets the expansion, and it
    // never leaks between files" in
    // src/tests/gui/tests/vcs/vcs_vm_test.nim.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(500);

    const mainTab = await openMainDiffTab(dr);
    await DeepReviewPage.expandBelowLine(mainTab).click();
    await expect(DeepReviewPage.revealedDecorations(mainTab)).toHaveCount(10, {
      timeout: 15_000,
    });

    // A different file's tab starts from nothing revealed.
    await dr.fileItemByIndex(1).click();
    const utilsTab = dr.diffTabFor("src/utils.rs");
    await expect(utilsTab).toBeVisible({ timeout: 20_000 });
    await expect(
      utilsTab.locator(".monaco-editor .view-lines"),
    ).toBeVisible({ timeout: 20_000 });
    await expect(DeepReviewPage.revealedDecorations(utilsTab)).toHaveCount(0);

    // ...and coming back finds main.rs still expanded: the state is on the
    // ViewModel, so it survives the tab losing and regaining focus.
    await dr.fileItemByIndex(0).click();
    await expect(mainTab.locator(".monaco-editor .view-lines")).toBeVisible({
      timeout: 20_000,
    });
    await expect(DeepReviewPage.revealedDecorations(mainTab)).toHaveCount(10, {
      timeout: 15_000,
    });

    // Closing the tab must drop its ViewModel and its source cache, so
    // reopening the same file starts unexpanded.  This is the only coverage
    // of the `closeLayoutTab` -> `forgetUnifiedDiffTab` wiring: the tab
    // component is JS-only and cannot be reached headlessly, so without these
    // four lines the test's own title would be asserting nothing.
    const mainTabHeader = ctPage
      .locator(".lm_tab")
      .filter({ hasText: /^Diff:\s*main\.rs/ })
      .first();
    await mainTabHeader.locator(".lm_close_tab").click();
    await expect(mainTabHeader).toHaveCount(0, { timeout: 20_000 });

    const reopened = await openMainDiffTab(dr);
    await expect(
      reopened.locator(".monaco-editor .view-lines"),
    ).toBeVisible({ timeout: 20_000 });
    await expect(DeepReviewPage.revealedDecorations(reopened)).toHaveCount(0);
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

      // Step 7-8: expanding context above the hunk reveals lines that were
      // hidden, and they arrive marked as revealed.
      await expect(
        DeepReviewPage.revealedDecorations(mainTab),
      ).toHaveCount(0);

      const expandAbove = DeepReviewPage.expandAboveLine(mainTab);
      await expect(expandAbove).toHaveCount(1, { timeout: 15_000 });
      await expandAbove.click();

      await expect(
        DeepReviewPage.revealedDecorations(mainTab),
      ).toHaveCount(1, { timeout: 15_000 });
      // A revealed line is an ordinary context line of the document — DR-R5's
      // rule that expansion adds no fourth, inert line kind.
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

      // ...and the third pillar is populated from the same dataset (§2.1).
      await expect(dr.reviewActivitySection()).toBeVisible();
      await expect(dr.reviewActivityFileRows()).toHaveCount(3);
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

    // RV-4 deliverable 4, at the surface a user sees: the dataset carries no
    // test results, and the pane must say so rather than show a zeroed
    // roll-up that reads as "all tests passed" (DR-R3).
    test("RV-4: a materialized review reports test results as unavailable", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();

      await expect(dr.reviewActivitySection()).toBeVisible();
      await expect(dr.reviewActivityCoverageCard()).toBeVisible();
      // Asserted the way the native-dataset suite asserts it
      // (`agent-activity-deepreview.spec.ts:e2e_review_test_results_row_says_the_dataset_carries_none`):
      // the pane must SAY the dataset carries none, not merely avoid printing
      // a zero — an empty or errored card would pass a negative check alone.
      const tests = await dr.reviewActivityTestsCard().textContent();
      expect(tests).toContain("not available for this dataset");
      expect(tests).not.toContain("all passing");
      expect(tests ?? "").not.toMatch(/\b0 passed\b/);
    });
  });
});
