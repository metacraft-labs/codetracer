import { test, expect } from "../../lib/fixtures";
import { retry, retryAction } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import type { Page, TestInfo } from "@playwright/test";
import * as fs from "node:fs";

const ReferenceDumpRoot =
  "/home/zahary/metacraft/codetracer-main/ui-tests/reference-dumps";
const ReferenceMenuDump =
  `${ReferenceDumpRoot}/isonim-karax-reference-20260504T220906Z/20260504T220925Z_noir-menu-view-open.html`;
const ReferenceCommandPaletteDump =
  `${ReferenceDumpRoot}/isonim-karax-reference-20260504T222307Z/20260504T222339Z_noir-command-palette-karax-open.html`;
const ReferenceWelcomeStyles =
  `${ReferenceDumpRoot}/isonim-karax-reference-20260504T220906Z/20260504T221201Z_welcome-screen.computed-styles.json`;
const ReferenceCommandPlaceholder = "Navigate to file or run a :command";

async function getSessionCount(page: Page): Promise<number> {
  return page.evaluate(() => {
    const data = (window as any).data;
    return data?.sessions?.length ?? 0;
  });
}

async function getActiveSessionIndex(page: Page): Promise<number> {
  return page.evaluate(() => {
    const data = (window as any).data;
    return data?.activeSessionIndex ?? -1;
  });
}

function readReferenceFacts() {
  const facts: Record<string, unknown> = {};

  if (fs.existsSync(ReferenceCommandPaletteDump)) {
    const commandHtml = fs.readFileSync(ReferenceCommandPaletteDump, "utf8");
    facts.commandPalette = {
      path: ReferenceCommandPaletteDump,
      hasLegacyCommandView: commandHtml.includes('id="command-view"'),
      hasLegacyInput: commandHtml.includes('id="command-query-text"'),
      placeholder: commandHtml.includes(`placeholder="${ReferenceCommandPlaceholder}"`)
        ? ReferenceCommandPlaceholder
        : null,
    };
  }

  if (fs.existsSync(ReferenceMenuDump)) {
    const menuHtml = fs.readFileSync(ReferenceMenuDump, "utf8");
    facts.menu = {
      path: ReferenceMenuDump,
      hasDropdown: menuHtml.includes('id="menu-main"'),
      activeNodeSnippet:
        menuHtml.match(/<div class="menu-node-container menu-active-node">[\s\S]{0,300}/)
          ?.[0] ?? null,
    };
  }

  if (fs.existsSync(ReferenceWelcomeStyles)) {
    const styles = JSON.parse(fs.readFileSync(ReferenceWelcomeStyles, "utf8"));
    facts.welcome = {
      path: ReferenceWelcomeStyles,
      viewport: styles.viewport,
      welcomeHost: styles.elements?.find((entry: any) => entry.selector === "#welcomeScreen")
        ?.rect,
      rootContainer: styles.elements?.find((entry: any) => entry.selector === "#root-container")
        ?.rect,
      status: styles.elements?.find((entry: any) => entry.selector === "#status")
        ?.rect,
    };
  }

  return facts;
}

