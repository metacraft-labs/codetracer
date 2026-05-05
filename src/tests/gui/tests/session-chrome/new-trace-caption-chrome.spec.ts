import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import type { Page, TestInfo } from "@playwright/test";

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
          height: style.height,
          zIndex: style.zIndex,
        },
      };
    }

    return {
      bodyClass: document.body.className,
      menuHtml: document.querySelector("#menu")?.outerHTML.slice(0, 4_000) ?? "",
      welcomeHtml:
        document.querySelector("#welcomeScreen")?.outerHTML.slice(0, 4_000) ?? "",
      elements: [
        inspect("#menu"),
        inspect("#navigation-menu"),
        inspect("#menu-logo-img"),
        inspect("#debug"),
        inspect("#debug [id^='commandPaletteComponent-']"),
        inspect("#isonim-debug-controls"),
        inspect("#isonim-debug-controls .isonim-debug-controls"),
        inspect(".session-tab-add"),
        inspect(".welcome-screen"),
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

  const toolbarHost = page.locator("#isonim-debug-controls");
  await expect(toolbarHost).toBeVisible({ timeout: 10_000 });
  const toolbar = toolbarHost.locator(".isonim-debug-controls");
  await expect(toolbar).toBeVisible({ timeout: 10_000 });
  await expect(toolbar.locator("button")).toHaveCount(13, { timeout: 10_000 });

  const menuBox = await menu.boundingBox();
  const toolbarBox = await toolbar.boundingBox();
  const debugBox = await debugHost.boundingBox();
  expect(menuBox, "caption bar should have layout").not.toBeNull();
  expect(toolbarBox, "debugger toolbar should have layout").not.toBeNull();
  expect(debugBox, "omnibox host should have layout").not.toBeNull();
  expect(toolbarBox!.height).toBeGreaterThan(20);
  expect(debugBox!.height).toBeGreaterThan(20);
  expect(toolbarBox!.y).toBeGreaterThanOrEqual(menuBox!.y - 1);
  expect(toolbarBox!.y + toolbarBox!.height).toBeLessThanOrEqual(
    menuBox!.y + menuBox!.height + 8,
  );

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
    } finally {
      await attachCaptionArtifacts(ctPage, testInfo);
    }
  });
});
