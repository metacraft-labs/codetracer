/**
 * plat60-low-level-code-capture.spec.ts — PLAT-60, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Low Level Code panes are
 * measured against.
 *
 * Spec: codetracer-pm `spec/GUI/Debugging-Features/Generated-Code-Listing.md`
 * §0 and §0.2 (the native front-ends).
 *
 * The real Electron front-end on the `noir_space_ship` recording the
 * terminal lanes record (the Noir producer's; `test-logs/tui-fixtures/`),
 * its Low Level Code view read from the DOM:
 *
 *   * the view, opened with the desktop's gesture (`Alt+1`, `aLowLevel1`):
 *     every row of the listing in order — a source line's number, an
 *     instruction's offset, text and source line — and which instruction
 *     carries the execution pointer and the debugger's line;
 *   * the header's words: the sync toggle, what a step does;
 *   * an instruction's right-click menu (PLAT-60 added it): its entries and
 *     which are disabled;
 *   * a click on an instruction of another line: the debugger's line after.
 *
 * Written to `src/tests/visual/answers/plat60-low-level-code.electron.json`,
 * which `src/frontend/tui/tests/test_plat60_low_level_code.nim` and
 * `src/frontend/gpui/tests/test_plat60_gpui_low_level_code.nim` assert the
 * native panes against.
 *
 * No mocks: a real recording, a real `replay-server`, the real Electron app
 * running this checkout's desktop JavaScript (`PLAT60_DESKTOP_PREFIX`, from
 * `scripts/plat45-desktop-prefix.sh`).
 */
import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
// A mutation harness grading through this spec names another file, so a run
// over a planted defect never writes the committed answers.
const answersFile =
  process.env.PLAT60_ANSWERS_OUT || path.join(answersDir, "plat60-low-level-code.electron.json");
const prefix = process.env.PLAT60_DESKTOP_PREFIX ?? "";

function recording(name: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(name + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-60: the '${name}' recording is not in test-logs/tui-fixtures/; ` +
        "run scripts/plat60-capture-electron.sh (it records it).",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

function where(page: any) {
  return page.evaluate(() => {
    const loc = (globalThis as any).data?.services?.debugger?.location;
    return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
  });
}

/** The listing as a reader of the DOM sees it, in order. */
function readListing(page: any) {
  return page.evaluate(() => {
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    const rows = Array.from(
      document.querySelectorAll(".low-level-code .low-level-code-instructions > div"),
    );
    return rows.map((row) => {
      if (row.classList.contains("low-level-code-source-line")) {
        return {
          kind: "source",
          line: Number(text(row.querySelector(".low-level-code-source-line-number"))),
          active: row.classList.contains("active-source-line"),
        };
      }
      return {
        kind: "instruction",
        offset: text(row.querySelector(".low-level-code-instruction-offset")),
        name: text(row.querySelector(".low-level-code-instruction-name")),
        source: text(row.querySelector(".low-level-code-instruction-source")),
        active: row.classList.contains("active-instruction"),
        executing: row.classList.contains("execution-pointer"),
      };
    });
  });
}

test.setTimeout(400_000);

test.describe("PLAT-60: the desktop's Low Level Code view, captured", () => {
  test.use({
    sourcePath: recording("noir_space_ship"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test("the listing, the pointer, the header, a row's menu, a click", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e: any) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    // The desktop's gesture: Alt+1 (`aLowLevel1`).
    const rows = ctPage.locator(".low-level-code .low-level-code-instruction");
    for (let attempt = 0; attempt < 5; attempt++) {
      await ctPage.keyboard.press("Alt+1");
      try {
        await rows.first().waitFor({ state: "visible", timeout: 15_000 });
        break;
      } catch {
        // pressed again
      }
    }
    try {
      await rows.first().waitFor({ state: "visible", timeout: 60_000 });
    } catch (e) {
      // Say what the view holds instead (an error, the empty statement).
      const pane = await ctPage.evaluate(
        () => (document.querySelector(".low-level-code") as HTMLElement | null)?.innerText ?? "",
      );
      throw new Error(`no instruction drawn; the view says: ${pane}; ${e}`);
    }
    await ctPage.waitForTimeout(1_000);
    const start = await where(ctPage);
    const listing = await readListing(ctPage);
    const header = await ctPage.evaluate(() => ({
      sync: (document.querySelector(".low-level-code .low-level-code-sync")?.textContent || "").trim(),
      stepping: (document.querySelector(".low-level-code .low-level-code-stepping")?.textContent || "").trim(),
    }));

    // An instruction's right-click menu.
    await rows.first().click({ button: "right" });
    let rowMenu: { label: string; disabled: boolean }[] = [];
    try {
      await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 5_000 });
      rowMenu = await ctPage.evaluate(() =>
        Array.from(document.querySelectorAll("#context-menu-container .context-menu-item")).map((e) => ({
          label: ((e.querySelector(".ct-menu-item-label") || e).textContent || "").trim(),
          disabled: e.classList.contains("ct-menu-item--disabled"),
        })),
      );
      await ctPage.keyboard.press("Escape");
    } catch {
      rowMenu = [];
    }

    // A click on the last instruction that has a step, on another line.
    const instructions = (listing as any[]).filter((r) => r.kind === "instruction");
    let target = -1;
    instructions.forEach((r, i) => {
      if (r.offset.startsWith("StepId(") && !r.source.endsWith(":" + start.line)) target = i;
    });
    const targetLine = target >= 0 ? Number(instructions[target].source.split(":").pop()) : -1;
    if (target >= 0) {
      await rows.nth(target).click();
      const deadline = Date.now() + 60_000;
      while (Date.now() < deadline && (await where(ctPage)).line !== targetLine) {
        await ctPage.waitForTimeout(200);
      }
    }
    const after = await where(ctPage);
    const listingAfter = await readListing(ctPage);

    const out = {
      _comment: [
        "PLAT-60 — the desktop's Low Level Code view on noir_space_ship, read from the real Electron app.",
        "Produced by src/tests/gui/tests/low-level-code/plat60-low-level-code-capture.spec.ts",
        "(`just plat60-capture-electron`).",
      ],
      start,
      listing,
      header,
      rowMenu,
      click: { target, targetLine, after },
      listingAfter,
      pageErrors,
    };
    fs.mkdirSync(path.dirname(answersFile), { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

    expect(instructions.length).toBeGreaterThan(1);
    expect(rowMenu.map((e) => e.label)).toEqual([
      "Go to Source Line",
      "Show Source Line",
      "Copy Instruction",
      "Copy Source Location",
    ]);
    expect(after.line).toBe(targetLine);
  });
});
