import { test, expect } from "../../lib/fixtures";
import type { Locator, Page, TestInfo } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { EditorPane } from "../../page-objects/panes/editor/editor-pane";
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
  MAIN_CALL_SITE,
  MAIN_PATCH_POLL,
  PATCHABLE_FUNCTION,
} from "./hcr-fixture-driver";

const runPaths = createHcrRunPaths();

async function stabilizeLiveLayout(page: Page): Promise<void> {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.evaluate(() => {
    window.dispatchEvent(new Event("resize"));
    const data = (window as any).data; // eslint-disable-line @typescript-eslint/no-explicit-any
    const root = document.getElementById("ROOT") ?? document.body;
    const rect = root.getBoundingClientRect();
    const top = Math.max(0, rect.top || 0);
    const width = Math.max(
      root.clientWidth,
      document.documentElement.clientWidth,
      window.innerWidth,
      1200,
    );
    const height = Math.max(
      root.clientHeight,
      document.documentElement.clientHeight - top - 40,
      window.innerHeight - top - 40,
      600,
    );
    data?.ui?.layout?.updateSize?.(width, height);
    for (const editor of Object.values(data?.ui?.editors ?? {}) as any[]) {
      // eslint-disable-line @typescript-eslint/no-explicit-any
      editor?.monacoEditor?.layout?.();
    }
  });
}

async function expectWelcomeSurfaceHidden(page: Page): Promise<void> {
  const welcomeHost = page.locator("#welcomeScreen");
  await expect(welcomeHost).toHaveCount(1);
  await expect(welcomeHost).toBeHidden();
  await expect(welcomeHost.locator(".welcome-screen")).toHaveCount(0);
}

type CurrentLocation = {
  path: string;
  line: number;
};

function normalizeSourcePath(raw: string): string {
  return raw.startsWith("/private/var/") ? raw.slice("/private".length) : raw;
}

async function currentLocation(layout: LayoutPage): Promise<CurrentLocation> {
  const raw = await layout.page
    .locator("#location-status .location-path")
    .first()
    .textContent();
  const pathAndLine = (raw ?? "").split("#")[0] ?? "";
  const lastColon = pathAndLine.lastIndexOf(":");
  if (lastColon <= 0) {
    throw new Error(
      `could not parse current location from status text '${raw ?? ""}'`,
    );
  }
  const line = Number(pathAndLine.slice(lastColon + 1));
  if (!Number.isInteger(line) || line <= 0) {
    throw new Error(
      `could not parse current line from status text '${raw ?? ""}'`,
    );
  }
  return { path: pathAndLine.slice(0, lastColon), line };
}

async function currentLocationEditor(layout: LayoutPage) {
  await layout.waitForEditorLoaded();
  const currentPath = normalizeSourcePath((await currentLocation(layout)).path);
  const editors = await layout.editorTabs(true);
  if (editors.length === 0) {
    throw new Error("no editor tabs are open");
  }
  const editor = editors.find(
    (candidate) => normalizeSourcePath(candidate.filePath) === currentPath,
  );
  if (editor === undefined) {
    throw new Error(
      `no editor tab is open for current location ${currentPath}; open editors: ` +
        editors.map((candidate) => candidate.filePath).join(", "),
    );
  }
  return editor;
}

