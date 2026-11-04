/**
 * plat60-native-low-level-code-capture.spec.ts — the desktop's Low Level
 * Code view over a NATIVE recording: the reference the terminal's and the
 * GPUI window's panes are measured against on the same recording.
 *
 * Spec: codetracer-pm `spec/GUI/Debugging-Features/Generated-Code-Listing.md`
 * §0.2 and §13 — a native recording's listing is its function's machine
 * code, cross-referenced to the source line each instruction came from, and
 * a step pressed in the listing goes by instruction where the engine offers
 * it.
 *
 * The real Electron front-end on an rr recording of the shared native
 * fixture `codetracer-native-test-programs/c/sudoku_solver` (`ct record`, as
 * the language suites record theirs), replayed by `ct-native-replay`
 * (`CODETRACER_CT_NATIVE_REPLAY_CMD`), its Low Level Code view read from the
 * DOM:
 *
 *   * at the recording's first stop (`main`), opened with `Alt+1`: every row —
 *     a source line's number, an instruction's offset (its load address), text and
 *     source line — and which instruction carries the execution pointer;
 *   * the header: the function's load address and what a step does (`steps
 *     by instruction`, which the engine announced);
 *   * F10 pressed with the keyboard focus in the listing (focused as Tab
 *     focuses a row, without a click, which would move the debugger): the
 *     listing after it, whose pointer is on the next instruction (rr's tick
 *     counts branches, so it may not move);
 *   * Shift+F10 then: back to the first instruction and tick.
 *
 * Written to `src/tests/visual/answers/plat60-native-low-level-code.electron.json`
 * (`PLAT60_NATIVE_ANSWERS_OUT`) — the desktop's rows, beside the terminal's
 * and GPUI's suites on the same fixture.
 *
 * No mocks: a real rr recording, a real `replay-server` and
 * `ct-native-replay`, the real Electron app running this checkout's desktop
 * JavaScript (`PLAT60_DESKTOP_PREFIX`, from `scripts/plat45-desktop-prefix.sh`).
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
  process.env.PLAT60_NATIVE_ANSWERS_OUT ||
  path.join(answersDir, "plat60-native-low-level-code.electron.json");
const prefix = process.env.PLAT60_DESKTOP_PREFIX ?? "";

/** The shared native fixture: `ct record` records it with rr. */
function nativeFixture(): string {
  const programs =
    process.env.NATIVE_TEST_PROGRAMS_REPO || path.join(repoRoot, "..", "codetracer-native-test-programs");
  return path.join(programs, "c", "sudoku_solver", "main.c");
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
    const rows = Array.from(document.querySelectorAll(".low-level-code .low-level-code-instructions > div"));
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

function pointerOf(listing: any[]): string {
  const at = listing.filter((r) => r.kind === "instruction" && r.executing);
  return at.length === 1 ? at[0].offset : `<${at.length} pointers>`;
}

/** Wait until the pointer is no longer on `offset` (the step landed). */
async function pointerLeaves(page: any, offset: string) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const now = pointerOf(await readListing(page));
    if (now !== offset && !now.startsWith("<0")) return now;
    await page.waitForTimeout(200);
  }
  return pointerOf(await readListing(page));
}

/** Put the keyboard focus on the listing's first row, as Tab would. */
async function focusListing(page: any) {
  await page.evaluate(() => {
    const row = document.querySelector(".low-level-code .low-level-code-instruction") as HTMLElement | null;
    row?.focus();
  });
}

test.setTimeout(600_000);

