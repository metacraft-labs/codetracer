/**
 * plat48-menu-capture.spec.ts — PLAT-48, the desktop's column: THE DESKTOP'S
 * MENU IS DRAWN FROM THE SHARED MENU VIEWMODEL, and nothing else.
 *
 * The real Electron front-end on the terminal lanes' own `calc` recording:
 *
 *   * THE GATE — the Menu ViewModel (`viewmodel/viewmodels/menu_vm.MenuVM`,
 *     exposed by `ui/menu.nim` as `window.__ctMenuVM`) is given a highlighted
 *     item DIRECTLY, and the DOM's highlighted items (`.menu-active-node`)
 *     are read back: they are the open folder and the item the ViewModel
 *     says, and they MOVE when only the ViewModel's highlight moves. A
 *     renderer that kept its own copy of the menu's state would not follow.
 *   * the menu opens by click (`#menu-root`) and by key (`CTRL+M`, the
 *     desktop's `aMenu`); the pointer walks into the Debug folder; each
 *     stepping item's shortcut is the chord the desktop's keymap binds
 *     (`default_config.yaml`, rendered as `renderChord` renders it);
 *     choosing Step Over moves the debugger;
 *   * the footer strip's labels are the shared default's docked panes.
 *
 * Written to `src/tests/visual/answers/plat48-menu.electron.json`, which
 * `src/frontend/tui/tests/test_plat48_desktop_menu.nim` asserts beside the
 * terminal's and GPUI's menus.
 *
 * No mocks: a real `.ct` recording, the real `ct`, a real `replay-server`,
 * the real Electron app. The prefix (this checkout's desktop JavaScript)
 * comes from `scripts/plat45-desktop-prefix.sh` via `PLAT48_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat48-menu.electron.json");

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-48: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT48_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);

type MenuState = { isOpen: boolean; path: number[]; highlight: number; keyNavigation: boolean };

test("PLAT-48: the desktop's menu is drawn from the shared Menu ViewModel", async ({ ctPage }) => {
  const out: Record<string, unknown> = {
    _comment: [
      "PLAT-48 — the desktop's menu, read from the real Electron app on calc.",
      "Produced by src/tests/gui/tests/visual/plat48-menu-capture.spec.ts",
      "(`just plat48-capture-electron`).",
    ],
  };
  await ctPage.waitForFunction(() => typeof (globalThis as any).__ctMenuVM !== "undefined", {
    timeout: 120_000,
  });
  const state = async (): Promise<MenuState> =>
    JSON.parse(await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.state()));
  const activeLabels = async (): Promise<string[]> =>
    (await ctPage.locator(".menu-active-node .ct-menu-item-label").allInnerTexts()).map((s) => s.trim());

  // ---- OPEN BY CLICK ----------------------------------------------------------
  await ctPage.locator("#menu-root").click();
  await ctPage.locator("#menu-main").waitFor({ timeout: 30_000 });
  out.openedByClick = (await state()).isOpen;
  const roots = (await ctPage.locator("#menu-elements > .menu-node-container .ct-menu-item-label").allInnerTexts())
    .map((s) => s.trim());
  out.rootLabels = roots;

  // ---- THE GATE: the ViewModel's highlight, and only it, moves the DOM's ------
  // The Debug folder is child 6 of the product menu's root (index 0 is the
  // macOS application folder, hidden off macOS); Step Over is its item 1.
  await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.setHighlight([6], 1));
  await ctPage.waitForFunction(
    () => Array.from(document.querySelectorAll(".menu-active-node .ct-menu-item-label"))
      .some((e) => (e.textContent ?? "").trim() === "Step Over"),
    undefined, { timeout: 30_000 });
  const first = await activeLabels();
  await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.setHighlight([6], 3));
  await ctPage.waitForFunction(
    () => Array.from(document.querySelectorAll(".menu-active-node .ct-menu-item-label"))
      .some((e) => (e.textContent ?? "").trim() === "Step Out"),
    undefined, { timeout: 30_000 });
  const second = await activeLabels();
  out.gate = { vmHighlightStepOver: first, vmHighlightStepOut: second };
  expect(first).toContain("Debug");
  expect(first).toContain("Step Over");
  expect(second).toContain("Step Out");
  expect(second).not.toContain("Step Over");

  // ---- THE DEBUG FOLDER'S SHORTCUTS: the keymap's chords --------------------
  const nested = ctPage.locator(".menu-nested-elements").first();
  const items = await nested.locator(".ct-menu-item").all();
  const shortcuts: Record<string, string> = {};
  for (const it of items) {
    const label = ((await it.locator(".ct-menu-item-label").first().textContent()) ?? "").trim();
    const sub = it.locator(".ct-menu-item-sublabel");
    shortcuts[label] = (await sub.count()) > 0 ? ((await sub.first().textContent()) ?? "").trim() : "";
  }
  out.debugShortcuts = shortcuts;
  expect(shortcuts["Step Over"]).toBe("F10");
  expect(shortcuts["Continue"]).toBe("F8 F2");

  // ---- CHOOSE Step Over: the debugger moves ----------------------------------
  const tick = async (): Promise<number> =>
    ctPage.evaluate(() => Number((window as any).data?.services?.debugger?.location?.rrTicks ?? -1));
  const before = await tick();
  await nested.locator(".ct-menu-item", { hasText: "Step Over" }).first().click();
  await ctPage.waitForFunction(
    (b) => Number((window as any).data?.services?.debugger?.location?.rrTicks ?? -1) !== b,
    before, { timeout: 120_000 });
  out.stepOver = { before, after: await tick(), closed: !(await state()).isOpen };

  // ---- OPEN BY KEY: the desktop's aMenu chord --------------------------------
  // Off the editor first: Monaco binds CTRL+M itself (tab-moves-focus), so
  // the chord reaches the desktop's keymap only from the page.
  await ctPage.mouse.click(900, 600);
  await ctPage.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await ctPage.keyboard.press("Control+m");
  await ctPage.waitForTimeout(500);
  out.openedByKey = (await state()).isOpen;
  if ((await state()).isOpen) {
    await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.close());
  }

  // ---- THE FOOTER: the shared default's docked panes --------------------------
  out.footerLabels = (await ctPage.locator(".auto-hide-strip-tab-label").allInnerTexts())
    .map((s) => s.trim()).filter((s) => s.length > 0);

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
});