async function attachCaptionDump(page: Page, testInfo: TestInfo): Promise<void> {
  const dump = await page.evaluate(() => {
    function inspect(selector: string) {
      const element = document.querySelector(selector) as HTMLElement | null;
      if (!element) {
        return { selector, exists: false };
      }

      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return {
        selector,
        exists: true,
        tagName: element.tagName,
        id: element.id,
        className: element.className,
        text: element.textContent?.trim().slice(0, 200) ?? "",
        value:
          element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
            ? element.value
            : undefined,
        placeholder:
          element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
            ? element.placeholder
            : undefined,
        rect: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        },
        style: {
          display: style.display,
          visibility: style.visibility,
          position: style.position,
          backgroundColor: style.backgroundColor,
          backgroundImage: style.backgroundImage,
          pointerEvents: style.pointerEvents,
          opacity: style.opacity,
          overflow: style.overflow,
          flex: style.flex,
          order: style.order,
          height: style.height,
          width: style.width,
          maxWidth: style.maxWidth,
          zIndex: style.zIndex,
        },
      };
    }

    return {
      bodyClass: document.body.className,
      menuHtml: document.querySelector("#menu")?.outerHTML.slice(0, 4_000) ?? "",
      welcomeHtml:
        document.querySelector("#welcomeScreen")?.outerHTML.slice(0, 4_000) ?? "",
      activeElement: {
        tagName: document.activeElement?.tagName,
        id: (document.activeElement as HTMLElement | null)?.id,
        className: (document.activeElement as HTMLElement | null)?.className,
      },
      elements: [
        inspect("#menu"),
        inspect("#navigation-menu"),
        inspect("#menu-logo-img"),
        inspect("#menu-main"),
        inspect("#menu-elements"),
        inspect(".menu-node-container"),
        inspect(".menu-node-container.menu-active-node"),
        inspect("#debug"),
        inspect("#debug [id^='commandPaletteComponent-']"),
        inspect("#debug .command-container"),
        inspect("#debug .command-input-row"),
        inspect("#debug .command-input-field"),
        inspect("#debug .command-results"),
        inspect("#debug .command-result"),
        inspect("#isonim-debug-controls"),
        inspect("#isonim-debug-controls .isonim-debug-controls"),
        inspect("#session-tab-bar"),
        inspect(".session-tab"),
        inspect(".session-tab-overflow"),
        inspect(".session-tab-add"),
        inspect("#welcomeScreen"),
        inspect(".welcome-screen-wrapper"),
        inspect(".welcome-screen"),
        inspect("#root-container"),
        inspect("#status"),
      ],
    };
  });

  await testInfo.attach("caption-new-trace-dom-styles.json", {
    body: JSON.stringify(dump, null, 2),
    contentType: "application/json",
  });
}

async function attachCaptionArtifacts(page: Page, testInfo: TestInfo): Promise<void> {
  try {
    await attachCaptionDump(page, testInfo);
  } catch (error) {
    console.warn(`failed to attach caption DOM/style dump: ${String(error)}`);
  }

  try {
    await testInfo.attach("caption-reference-baseline.json", {
      body: JSON.stringify(readReferenceFacts(), null, 2),
      contentType: "application/json",
    });
  } catch (error) {
    console.warn(`failed to attach caption reference baseline: ${String(error)}`);
  }

  try {
    await testInfo.attach("caption-new-trace-screenshot.png", {
      body: await page.screenshot({ fullPage: true }),
      contentType: "image/png",
    });
  } catch (error) {
    console.warn(`failed to attach caption screenshot: ${String(error)}`);
  }
}