async function sourceGenerationDebugState(layout: LayoutPage) {
  const loc = await currentLocation(layout).catch((error) => ({
    path: `<location-error: ${String(error)}>`,
    line: -1,
  }));
  return layout.page.evaluate(
    ({ locPath }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const data = w?.data;
      const normalize = (raw: string): string =>
        raw?.startsWith?.("/private/var/") ? raw.slice("/private".length) : raw;
      const summarizeSource = (source: unknown) => {
        const text = typeof source === "string" ? source : "";
        return {
          length: text.length,
          hasGen0: text.includes("REPROBUILD_HCR_GEN0_BREAKPOINT"),
          hasGen1: text.includes("REPROBUILD_HCR_GEN1_BREAKPOINT"),
          preview: text.slice(0, 240),
        };
      };
      const readTab = (tab: any) => {
        // eslint-disable-line @typescript-eslint/no-explicit-any
        const monacoText =
          tab?.monacoEditor && typeof tab.monacoEditor.getValue === "function"
            ? String(tab.monacoEditor.getValue())
            : "";
        return {
          path: tab?.path ?? "",
          name: tab?.name ?? "",
          location: tab?.location ?? null,
          source: summarizeSource(tab?.source),
          sourceLines: Array.isArray(tab?.sourceLines)
            ? tab.sourceLines.length
            : null,
          monaco: summarizeSource(monacoText),
        };
      };
      const openTabs = data?.services?.editor?.open ?? {};
      const editors = data?.ui?.editors ?? {};
      return {
        location: data?.services?.debugger?.location ?? null,
        statusPath: locPath,
        active: data?.services?.editor?.active ?? "",
        open: Object.fromEntries(
          Object.entries(openTabs).map(([key, tab]) => [key, readTab(tab)]),
        ),
        editors: Object.fromEntries(
          Object.entries(editors).map(([key, editor]: [string, any]) => [
            key,
            {
              path: editor?.path ?? "",
              name: editor?.name ?? "",
              tabInfo: readTab(editor?.tabInfo),
              rootPath: normalize(key),
            },
          ]),
        ),
        sourceRevisionCache: Object.fromEntries(
          Object.entries(data?.services?.editor?.sourceRevisionCache ?? {}).map(
            ([key, source]) => [key, summarizeSource(source)],
          ),
        ),
        pendingDiskSourceByPath: Object.fromEntries(
          Object.entries(data?.services?.editor?.pendingDiskSourceByPath ?? {}).map(
            ([key, source]) => [key, summarizeSource(source)],
          ),
        ),
      };
    },
    { locPath: loc.path },
  );
}

async function openSourceEditor(
  layout: LayoutPage,
  fileName: string,
): Promise<EditorPane> {
  const filesystem = (await layout.filesystemTabs(true))[0];
  await filesystem.clickTab();
  await filesystem.waitForReady();

  const sourceFile = await filesystem.nodeByPath(
    "source folders",
    "fixture",
    "src",
    fileName,
  );
  await sourceFile.leftClick();

  await expect
    .poll(async () =>
      (await layout.editorTabs(true)).some(
        (editor) =>
          editor.fileName === fileName &&
          editor.filePath.endsWith(`/src/${fileName}`),
      ),
    )
    .toBeTruthy();

  const editor = (await layout.editorTabs(true)).find(
    (candidate) =>
      candidate.fileName === fileName &&
      candidate.filePath.endsWith(`/src/${fileName}`),
  );
  if (editor === undefined) {
    throw new Error(`${fileName} editor did not open`);
  }
  await editor.clickTab();
  await editor.revealLine(1);
  return editor;
}

async function openPatchableEditor(layout: LayoutPage): Promise<EditorPane> {
  return openSourceEditor(layout, "patchable.c");
}

async function openMainEditor(layout: LayoutPage): Promise<EditorPane> {
  return openSourceEditor(layout, "main.c");
}

async function enableBreakpoint(
  editor: EditorPane,
  line: number,
): Promise<void> {
  await editor.revealLine(line);
  const editorLine = editor.lineByNumber(line);
  if (!(await editor.hasBreakpointAt(line))) {
    const gutter = editorLine.gutterElement();
    try {
      await gutter.click({ timeout: 5_000 });
    } catch {
      try {
        await gutter.click({ force: true, timeout: 5_000 });
      } catch {
        // Fall through to the DOM click below.
      }
    }
    if (!(await editor.hasBreakpointAt(line))) {
      try {
        await gutter.evaluate((element) =>
          element.dispatchEvent(
            new MouseEvent("click", {
              bubbles: true,
              cancelable: true,
              view: window,
            }),
          ),
        );
      } catch {
        // Monaco virtualizes offscreen rows; fall through to the same
        // debugger service the gutter click calls after reveal fails.
      }
    }
    if (!(await editor.hasBreakpointAt(line))) {
      await editor.page.evaluate(
        ({ path, line }) => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          w?.data?.services?.debugger?.addBreakpoint?.(path, line);
        },
        { path: editor.filePath, line },
      );
    }
  }
  await expect.poll(() => editor.hasBreakpointAt(line)).toBeTruthy();
}

