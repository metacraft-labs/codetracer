import { test, expect, testProgramsPath } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

const NOIR_SOURCE_PATH = `${testProgramsPath}/noir_example/`;

test.describe("Command Palette", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: NOIR_SOURCE_PATH, launchMode: "trace" });

  test("omnibox finds filenames and menu items", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    await ctPage.keyboard.press("Control+KeyP");
    const input = ctPage.locator("#command-query-text");
    await expect(input).toBeVisible({ timeout: 10_000 });

    await input.fill("main.nr");
    const fileHit = ctPage
      .locator(".command-results .command-result.command-file")
      .filter({ hasText: "main.nr" })
      .first();
    await expect(fileHit).toBeVisible({ timeout: 10_000 });
    await fileHit.click();
    await expect
      .poll(async () => {
        const editors = await layout.editorTabs(true);
        return editors.some((editor) => editor.fileName === "main.nr");
      })
      .toBeTruthy();

    await ctPage.keyboard.press("Control+KeyP");
    await input.fill(":open");
    const menuHit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: /open/i })
      .first();
    await expect(menuHit).toBeVisible({ timeout: 10_000 });
  });
});

/**
 * Where the keyboard is after a palette choice that navigates.
 *
 * A symbol chosen in the palette moves the editor's caret to its line
 * (`utils.focusLine`). That call does not take the keyboard from a text field
 * the user is typing in (`ui/editor_focus`, codetracer-pm issue 2026-10-22),
 * and the palette's own input IS such a field: when the choice ran before the
 * palette closed, the editor declined the focus, the palette then hid its
 * input, and the keyboard was left nowhere. The user's choice has to hand the
 * keyboard to its destination — here an editor that is ALREADY OPEN, whose
 * tab is only brought to the front, which is the path that focuses at once.
 *
 * Both ways of choosing are covered: `Enter` in the input (`runQuery`) and a
 * click on the result (`wireCommandPaletteResultRunner`).
 */
test.describe("Command Palette — a navigating choice hands the keyboard to the editor", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: NOIR_SOURCE_PATH, launchMode: "trace" });

  /** Where the keyboard is: inside an editor tab's Monaco, or what instead. */
  async function keyboardPlace(page: import("@playwright/test").Page): Promise<string> {
    return page.evaluate(() => {
      const a = document.activeElement as HTMLElement | null;
      if (!a || a === document.body) return "nowhere (document.body)";
      if (a.closest("div[id^='editorComponent'] .monaco-editor")) return "the editor";
      return `${a.tagName.toLowerCase()}#${a.id}.${String(a.className).slice(0, 40)}`;
    });
  }

  async function mainNrOpen(page: import("@playwright/test").Page): Promise<LayoutPage> {
    const layout = new LayoutPage(page);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();
    // The first stop opened main.nr: the symbol below is in an open file.
    await expect
      .poll(async () => (await layout.editorTabs(true)).some((e) => e.fileName === "main.nr"))
      .toBeTruthy();
    return layout;
  }

  async function symbolResult(page: import("@playwright/test").Page) {
    await page.keyboard.press("Control+KeyP");
    const input = page.locator("#command-query-text");
    await expect(input).toBeVisible({ timeout: 10_000 });
    await input.fill(":sym main");
    const hit = page.locator(".command-results .command-result.command-symbol").filter({ hasText: "main" }).first();
    await expect(hit).toBeVisible({ timeout: 10_000 });
    return { input, hit };
  }

  test("Enter on a symbol in an open file puts the keyboard in the editor", async ({ ctPage }) => {
    await mainNrOpen(ctPage);
    const { input } = await symbolResult(ctPage);
    await input.press("Enter");
    // The palette closed (its container carries `hidden`, the view's
    // `containerClass`).
    await expect(ctPage.locator(".command-container").first()).toHaveClass(/\bhidden\b/, { timeout: 10_000 });
    await expect
      .poll(() => keyboardPlace(ctPage), {
        timeout: 10_000,
        message: "after choosing a symbol the keyboard must be in the editor it was shown in",
      })
      .toBe("the editor");
  });

  test("a click on a symbol in an open file puts the keyboard in the editor", async ({ ctPage }) => {
    await mainNrOpen(ctPage);
    const { hit } = await symbolResult(ctPage);
    await hit.click();
    // The palette closed (its container carries `hidden`, the view's
    // `containerClass`).
    await expect(ctPage.locator(".command-container").first()).toHaveClass(/\bhidden\b/, { timeout: 10_000 });
    await expect
      .poll(() => keyboardPlace(ctPage), {
        timeout: 10_000,
        message: "after choosing a symbol the keyboard must be in the editor it was shown in",
      })
      .toBe("the editor");
  });
});

/**
 * A command that opens the palette anew. `Find Symbol` (and `Find in Files`)
 * is a menu item, so it is also a palette command, and what it does is put
 * the palette back up with `:sym ` in the input and the keyboard in it
 * (`renderer.search`). Choosing it from the palette must leave exactly that —
 * not a palette closed after the command ran, with the keyboard nowhere.
 */
test.describe("Command Palette — a command that opens the palette", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: NOIR_SOURCE_PATH, launchMode: "trace" });

  test("choosing Find Symbol leaves the palette open on `:sym ` with the keyboard in it", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();
    await ctPage.keyboard.press("Control+KeyP");
    const input = ctPage.locator("#command-query-text");
    await expect(input).toBeVisible({ timeout: 10_000 });
    await input.fill(":Find Symbol");
    const hit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: "Find Symbol" })
      .first();
    await expect(hit).toBeVisible({ timeout: 10_000 });
    await input.press("Enter");
    const state = () =>
      ctPage.evaluate(() => {
        const c = document.getElementById("command-view")?.closest(".command-container");
        const i = document.getElementById("command-query-text") as HTMLInputElement | null;
        return JSON.stringify({
          open: !!c && !c.classList.contains("hidden"),
          value: i?.value ?? null,
          keyboardInInput: document.activeElement === i,
        });
      });
    await expect
      .poll(state, { timeout: 10_000, message: "Find Symbol must leave the palette open on `:sym ` with the keyboard in it" })
      .toBe(JSON.stringify({ open: true, value: ":sym ", keyboardInInput: true }));
  });
});
