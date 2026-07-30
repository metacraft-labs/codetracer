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
  await ctPage.locator(".monaco-editor .view-line").first().click();
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

  test("re-record queues launch when files are dirty and triggers after save completes", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await expect.poll(async () => activeEditorValue(ctPage), { timeout: 10_000 })
      .toContain("initial");

    // Make the editor dirty
    await setActiveEditorValue(ctPage, 'print("ours in memory for re-record")\n');

    // Evaluate in browser context to mock data.trace and call reRecordCurrent
    await ctPage.evaluate(() => {
      const data = (window as any).__CODETRACER_DATA__;
      data.trace = { program: "main.py", lang: "python" }; // mock non-nil trace
      data.reRecordCurrent(false);
    });

    // Verify it is queued
    await expect.poll(async () => {
      return await ctPage.evaluate(() => {
        const data = (window as any).__CODETRACER_DATA__;
        return data.pendingReRecord != null;
      });
    }, { timeout: 5000 }).toBe(true);

    // Wait for the automatic save and verify the queue is cleared (meaning re-record triggered)
    await expect.poll(async () => {
      return await ctPage.evaluate(() => {
        const data = (window as any).__CODETRACER_DATA__;
        return data.pendingReRecord == null;
      });
    }, { timeout: 10_000 }).toBe(true);
  });
});
