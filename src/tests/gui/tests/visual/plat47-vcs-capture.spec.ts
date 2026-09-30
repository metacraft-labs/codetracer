/**
 * plat47-vcs-capture.spec.ts — PLAT-47 deliverable 4's desktop column: what the
 * REAL Electron front-end's VCS panel shows for a real git repository.
 *
 * The repository is `scripts/plat47-vcs-fixture.sh`'s: on branch `plat47-vcs`,
 * `notes.txt` modified, `added.txt` added (staged), `scratch.txt` untracked,
 * `unchanged.txt` committed and untouched. The desktop is opened on it in edit
 * mode (`ct edit <repo>`, which hands the VCS panel the project folder), the
 * panel's VCS tab is selected, and its working-tree rows are read off the DOM:
 * each row's state letter and path, in order, and the branch the panel names.
 *
 * Written to `src/tests/visual/answers/plat47-vcs.electron.json`. The
 * terminal's real-PTY suite (`tests/real_terminal/test_plat47_vcs_pane.nim`)
 * builds the same repository with the same script and compares its VCS pane
 * with it; GPUI's parity suite does the same from its window.
 *
 * No mocks: a real git repository, the real `ct`, the real Electron app. The
 * prefix (this checkout's desktop JavaScript) comes from
 * `scripts/plat45-desktop-prefix.sh` via `PLAT47_DESKTOP_PREFIX`.
 */

import * as childProcess from "child_process";
import * as fs from "fs";
import * as path from "path";

import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat47-vcs.electron.json");

function fixtureRepo(): string {
  const parent = fs.mkdtempSync(path.join(repoRoot, "test-logs", "plat47-vcs-"));
  const repo = path.join(parent, "repo");
  const r = childProcess.spawnSync("bash", [
    path.join(repoRoot, "scripts", "plat47-vcs-fixture.sh"), repo,
  ], { encoding: "utf-8" });
  if (r.status !== 0) {
    throw new Error(`plat47-vcs-fixture.sh failed: ${r.stderr}`);
  }
  return repo;
}

const repo = fixtureRepo();

test.use({
  launchMode: "edit",
  editFolderPath: repo,
  editWorkingDirectory: repo,
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT47_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);

test("PLAT-47: the desktop's VCS panel on a repository with a modified, an added and an untracked file", async ({ ctPage }) => {
  await ctPage.waitForSelector(".lm_tab", { timeout: 90_000 });
  // Select the VCS tab of the Files stack.
  const vcsTab = ctPage.locator(".lm_tab", { has: ctPage.locator(".lm_title", { hasText: /^VCS$/ }) }).first();
  await vcsTab.click();
  await ctPage.waitForSelector(".vcs-working-file", { timeout: 60_000 });
  await ctPage.waitForTimeout(1_000);

  const panel = await ctPage.evaluate(() => {
    const rows = Array.from(document.querySelectorAll(".vcs-working-file")).map((row) => [
      (row.querySelector(".vcs-working-status")?.textContent ?? "").trim(),
      (row.querySelector(".vcs-working-path")?.textContent ?? "").trim(),
    ]);
    const header = (document.querySelector(".vcs-working-tree .vcs-section-header")?.textContent ?? "").trim();
    const branch = (document.querySelector(".vcs-branch-name")?.textContent ?? "").trim();
    const commits = Array.from(document.querySelectorAll(".vcs-commit-msg"))
      .map((e) => (e.textContent ?? "").trim());
    return { rows, header, branch, commits };
  });

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify({
    takenAt: new Date().toISOString(),
    fixture: "scripts/plat47-vcs-fixture.sh",
    ...panel,
  }, null, 2) + "\n");
  await ctPage.screenshot({ path: path.join(repoRoot, "test-logs", "plat47-vcs.png") });
});