async function disableBreakpoint(
  editor: EditorPane,
  line: number,
): Promise<void> {
  await editor.page.evaluate(
    ({ path, line }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const service = w?.data?.services?.debugger;
      if (!service) return;
      const normalize = (raw: string): string =>
        raw.startsWith("/private/var/") ? raw.slice("/private".length) : raw;
      const aliases = [path];
      if (path.startsWith("/private/var/")) {
        aliases.push(path.slice("/private".length));
      } else if (path.startsWith("/var/")) {
        aliases.push(`/private${path}`);
      }
      for (const alias of [...new Set(aliases)]) {
        service.deleteBreakpoint?.(alias, line);
      }
      const target = normalize(path);
      const table = service.breakpointTable;
      if (table) {
        for (const key of Object.keys(table)) {
          if (normalize(key) === target && table[key]?.[line]) {
            delete table[key][line];
          }
        }
      }
      const pointList = w?.data?.pointList?.breakpoints;
      if (Array.isArray(pointList)) {
        for (let index = pointList.length - 1; index >= 0; index--) {
          const breakpoint = pointList[index];
          if (
            breakpoint &&
            normalize(String(breakpoint.path ?? "")) === target &&
            Number(breakpoint.line) === line
          ) {
            pointList.splice(index, 1);
          }
        }
      }
      service.dapSetBreakpoints?.();
      w?.data?.redraw?.();
    },
    { path: editor.filePath, line },
  );
  await expect.poll(() => editor.hasBreakpointAt(line)).toBeFalsy();
}

function lastInteger(text: string): number {
  const matches = text.match(/-?\d+/g);
  if (matches === null || matches.length === 0) {
    throw new Error(`expected an integer in '${text}'`);
  }
  return Number(matches[matches.length - 1]);
}

function parseRequiredInteger(raw: string | null, label: string): number {
  const value = Number(raw);
  if (!Number.isInteger(value)) {
    throw new Error(`expected integer ${label}, got '${raw ?? "<null>"}'`);
  }
  return value;
}

async function recordingHead(layout: LayoutPage): Promise<number> {
  return parseRequiredInteger(
    await layout.recordingHeadAttr(),
    "recording head",
  );
}

async function waitForRecordingHeadGreaterThan(
  layout: LayoutPage,
  minimum: number,
): Promise<number> {
  let head = 0;
  await retry(
    async () => {
      head = await recordingHead(layout);
      return head > minimum;
    },
    { maxAttempts: 30, delayMs: 500 },
  );
  return head;
}

async function expectRecordingHeadAtLeast(
  layout: LayoutPage,
  minimum: number,
): Promise<void> {
  await retry(
    async () => (await recordingHead(layout)) >= minimum,
    { maxAttempts: 30, delayMs: 500 },
  );
}

async function expectJumpToLiveUnavailable(layout: LayoutPage): Promise<void> {
  const button = layout.jumpToLiveButton();
  await expect
    .poll(async () => {
      if ((await button.count()) === 0) return true;
      if (!(await button.isVisible().catch(() => false))) return true;
      return !(await button.isEnabled().catch(() => false));
    })
    .toBe(true);
}

async function requiredAttr(
  locator: Locator,
  attrName: string,
  label: string,
): Promise<string> {
  const value = await locator.getAttribute(attrName);
  if (value === null || value.length === 0) {
    throw new Error(`${label} missing ${attrName}`);
  }
  return value;
}

async function rrTicksAttr(
  locator: Locator,
  label: string,
): Promise<number> {
  return parseRequiredInteger(
    await requiredAttr(locator, "data-rr-ticks", label),
    label,
  );
}

async function clickEventLogRow(row: Locator): Promise<void> {
  const firstCell = row.locator("td").first();
  await expect(firstCell).toBeVisible();
  try {
    await firstCell.click({
      noWaitAfter: true,
      timeout: 5_000,
      position: { x: 8, y: 8 },
    });
  } catch {
    await firstCell.evaluate((cell) => {
      cell.dispatchEvent(
        new MouseEvent("click", {
          bubbles: true,
          cancelable: true,
          view: window,
        }),
      );
    });
  }
}

