// Ctrl+R is the scenarios under `src/tests/scenarios/re-record/` (a failed
// save, a save that re-records, a burst of presses). The two cases below stay
// until the scenario format's `act:` step, a change made outside the
// application mid-run, is in the pinned runner.
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function makeFixtureDir(prefix: string, content: string): { dir: string; file: string } {
  const baseDir = path.join(process.cwd(), "non-nix-build", "tmp");
  fs.mkdirSync(baseDir, { recursive: true });
  const dir = fs.mkdtempSync(path.join(baseDir, prefix));
  const file = path.join(dir, "main.py");
  fs.writeFileSync(file, content, "utf8");
  return { dir, file };
}

async function activeEditorValue(ctPage: any): Promise<string> {
  return await ctPage.evaluate(() => {
    return Array.from(document.querySelectorAll(".monaco-editor .view-lines"))
      .map((node) => (node as HTMLElement).innerText.replace(/\u00a0/g, " "))
      .join("\n");
  });
}

async function setActiveEditorValue(ctPage: any, value: string): Promise<void> {
  // Column 0, for the reason spelled out on `enterEditMode` below: an inline
  // omniscience value chip covers the middle of the line and would swallow an
  // unpositioned click.
  await ctPage
    .locator(".monaco-editor .view-line")
    .first()
    .click({ position: { x: 2, y: 2 } });
  await ctPage.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await ctPage.keyboard.type(value);
}

const cleanFixture = makeFixtureDir("ct-file-watch-clean-", 'print("initial")\n');
const dirtyFixture = makeFixtureDir("ct-file-watch-dirty-", 'print("initial")\n');

test.describe("External File Changes - clean buffers", () => {
  test.use({ launchMode: "edit", editFolderPath: cleanFixture.dir });

  test("clean open files reload after external disk changes", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("initial");

    fs.writeFileSync(cleanFixture.file, 'print("external clean reload")\n', "utf8");

    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("external clean reload");
  });
});

test.describe("External File Changes - dirty buffers", () => {
  test.use({ launchMode: "edit", editFolderPath: dirtyFixture.dir });

  test("dirty open files prompt before reloading external disk changes", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("initial");

    await setActiveEditorValue(ctPage, 'print("ours in memory")\n');
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("ours in memory");

    fs.writeFileSync(dirtyFixture.file, 'print("theirs on disk")\n', "utf8");

    const dialog = ctPage.locator(".file-conflict-dialog", { hasText: "changed on disk" });
    await expect(dialog).toBeVisible({ timeout: 10_000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("ours in memory");
  });

});

/**
 * Issue #603.  The previous version of this test could not pass and would not
 * have proved anything if it had:
 *
 *   * it called `data.reRecordCurrent(...)`, which is not a property of the
 *     data object — Nim emits a free function;
 *   * it assigned `data.trace`, which is a Nim template and therefore inert;
 *   * it ran in `launchMode: "edit"`, where `reRecordCurrent` returns before
 *     the dirty check ever runs;
 *   * and its success condition was `pendingReRecord == null`, which is
 *     equally true after a successful dispatch, an early return and a throw.
 *
 * The rewrite drives the real Ctrl+R shortcut against a real loaded trace and
 * asserts the only thing that means "the program was launched": the recording
 * id changes.
 */
