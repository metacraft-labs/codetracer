// VCS panel — "View Diff" opens a unified diff tab (issues #561 / #611).
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
// Fixture: a throwaway git repository with two commits, so the newest commit's
// diff carries both added and removed lines.

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

fs.mkdirSync(path.join(gitFixture, "src"), { recursive: true });
fs.writeFileSync(path.join(gitFixture, "README.md"), "# VCS diff fixture\n");
fs.writeFileSync(
  path.join(gitFixture, "src", "main.nim"),
  'proc main() =\n  echo "first"\n  echo "unchanged"\n',
);
git("init");
commit("initial");

// A second commit so the newest commit has a real modification hunk
// (one removed line, one added line) rather than a pure file addition.
fs.writeFileSync(
  path.join(gitFixture, "src", "main.nim"),
  'proc main() =\n  echo "second"\n  echo "unchanged"\n',
);
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
    // newest commit rewrites one line, so both an addition and a removal must
    // be decorated.
    const diffTab = ctPage.locator(".vcs-container .deepreview-unified-diff");
    await expect(diffTab.first()).toBeVisible({ timeout: 15_000 });
    await expect
      .poll(
        async () =>
          await ctPage
            .locator(".deepreview-unified-line-added")
            .count(),
        { timeout: 15_000 },
      )
      .toBeGreaterThan(0);
    await expect(
      ctPage.locator(".deepreview-unified-line-removed").first(),
    ).toBeVisible({ timeout: 15_000 });
    await expect(
      ctPage.locator(".deepreview-unified-hunk-header").first(),
    ).toHaveText(/@@ -\d+,\d+ \+\d+,\d+ @@/, { timeout: 15_000 });

    // #561: the diff is an additional tab, not a replacement for the panel —
    // the VCS panel must still be showing its commit history.
    await expect(ctPage.locator(".vcs-commit-list").first()).toBeVisible();
    await expect(ctPage.locator(".vcs-commit-header").first()).toBeVisible();
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
});