async function expectCaptionChrome(page: Page): Promise<void> {
  const menu = page.locator("#menu");
  await expect(menu).toBeVisible({ timeout: 10_000 });

  const navigation = page.locator("#navigation-menu");
  await expect(navigation).toBeVisible({ timeout: 10_000 });

  const logo = page.locator("#menu-logo-img");
  await expect(logo).toBeVisible({ timeout: 10_000 });
  await expect(logo).toHaveCSS("background-image", /Icon|logo|svg|png|url/i);

  const debugHost = page.locator("#debug");
  await expect(debugHost).toBeVisible({ timeout: 10_000 });
  await expect(debugHost.locator("[id^='commandPaletteComponent-']")).toHaveCount(1, {
    timeout: 10_000,
  });
  const omnibox = debugHost.locator(".command-input-field");
  await expect(omnibox).toBeVisible({ timeout: 10_000 });
  await expect(omnibox).toBeEnabled({ timeout: 10_000 });
  await expect.soft(omnibox).toHaveAttribute("placeholder", ReferenceCommandPlaceholder);

  const toolbarHost = page.locator("#isonim-debug-controls");
  await expect(toolbarHost).toBeVisible({ timeout: 10_000 });
  const toolbar = toolbarHost.locator(".isonim-debug-controls");
  await expect(toolbar).toBeVisible({ timeout: 10_000 });
  await expect(toolbar.locator("button")).toHaveCount(13, { timeout: 10_000 });

  await retryAction(async () => {
    const menuBox = await menu.boundingBox();
    const logoBox = await logo.boundingBox();
    const toolbarBox = await toolbar.boundingBox();
    const debugBox = await debugHost.boundingBox();
    const omniboxBox = await omnibox.boundingBox();
    expect(menuBox, "caption bar should have layout").not.toBeNull();
    expect(logoBox, "menu logo should have layout").not.toBeNull();
    expect(toolbarBox, "debugger toolbar should have layout").not.toBeNull();
    expect(debugBox, "omnibox host should have layout").not.toBeNull();
    expect(omniboxBox, "omnibox input should have layout").not.toBeNull();
    expect(toolbarBox!.height).toBeGreaterThan(20);
    expect(debugBox!.height).toBeGreaterThan(20);
    expect(omniboxBox!.height).toBeGreaterThan(16);
    expect(toolbarBox!.x).toBeGreaterThanOrEqual(logoBox!.x + logoBox!.width - 2);
    expect(toolbarBox!.x).toBeLessThan(logoBox!.x + logoBox!.width + 260);
    expect(omniboxBox!.x).toBeGreaterThanOrEqual(toolbarBox!.x + toolbarBox!.width + 6);
    const horizontalOverlap = Math.max(
      0,
      Math.min(omniboxBox!.x + omniboxBox!.width, toolbarBox!.x + toolbarBox!.width) -
        Math.max(omniboxBox!.x, toolbarBox!.x),
    );
    const verticalOverlap = Math.max(
      0,
      Math.min(omniboxBox!.y + omniboxBox!.height, toolbarBox!.y + toolbarBox!.height) -
        Math.max(omniboxBox!.y, toolbarBox!.y),
    );
    expect(horizontalOverlap * verticalOverlap).toBe(0);
    expect(Math.abs(
      (omniboxBox!.x + omniboxBox!.width / 2) - (menuBox!.x + menuBox!.width / 2),
    )).toBeLessThan(menuBox!.width * 0.18);
    const viewportWidth = page.viewportSize()?.width ?? menuBox!.width;
    expect.soft(omniboxBox!.x + omniboxBox!.width).toBeLessThanOrEqual(
      Math.min(menuBox!.x + menuBox!.width - 120, viewportWidth - 120),
    );
    expect(toolbarBox!.y).toBeGreaterThanOrEqual(menuBox!.y - 1);
    expect(toolbarBox!.y + toolbarBox!.height).toBeLessThanOrEqual(
      menuBox!.y + menuBox!.height + 8,
    );
  }, { maxAttempts: 50, delayMs: 100 });

  const menuStyles = await menu.evaluate((element) => {
    const style = window.getComputedStyle(element);
    return {
      position: style.position,
      backgroundColor: style.backgroundColor,
      height: parseFloat(style.height),
    };
  });
  expect(menuStyles.position).toBe("fixed");
  expect(menuStyles.height).toBeGreaterThan(20);
  expect(menuStyles.backgroundColor).not.toBe("rgba(0, 0, 0, 0)");
}

