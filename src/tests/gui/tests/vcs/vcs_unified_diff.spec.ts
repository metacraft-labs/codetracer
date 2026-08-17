// VCS panel — "View Diff" opens a unified diff tab (issues #561 / #611, DR-R4).
//
// The button used to do nothing at all: `openLayoutTab` treated every VCS
// request as a request for the *singleton* VCS panel, so a click re-focused
// the already-active docked panel and returned without creating a tab, logging
// anything, or raising.  Everything downstream of that early return had never
// executed.  These scenarios pin the whole path end to end:
//
//   VCS-004  a unified diff view opens in the editor area with decorations
//   #561     the diff must NOT replace the VCS panel's commit history
//   #611     a second click focuses the existing tab rather than stacking
//            duplicates
//
// DR-R4 changed what the tab *is*, not what opens it.  It used to be a second
// VCS panel instance drawing nested `tdiv` elements; it is now a real Monaco
// editor whose model holds the assembled diff text, per VCS-Panel.md,
// "Unified Diff View (Editor Integration)": "Uses the standard CodeTracer
// Monaco editor".  The scenarios above are unchanged in substance; the
// assertions that named the DOM renderer's markup now name Monaco's decoration
// layers, and two scenarios are added for what only a real editor can do.
//
// Fixture: a throwaway git repository whose newest commit rewrites two regions
// of one file, so the diff carries added lines, removed lines, context lines
// and — importantly for the hunk editor — TWO hunks.

import { test, expect } from "../../lib/fixtures";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const gitFixture = fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-vcs-diff-"));

function git(...args: string[]): void {
  childProcess.execFileSync("git", args, { cwd: gitFixture, stdio: "ignore" });
}

function commit(message: string): void {
  git("add", ".");
  git(
    "-c",
    "user.name=CodeTracer Tests",
    "-c",
    "user.email=tests@codetracer.dev",
    "commit",
    "-m",
    message,
  );
}

/// Build main.nim with the two greeting lines parameterised.  The two edited
/// lines are 20 lines apart, comfortably more than twice git's 3-line context,
/// so a diff between two versions produces two separate hunks.
function mainNim(first: string, last: string): string {
  const filler = Array.from(
    { length: 20 },
    (_, i) => `  echo "filler ${i}"`,
  ).join("\n");
  return `proc main() =\n  echo "${first}"\n${filler}\n  echo "${last}"\n  echo "unchanged"\n`;
}

fs.mkdirSync(path.join(gitFixture, "src"), { recursive: true });
fs.writeFileSync(path.join(gitFixture, "README.md"), "# VCS diff fixture\n");
fs.writeFileSync(path.join(gitFixture, "src", "main.nim"), mainNim("first", "tail"));
git("init");
commit("initial");

// A second commit so the newest commit has real modification hunks
// (one removed line and one added line in each of two regions) rather than a
// pure file addition.
fs.writeFileSync(path.join(gitFixture, "src", "main.nim"), mainNim("second", "TAIL"));
commit("change the greeting");

async function openVcsPanel(ctPage: any): Promise<void> {
  await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 45_000 });
  await ctPage.locator(".lm_tab", { hasText: "VCS" }).first().click();
  await expect(ctPage.locator(".vcs-container").first()).toBeVisible({
    timeout: 15_000,
  });
  await expect(ctPage.locator(".vcs-commit-header").first()).toBeVisible({
    timeout: 30_000,
  });
}

/// Expand the newest commit and click the "View Diff" button of one of its
/// file rows.  The button is `display: none` until the row is hovered, so the
/// hover is part of the interaction, not a workaround.
///
/// Expanding is conditional because a commit header is a TOGGLE: the second
/// call in "clicking View Diff twice" would otherwise collapse the accordion
/// the first call opened, and the file row it needs would be gone.
async function clickViewDiffOnNewestCommit(ctPage: any): Promise<void> {
  const fileRow = ctPage.locator(".vcs-accordion-file").first();
  if ((await fileRow.count()) === 0) {
    await ctPage.locator(".vcs-commit-header").first().click();
  }
  await expect(fileRow).toBeVisible({ timeout: 15_000 });
  await fileRow.hover();
  const diffButton = fileRow.locator(".vcs-file-diff-btn").first();
  await expect(diffButton).toBeVisible({ timeout: 5_000 });
  await diffButton.click();
}

