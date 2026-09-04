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
    // A runner with commit.gpgsign=true and no secret key would abort this
    // commit; the diff behaviour under test is unrelated to signing.
    "-c",
    "commit.gpgsign=false",
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

/// The code editor a unified diff tab renders into.
///
/// Since UD-1 the tab holds a Monaco **diff editor**, which is two code
/// editors — `original-in-monaco-diff-editor` for the old revision and
/// `modified-in-monaco-diff-editor` for the new one.  In the unified (inline)
/// layout the modified one is the scroll a reader reads: the old revision's
/// lines are drawn inside it as `view-lines line-delete` view zones.  The
/// one piece of chrome still inside the models — the `@@` divider — is present
/// in BOTH, byte-identical, so Monaco reads it as unchanged and draws it once
/// — which is exactly why every locator below has to name a side.  (The file
/// header left the model in UD-2: with `hideUnchangedRegions` on, line 1 is
/// what a collapsed run at the top of a file hides, so it is DOM chrome above
/// the editor now.)
const DIFF_BODY = ".monaco-editor.modified-in-monaco-diff-editor";
const DIFF_ORIGINAL = ".monaco-editor.original-in-monaco-diff-editor";

/// The diff tab's Monaco editor, once it has rendered its content.
function diffEditor(ctPage: any) {
  return ctPage.locator(`.unified-diff-container ${DIFF_BODY}`).first();
}