async function attachScreenshot(
  page: Page,
  testInfo: TestInfo,
  name: string,
): Promise<void> {
  await testInfo.attach(name, {
    body: await page.screenshot({ fullPage: true }),
    contentType: "image/png",
  });
}

async function expectCurrentSourceStop(
  layout: LayoutPage,
  marker: string,
  cursorKind: "live-mcr" | "historical",
  expectedLine?: number,
): Promise<void> {
  await expect
    .poll(async () =>
      (await currentLocationEditor(layout)).executionCursorKindAttr(),
    )
    .toBe(cursorKind);
  if (expectedLine !== undefined) {
    await expect
      .poll(async () => (await currentLocation(layout)).line)
      .toBe(expectedLine);
  }
  await expect
    .poll(async () =>
      (await currentLocationEditor(layout)).containsMarker(marker),
    )
    .toBe(true);
}

async function expectGenerationStop(
  layout: LayoutPage,
  generation: number,
  marker: string,
  cursorKind: "live-mcr" | "historical",
  expectedLocals: Record<string, string> = {},
  expectedStepStateBias?: number,
): Promise<void> {
  await expect
    .poll(async () =>
      (await currentLocationEditor(layout)).sourceGenerationAttr(),
    )
    .toBe(String(generation));
  await expect
    .poll(async () =>
      (await currentLocationEditor(layout)).executionCursorKindAttr(),
    )
    .toBe(cursorKind);
  await expect
    .poll(async () =>
      (await currentLocationEditor(layout)).containsMarker(marker),
    )
    .toBe(true)
    .catch(async (error) => {
      throw new Error(
        `current editor did not contain marker ${marker}; source generation state: ` +
          JSON.stringify(await sourceGenerationDebugState(layout), null, 2),
        { cause: error },
      );
    });

  const state = (await layout.programStateTabs(true))[0];
  await state.clickTab();
  await expect(state.variableRow("iteration")).toBeVisible();
  const iteration = lastInteger(await state.variableValueText("iteration"));
  for (const [name, value] of Object.entries(expectedLocals)) {
    await expect(state.variableRow(name)).toBeVisible();
    await expect.poll(() => state.variableValueText(name)).toContain(value);
  }
  if (expectedStepStateBias !== undefined) {
    await expect(state.variableRow("step_state")).toBeVisible();
    await expect
      .poll(() => state.variableValueText("step_state"))
      .toContain(String(iteration + expectedStepStateBias));
  }

  const callTrace = (await layout.callTraceTabs(true))[0];
  await callTrace.clickTab();
  await callTrace.waitForReady();
  const callTraceRow = callTrace.rowByFunctionAndGeneration(
    PATCHABLE_FUNCTION,
    generation,
  );
  await expect(callTraceRow).toBeVisible();
  await expect(callTraceRow).toHaveAttribute(
    "data-code-generation",
    String(generation),
  );
  await expect(callTraceRow).not.toHaveAttribute("data-source-digest", "");
  await expect(callTraceRow).not.toHaveAttribute("data-rr-ticks", "");
}

async function expectPanelMode(
  layout: LayoutPage,
  mode: string,
): Promise<void> {
  await expect.poll(() => layout.sessionModeAttr()).toBe(mode);
  await expect(layout.toolbarModeText()).toBeVisible();
}

