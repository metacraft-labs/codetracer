import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import type { Locator, Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { TraceLogPanel } from "../../page-objects/panes/editor/trace-log-panel";
import { retry } from "../../lib/retry-helpers";

const visualTracePath = process.env.CODETRACER_REAL_VISUAL_TRACE ?? "";
const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const outputDir = process.env.CODETRACER_README_SCREENSHOT_DIR ?? repoRoot;

test.use({
  sourcePath: path.resolve(__dirname, "..", "..", "..", "..", "..", "examples", "fibonacci.py"),
  launchMode: "trace",
  deploymentMode: "web",
  video: "on",
});

async function captureReadmeScreenshot(
  target: Page | Locator,
  fileName: string,
): Promise<void> {
  fs.mkdirSync(outputDir, { recursive: true });
  await target.screenshot({
    path: path.join(outputDir, fileName),
  });
}

test.describe("README animations", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(240_000);

  test.beforeEach(() => {
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
  });

  async function setup(ctPage: Page) {
    const layout = new LayoutPage(ctPage);
    // Be resilient to layout variations by not waiting for ALL components
    await layout.waitForTraceLoaded();
    await layout.waitForEditorLoaded();
    await layout.waitForStateLoaded();
    await layout.waitForCallTraceLoaded();
    await layout.waitForEventLogLoaded();
    await ctPage.setViewportSize({ width: 1440, height: 900 });

    let editor: any;
    await retry(async () => {
        const tabs = await layout.editorTabs();
        // The tab title might be "fibonacci.py" or the full path
        editor = tabs.find(t => t.tabButtonText.toLowerCase().includes("fibonacci.py"));
        return !!editor;
    }, { maxAttempts: 60, delayMs: 1000 });

    await editor.tabButton().click();
    // Wait for Monaco editor to appear
    await expect(editor.root.locator(".monaco-editor")).toBeVisible({ timeout: 30000 });
    await ctPage.waitForTimeout(2000);

    return { layout, editor };
  }

  test("omniscience", async ({ ctPage }) => {
    const { editor } = await setup(ctPage);

    // Show flow decorations.  Select line 8 of the source via the gutter
    // -anchored resolver — Monaco does not put a `data-line-number` on its
    // `.view-line` divs, and a left-click on the gutter itself would set a
    // breakpoint rather than select the line.
    await editor.clickSourceLine(8);
    await expect(ctPage.locator(".flow-parallel-value-box, .flow-inline-value-box").first()).toBeVisible({ timeout: 30000 });

    // Scrub the iteration slider.
    //
    // These used to be `if (await slider.isVisible())` / `if (box)` guards,
    // which made the whole block a silent no-op whenever the slider failed to
    // render.  That is exactly the failure mode of #562 — the slider was
    // created with a zero-width box and so was never `isVisible()` — and this
    // spec tolerated it for three release cycles while the issue was reported
    // "fixed" twice.  Assert instead: a loop screenshot without a working
    // slider is not a screenshot worth taking.
    //
    // `.noUi-base` is injected by `noUiSlider.create()`; `.flow-loop-slider`
    // is the container we create ourselves and is present even when the
    // widget failed to initialise, so the container alone proves nothing.
    const slider = ctPage.locator(".flow-loop-slider").first();
    await expect(slider).toBeVisible({ timeout: 30000 });
    await expect(slider.locator(".noUi-base")).toBeVisible();

    const box = await slider.boundingBox();
    expect(box, "the loop iteration slider must have a layout box").not.toBeNull();
    expect(box!.width, "the loop iteration slider must not be zero-width (#562)").toBeGreaterThan(0);

    await ctPage.mouse.move(box!.x + 10, box!.y + box!.height / 2);
    await ctPage.mouse.down();
    await ctPage.mouse.move(box!.x + box!.width - 10, box!.y + box!.height / 2, { steps: 50 });
    await ctPage.mouse.up();
    await ctPage.waitForTimeout(500);
    await ctPage.mouse.down();
    await ctPage.mouse.move(box!.x + 10, box!.y + box!.height / 2, { steps: 50 });
    await ctPage.mouse.up();
    await ctPage.waitForTimeout(1000);
  });

  test("tracepoint", async ({ ctPage }) => {
    const { editor } = await setup(ctPage);

    await editor.openTrace(9); // print(f"fib({i}) = ...")
    const tracePanel = new TraceLogPanel(editor, 9);
    await tracePanel.root.waitFor({ state: "visible" });
    await tracePanel.typeExpression("log(i)");
    await editor.runTracepointsJs();

    const resultRows = tracePanel.root.locator(
      ".chart-table .trace-table tbody tr:has(td.trace-values)",
    );
    await expect(tracePanel.root.locator(".trace-error")).toHaveCount(0);
    await expect(resultRows).toHaveCount(10, { timeout: 30000 });
    await expect(resultRows.first()).toContainText("i=0");
    await expect(resultRows.nth(9)).toContainText("i=9");
    await expect(tracePanel.root.locator(".data-tables-footer-rows-count")).toHaveText("10");

    // Scroll through results
    const results = tracePanel.root.locator(".chart-table .dt-scroll-body");
    await results.hover();
    await ctPage.mouse.wheel(0, 500);
    await ctPage.waitForTimeout(500);
    await ctPage.mouse.wheel(0, -500);
    await ctPage.waitForTimeout(1000);
  });

  test("calltrace", async ({ ctPage }) => {
    const { layout } = await setup(ctPage);
    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.tabButton().click();
    await expect(callTrace.root.locator(".calltrace-call-line").first()).toBeVisible({ timeout: 10000 });

    await ctPage.mouse.wheel(0, 300);
    await ctPage.waitForTimeout(500);
    await ctPage.mouse.wheel(0, -300);
    await ctPage.waitForTimeout(1000);
  });

  test("state-and-history", async ({ ctPage }) => {
    const { layout } = await setup(ctPage);
    const state = (await layout.programStateTabs())[0];
    await state.tabButton().click();
    await expect(state.root.locator(".value-expanded").first()).toBeVisible({ timeout: 10000 });

    await ctPage.mouse.wheel(0, 300);
    await ctPage.waitForTimeout(500);
    await ctPage.mouse.wheel(0, -300);
    await ctPage.waitForTimeout(1000);
  });

  test("eventlog", async ({ ctPage }) => {
    const { layout } = await setup(ctPage);
    const eventLog = (await layout.eventLogTabs())[0];
    await eventLog.tabButton().click();
    await expect(eventLog.root.locator(".eventLog-dense-table tbody tr").first()).toBeVisible({ timeout: 10000 });

    await ctPage.mouse.wheel(0, 300);
    await ctPage.waitForTimeout(500);
    await ctPage.mouse.wheel(0, -300);
    await ctPage.waitForTimeout(1000);
  });

  test("terminal", async ({ ctPage }) => {
    const { layout } = await setup(ctPage);
    const terminal = (await layout.terminalTabs())[0];
    await terminal.tabButton().click();
    await expect(terminal.root.locator(".terminal-line").first()).toBeVisible({ timeout: 10000 });

    await ctPage.mouse.wheel(0, 300);
    await ctPage.waitForTimeout(500);
    await ctPage.mouse.wheel(0, -300);
    await ctPage.waitForTimeout(1000);
  });
});