async function expectMenuMouseInteraction(page: Page): Promise<void> {
  await page.locator("#menu-logo-img").click();
  const menuMain = page.locator("#menu-main");
  await expect(menuMain).toBeVisible({ timeout: 5_000 });

  const box = await menuMain.boundingBox();
  expect(box, "menu dropdown should have layout").not.toBeNull();
  await page.mouse.move(box!.x + box!.width - 4, box!.y + box!.height - 4);
  await expect(menuMain).toBeVisible({ timeout: 1_000 });

  const menuNodes = page.locator("#menu-main .menu-node-container");
  expect(await menuNodes.count(), "menu dropdown should expose top-level nodes").toBeGreaterThan(3);
  const targetNode = menuNodes.nth(1);
  const targetText = (await targetNode.textContent())?.trim() ?? "";
  const targetBox = await targetNode.boundingBox();
  expect(targetBox, "menu node should have layout").not.toBeNull();
  await page.mouse.move(targetBox!.x + targetBox!.width / 2, targetBox!.y + targetBox!.height / 2);
  await expect(targetNode, `hovered menu row '${targetText}' should become active`)
    .toHaveClass(/menu-active-node/, { timeout: 1_000 });

  const hitTest = await targetNode.evaluate((node) => {
    const rect = node.getBoundingClientRect();
    const hit = document.elementFromPoint(
      rect.left + rect.width / 2,
      rect.top + rect.height / 2,
    );
    return {
      matches: hit === node || node.contains(hit),
      nodeText: node.textContent?.trim() ?? "",
      nodeRect: {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
      },
      hitTag: hit?.tagName ?? null,
      hitId: (hit as HTMLElement | null)?.id ?? null,
      hitClass: (hit as HTMLElement | null)?.className?.toString() ?? null,
      hitText: hit?.textContent?.trim().slice(0, 120) ?? null,
    };
  });
  expect(
    hitTest.matches,
    `hit testing should target the hovered menu row: ${JSON.stringify(hitTest)}`,
  ).toBe(true);

  await page.mouse.click(box!.x + box!.width + 420, box!.y + box!.height + 420);
  await expect(menuMain).toBeHidden({ timeout: 5_000 });
}

async function expectOmniboxSearchIsInteractive(page: Page): Promise<void> {
  const omnibox = page.locator("#debug .command-input-field");
  try {
    await omnibox.click({ timeout: 5_000 });
  } catch (error) {
    expect.soft(
      false,
      `omnibox should accept a stable click/focus action: ${String(error)}`,
    ).toBe(true);
    return;
  }
  await expect(omnibox).toBeFocused({ timeout: 2_000 });

  await omnibox.pressSequentially(":new trace");
  await expect.soft(omnibox).toHaveValue(":new trace", { timeout: 2_000 });

  const results = page.locator("#debug .command-results");
  await expect.soft(results).toBeVisible({ timeout: 5_000 });
  await expect.soft(page.locator("#debug .command-result").first()).toBeVisible({
    timeout: 5_000,
  });
  await expect.soft(results).toContainText(/New Trace|Record New Trace|Trace/i, {
    timeout: 5_000,
  });

  await page.keyboard.press("Escape");
}

async function createTabs(page: Page, count: number): Promise<void> {
  for (let i = await getSessionCount(page); i < count; i += 1) {
    await page.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(page)) === i + 1,
      { maxAttempts: 30, delayMs: 500 },
    );
  }
}