test.describe("the desktop's Low Level Code view on a native recording, captured", () => {
  test.use({
    sourcePath: nativeFixture(),
    launchMode: "trace",
    recordBackend: "rr",
    codetracerPrefixOverride: prefix,
  });

  test("machine code, the pointer, the header, a step by instruction and back", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e: any) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view", { timeout: 60_000 });
    const rows = ctPage.locator(".low-level-code .low-level-code-instruction");
    // Alt+1 until the view is up, then until it holds either the listing or
    // the engine's refusal (the fixture gives an rr program two minutes).
    const paneText = () =>
      ctPage.evaluate(
        () => (document.querySelector(".low-level-code") as HTMLElement | null)?.innerText ?? "",
      );
    for (let attempt = 0; attempt < 3 && (await ctPage.locator(".low-level-code").count()) === 0; attempt++) {
      await ctPage.keyboard.press("Alt+1");
      await ctPage.waitForTimeout(3_000);
    }
    const deadline = Date.now() + 45_000;
    while (Date.now() < deadline && (await rows.count()) === 0) {
      await ctPage.waitForTimeout(500);
    }
    if ((await rows.count()) === 0) {
      const pane = (await paneText()).replace(/\s+/g, " ");
      throw new Error(`no instruction drawn; the view says: ${pane}`);
    }
    // The stepping words arrive with the engine's announcement.
    await ctPage.waitForTimeout(1_000);
    const start = await where(ctPage);
    const listing = await readListing(ctPage);
    const header = await ctPage.evaluate(() => ({
      address: (document.querySelector(".low-level-code .low-level-code-address")?.textContent || "").trim(),
      stepping: (document.querySelector(".low-level-code .low-level-code-stepping")?.textContent || "").trim(),
    }));
    const firstPointer = pointerOf(listing);

    // F10 with the focus in the listing: one instruction.
    await focusListing(ctPage);
    await ctPage.keyboard.press("F10");
    const stepped = await pointerLeaves(ctPage, firstPointer);
    await ctPage.waitForTimeout(500);
    const afterStep = await where(ctPage);
    const listingAfterStep = await readListing(ctPage);

    // Shift+F10: back to where it was.
    await focusListing(ctPage);
    await ctPage.keyboard.press("Shift+F10");
    const back = await pointerLeaves(ctPage, stepped);
    await ctPage.waitForTimeout(500);
    const afterBack = await where(ctPage);

    const out = {
      _comment: [
        "The desktop's Low Level Code view on the native_sudoku_c rr recording, read from the real Electron app.",
        "Produced by src/tests/gui/tests/low-level-code/plat60-native-low-level-code-capture.spec.ts",
        "(`just plat60-native-capture-electron`).",
      ],
      start,
      listing,
      header,
      step: { from: firstPointer, to: stepped, after: afterStep, back, afterBack },
      listingAfterStep,
      pageErrors,
    };
    fs.mkdirSync(path.dirname(answersFile), { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

    const instructions = (listing as any[]).filter((r) => r.kind === "instruction");
    expect(instructions.length).toBeGreaterThan(10);
    expect(instructions.every((r) => /^\d+$/.test(r.offset))).toBe(true);
    expect(firstPointer).toMatch(/^\d+$/);
    expect(header.address).toMatch(/^Originating address: 0x[0-9A-Fa-f]+$/);
    expect(header.stepping).toBe("steps by instruction");
    expect(stepped).not.toBe(firstPointer);
    expect(stepped).toMatch(/^\d+$/);
    // By ONE instruction: from an instruction that falls through, the next one
    // of the listing (a line step would pass the rest of the line).
    const at = instructions.findIndex((r) => r.offset === firstPointer);
    const mnemonic = (instructions[at]?.name || "").toLowerCase();
    const fallsThrough = !/^(j|call|ret|loop)/.test(mnemonic);
    if (fallsThrough) expect(stepped).toBe(instructions[at + 1].offset);
    expect(back).toBe(firstPointer);
    expect(afterBack.ticks).toBe(start.ticks);
    // A page error with a message is a defect of this view; the window also
    // reports one `null` rejection with no message on every native launch,
    // which says nothing about it.
    expect(pageErrors.filter((e) => e.trim().length > 0)).toEqual([]);
  });
});