/// The rendered lines whose text is a hunk header.  Monaco renders the model
/// text into `.view-line` elements, so this is the same `@@` divider a reader
/// sees — and the click target the hunk editor listens on.
function hunkHeaderLines(ctPage: any) {
  return ctPage
    .locator(`.unified-diff-container ${DIFF_BODY} .view-line`)
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
            .locator(`.unified-diff-container ${DIFF_BODY} .view-overlays .ct-diff-line-added`)
            .count(),
        { timeout: 15_000 },
      )
      .toBeGreaterThan(0);
    await expect(
      ctPage
        .locator(`.unified-diff-container ${DIFF_ORIGINAL} .view-overlays .ct-diff-line-removed`)
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

    // A real editor: Monaco's own view layers are there.  Since UD-1 it is a
    // real *diff* editor in the unified (inline) layout — two code editors,
    // one per revision — which is what makes the highlighting and the
    // word-level marking Monaco's job rather than ours.
    await expect(tab.locator(".monaco-diff-editor")).toBeVisible();
    await expect(tab.locator(".monaco-diff-editor.side-by-side")).toHaveCount(0);
    await expect(diffEditor(ctPage)).toBeVisible();
    await expect(
      tab.locator(`${DIFF_BODY} > .overflow-guard .view-lines`).first(),
    ).toBeVisible();
    // ... including the minimap, one of the affordances a DOM diff cannot give.
    await expect(tab.locator(`${DIFF_BODY} .minimap`)).toBeAttached();

    // The lines carry the diff decoration classes, each on the side that has
    // those lines: an addition exists only in the new revision and a removal
    // only in the old one, which is the whole reason there are two models.
    const modified = tab.locator(`${DIFF_BODY} .view-overlays`);
    const original = tab.locator(`${DIFF_ORIGINAL} .view-overlays`);
    await expect(modified.locator(".ct-diff-line-added").first()).toBeAttached();
    await expect(original.locator(".ct-diff-line-removed").first()).toBeAttached();
    await expect(modified.locator(".ct-diff-line-context").first()).toBeAttached();
    await expect(
      modified.locator(".ct-diff-line-hunk-header").first(),
    ).toBeAttached();
    await expect(modified.locator(".ct-diff-line-removed")).toHaveCount(0);
    await expect(original.locator(".ct-diff-line-added")).toHaveCount(0);

    // ... and the `+` / `-` gutter markers are in each side's margin layer.
    await expect(
      tab.locator(`${DIFF_BODY} .margin-view-overlays .ct-diff-gutter-added`).first(),
    ).toBeAttached();
    await expect(
      tab
        .locator(`${DIFF_ORIGINAL} .margin-view-overlays .ct-diff-gutter-removed`)
        .first(),
    ).toBeAttached();

    // Monaco computed the diff itself, rather than being handed a document
    // that already looked like one: these are ITS classes, and `char-insert`
    // is the word-level intra-line marking a synthetic single model could not
    // produce at all.
    await expect(tab.locator(".line-insert").first()).toBeAttached();
    await expect(tab.locator(".line-delete").first()).toBeAttached();
    await expect
      .poll(async () => await tab.locator(".char-insert").count(), {
        timeout: 15_000,
      })
      .toBeGreaterThan(0);

    // The old DOM diff surface is gone from the page entirely — the VCS panel
    // no longer renders one either.
    await expect(ctPage.locator(".deepreview-unified-line")).toHaveCount(0);
    await expect(ctPage.locator(".deepreview-unified-diff")).toHaveCount(0);

    // Old and new line numbers, as the DOM renderer's two gutter columns
    // provided — one column per revision now that each revision has its own
    // editor, so a context line is numbered in both.
    const newNumbers = await tab
      .locator(`${DIFF_BODY} .margin-view-overlays .line-numbers`)
      .allTextContents();
    const oldNumbers = await tab
      .locator(`${DIFF_ORIGINAL} .margin-view-overlays .line-numbers`)
      .allTextContents();
    const digits = (labels: string[]) =>
      labels.map((t) => t.replace(/ /g, " ").trim()).filter((t) => t !== "");
    expect(digits(newNumbers).length).toBeGreaterThan(0);
    expect(digits(oldNumbers).length).toBeGreaterThan(0);
    // Each label is ONE number with its `+` / `-` / blank marker, not the
    // padded pair DR-R4 packed into a single gutter: with two editors the pair
    // is two columns, and a label carrying both numbers would mean the pair had
    // been drawn twice, once per side.
    for (const label of digits(newNumbers).concat(digits(oldNumbers))) {
      expect(label).toMatch(/^[-+]?\s*\d+$/);
    }
    // ... and the markers VCS-Panel.md requires are in it: `+` only on the new
    // revision's column, `-` only on the old one.
    expect(digits(newNumbers).some((t) => t.startsWith("+"))).toBe(true);
    expect(digits(newNumbers).some((t) => t.startsWith("-"))).toBe(false);
    expect(digits(oldNumbers).some((t) => t.startsWith("-"))).toBe(true);
    expect(digits(oldNumbers).some((t) => t.startsWith("+"))).toBe(false);
    // The `@@` divider belongs to neither revision and is numbered in neither
    // column, so there are fewer numbers than there are lines.  (Monaco
    // renders no element at all for an empty label, so the absence is counted
    // rather than matched.)
    const renderedLines = await tab
      .locator(`${DIFF_BODY} > .overflow-guard .view-lines .view-line`)
      .count();
    expect(renderedLines).toBeGreaterThan(digits(newNumbers).length);
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

// ---------------------------------------------------------------------------
// e2e_normal_git_diff_tab_expand_fetches_content (DR-R5)
// ---------------------------------------------------------------------------
//
// DeepReview-GUI.md §4.2 makes the content source the ONE thing the two
// instantiation modes of the diff tab may differ in:
//
//   "In normal version-control mode the surrounding lines are not part of the
//    diff and must be fetched from the repository (e.g. `git show
//    <rev>:<path>`) before they can be revealed.  The control, the
//    decorations and the overlay behavior are identical in both cases."
//
// Before DR-R5 nothing implemented that fetch, so expansion in normal git
// mode did not exist at all: the review's `sourceContent` was the only source
// of revealed lines anywhere in the product.
//
// The scenario needs a diff whose surroundings are in NEITHER the diff nor
// the working tree, or the fetch could be faked by reading the file on disk.
// Hence a three-commit fixture of its own:
//
//   1. "baseline"          — src/app.nim, 41 lines: `proc main() =` then
//                            `echo "alpha 1"` .. `echo "alpha 40"`.
//   2. "edit the middle"   — rewrites line 21 (`alpha 20` -> `beta 20`).
//                            Its diff carries 3 context lines either side,
//                            i.e. new lines 18..24; everything else is hidden.
//   3. "replace the file"  — rewrites the file completely, so NO `alpha` line
//                            survives into the working tree.
//
// The tab under test is commit 2's, which is not HEAD.  `alpha 7` is then a
// line that exists only in that commit's blob: absent from the diff, absent
// from HEAD, absent from disk.  Revealing it is possible only via `git show
// <rev>:<path>`, which is exactly the claim.
//
// Headless counterparts: test_context_expansion_window_reveals_lines_above_and_below
// and test_context_expansion_clamps_at_file_boundaries (the window
// arithmetic), plus test_context_expansion_fetches_source_once_and_caches
// (the fetch-and-cache boundary: one fetch per (revision, path), a failed
// fetch not remembered as an answer) — all in
// src/tests/gui/tests/vcs/vcs_context_expansion_test.nim.

const historyFixture = fs.mkdtempSync(
  path.join(os.tmpdir(), "codetracer-vcs-expand-"),
);

function historyGit(...args: string[]): void {
  childProcess.execFileSync("git", args, {
    cwd: historyFixture,
    stdio: "ignore",
  });
}

function historyCommit(message: string): string {
  historyGit("add", ".");
  historyGit(
    "-c",
    "user.name=CodeTracer Tests",
    "-c",
    "user.email=tests@codetracer.dev",
    // As above: keep this throwaway history repo hermetic against a signing
    // configuration inherited from the host.
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    message,
  );
  return childProcess
    .execFileSync("git", ["rev-parse", "HEAD"], { cwd: historyFixture })
    .toString()
    .trim();
}

const historyAppPath = path.join(historyFixture, "src", "app.nim");

/// 41 lines: a header plus `echo "<tag> N"` for N in 1..40, with line
/// `markedLine` carrying `markedTag` instead.  40 lines is comfortably more
/// than git's 3-line context plus two 10-line expansion steps in each
/// direction, so the expansion never runs into a file boundary here — the
/// boundary cases are asserted headlessly, where they belong.
function appNim(markedTag: string): string {
  const lines = ["proc main() ="];
  for (let i = 1; i <= 40; i += 1) {
    lines.push(i === 20 ? `  echo "${markedTag} 20"` : `  echo "alpha ${i}"`);
  }
  return lines.join("\n") + "\n";
}

fs.mkdirSync(path.join(historyFixture, "src"), { recursive: true });
fs.writeFileSync(historyAppPath, appNim("alpha"));
historyGit("init");
historyCommit("baseline");

fs.writeFileSync(historyAppPath, appNim("beta"));
const middleCommitSha = historyCommit("edit the middle");

// The newest commit replaces the file outright, so nothing the middle
// commit's diff surrounds is on disk any more.
fs.writeFileSync(
  historyAppPath,
  'proc main() =\n  echo "the file was rewritten"\n',
);
historyCommit("replace the file");

test.describe("VCS unified diff — context expansion in normal git mode", () => {
  test.use({ launchMode: "edit", editFolderPath: historyFixture });

  /// The rendered lines of the diff tab.
  function diffTabLines(ctPage: any) {
    return ctPage.locator(`.unified-diff-container ${DIFF_BODY} .view-line`);
  }

  /// One side's gutter labels, whitespace-normalised.  Monaco pads them with
  /// U+00A0 to keep the column aligned.
  ///
  /// DR-R4 had one model and padded the old and the new number into a single
  /// label, so this returned pairs like `"8 8"`.  UD-1's diff editor gives
  /// each revision its own margin — the way VS Code's inline diff draws it —
  /// so the pair is now two columns and each is read on its own side.
  async function diffLineNumbersOn(ctPage: any, side: string): Promise<string[]> {
    const raw = await ctPage
      .locator(`.unified-diff-container ${side} .margin-view-overlays .line-numbers`)
      .allTextContents();
    return raw.map((t: string) =>
      t.replace(/\u00a0/g, " ").trim().replace(/\s+/g, " "),
    );
  }

  test("UD-2: the whole file tokenizes, without a Monarch rule aborting it", async ({
    ctPage,
  }) => {
    // The blocker UD-1 recorded, and its first casualty in normal git mode.
    //
    // A Monaco model is tokenized from its OWN line 1, so the diff tab's model
    // is the whole file since UD-2.  That turned CodeTracer's Nim grammar over
    // the *whole* of the fixture's `main.nim` rather than over a window around
    // one hunk, and it threw:
    //
    //   nim: matched number of groups does not match the number of actions in
    //   rule: (unknown)
    //
    // Monarch aborts the model's tokenization at that point, so every line
    // after it renders as one untokenized run — the exact failure mode this
    // milestone exists to remove, arriving from a different direction.  The
    // rule (`src/frontend/languages/nimLanguage.js`, the unary-minus
    // heuristic) declared two actions for one capture group.
    const errors: string[] = [];
    ctPage.on("pageerror", (error: Error) => errors.push(error.message));

    await openVcsPanel(ctPage);
    await clickViewDiffOnNewestCommit(ctPage);
    await waitForDiffTab(ctPage);

    // Tokenization is a background task, so it is given a moment to reach the
    // end of the model before the absence of an error means anything.
    await ctPage.waitForTimeout(2000);
    expect(
      errors.filter((message) => message.includes("matched number of groups")),
    ).toEqual([]);

    // ... and the result is visible: more than one token class across the
    // rendered lines, which a model that stopped tokenizing cannot produce.
    const classes = await ctPage
      .locator(`.unified-diff-container ${DIFF_BODY} .view-line span span`)
      .evaluateAll((nodes: Element[]) =>
        Array.from(new Set(nodes.map((n) => n.className))),
      );
    expect(classes.filter((c) => c.startsWith("mtk")).length).toBeGreaterThan(1);
  });

  test("e2e_normal_git_diff_tab_expand_fetches_content", async ({ ctPage }) => {
    // The premise, checked rather than assumed: the line this test reveals is
    // not on disk, so no implementation that reads the working tree could
    // produce it.
    const workingTree = fs.readFileSync(historyAppPath, "utf8");
    expect(workingTree).not.toContain("alpha");

    await openVcsPanel(ctPage);

    // Expand the "edit the middle" commit, which is not HEAD, and open the
    // diff tab for its file.
    //
    // The entry is located by its commit message and the file row is scoped
    // INSIDE it: the panel may already have another commit expanded, and an
    // unscoped `.vcs-accordion-file` would then belong to that one — which is
    // how this test first opened HEAD's diff and looked for a line HEAD does
    // not contain.
    const middleEntry = ctPage
      .locator(".vcs-commit-entry")
      .filter({ hasText: "edit the middle" })
      .first();
    await expect(middleEntry).toBeVisible({ timeout: 30_000 });
    await middleEntry.locator(".vcs-commit-header").first().click();

    const fileRow = middleEntry.locator(".vcs-accordion-file").first();
    await expect(fileRow).toBeVisible({ timeout: 15_000 });
    await fileRow.hover();
    const diffButton = fileRow.locator(".vcs-file-diff-btn").first();
    await expect(diffButton).toBeVisible({ timeout: 5_000 });
    await diffButton.click();

    await waitForDiffTab(ctPage);

    // The lines far from the change are collapsed behind a boundary, so
    // `alpha 7` is not on screen yet even though the model (since UD-2, the
    // whole file) holds it.
    await expect(
      diffTabLines(ctPage).filter({ hasText: /echo\s+"beta\s+20"/ }),
    ).toHaveCount(1, { timeout: 15_000 });
    await expect(
      diffTabLines(ctPage).filter({ hasText: /echo\s+"alpha\s+7"/ }),
    ).toHaveCount(0);

    // The collapsed region above the hunk.  Since UD-2 the control is not a
    // line of the model but Monaco's own boundary widget, whose two drag
    // handles `ui/diff_expansion.nim` stamps with `.ct-diff-expand-boundary`
    // (VCS-Panel.md: "Context expansion controls (Expand N lines
    // above/below)"; DeepReview-GUI.md §4.3: "a draggable edge line").
    //
    // Its `below` handle is the one wanted: each handle is named for where in
    // its own region the lines appear, and the lines nearest the hunk are at
    // the region's BOTTOM.  Pressing it walks back up the file, which is what
    // "expand the context above this hunk" means to a reader.
    // Two regions collapse on this file — one before the hunk and one after
    // it — so the wanted handle is named by position as well as by direction:
    // the FIRST region in line order is the one above the hunk.
    const boundaries = ctPage.locator(
      `.unified-diff-container ${DIFF_BODY} .ct-diff-expand-boundary[data-ct-expand="below"]`,
    );
    await expect(boundaries).toHaveCount(2, { timeout: 15_000 });
    const boundary = boundaries.first();
    const hiddenBefore = Number(
      await boundary.getAttribute("data-ct-hidden"),
    );
    expect(hiddenBefore).toBeGreaterThan(10);
    await boundary.click();

    // Ten lines come on screen, ending immediately above the hunk's own
    // context — the bottom handle reveals from the end of the collapsed run.
    await expect
      .poll(
        async () => Number(await boundary.getAttribute("data-ct-hidden")),
        { timeout: 15_000 },
      )
      .toBe(hiddenBefore - 10);

    // ...and `echo "alpha 7"` is among them.  That line is in neither the
    // diff nor the working tree; only `git show <rev>:<path>` has it, so its
    // appearance is what says the tab fetched the blob rather than reading
    // the tree — the property this test exists for, and the one UD-2 makes
    // load-bearing, because the whole-file model is built from exactly that
    // fetch.
    await expect(
      diffTabLines(ctPage).filter({ hasText: /echo\s+"alpha\s+7"/ }),
    ).toHaveCount(1, { timeout: 15_000 });
    // Unchanged lines, so they carry the same number in BOTH gutter columns.
    const numbers = await diffLineNumbersOn(ctPage, DIFF_BODY);
    expect(numbers).toContain("8");
    expect(numbers).toContain("17");
    expect(numbers).not.toContain("7");
    expect(await diffLineNumbersOn(ctPage, DIFF_ORIGINAL)).toContain("8");

    // A second press reveals FURTHER content rather than the same window
    // again — DeepReview-GUI.md §4.2's third required control.  The rest of
    // the region follows, and its boundary retires once it is exhausted:
    // expansion is bounded, not unbounded.  The region AFTER the hunk is
    // untouched and keeps its own boundary, which is what "each region
    // independently" means.
    await boundary.click();
    await expect(
      diffTabLines(ctPage).filter({ hasText: /echo\s+"alpha\s+1"$/ }),
    ).toHaveCount(1, { timeout: 15_000 });
    const afterSecond = await diffLineNumbersOn(ctPage, DIFF_BODY);
    expect(afterSecond).toContain("2");
    expect(afterSecond).toContain("7");
    await expect(boundaries).toHaveCount(1, { timeout: 15_000 });

    // The commit whose blob was fetched is the one the tab shows, not HEAD.
    expect(middleCommitSha).toBeTruthy();
  });
});
