/**
 * plat61-shell-capture.spec.ts — PLAT-61, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Shell panes are measured
 * against.
 *
 * Spec: codetracer-pm `spec/Planned-Features/CodeTracer-Shell.md` §7.
 *
 * The real Electron front-end on a real recording (`PLAT61_SESSION_TRACE`,
 * recorded by `ct record` in `just plat61-capture-electron`), its Shell pane
 * opened from View › Shell, its shell — a real bash behind the main process
 * (`ct shell-session`) — running a recorded build (`PLAT61_PROJECT/build.sh`:
 * it writes a Python program and `ct record`s it). Read from the DOM:
 *
 *   * the pane's rows: each line's text, its mark (`start` / `range` / none),
 *     its tone, its gutter glyph and the gutter's computed colour;
 *   * the pane's status words;
 *   * a click on the recording's gutter: a new session tab, the recording's.
 *
 * Written to `src/tests/visual/answers/plat61-shell.electron.json` (the
 * recording's id and the project's folder normalised, as they differ per
 * run), which `src/frontend/tui/tests/test_plat61_shell.nim` and
 * `src/frontend/gpui/tests/test_plat61_gpui_shell.nim` assert their panes
 * against.
 *
 * No mocks: a real recording, the real Electron app, a real shell on a real
 * pty, a real `ct record`.
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as path from "node:path";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat61-shell.electron.json");
const trace = process.env.PLAT61_SESSION_TRACE || "";
const project = process.env.PLAT61_PROJECT || "";

/** The pane's rows, as a reader of the DOM sees them. */
async function readRows(ctPage: any) {
  return await ctPage.evaluate(() =>
    Array.from(document.querySelectorAll(".isonim-shell .shell-row")).map((row) => {
      const gutter = row.querySelector(".shell-gutter") as HTMLElement;
      const text = row.querySelector(".shell-text");
      return {
        line: Number(row.getAttribute("data-line")),
        mark: row.getAttribute("data-mark") || "",
        tone: row.getAttribute("data-tone") || "",
        gutter: gutter ? (gutter.textContent || "").trim() : "",
        gutterColor: gutter && row.getAttribute("data-tone") ? getComputedStyle(gutter).color : "",
        text: text ? (text.textContent || "").replace(/\s+$/, "") : "",
      };
    }),
  );
}

function normalised(text: string): string {
  return text
    .replace(/recordingId:[0-9a-f-]+/g, "recordingId:<id>")
    .split(project).join("<project>");
}

