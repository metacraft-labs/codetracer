import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import {
  clearHcrTargetEnv,
  createHcrRunPaths,
  exportHcrTargetEnv,
  GEN0_BREAKPOINT,
  GEN0_STEP_NEXT,
  GEN0_STEP_START,
  GEN1_BREAKPOINT,
  GEN1_STEP_NEXT,
  GEN1_STEP_START,
  HcrFixtureDriver,
  PATCHABLE_FUNCTION,
} from "./hcr-fixture-driver";

const runPaths = createHcrRunPaths();

async function activeEditor(layout: LayoutPage) {
  await layout.waitForEditorLoaded();
  const editors = await layout.editorTabs(true);
  if (editors.length === 0) {
    throw new Error("no editor tabs are open");
  }
  return editors[0];
}

async function expectGenerationStop(
  layout: LayoutPage,
  generation: number,
  marker: string,
  cursorKind: "live-mcr" | "historical",
): Promise<void> {
  const editor = await activeEditor(layout);
  await expect.poll(() => editor.sourceGenerationAttr()).toBe(String(generation));
  await expect.poll(() => editor.executionCursorKindAttr()).toBe(cursorKind);
  await expect.poll(() => editor.containsMarker(marker)).toBe(true);

  const state = (await layout.programStateTabs(true))[0];
  await state.clickTab();
  await expect(state.variableRow("generation")).toBeVisible();
  await expect.poll(() => state.variableValueText("generation")).toContain(
    String(generation),
  );
  await expect(state.variableRow("iteration")).toBeVisible();

  const callTrace = (await layout.callTraceTabs(true))[0];
  await callTrace.clickTab();
  await expect(
    callTrace.rowByFunctionAndGeneration(PATCHABLE_FUNCTION, generation),
  ).toBeVisible();
}

async function expectPanelMode(layout: LayoutPage, mode: string): Promise<void> {
  await expect.poll(() => layout.sessionModeAttr()).toBe(mode);
  await expect(layout.toolbarModeText()).toBeVisible();
}

test.describe("Reprobuild HCR live GUI E2E", () => {
  test.skip(
    process.env.CODETRACER_ENABLE_MCR_HCR_GUI_E2E !== "1",
    "set CODETRACER_ENABLE_MCR_HCR_GUI_E2E=1 to run the gated live HCR GUI test",
  );
  test.skip(
    process.platform !== "darwin" || process.arch !== "arm64",
    "initial live HCR GUI profile is macOS arm64",
  );

  test.setTimeout(240_000);
  test.use({ launchMode: "welcome" });

  test.beforeAll(() => {
    exportHcrTargetEnv(runPaths);
  });

  test.afterAll(() => {
    clearHcrTargetEnv();
  });

  test("starts from Welcome, reloads code, and navigates old/new generations", async ({
    ctPage,
  }, testInfo) => {
    const missing = HcrFixtureDriver.checkPrerequisites();
    testInfo.skip(missing.length > 0, missing.join("; "));

    const driver = new HcrFixtureDriver(runPaths);
    try {
      driver.prepareProject();
      driver.startReproWatch();
      await driver.waitForInitialBuild();

      await ctPage.waitForSelector(".welcome-screen", { timeout: 15_000 });
      await ctPage.locator(".start-option.record-new-trace").click();
      await expect(ctPage.locator("#new-record-executable")).toBeVisible();

      await ctPage.locator("#new-record-executable").fill(driver.binaryPath);
      await ctPage.locator("#new-record-workdir").fill(driver.paths.projectDir);

      const backendSelector = ctPage.locator("#new-record-backend");
      if (await backendSelector.isVisible()) {
        await expect(backendSelector.locator("option[value='mcr']")).toHaveCount(1);
        await backendSelector.selectOption("mcr");
        await expect(backendSelector).toHaveValue("mcr");
      }

      await Promise.all([
        driver.waitForAgentConnected(),
        ctPage.locator("#new-record-submit").click(),
      ]);

      const layout = new LayoutPage(ctPage);
      await layout.waitForBaseComponentsLoaded();
      await expectPanelMode(layout, "liveMcr");
      await expect(layout.recordingHeadIndicator()).toBeVisible();

      await expectGenerationStop(layout, 0, GEN0_BREAKPOINT, "live-mcr");
      await layout.clickNextButton();
      await expectGenerationStop(layout, 0, GEN0_STEP_START, "live-mcr");
      await layout.clickNextButton();
      await expectGenerationStop(layout, 0, GEN0_STEP_NEXT, "live-mcr");

      driver.applyGenerationOneEdit();
      await driver.waitForPatchApplied();

      await layout.clickContinueButton();
      await expectGenerationStop(layout, 1, GEN1_BREAKPOINT, "live-mcr");
      await layout.clickNextButton();
      await expectGenerationStop(layout, 1, GEN1_STEP_START, "live-mcr");
      await layout.clickNextButton();
      await expectGenerationStop(layout, 1, GEN1_STEP_NEXT, "live-mcr");

      const eventLog = (await layout.eventLogTabs(true))[0];
      await eventLog.clickTab();
      await expect(
        eventLog.root
          .locator(
            '[data-event-kind*="hcr" i], [data-event-kind*="hot-code" i], [data-source-generation="1"]',
          )
          .first(),
      ).toBeVisible();

      const gen0Event = eventLog.rowByGeneration(0);
      await expect(gen0Event).toBeVisible();
      await gen0Event.click();
      await expectPanelMode(layout, "historicalFromLive");
      await expectGenerationStop(layout, 0, GEN0_BREAKPOINT, "historical");

      await layout.clickNextButton();
      await expectGenerationStop(layout, 0, GEN0_STEP_START, "historical");

      await expect(layout.jumpToLiveButton()).toBeVisible();
      await expect(layout.jumpToLiveButton()).toBeEnabled();
      await layout.jumpToLiveButton().click();
      await expectPanelMode(layout, "liveMcr");
      await expectGenerationStop(layout, 1, GEN1_STEP_NEXT, "live-mcr");

      await retry(
        async () => {
          const head = Number(await layout.recordingHeadAttr());
          return Number.isFinite(head) && head > 0;
        },
        { maxAttempts: 30, delayMs: 500 },
      );
    } finally {
      await driver.attachArtifacts(testInfo);
      await driver.stop();
    }
  });
});
