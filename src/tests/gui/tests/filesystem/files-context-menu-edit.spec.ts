// The Files pane's context menu in a `ct edit <folder>` session: Create and
// Rename act on the disk, and the tree follows them.
//
// The headless suite (`filesystem_vm_test.nim`, "Files context menu") holds the
// menu's decisions and the main-process suite (`file_tree_operations_test.nim`)
// holds the disk side. Neither covers the round trip between them, which is
// where three defects hid:
//
// - a `ct edit` launch never recorded its folder on the index process, so every
//   Create, Rename and Delete was refused with "No folder is open";
// - `ct edit` names the opened folder with a trailing `/`, while the index
//   process answers with a resolved path, so the opened folder's own row was
//   never reloaded after an operation in it;
// - a reload brings the folder's sub-folders back as "Loading..." stubs, and
//   one the user had expanded stayed on "Loading..." for good.
//
// Delete is not driven: in Electron it moves the entry to the user's real
// trash. The fixture is a fresh temporary folder; no mocks.
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "ct-files-context-menu-"));
fs.mkdirSync(path.join(fixture, "src"), { recursive: true });
fs.writeFileSync(path.join(fixture, "README.md"), "readme\n");
fs.writeFileSync(path.join(fixture, "src", "main.nim"), "echo 1\n");

test.describe("Files context menu in edit mode", () => {
  test.use({ launchMode: "edit", editFolderPath: fixture });

  test("Create and Rename act on the disk and the tree follows", async ({ ctPage }) => {
    // Rows are matched by `.jstree-anchor`, the class the Files pane's DOM
    // renderer gives each row's label (`isonim_filesystem_view`).
    const label = (name: string) =>
      ctPage.locator(".filesystem .jstree-anchor").filter({
        hasText: new RegExp(`^${name.replace(/\./g, "\\.")}$`),
      });
    const menu = ctPage.locator("#context-menu-container");
    const nameField = ctPage.locator(".filesystem-name-input");

    const openMenu = async (name: string) => {
      await label(name).first().evaluate((anchor: Element) => {
        const rect = anchor.getBoundingClientRect();
        anchor.dispatchEvent(
          new MouseEvent("contextmenu", {
            bubbles: true,
            cancelable: true,
            view: window,
            button: 2,
            buttons: 2,
            clientX: rect.left + rect.width / 2,
            clientY: rect.top + rect.height,
          }),
        );
      });
      await menu.waitFor({ state: "visible", timeout: 10_000 });
    };
    const choose = async (entry: string) => {
      await menu.locator(".context-menu-item", { hasText: entry }).first().click();
    };

    await expect(label("README.md").first()).toBeVisible({ timeout: 60_000 });
    await ctPage.locator(".lm_tab", { hasText: "FILES" }).first().click();
    // `src` expanded: its entries must survive the opened folder's reload.
    await label("src").first().click();
    await expect(label("main.nim").first()).toBeVisible({ timeout: 30_000 });

    // Create next to README.md, that is in the opened folder itself.
    await openMenu("README.md");
    const entries = (await menu.locator(".ct-menu-item-label").allInnerTexts()).map((t) => t.trim());
    expect(entries).toEqual(["Create", "Rename", "Delete", "Edit"]);
    await choose("Create");
    await expect(nameField).toBeVisible({ timeout: 10_000 });
    await nameField.fill("NEW.md");
    await nameField.press("Enter");
    await expect
      .poll(() => fs.existsSync(path.join(fixture, "NEW.md")), {
        timeout: 15_000,
        message: "Create did not make the file on disk",
      })
      .toBe(true);
    expect(fs.readFileSync(path.join(fixture, "NEW.md"), "utf8")).toBe("");
    await expect(label("NEW.md").first(), "the opened folder's row was not reloaded").toBeVisible({
      timeout: 15_000,
    });
    await expect(label("main.nim").first(), "the expanded src did not load again").toBeVisible({
      timeout: 15_000,
    });
    await expect(label("Loading...")).toHaveCount(0, { timeout: 15_000 });

    // Rename README.md: a taken name is refused in the field, a free one
    // renames the file on disk.
    await ctPage.keyboard.press("Escape");
    await openMenu("README.md");
    await choose("Rename");
    await expect(nameField).toHaveValue("README.md", { timeout: 10_000 });
    await nameField.fill("NEW.md");
    await nameField.press("Enter");
    await expect(ctPage.locator(".filesystem-name-error")).toContainText("already exists");
    expect(fs.readFileSync(path.join(fixture, "README.md"), "utf8")).toBe("readme\n");
    await nameField.fill("README2.md");
    await nameField.press("Enter");
    await expect
      .poll(() => fs.existsSync(path.join(fixture, "README2.md")), { timeout: 15_000 })
      .toBe(true);
    expect(fs.existsSync(path.join(fixture, "README.md"))).toBe(false);
    expect(fs.readFileSync(path.join(fixture, "README2.md"), "utf8")).toBe("readme\n");
    await expect(label("README2.md").first()).toBeVisible({ timeout: 15_000 });
    await expect(label("README.md")).toHaveCount(0, { timeout: 15_000 });

    // The opened folder's own row: Rename and Delete are disabled with the
    // reason as their sublabel.
    await openMenu(path.basename(fixture));
    const reasons = await menu.locator(".ct-menu-item-sublabel").allInnerTexts();
    expect(reasons.join("|")).toContain("The opened folder cannot be renamed or deleted from the tree");
  });
});