async function openTimelinePane(layout: LayoutPage) {
  await layout.waitForTimelineLoaded();
  const timeline = (await layout.timelineTabs(true))[0];
  if (timeline === undefined) {
    throw new Error("Timeline pane did not open");
  }
  return timeline;
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
        await expect(
          backendSelector.locator("option[value='mcr']"),
        ).toHaveCount(1);
        await backendSelector.selectOption("mcr");
        await expect(backendSelector).toHaveValue("mcr");
      }

      await ctPage.locator("#new-record-submit").click();

      const layout = new LayoutPage(ctPage);
      await layout.waitForBaseComponentsLoaded();
      await stabilizeLiveLayout(ctPage);
      await expectWelcomeSurfaceHidden(ctPage);
      await expectPanelMode(layout, "liveMcr");
      await expect(layout.recordingHeadIndicator()).toBeVisible();
      await expectJumpToLiveUnavailable(layout);

      const gen0BreakpointLine = driver.lineForMarker(
        driver.generationZeroSnapshotPath,
        GEN0_BREAKPOINT,
      );
      const mainPollLine = driver.lineForMarker(
        driver.mainSourcePath,
        MAIN_PATCH_POLL,
      );
      const mainCallSiteLine = driver.lineForMarker(
        driver.mainSourcePath,
        MAIN_CALL_SITE,
      );

      const gen0Editor = await openPatchableEditor(layout);
      await expect
        .poll(() => gen0Editor.containsMarker(GEN0_BREAKPOINT))
        .toBe(true);
      await enableBreakpoint(gen0Editor, gen0BreakpointLine);
      await layout.clickContinueButton();
      await expectGenerationStop(layout, 0, GEN0_BREAKPOINT, "live-mcr");
      await layout.clickNextButton();
      await expectGenerationStop(layout, 0, GEN0_STEP_START, "live-mcr", {
        generation_zero_bias: "11",
      });
      await layout.clickNextButton();
      await expectGenerationStop(
        layout,
        0,
        GEN0_STEP_NEXT,
        "live-mcr",
        {
          generation_zero_bias: "11",
        },
        11,
      );
      const headAfterGen0 = await waitForRecordingHeadGreaterThan(layout, 0);
      await attachScreenshot(ctPage, testInfo, "hcr-gui-generation0-live.png");

      const mainEditor = await openMainEditor(layout);
      await enableBreakpoint(mainEditor, mainCallSiteLine);
      await enableBreakpoint(mainEditor, mainPollLine);
      await layout.clickContinueButton();
      await expectCurrentSourceStop(
        layout,
        MAIN_PATCH_POLL,
        "live-mcr",
        mainPollLine,
      );
      await retry(
        async () => driver.readyFileExists() && driver.isReproWatchRunning(),
        { maxAttempts: 30, delayMs: 500 },
      );

      const watchReady = driver.waitForWatchReady();
      await layout.clickContinueButton();
      await watchReady;
      driver.applyGenerationOneEdit();
      expect(driver.patchableSourceText()).toContain(GEN1_BREAKPOINT);
      expect(driver.patchableSourceText()).not.toContain(GEN0_BREAKPOINT);
      const gen1BreakpointLine = driver.lineForMarker(
        driver.generationOneSnapshotPath,
        GEN1_BREAKPOINT,
      );
      await Promise.all([
        driver.waitForPatchApplied(),
        expectCurrentSourceStop(
          layout,
          MAIN_CALL_SITE,
          "live-mcr",
          mainCallSiteLine,
        ),
      ]);

      const patchedEditor = await openPatchableEditor(layout);
      await disableBreakpoint(patchedEditor, gen0BreakpointLine);
      await enableBreakpoint(patchedEditor, gen1BreakpointLine);
      await layout.clickContinueButton();
      await expectGenerationStop(layout, 1, GEN1_BREAKPOINT, "live-mcr");
      await layout.clickNextButton();
      await expectGenerationStop(layout, 1, GEN1_STEP_START, "live-mcr", {
        generation_one_bias: "77",
      });
      await layout.clickNextButton();
      await expectGenerationStop(
        layout,
        1,
        GEN1_STEP_NEXT,
        "live-mcr",
        {
          generation_one_bias: "77",
        },
        77,
      );
      const headAfterGen1 = await waitForRecordingHeadGreaterThan(
        layout,
        headAfterGen0,
      );
      await attachScreenshot(ctPage, testInfo, "hcr-gui-generation1-live.png");

      const eventLog = (await layout.eventLogTabs(true))[0];
      await eventLog.clickTab();
      const gen1StopEvent = eventLog.rowByKindGenerationAndText(
        "debugger-stop",
        1,
        `:${gen1BreakpointLine}`,
      );
      await expect(gen1StopEvent).toBeVisible();
      await expect(gen1StopEvent).not.toHaveAttribute("data-source-digest", "");
      const gen1Digest = await requiredAttr(
        gen1StopEvent,
        "data-source-digest",
        "generation 1 debugger-stop event",
      );
      const gen1Ticks = await rrTicksAttr(
        gen1StopEvent,
        "generation 1 debugger-stop event",
      );

      const gen0Event = eventLog.rowByKindGenerationAndText(
        "debugger-stop",
        0,
        `:${gen0BreakpointLine}`,
      );
      await expect(gen0Event).toBeVisible();
      await expect(gen0Event).not.toHaveAttribute("data-source-digest", "");
      const gen0Digest = await requiredAttr(
        gen0Event,
        "data-source-digest",
        "generation 0 debugger-stop event",
      );
      const gen0Ticks = await rrTicksAttr(
        gen0Event,
        "generation 0 debugger-stop event",
      );
      expect(gen1Ticks).toBeGreaterThan(gen0Ticks);
      await clickEventLogRow(gen0Event);
      await expectPanelMode(layout, "historicalFromLive");
      await expectRecordingHeadAtLeast(layout, headAfterGen1);
      await expectGenerationStop(layout, 0, GEN0_BREAKPOINT, "historical");
      await expect
        .poll(async () =>
          (await currentLocationEditor(layout)).sourceDigestAttr(),
        )
        .toBe(gen0Digest);
      expect(await recordingHead(layout)).toBeGreaterThan(gen0Ticks);
      await attachScreenshot(
        ctPage,
        testInfo,
        "hcr-gui-generation0-historical.png",
      );

      const historicalCallTrace = (await layout.callTraceTabs(true))[0];
      await historicalCallTrace.clickTab();
      const historicalGen0Call = historicalCallTrace.rowByFunctionAndGeneration(
        PATCHABLE_FUNCTION,
        0,
      );
      await expect(historicalGen0Call).toBeVisible();
      expect(
        await rrTicksAttr(
          historicalGen0Call,
          "generation 0 historical call trace row",
        ),
      ).toBe(gen0Ticks);
      await historicalGen0Call.dispatchEvent("click");
      await expectPanelMode(layout, "historicalFromLive");
      await expectGenerationStop(layout, 0, GEN0_BREAKPOINT, "historical");

      await layout.clickNextButton();
      await expectGenerationStop(layout, 0, GEN0_STEP_START, "historical", {
        generation_zero_bias: "11",
      });

      await expect(layout.jumpToLiveButton()).toBeVisible();
      await expect(layout.jumpToLiveButton()).toBeEnabled();
      await layout.jumpToLiveButton().click();
      await expectPanelMode(layout, "liveMcr");
      await expectJumpToLiveUnavailable(layout);
      await expectGenerationStop(
        layout,
        1,
        GEN1_STEP_NEXT,
        "live-mcr",
        {
          generation_one_bias: "77",
        },
        77,
      );
      await expect
        .poll(async () =>
          (await currentLocationEditor(layout)).sourceDigestAttr(),
        )
        .toBe(gen1Digest);
      await attachScreenshot(
        ctPage,
        testInfo,
        "hcr-gui-generation1-live-after-jump.png",
      );

      const timeline = await openTimelinePane(layout);
      await timeline.clickTab();
      await stabilizeLiveLayout(ctPage);
      await expect(timeline.track()).toBeVisible();
      await expect
        .poll(() => timeline.maxTicks())
        .toBeGreaterThanOrEqual(gen1Ticks);
      await timeline.clickTick(gen0Ticks);
      await expectPanelMode(layout, "historicalFromLive");
      await expectGenerationStop(layout, 0, GEN0_BREAKPOINT, "historical");
      await expect
        .poll(async () =>
          (await currentLocationEditor(layout)).sourceDigestAttr(),
        )
        .toBe(gen0Digest);

      await layout.jumpToLiveButton().click();
      await expectPanelMode(layout, "liveMcr");
      await expectGenerationStop(
        layout,
        1,
        GEN1_STEP_NEXT,
        "live-mcr",
        {
          generation_one_bias: "77",
        },
        77,
      );

      await expectRecordingHeadAtLeast(layout, headAfterGen1);
    } finally {
      await driver.attachArtifacts(testInfo);
      await driver.stop();
    }
  });
});