/// The diff tab's Monaco editor, once it has rendered its content.
function diffEditor(ctPage: any) {
  return ctPage.locator(".unified-diff-container .monaco-editor").first();
}

/// The rendered lines whose text is a hunk header.  Monaco renders the model
/// text into `.view-line` elements, so this is the same `@@` divider a reader
/// sees — and the click target the hunk editor listens on.
function hunkHeaderLines(ctPage: any) {
  return ctPage
    .locator(".unified-diff-container .monaco-editor .view-line")
    // `\s` rather than a literal space, and unanchored: Monaco renders runs
    // of spaces as U+00A0 to preserve their width, and matches `hasText`
    // regexes against the element's raw text rather than a normalized copy.
    .filter({ hasText: /@@\s-\d+,\d+\s\+\d+,\d+\s@@/ });
}

async function waitForDiffTab(ctPage: any): Promise<void> {
  await expect(diffEditor(ctPage)).toBeVisible({ timeout: 20_000 });
  await expect
    .poll(async () => await hunkHeaderLines(ctPage).count(), { timeout: 20_000 })
    .toBeGreaterThan(0);
}

test.describe("VCS unified diff", () => {
  test.use({ launchMode: "edit", editFolderPath: gitFixture });

  test("View Diff opens a dedicated diff tab with diff decorations", async ({
    ctPage,
  }) => {
    await openVcsPanel(ctPage);

    const tabsBefore = await ctPage.locator(".lm_tab").count();

    await clickViewDiffOnNewestCommit(ctPage);

    // VCS-004: a new tab appears in the editor area.
    await expect
      .poll(async () => await ctPage.locator(".lm_tab").count(), {
        timeout: 15_000,
      })
      .toBe(tabsBefore + 1);

    // ... titled after the file it is showing, and focused.
    const diffTabHandle = ctPage.locator(".lm_tab", { hasText: /Diff:/ }).first();
    await expect(diffTabHandle).toBeVisible({ timeout: 15_000 });
    await expect(diffTabHandle).toHaveText(/Diff:\s*main\.nim/);
    await expect(diffTabHandle).toHaveClass(/lm_active/);

    // ... and actually containing the diff, not an empty shell.  The fixture's
    // newest commit rewrites two lines, so additions and removals must both be
    // decorated, and the hunk headers must be present as section dividers.
    await waitForDiffTab(ctPage);
    await expect
      .poll(
        async () =>
          await ctPage
            .locator(".unified-diff-container .view-overlays .ct-diff-line-added")
            .count(),
        { timeout: 15_000 },
      )
      .toBeGreaterThan(0);
    await expect(
      ctPage
        .locator(".unified-diff-container .view-overlays .ct-diff-line-removed")
        .first(),
    ).toBeAttached({ timeout: 15_000 });
    await expect(hunkHeaderLines(ctPage).first()).toHaveText(
      /@@\s-\d+,\d+\s\+\d+,\d+\s@@/,
    );

    // #561: the diff is an additional tab, not a replacement for the panel —
    // the VCS panel must still be showing its commit history.
    await expect(ctPage.locator(".vcs-commit-list").first()).toBeVisible();
    await expect(ctPage.locator(".vcs-commit-header").first()).toBeVisible();
  });

  // e2e_unified_diff_tab_is_a_monaco_editor (DR-R4).
  //
  // VCS-Panel.md, "Unified Diff View (Editor Integration)": "Uses the standard
  // CodeTracer Monaco editor".  DeepReview-GUI.md §4: "there is no separate
  // diff renderer for reviews, and no DOM-based diff surface: the diff is
  // Monaco content with decorations, so every editor affordance (search,
  // selection, copy, minimap, keyboard navigation) works inside it."
  //
  // Falsifiable before DR-R4: the tab contained `.deepreview-unified-line`
  // elements and no Monaco instance at all.
  //
  // Headless counterparts: test_diff_decorations_classify_added_removed_context,
  // test_diff_decorations_are_mode_agnostic and test_diff_dual_line_numbers in
  // src/tests/gui/tests/vcs/vcs_diff_decorations_test.nim.
  test("e2e_unified_diff_tab_is_a_monaco_editor", async ({ ctPage }) => {
    await openVcsPanel(ctPage);
    await clickViewDiffOnNewestCommit(ctPage);
    await waitForDiffTab(ctPage);

    const tab = ctPage.locator(".unified-diff-container").first();

    // A real editor: Monaco's own view layers are there.
    await expect(tab.locator(".monaco-editor")).toBeVisible();
    await expect(tab.locator(".monaco-editor .view-lines")).toBeVisible();
    // ... including the minimap, one of the affordances a DOM diff cannot give.
    await expect(tab.locator(".monaco-editor .minimap")).toBeAttached();

    // The lines carry the diff decoration classes.
    const overlays = tab.locator(".view-overlays");
    await expect(overlays.locator(".ct-diff-line-added").first()).toBeAttached();
    await expect(overlays.locator(".ct-diff-line-removed").first()).toBeAttached();
    await expect(overlays.locator(".ct-diff-line-context").first()).toBeAttached();
    await expect(
      overlays.locator(".ct-diff-line-hunk-header").first(),
    ).toBeAttached();

    // ... and the `+` / `-` gutter markers are in the margin layer.
    const margin = tab.locator(".margin-view-overlays");
    await expect(margin.locator(".ct-diff-gutter-added").first()).toBeAttached();
    await expect(margin.locator(".ct-diff-gutter-removed").first()).toBeAttached();

    // The old DOM diff surface is gone from the page entirely — the VCS panel
    // no longer renders one either.
    await expect(ctPage.locator(".deepreview-unified-line")).toHaveCount(0);
    await expect(ctPage.locator(".deepreview-unified-diff")).toHaveCount(0);

    // Dual old/new line numbers, as the DOM renderer's two gutter columns
    // provided: a context line's label carries both.
    const lineNumbers = await tab
      .locator(".margin-view-overlays .line-numbers")
      .allTextContents();
    expect(lineNumbers.some((t) => /\d+\s+\d+/.test(t))).toBe(true);
  });

  // e2e_unified_diff_hunk_selection_and_copy (DR-R4).
  //
  // VCS-Panel.md, "Hunk Editor": "Click a hunk header to select it.
  // Shift-click to select a range of hunks." and "Copy — copy selected hunks
  // to clipboard (as patch format)".
  //
  // DeepReview-GUI.md §4.5 makes the hunk editor a constraint on the diff tab
  // rather than an optional extra, so this is the scenario that says the port
  // did not silently delete it.  The toolbar it asserts on is rendered from
  // `VCSVM.selectedHunks` / `hunkToolbarVisible` / `hunkCopyFeedback`: a tab
  // that kept a selection model of its own would leave it empty.
  //
  // Headless counterparts: test_hunk_selection_drives_the_shared_vcs_vm_state
  // and test_copy_as_patch_output_is_unchanged_by_the_monaco_port in
  // src/tests/gui/tests/vcs/vcs_vm_test.nim.
  test("e2e_unified_diff_hunk_selection_and_copy", async ({ ctPage }) => {
    await openVcsPanel(ctPage);
    await clickViewDiffOnNewestCommit(ctPage);
    await waitForDiffTab(ctPage);

    const tab = ctPage.locator(".unified-diff-container").first();
    const headers = hunkHeaderLines(ctPage);
    // The fixture's newest commit edits two regions 20 lines apart, so git
    // reports two hunks.
    await expect.poll(async () => await headers.count()).toBe(2);

    // No selection to begin with, so no toolbar.
    await expect(tab.locator(".hunk-toolbar")).toHaveCount(0);

    await headers.nth(0).click();
    await expect(tab.locator(".hunk-toolbar-count")).toHaveText(
      "1 hunk selected",
      { timeout: 10_000 },
    );

    // Shift-click extends the selection to a range.
    await headers.nth(1).click({ modifiers: ["Shift"] });
    await expect(tab.locator(".hunk-toolbar-count")).toHaveText(
      "2 hunks selected",
      { timeout: 10_000 },
    );

    // The selected hunks are marked on the Monaco content itself.
    await expect(
      tab.locator(".view-overlays .ct-diff-hunk-selected").first(),
    ).toBeAttached();

    // Copy as patch reports success.
    const copyButton = tab.locator(".hunk-toolbar-button").first();
    await expect(copyButton).toHaveText("Copy as patch");
    await copyButton.click();
    await expect(copyButton).toHaveText("Copied!", { timeout: 10_000 });

    // Clearing puts the toolbar away again.
    await tab.locator(".hunk-toolbar-button-subtle").click();
    await expect(tab.locator(".hunk-toolbar")).toHaveCount(0);
  });

  test("clicking View Diff twice focuses the tab instead of duplicating it", async ({
    ctPage,
  }) => {
    await openVcsPanel(ctPage);

    const tabsBefore = await ctPage.locator(".lm_tab").count();

    await clickViewDiffOnNewestCommit(ctPage);
    await expect
      .poll(async () => await ctPage.locator(".lm_tab").count(), {
        timeout: 15_000,
      })
      .toBe(tabsBefore + 1);

    // Reuse is keyed on the diff target, so asking for the same diff again
    // focuses the tab that already shows it.
    await clickViewDiffOnNewestCommit(ctPage);
    await expect
      .poll(async () => await ctPage.locator(".lm_tab").count(), {
        timeout: 15_000,
      })
      .toBe(tabsBefore + 1);

    const diffTab = ctPage.locator(".lm_tab", { hasText: /Diff:/ });
    await expect(diffTab).toHaveCount(1);
    await expect(diffTab.first()).toHaveClass(/lm_active/);
  });

  test("the view-mode toggle does not replace the commit history", async ({
    ctPage,
  }) => {
    // #561's original report.  `renderDiffToggle` was dead code and
    // `onToggleUnifiedDiff` was a `discard`, so the switch was absent; when it
    // was wired to the flag that drives the panel's own rendering it replaced
    // the commit list instead of changing what a file click does.
    await openVcsPanel(ctPage);

    const toggle = ctPage.locator(".vcs-diff-toggle .vcs-toggle-button").first();
    await expect(toggle).toBeVisible({ timeout: 15_000 });
    // `vcs.defaultView: "unified-diff"` — the switch starts active.
    await expect(toggle).toHaveClass(/vcs-toggle-active/);

    await toggle.click();

    await expect(toggle).not.toHaveClass(/vcs-toggle-active/);
    await expect(ctPage.locator(".vcs-commit-list").first()).toBeVisible();
    await expect(ctPage.locator(".vcs-commit-header").first()).toBeVisible();
  });

  test("a normal git session gets no review header extras", async ({
    ctPage,
  }) => {
    // DR-R2 added the review's trace-context selector and stats to the VCS
    // panel's header region.  `renderHeader` is reached only from the review
    // branch today, so they cannot leak here; this guards a future refactor
    // that unifies the two headers.  VCS-Panel.md, "Normal Development Mode":
    // the panel then watches a live working tree — there are no recordings to
    // choose between and no fixed changeset to summarise, so neither element
    // may appear or take space here.  Passes before DR-R2 as well as after.
    //
    // Headless counterpart: "a normal git session shows neither the selector
    // nor the stats" in src/tests/gui/tests/vcs/vcs_view_test.nim.
    await openVcsPanel(ctPage);

    await expect(ctPage.locator(".vcs-review-trace-selector")).toHaveCount(0);
    await expect(ctPage.locator(".vcs-review-trace-select")).toHaveCount(0);
    await expect(ctPage.locator(".vcs-review-stats")).toHaveCount(0);
    // The header itself is intact — the branch picker still names the branch.
    await expect(ctPage.locator(".vcs-branch-picker").first()).toBeVisible();
  });
});
