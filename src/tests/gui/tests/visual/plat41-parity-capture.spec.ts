/**
 * plat41-parity-capture.spec.ts — PLAT-41's desktop column of the pane parity
 * table, taken from a RUN.
 *
 * PLAT-23's parity table put the desktop column at SOURCE level because no
 * desktop could be run on its host; it can now, so this column is a capture:
 * the `calc` recording, driven to the stop `src/tests/visual/plat41-scenario
 * .json` declares (the native lane drives it to the same one), and each of
 * the thirteen `PaneKind` values probed in the desktop's own DOM for whether
 * it draws DATA, draws a REPORT, or is not on screen at all. Where a pane
 * draws data, its value is recorded in PLAT-39's domain types for DIFF-10.
 *
 * Writes `src/tests/visual/answers/plat41-parity.electron.json`;
 * `plat41_record.nim` folds it into the committed record.
 *
 * No mocks: a real `.ct` recording, the real `ct` binary, a real
 * `replay-server`, the real Electron app. The recording's absence FAILS BY
 * NAME rather than skipping.
 */

import * as fs from "fs";
import * as path from "path";

import { test, expect } from "../../lib/fixtures";
import { debugToolbarSelector } from "../../page-objects/debug-toolbar-ids";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const visualRoot = path.join(repoRoot, "src", "tests", "visual");
const answersDir = path.join(visualRoot, "answers");

const scenario: { recording: string; nextSteps: number } = JSON.parse(
  fs.readFileSync(path.join(visualRoot, "plat41-scenario.json"), "utf8"),
);

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(`${scenario.recording}-`)).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-41: the '${scenario.recording}' recording is not in test-logs/tui-fixtures/; ` +
        "run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

/**
 * The desktop toolbar's transport buttons, id to label — the same table as
 * `debug_controls_vm.TransportActions`, whose ids the toolbar suffixes with
 * `-image`. `test_plat41_parity.nim` asserts this spec and that table agree.
 */
const TRANSPORT: [string, string][] = [
  ["reverse-next", "Reverse next"],
  ["next", "Next"],
  ["reverse-step-in", "Reverse step in"],
  ["step-in", "Step in"],
  ["reverse-step-out", "Reverse step out"],
  ["step-out", "Step out"],
  ["reverse-continue", "Reverse continue"],
  ["continue", "Continue"],
  ["run-to-entry", "Run to entry"],
];

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

test("the thirteen panes on the desktop, data or report, at one stop", async ({ ctPage }) => {
  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
  for (let i = 0; i < scenario.nextSteps; i++) {
    const before = await ticks(ctPage);
    await ctPage.locator(debugToolbarSelector("next")).dispatchEvent("click");
    await expect
      .poll(async () => (await ticks(ctPage)) !== before, { timeout: 60_000 })
      .toBe(true);
  }
  await ctPage.waitForTimeout(2_000);

  // The timeline is a tab of the event log's stack; its DOM is read off the
  // track's own data attributes once the tab has been shown.
  const timelineTab = ctPage.locator(".lm_tab", { hasText: /^TIMELINE$/i }).first();
  if ((await timelineTab.count()) > 0) {
    await timelineTab.click();
    await ctPage.waitForTimeout(1_000);
  }

  const census = await ctPage.evaluate((transport: [string, string][]) => {
    const count = (sel: string) => document.querySelectorAll(sel).length;
    const texts = (sel: string) =>
      Array.from(document.querySelectorAll(sel)).map((e) => (e.textContent ?? "").trim());
    const present = (sel: string) => document.querySelector(sel) !== null;
    type Row = { pane: string; state: "data" | "report" | "absent"; detail: string };
    const rows: Row[] = [];
    const row = (pane: string, isPresent: boolean, hasData: boolean, detail: string) =>
      rows.push({ pane, state: !isPresent ? "absent" : hasData ? "data" : "report", detail });

    row("editor", present(".monaco-editor"), count(".monaco-editor .view-line") > 0,
        `${count(".monaco-editor .view-line")} line(s)`);
    row("calltrace", present(".calltrace-view"), count(".calltrace-view .call-text") > 0,
        `${count(".calltrace-view .call-text")} call(s)`);
    const stateVars = count("[id^='stateComponent'] .value-name");
    row("state", present("[id^='stateComponent']"), stateVars > 0, `${stateVars} value(s)`);
    const events = texts(".eventLog-text").filter((t) => t.length > 0).length;
    row("eventLog", present(".eventLog"), events > 0, `${events} event row(s)`);
    const actions = transport
      .filter(([id]) => present(`#${id}-image`))
      .map(([, label]) => label);
    row("debugControls", present("#isonim-debug-controls"), actions.length > 0,
        `${actions.length} transport control(s)`);
    const flowNames = texts(".ct-omni-name");
    row("flow", present(".monaco-editor"), flowNames.length > 0, `${flowNames.length} value chip(s)`);
    const track = document.querySelector(".timeline-component .timeline-track");
    const lastTick = track ? Number(track.getAttribute("data-max-rr-ticks") ?? "0") : 0;
    const currentTick = track ? Number(track.getAttribute("data-current-rr-ticks") ?? "-1") : -1;
    row("timeline", track !== null, lastTick > 0, `tick ${currentTick} / ${lastTick}`);
    const searchRows = count("[id^='searchResultsComponent'] .search-result");
    row("search", present("[id^='searchResultsComponent']"), searchRows > 0, `${searchRows} result(s)`);
    const points = count(".point-list-component .point-list-row");
    row("pointList", present(".point-list-component"), points > 0, `${points} point(s)`);
    const pinned = count("[id^='scratchpadComponent'] .scratchpad-value");
    row("scratchpad", present("[id^='scratchpadComponent']"), pinned > 0, `${pinned} pinned value(s)`);
    const shellLines = count("[id^='shellComponent'] .shell-line");
    row("shell", present("[id^='shellComponent']"), shellLines > 0, `${shellLines} line(s)`);
    const fileLabels = texts("[id^='filesystemComponent'] .jstree-anchor, [id^='filesystemComponent'] .filesystem-entry-label")
      .filter((t) => t.length > 0);
    row("fileTree", present("[id^='filesystemComponent']"), fileLabels.length > 0,
        `${fileLabels.length} entr(y|ies)`);
    const buildLines = count("[id^='buildComponent'] .build-line");
    row("buildOutput", present("[id^='buildComponent']"), buildLines > 0, `${buildLines} line(s)`);

    return {
      rows,
      transport: { isVisible: actions.length > 0, actions },
      timeline: { isVisible: track !== null, currentTick, lastTick },
      fileTree: { isVisible: fileLabels.length > 0, entries: fileLabels },
      flowNames,
    };
  }, TRANSPORT);

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(
    path.join(answersDir, "plat41-parity.electron.json"),
    JSON.stringify(
      { takenAt: new Date().toISOString(), scenario, rrTicks: await ticks(ctPage), ...census },
      null,
      2,
    ) + "\n",
  );
  expect(census.rows.length).toBe(13);
});
