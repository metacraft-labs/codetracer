// Edit mode's flows are scenarios now (`src/tests/scenarios/edit-mode/`): the
// Files and VCS panes, the lazily filled folders, the edit bar and its
// Ctrl+F5 round trips, each tab's own bar, the welcome screen's Open Folder
// (in place and in a new tab) and `ct edit .` from inside a folder. What stays
// is the case a scenario cannot drive: a SECOND `ct edit .` process, started
// from a shell while the window is open, delegating into it.
import { test, expect, codetracerPath } from "../../lib/fixtures";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const gitEditFixture = fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-edit-mode-"));
fs.mkdirSync(path.join(gitEditFixture, "src"), { recursive: true });
fs.writeFileSync(path.join(gitEditFixture, "README.md"), "# Edit mode fixture\n");
fs.writeFileSync(path.join(gitEditFixture, "src", "main.nim"), "proc main() =\n  echo \"edit mode\"\n");
// The index process lists one level per load (`index/files.FilesystemLoadDepth`):
// the opened folder's own entries arrive, and every folder among them --
// `src` here -- is a single "Loading..." stub until it is expanded.  `src/db`
// is one stub further down, so reaching `store.nim` takes TWO successful
// `CODETRACER::load-path-content` round-trips.  Without a folder at this
// depth the tree never exercises the lazy fill at all -- which is why #574
// survived the earlier edit-mode specs.
fs.mkdirSync(path.join(gitEditFixture, "src", "db"), { recursive: true });
fs.writeFileSync(
  path.join(gitEditFixture, "src", "db", "store.nim"),
  "proc store() =\n  echo \"lazy child\"\n",
);
childProcess.execFileSync("git", ["init"], { cwd: gitEditFixture, stdio: "ignore" });
childProcess.execFileSync("git", ["add", "."], { cwd: gitEditFixture, stdio: "ignore" });
childProcess.execFileSync(
  "git",
  // commit.gpgsign=false: a runner configured to sign, with no secret key
  // present, would abort this fixture commit. Edit mode is not about signing.
  [
    "-c",
    "user.name=CodeTracer Tests",
    "-c",
    "user.email=tests@codetracer.dev",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    "initial",
  ],
  { cwd: gitEditFixture, stdio: "ignore" },
);

async function assertWorkspacePanelsPopulated(ctPage: any, expectedFile: RegExp) {
  await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 45_000 });

  await expect.poll(async () => {
    return await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll(".filesystem-entry-label, .jstree-anchor"))
        .map((node) => (node as HTMLElement).innerText)
        .join("\n"),
    );
  }, { timeout: 45_000 }).toMatch(expectedFile);

  await ctPage.locator(".lm_tab", { hasText: "VCS" }).first().click();
  await expect(ctPage.locator(".vcs-container").first()).toBeVisible({ timeout: 15_000 });

  await expect.poll(async () => {
    return await ctPage.evaluate(() => {
      const branch = document.querySelector(".vcs-branch-name") as HTMLElement | null;
      const commits = document.querySelectorAll(".vcs-commit-item").length;
      const noRepo = document.querySelector(".vcs-no-repo-message") as HTMLElement | null;
      const branchText = branch?.innerText.trim() ?? "";
      const noRepoText = noRepo?.innerText.trim() ?? "";
      return noRepoText.length === 0 && (branchText.length > 0 || commits > 0);
    });
  }, { timeout: 30_000 }).toBe(true);
}

test.describe("Welcome Open Folder via second process", () => {
  test.use({ launchMode: "welcome", newTracePolicy: "tab" });

  test("running ct edit dot delegates into the existing welcome window", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    const env = { ...process.env };
    // M-REC-6: legacy CODETRACER_TRACE_ID is retired in favour of
    // CODETRACER_RECORDING_ID; delete both so neither leaks in.
    delete env.CODETRACER_TRACE_ID;
    delete env.CODETRACER_RECORDING_ID;
    delete env.CODETRACER_CALLER_PID;
    env.CODETRACER_IN_UI_TEST = "1";
    env.CODETRACER_TEST = "1";
    env.CODETRACER_NEW_TRACE_POLICY = "tab";
    env.CODETRACER_ELECTRON_ARGS = [
      "--no-sandbox",
      "--no-zygote",
      "--disable-gpu",
      "--disable-gpu-compositing",
      "--disable-dev-shm-usage",
      "--in-process-gpu",
      "--ozone-platform-hint=x11",
    ].join(" ");

    const delegated = childProcess.spawnSync(codetracerPath, ["edit", "."], {
      cwd: gitEditFixture,
      env,
      encoding: "utf-8",
      timeout: 30_000,
      windowsHide: true,
    });

    expect(delegated.error, delegated.stderr).toBeUndefined();
    expect(delegated.status, delegated.stderr || delegated.stdout).toBe(0);
    await assertWorkspacePanelsPopulated(ctPage, /src|README|main\.nim/i);
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 10_000 });
  });
});
