/**
 * plat40-panes-capture.spec.ts — PLAT-40's desktop capture for `DIFF-9`.
 *
 * The desktop half of *"one producer, three surfaces"*: the `calc` recording,
 * driven to the stop `src/tests/visual/plat40-scenario.json` declares (the
 * same one the native window lane drives it to), one breakpoint set through
 * the editor's gutter, and the Breakpoints & Tracepoints pane opened from the
 * View menu — then the window is photographed with the call trace, the event
 * log and the breakpoint list on screen.
 *
 * Two artefacts, from two producers that share no code:
 *
 *   src/tests/visual/captures/electron/plat40-panes.png   the frame (gitignored)
 *   src/tests/visual/answers/plat40-panes.electron.json   the DOM's models
 *
 * `src/tests/visual/screen_oracle/plat40_record.nim` reads the frame into
 * PLAT-39's domain types; the DOM models are the second reading of the same
 * screen, taken AFTER the frame settled so the two describe one frame.
 *
 * No mocks: a real `.ct` recording, the real `ct` binary, a real
 * `replay-server`, the real Electron main process and renderer. The recording
 * is the one `just test-tui` records with the product's own `ct record`; its
 * absence FAILS BY NAME rather than skipping.
 */

import * as fs from "fs";
import * as path from "path";

import { test, expect } from "../../lib/fixtures";
import { debugToolbarSelector } from "../../page-objects/debug-toolbar-ids";
import { LayoutPage } from "../../page-objects/layout_page";
import {
  extractCalltraceModel,
  extractEventLogModel,
  extractPointListModel,
} from "../../page-objects/layout_extractors";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const visualRoot = path.join(repoRoot, "src", "tests", "visual");
const capturesDir = path.join(visualRoot, "captures", "electron");
const answersDir = path.join(visualRoot, "answers");

interface Plat40Scenario {
  recording: string;
  nextSteps: number;
  breakpointFile: string;
  breakpointLine: number;
}

const scenario: Plat40Scenario = JSON.parse(
  fs.readFileSync(path.join(visualRoot, "plat40-scenario.json"), "utf8"),
);

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(`${scenario.recording}-`)).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-40: the '${scenario.recording}' recording is not in test-logs/tui-fixtures/; ` +
        "run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const FRAME = { width: 1920, height: 1080 };

test.use({ sourcePath: recording(), launchMode: "trace-folder" });
test.setTimeout(300_000);

async function ticks(page: import("playwright").Page): Promise<number> {
  return page.evaluate(() => {
    const w = window as unknown as {
      data?: { services?: { debugger?: { location?: { rrTicks?: number } } } };
    };
    return w.data?.services?.debugger?.location?.rrTicks ?? -1;
  });
}

async function busy(page: import("playwright").Page): Promise<boolean> {
  return page.evaluate(() => {
    const w = window as unknown as { data?: { status?: { stableBusy?: boolean } } };
    return w.data?.status?.stableBusy === true;
  });
}

async function next(page: import("playwright").Page): Promise<void> {
  // One synthesized click, then WAIT FOR THE MOVE (PLAT-35's measured rule:
  // a fixed sleep races a round trip of 0.2 to 5 s).
  const before = await ticks(page);
  await page.locator(debugToolbarSelector("next")).dispatchEvent("click");
  await expect
    .poll(async () => (await ticks(page)) !== before && !(await busy(page)), {
      timeout: 60_000,
      message: "PLAT-40: 'next' was clicked and the program did not move",
    })
    .toBe(true);
}

test("the call trace, event log and breakpoint list, photographed at one stop", async ({
  ctPage,
  electronApp,
}) => {
  expect(electronApp, "the window must be sized through the main process").not.toBeNull();
  const win = await (electronApp as import("playwright").ElectronApplication).browserWindow(ctPage);
  await win.evaluate((w, s) => {
    const bw = w as unknown as {
      setResizable: (b: boolean) => void;
      unmaximize: () => void;
      setFullScreen: (b: boolean) => void;
      setContentSize: (a: number, b: number) => void;
    };
    bw.setResizable(true);
    bw.setFullScreen(false);
    bw.unmaximize();
    bw.setContentSize(s.width, s.height);
  }, FRAME);
  await expect
    .poll(async () => ctPage.evaluate(() => `${window.innerWidth}x${window.innerHeight}`))
    .toBe(`${FRAME.width}x${FRAME.height}`);

  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
  expect(await ticks(ctPage)).toBeGreaterThanOrEqual(0);
  for (let i = 0; i < scenario.nextSteps; i++) await next(ctPage);

  // The breakpoint, through the gutter the product drew for the line.
  const line = scenario.breakpointLine;
  const cell = ctPage.locator(
    `div[id^='editorComponent'] .margin-view-overlays .gutter[data-line='${line}']`,
  );
  await cell.dispatchEvent("click");
  await expect(
    ctPage.locator(
      `div[id^='editorComponent'] .margin-view-overlays .gutter[data-line='${line}'] ` +
        ".gutter-breakpoint-enabled",
    ),
  ).toHaveCount(1, { timeout: 15_000 });

  // The pane, from the View menu, as a user opens it.
  if (!(await ctPage.locator("#menu-main").isVisible())) {
    await ctPage.locator("#menu-root").click();
  }
  await ctPage.locator(".menu-folder-view").hover();
  await ctPage.locator(".menu-element-breakpoints-tracepoints").click();
  await expect
    .poll(async () => (await extractPointListModel(ctPage)).points.length, {
      timeout: 60_000,
      message: "PLAT-40: the breakpoint never became a row of the pane",
    })
    .toBe(1);

  // Settle: pointer off the chrome, animations frozen, two identical frames.
  fs.mkdirSync(capturesDir, { recursive: true });
  fs.mkdirSync(answersDir, { recursive: true });
  await ctPage.mouse.move(2, 2);
  await ctPage.keyboard.press("Escape");
  await ctPage.waitForTimeout(1_500);
  await ctPage.addStyleTag({
    content: `*, *::before, *::after { animation: none !important;
      transition: none !important; caret-color: transparent !important; }`,
  });
  const shot = path.join(capturesDir, "plat40-panes.png");
  let previous: Buffer | null = null;
  let settledAfter = 0;
  for (let attempt = 1; attempt <= 12; attempt++) {
    await ctPage.screenshot({ path: shot });
    const current = fs.readFileSync(shot);
    if (previous !== null && previous.equals(current)) {
      settledAfter = attempt;
      break;
    }
    previous = current;
    await ctPage.waitForTimeout(250);
  }
  expect(settledAfter, "the window never produced two identical frames").toBeGreaterThan(0);

  // The DOM's reading of the frame just taken.
  const layout = new LayoutPage(ctPage);
  const logs = await layout.eventLogTabs(true);
  const eventLog = logs.length > 0 ? await extractEventLogModel(logs[0]) : null;
  const answers = {
    takenAt: new Date().toISOString(),
    scenario,
    rrTicks: await ticks(ctPage),
    settledAfterAttempts: settledAfter,
    calltrace: await extractCalltraceModel(ctPage),
    eventLog,
    pointList: await extractPointListModel(ctPage),
  };
  fs.writeFileSync(
    path.join(answersDir, "plat40-panes.electron.json"),
    JSON.stringify(answers, null, 2) + "\n",
  );
  expect(answers.calltrace.calls.length).toBeGreaterThan(0);
  expect(answers.pointList.points).toEqual([
    { kind: "breakpoint", fileName: scenario.breakpointFile, lineNumber: line },
  ]);
});
