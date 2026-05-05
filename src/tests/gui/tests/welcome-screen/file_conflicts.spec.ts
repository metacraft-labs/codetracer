import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function makeFixtureDir(prefix: string, content: string): { dir: string; file: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
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
});