async function expectOmniboxDoesNotOverlapTabs(page: Page): Promise<void> {
  await createTabs(page, 12);
  const omnibox = page.locator("#debug .command-input-field");
  const toolbar = page.locator("#isonim-debug-controls .isonim-debug-controls");
  const tabBar = page.locator("#session-tab-bar");
  const firstTab = page.locator(".session-tab").first();
  const overflow = page.locator(".session-tab-overflow");
  const addTab = page.locator(".session-tab-add");

  await expect(tabBar).toBeVisible({ timeout: 10_000 });
  await expect(firstTab).toBeVisible({ timeout: 10_000 });
  await expect(
    overflow,
    "overflowing session tabs should expose a chevron/list affordance",
  ).toBeVisible({ timeout: 10_000 });
  await expect(addTab).toBeVisible({ timeout: 10_000 });

  await retryAction(async () => {
    const omniboxBox = await omnibox.boundingBox();
    const toolbarBox = await toolbar.boundingBox();
    const tabBox = await firstTab.boundingBox();
    const overflowBox = await overflow.boundingBox();
    const addBox = await addTab.boundingBox();
    expect(omniboxBox, "omnibox should have layout").not.toBeNull();
    expect(toolbarBox, "debug toolbar should have layout").not.toBeNull();
    expect(tabBox, "session tab should have layout").not.toBeNull();
    expect(overflowBox, "session overflow affordance should have layout").not.toBeNull();
    expect(addBox, "new-tab button should have layout").not.toBeNull();

    expect(toolbarBox!.x + toolbarBox!.width).toBeLessThanOrEqual(omniboxBox!.x - 6);
    expect(omniboxBox!.x + omniboxBox!.width).toBeLessThanOrEqual(tabBox!.x - 4);
    expect(
      tabBox!.x - (omniboxBox!.x + omniboxBox!.width),
      "tab bar should start directly after the omnibox without wasting caption space",
    ).toBeLessThanOrEqual(48);
    expect(omniboxBox!.x + omniboxBox!.width).toBeLessThanOrEqual(overflowBox!.x - 4);
    expect(overflowBox!.x + overflowBox!.width).toBeLessThanOrEqual(addBox!.x - 2);
  }, { maxAttempts: 30, delayMs: 100 });

  const overflowMetrics = await page.evaluate(() => {
    const bar = document.querySelector("#session-tab-bar") as HTMLElement | null;
    const tabs = Array.from(document.querySelectorAll(".session-tab")) as HTMLElement[];
    const overflow = document.querySelector(".session-tab-overflow") as HTMLElement | null;
    const add = document.querySelector(".session-tab-add") as HTMLElement | null;
    const firstTab = tabs[0];
    const tabStyle = firstTab ? window.getComputedStyle(firstTab) : null;
    const barStyle = bar ? window.getComputedStyle(bar) : null;
    const minWidth = tabStyle ? parseFloat(tabStyle.minWidth) : 0;
    const padding =
      barStyle ? parseFloat(barStyle.paddingLeft) + parseFloat(barStyle.paddingRight) : 0;
    const controlsWidth = (overflow?.offsetWidth ?? 0) + (add?.offsetWidth ?? 0) + padding;
    const barWidth = bar?.clientWidth ?? 0;
    return {
      sessionCount: (window as any).data?.sessions?.length ?? 0,
      visibleTabCount: tabs.length,
      barWidth,
      minWidth,
      controlsWidth,
      tabWidths: tabs.map((tab) => tab.getBoundingClientRect().width),
    };
  });
  expect(overflowMetrics.sessionCount).toBe(12);
  expect(overflowMetrics.visibleTabCount).toBeLessThan(overflowMetrics.sessionCount);
  expect(overflowMetrics.minWidth).toBeGreaterThanOrEqual(90);
  expect(
    overflowMetrics.visibleTabCount * overflowMetrics.minWidth +
      overflowMetrics.controlsWidth,
    "visible tabs and tab controls must fit within the caption tab slot at min width",
  ).toBeLessThanOrEqual(overflowMetrics.barWidth + 2);
  expect(
    (overflowMetrics.visibleTabCount + 1) * overflowMetrics.minWidth +
      overflowMetrics.controlsWidth,
    "one more visible tab would fall below the required min-width budget",
  ).toBeGreaterThan(overflowMetrics.barWidth - 2);
  for (const width of overflowMetrics.tabWidths) {
    expect(width).toBeGreaterThanOrEqual(overflowMetrics.minWidth - 1);
  }

  await overflow.click();
  const overflowMenu = page.locator(".session-tab-overflow-menu");
  await expect(overflowMenu).toBeVisible({ timeout: 5_000 });
  await expect(overflowMenu.locator(".session-tab-overflow-item")).toHaveCount(12, {
    timeout: 5_000,
  });

  await overflowMenu.locator(".session-tab-overflow-item").first().click();
  await retry(
    async () => (await getActiveSessionIndex(page)) === 0,
    { maxAttempts: 30, delayMs: 500 },
  );

  await overflow.click();
  await expect(overflowMenu).toBeVisible({ timeout: 5_000 });
  await overflowMenu.locator(".session-tab-overflow-item").nth(11).click();
  await retry(
    async () => (await getActiveSessionIndex(page)) === 11,
    { maxAttempts: 30, delayMs: 500 },
  );
}

