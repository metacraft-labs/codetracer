/**
 * plat49-chrome-capture.spec.ts — PLAT-49 part A, the desktop's column: the
 * REFERENCE the terminal and GPUI front-ends are measured against for the
 * user's 2026-10-01 findings that concern the desktop's own chrome.
 *
 * The real Electron front-end on the terminal lanes' own `calc` recording:
 *
 *   * finding 1, the MENU — the caption bar holds ONE root button
 *     (`#menu-root`) and no first-level title; clicking it shows the first
 *     level (`#menu-elements`) below it, one folder per row; hovering a
 *     folder opens its items as a submenu (`.menu-nested-elements`) to the
 *     RIGHT of the first level, level with the folder's row;
 *   * finding 5, the TOOLTIPS — each transport button's `.custom-tooltip`
 *     text (rendered from `debug_controls_vm.toolbarTooltip`);
 *   * finding 6, the OMNIBAR — the palette input's `placeholder` (rendered
 *     from `omnibar_vm.OmnibarPlaceholder`).
 *
 * Written to `src/tests/visual/answers/plat49-chrome.electron.json`, which
 * `src/frontend/tui/tests/test_plat49_desktop_reference.nim` asserts beside
 * the shared ViewModels the terminal and GPUI render from.
 *
 * No mocks: a real `.ct` recording, the real `ct`, a real `replay-server`,
 * the real Electron app. The prefix (this checkout's desktop JavaScript)
 * comes from `scripts/plat45-desktop-prefix.sh` via `PLAT49_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat49-chrome.electron.json");

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-49: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT49_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);

type Box = { x: number; y: number; w: number; h: number };

test("PLAT-49: the desktop's root menu, control tooltips and omnibar placeholder", async ({ ctPage }) => {
  const out: Record<string, unknown> = {
    _comment: [
      "PLAT-49 part A — the desktop's chrome, read from the real Electron app on calc.",
      "Produced by src/tests/gui/tests/visual/plat49-chrome-capture.spec.ts",
      "(`bash scripts/plat49-capture-electron.sh`).",
    ],
  };
  await ctPage.waitForFunction(() => typeof (globalThis as any).__ctMenuVM !== "undefined", {
    timeout: 120_000,
  });
  const box = async (selector: string): Promise<Box> => {
    const b = await ctPage.locator(selector).first().boundingBox();
    if (b === null) throw new Error("no box for " + selector);
    return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) };
  };

  // ---- 1. THE MENU ------------------------------------------------------------
  const rootTitles = ["File", "Edit", "View", "Build", "Reset", "Debug", "Help"];
  // Closed: one root button, and none of the first-level titles is on screen.
  const visibleTitlesClosed = await ctPage.evaluate((titles) => {
    const seen: string[] = [];
    for (const e of Array.from(document.querySelectorAll("#menu *"))) {
      const t = (e.textContent ?? "").trim();
      const r = (e as HTMLElement).getBoundingClientRect();
      if (titles.includes(t) && r.width > 0 && r.height > 0 && e.children.length === 0) seen.push(t);
    }
    return seen;
  }, rootTitles);
  out.closed = {
    rootButtons: await ctPage.locator("#menu-root").count(),
    visibleFirstLevelTitles: visibleTitlesClosed,
  };
  const button = await box("#menu-root");
  await ctPage.locator("#menu-root").click();
  await ctPage.locator("#menu-elements").waitFor({ timeout: 30_000 });
  const firstLevel = await box("#menu-elements");
  const labels = (await ctPage.locator("#menu-elements > .menu-node-container .ct-menu-item-label").allInnerTexts())
    .map((s) => s.trim());
  const rows: Record<string, Box> = {};
  for (const t of labels) {
    const b = await ctPage.locator("#menu-elements > .menu-node-container", { hasText: t }).first().boundingBox();
    if (b) rows[t] = { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) };
  }
  // Hover Debug: its items open beside the first level.
  await ctPage.locator("#menu-elements > .menu-node-container", { hasText: "Debug" }).first().hover();
  await ctPage.locator(".menu-nested-elements").first().waitFor({ timeout: 30_000 });
  const nested = await box(".menu-nested-elements");
  const nestedLabels = (await ctPage.locator(".menu-nested-elements").first()
    .locator(".ct-menu-item-label").allInnerTexts()).map((s) => s.trim());
  out.open = {
    button, firstLevel, labels, rows, nested,
    nestedFirstLabels: nestedLabels.slice(0, 3),
    firstLevelBelowButton: firstLevel.y >= button.y + button.h - 1,
    nestedRightOfFirstLevel: nested.x >= firstLevel.x + firstLevel.w - 2,
    nestedLevelWithFolder: Math.abs(nested.y - rows["Debug"].y) <= rows["Debug"].h,
  };
  expect(labels).toEqual(rootTitles);
  await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.close());

  // ---- 5. THE TRANSPORT TOOLTIPS ----------------------------------------------
  // The desktop's toolbar: one `#<action>-image` button per transport action,
  // each carrying a `.custom-tooltip` (`isonim_debug_controls_view`).
  const ids = ["reverse-next", "next", "reverse-step-in", "step-in", "reverse-step-out",
    "step-out", "reverse-continue", "continue", "run-to-entry"];
  const tooltips: Record<string, string> = {};
  for (const id of ids) {
    tooltips[id] = await ctPage.evaluate((i) => {
      const t = document.querySelector("#" + i + "-image .custom-tooltip");
      return t ? (t.textContent ?? "").trim() : "";
    }, id);
  }
  out.tooltips = tooltips;
  expect(tooltips["next"].length).toBeGreaterThan(0);

  // ---- 6. THE OMNIBAR'S PLACEHOLDER --------------------------------------------
  out.omnibarPlaceholder = await ctPage.evaluate(() => {
    const input = document.getElementById("command-query-text") as HTMLInputElement | null;
    return input ? input.placeholder : "";
  });
  // THE GATE: the desktop draws the Omnibar ViewModel's placeholder — the
  // constant in `omnibar_vm.nim`, read from the source the desktop is
  // compiled from — and not words of its own.
  const omnibarVm = fs.readFileSync(path.join(repoRoot, "src", "frontend", "viewmodel",
    "viewmodels", "omnibar_vm.nim"), "utf8");
  const declared = /OmnibarPlaceholder\* = "([^"]*)"/.exec(omnibarVm);
  expect(declared).not.toBeNull();
  expect(out.omnibarPlaceholder).toBe(declared ? declared[1] : "");

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
});