test.describe("PLAT-61: the desktop's Shell pane, captured", () => {
  test.skip(!trace || !project, "PLAT61_SESSION_TRACE / PLAT61_PROJECT (just plat61-capture-electron)");
  test.use({ launchMode: "trace-folder", sourcePath: trace });
  test.setTimeout(300_000);

  test("a recorded build in the pane's shell; a click opens its recording", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 120_000 });
    // View › Shell, as a user opens it.
    await ctPage.locator("#menu-root").click();
    await ctPage.locator("#menu-elements").waitFor({ timeout: 30_000 });
    await ctPage.locator("#menu-elements > .menu-node-container", { hasText: "View" }).first().hover();
    await ctPage.locator(".menu-nested-elements .ct-menu-item-label", { hasText: /^Shell$/ }).first().click();
    const pane = ctPage.locator('.isonim-shell[data-state="running"]');
    await expect(pane).toBeVisible({ timeout: 60_000 });
    await expect(ctPage.locator(".isonim-shell .shell-row", { hasText: "$" }).first()).toBeVisible({ timeout: 60_000 });

    // The build, typed into the focused pane — edited with the shell's own
    // line-editing keys, which the window also binds (`Ctrl+B` toggles the
    // side panels, `Ctrl+E` the editor's read-only mode): the pane owns them
    // while it has the focus (§7.5), so the line the shell runs is the build.
    // Were the window to take them, the `b` would land at the end and the
    // shell would run `…/uild.shb`, which builds nothing.
    await ctPage.locator(".isonim-shell .shell-rows").click();
    await ctPage.keyboard.type(project + "/uild.sh");
    for (let i = 0; i < "uild.sh".length; i++) await ctPage.keyboard.press("Control+b");
    await ctPage.keyboard.type("b");
    await ctPage.keyboard.press("Control+e");
    await ctPage.keyboard.press("Enter");
    await expect(ctPage.locator(".isonim-shell .shell-status")).toContainText("1 recording", { timeout: 180_000 });
    await expect(ctPage.locator(".isonim-shell .shell-row", { hasText: "recordingId:" })).toBeVisible({ timeout: 60_000 });
    const rows = await readRows(ctPage);
    const status = ((await ctPage.locator(".isonim-shell .shell-status").textContent()) || "").trim();
    const size = await ctPage.evaluate(() => {
      const rows = document.querySelectorAll(".isonim-shell .shell-row");
      return rows.length;
    });

    // The recording's gutter: a new session tab, the recording's.
    // A recording id can wrap across physical terminal rows. Join only for
    // identity extraction; keep the captured rows and answer projection intact.
    const emittedText = rows.map((r: any) => r.text).join("");
    const recordingIds = [...emittedText.matchAll(/recordingId:([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/g)]
      .map((match) => match[1]);
    expect(recordingIds, "the build emits exactly one complete recording id").toHaveLength(1);
    const recordingId = recordingIds[0];
    const tabsBefore = await ctPage.locator(".session-tab").count();
    // The gutter's own `click` listener, dispatched on it: the pointer's aim
    // at a 2ch inline cell is Playwright's to get wrong, not the pane's.
    const startGutter = ctPage.locator('.isonim-shell .shell-row[data-mark="start"] .shell-gutter').first();
    await startGutter.dispatchEvent("click");
    const openDeadline = Date.now() + 120_000;
    const remainingOpenBudget = () => {
      const remaining = openDeadline - Date.now();
      if (remaining <= 0) throw new Error("the recording did not finish opening within 120000 ms");
      return remaining;
    };
    await expect(ctPage.locator(".session-tab")).toHaveCount(tabsBefore + 1, { timeout: 120_000 });
    // Preserve the activation note before loading the new trace remounts the pane.
    const note = ((await ctPage.locator(".isonim-shell .shell-status").first().textContent({ timeout: remainingOpenBudget() })) || "").trim();
    // The first two-tab frame precedes the asynchronous load. Measure identity
    // and rendered tabs together, using the remainder of the same open budget.
    let openedSnapshot: { recordingId: string; sessionCount: number; tabsAfter: number } | undefined;
    await expect.poll(async () => {
      openedSnapshot = await ctPage.evaluate((sessionIndex: number) => {
        const sessions = (window as any).data?.sessions || [];
        return {
          recordingId: String(sessions[sessionIndex]?.trace?.recordingId ?? ""),
          sessionCount: sessions.length,
          tabsAfter: document.querySelectorAll(".session-tab").length,
        };
      }, tabsBefore);
      return openedSnapshot;
    }, { timeout: remainingOpenBudget() }).toEqual({
      recordingId, sessionCount: tabsBefore + 1, tabsAfter: tabsBefore + 1,
    });
    const tabsAfter = openedSnapshot!.tabsAfter;

    // The build's own lines: from its first through the row after the
    // recording's range (the id `ct record` prints). Rows before it and after
    // it depend on the pane's width (the command line wraps), which differs
    // between front-ends; these do not.
    const built = rows.findIndex((r: any) => r.text === "building prog.py");
    let last = built;
    rows.forEach((r: any, i: number) => { if (r.mark !== "none") last = i; });
    const out = {
      rows: rows.slice(built, last + 2).map((r: any) => ({
        mark: r.mark, tone: r.tone, gutter: r.gutter, gutterColor: r.gutterColor,
        text: normalised(r.text),
      })),
      status: status.replace(/^Shell — /, ""),
      shownRows: size,
      opened: {
        tabsBefore,
        tabsAfter,
        note: normalised(note).replace(/^Shell — /, "")
          .replace(/opened recording [0-9a-f]+/, "opened recording <id>"),
      },
    };
    fs.mkdirSync(answersDir, { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 2) + "\n");
    expect(built).toBeGreaterThan(0);
    expect(rows[built + 1].mark).toBe("start");
    expect(rows[built + 1].gutter).toBe("●");
    expect(rows[built + 2].mark).toBe("range");
    expect(rows[built + 2].gutter).toBe("│");
    expect(out.opened.tabsAfter).toBe(tabsBefore + 1);
    expect(out.opened.note).toContain("opened recording <id>");
  });
});