async function expectWelcomeFillsAvailableView(page: Page): Promise<void> {
  const menu = page.locator("#menu");
  const status = page.locator("#status");
  const welcomeHost = page.locator("#welcomeScreen");
  const welcomeWrapper = page.locator(".welcome-screen-wrapper");
  const welcomeScreen = page.locator(".welcome-screen");

  await expect(welcomeHost).toBeVisible({ timeout: 15_000 });
  await expect(welcomeWrapper).toBeVisible({ timeout: 15_000 });
  await expect(welcomeScreen).toBeVisible({ timeout: 15_000 });

  await retryAction(async () => {
    const menuBox = await menu.boundingBox();
    const statusBox = await status.boundingBox();
    const hostBox = await welcomeHost.boundingBox();
    const wrapperBox = await welcomeWrapper.boundingBox();
    const screenBox = await welcomeScreen.boundingBox();
    expect(menuBox, "caption bar should have layout").not.toBeNull();
    expect(hostBox, "welcome host should have layout").not.toBeNull();
    expect(wrapperBox, "welcome wrapper should have layout").not.toBeNull();
    expect(screenBox, "welcome screen should have layout").not.toBeNull();

    const viewport = page.viewportSize() ?? {
      width: Math.max(hostBox!.width, wrapperBox!.width, screenBox!.width),
      height: Math.max(
        hostBox!.y + hostBox!.height,
        wrapperBox!.y + wrapperBox!.height,
        screenBox!.y + screenBox!.height,
      ),
    };
    const top = menuBox!.y + menuBox!.height;
    const bottom = statusBox && statusBox.height > 0
      ? statusBox.y
      : viewport.height;
    const availableHeight = bottom - top;

    expect.soft(hostBox!.y).toBeLessThanOrEqual(top + 2);
    expect.soft(hostBox!.y).toBeGreaterThanOrEqual(top - 2);
    expect.soft(hostBox!.height).toBeGreaterThanOrEqual(availableHeight - 4);
    expect.soft(wrapperBox!.height).toBeGreaterThanOrEqual(availableHeight - 4);
    expect.soft(wrapperBox!.width).toBeGreaterThanOrEqual(viewport.width - 4);
    expect.soft(screenBox!.y).toBeGreaterThanOrEqual(top - 2);
    expect.soft(screenBox!.y + screenBox!.height).toBeLessThanOrEqual(bottom + 2);
  }, { maxAttempts: 50, delayMs: 100 });
}

test.describe("New Trace caption chrome", () => {
  test.setTimeout(180_000);
  test.describe.configure({ retries: 1 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("clicking New Trace opens a welcome tab with styled caption chrome", async ({
    ctPage,
  }, testInfo) => {
    ctPage.on("pageerror", (error) => {
      console.error(`[pageerror-stack] ${error.stack ?? error.message}`);
    });

    try {
      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await expectCaptionChrome(ctPage);
      await expectOmniboxSearchIsInteractive(ctPage);

      await retry(
        async () => (await getSessionCount(ctPage)) >= 1,
        { maxAttempts: 30, delayMs: 500 },
      );

      await ctPage.locator(".session-tab-add").click();

      await retry(
        async () => (await getSessionCount(ctPage)) === 2,
        { maxAttempts: 30, delayMs: 500 },
      );
      await retry(
        async () => (await getActiveSessionIndex(ctPage)) === 1,
        { maxAttempts: 30, delayMs: 500 },
      );

      const welcomeScreen = ctPage.locator(".welcome-screen");
      await expect(welcomeScreen).toBeVisible({ timeout: 15_000 });
      await expect(ctPage.locator(".welcome-left-panel")).toBeVisible({
        timeout: 15_000,
      });
      await expect(ctPage.locator(".welcome-right-panel")).toBeVisible({
        timeout: 15_000,
      });

      await expectCaptionChrome(ctPage);
      const menuBox = await ctPage.locator("#menu").boundingBox();
      const welcomeBox = await welcomeScreen.boundingBox();
      expect(menuBox, "caption bar should remain visible above welcome").not.toBeNull();
      expect(welcomeBox, "welcome screen should have layout").not.toBeNull();
      expect(welcomeBox!.y).toBeGreaterThanOrEqual(menuBox!.y + menuBox!.height - 2);

      await expectWelcomeFillsAvailableView(ctPage);
      await expectOmniboxDoesNotOverlapTabs(ctPage);
      await expectMenuMouseInteraction(ctPage);
    } finally {
      await attachCaptionArtifacts(ctPage, testInfo);
    }
  });
});
