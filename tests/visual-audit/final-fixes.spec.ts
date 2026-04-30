/**
 * Complete visual review — captures screenshots of all new UI components
 * for formal design review and scoring.
 *
 * Screenshots saved to /tmp/visual-review/:
 *   01-normal-layout.png       — Default GL layout with FILESYSTEM, VCS, panels
 *   02-vcs-panel.png           — VCS tab active showing branch/commits/files
 *   03-build-success.png       — BUILD auto-hide overlay with success output
 *   04-build-failure.png       — BUILD auto-hide overlay with error output
 *   05-problems.png            — PROBLEMS auto-hide overlay with severity filter
 *   06-search-results.png      — SEARCH RESULTS auto-hide overlay grouped by file
 *   07-left-strip.png          — Left auto-hide strip with vertical text labels
 *   08-left-overlay.png        — Left overlay open showing FILESYSTEM content
 *   09-multi-tab.png           — Session tabs in caption bar (2 tabs)
 *   10-deepreview.png          — DeepReview mode with changed files list
 */

import * as path from "node:path";
import {
  test,
  expect,
  wait,
  codetracerInstallDir,
} from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  ensureDefaultLayout,
  restoreUserLayout,
} from "../../lib/layout-reset";

const DIR = "/tmp/visual-review";

const OVERLAY_SETTLE_MS = 800;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function clickBottomTab(
  page: import("@playwright/test").Page,
  label: string,
): Promise<void> {
  const tab = page.locator(".auto-hide-strip-tab", { hasText: label });
  await expect(tab.first()).toBeVisible({ timeout: 10_000 });
  await tab.first().click();
  await wait(OVERLAY_SETTLE_MS);
}

async function waitForOverlay(
  page: import("@playwright/test").Page,
): Promise<void> {
  await expect(page.locator("#auto-hide-overlay")).toHaveClass(/visible/, {
    timeout: 5_000,
  });
}

async function dismissOverlay(
  page: import("@playwright/test").Page,
): Promise<void> {
  await page.keyboard.press("Escape");
  await wait(500);
}

// ---------------------------------------------------------------------------
// Trace mode screens (1-9)
// ---------------------------------------------------------------------------

test.describe("Visual Review — All Components", () => {
  test.setTimeout(300_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => {
    ensureDefaultLayout(codetracerInstallDir);
  });
  test.afterAll(() => {
    restoreUserLayout();
  });

  test("01 Normal layout", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30_000 });
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for editor to appear (best-effort).
    await ctPage
      .locator("div[id^='editorComponent'] .view-lines")
      .first()
      .waitFor({ state: "visible", timeout: 15_000 })
      .catch(() => {});

    await wait(3000);
    await ctPage.screenshot({ path: `${DIR}/01-normal-layout.png` });
  });

  test("02 VCS panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Click the VCS tab in the left stack.
    const vcsTab = ctPage.locator(".lm_tab .lm_title", { hasText: "VCS" });
    if ((await vcsTab.count()) > 0) {
      await vcsTab.first().click();
      await wait(1500);
    }

    await ctPage.screenshot({ path: `${DIR}/02-vcs-panel.png` });
  });

  test("03 BUILD success", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    await clickBottomTab(ctPage, "BUILD");
    await waitForOverlay(ctPage);

    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const bc = s.ui.componentMapping[11]?.[0];
      if (bc?.build) {
        bc.build.output = [
          { Field0: "$ nim c --sourcemap:on main.nim", Field1: false },
          {
            Field0: "\x1b[32mHint:\x1b[0m used 42 lines of code",
            Field1: false,
          },
          {
            Field0: "\x1b[32mHint:\x1b[0m operation successful (0.8s)",
            Field1: false,
          },
          { Field0: "\x1b[32mHint: [SuccessX]\x1b[0m", Field1: false },
        ];
        bc.build.code = 0;
        bc.build.running = false;
        bc.build.command = "$ nim c --sourcemap:on main.nim";
      }
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(11);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/03-build-success.png` });
    await dismissOverlay(ctPage);
  });

  test("04 BUILD failure", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    await clickBottomTab(ctPage, "BUILD");
    await waitForOverlay(ctPage);

    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const bc = s.ui.componentMapping[11]?.[0];
      if (bc?.build) {
        bc.build.output = [
          { Field0: "$ cargo build", Field1: false },
          {
            Field0:
              "\x1b[31merror[E0308]\x1b[0m: mismatched types",
            Field1: true,
          },
          {
            Field0: " \x1b[34m-->\x1b[0m src/main.rs:42:5",
            Field1: false,
          },
          { Field0: "  |", Field1: false },
          { Field0: "42 |     let x: bool = 42;", Field1: false },
          {
            Field0:
              "  |                   \x1b[31m^^\x1b[0m expected `bool`, found integer",
            Field1: false,
          },
          { Field0: "", Field1: false },
          {
            Field0: "\x1b[33mwarning\x1b[0m: unused variable: `y`",
            Field1: false,
          },
          {
            Field0: " \x1b[34m-->\x1b[0m src/main.rs:10:9",
            Field1: false,
          },
          { Field0: "", Field1: false },
          {
            Field0:
              "\x1b[31merror\x1b[0m: aborting due to previous error",
            Field1: true,
          },
        ];
        bc.build.code = 1;
        bc.build.running = false;
        bc.build.command = "$ cargo build";
      }
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(11);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/04-build-failure.png` });
    await dismissOverlay(ctPage);
  });

  test("05 PROBLEMS panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Inject problems into the Build component (ErrorsComponent reads from it).
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const bc = s.ui.componentMapping[11]?.[0];
      if (bc?.build) {
        bc.build.problems = [
          {
            severity: 0,
            path: "src/main.rs",
            line: 42,
            col: 5,
            message: "mismatched types: expected `bool`, found integer",
          },
          {
            severity: 0,
            path: "src/main.rs",
            line: 55,
            col: 12,
            message: "cannot find value `undefined_var` in this scope",
          },
          {
            severity: 1,
            path: "src/main.rs",
            line: 10,
            col: 9,
            message: "unused variable: `y`",
          },
        ];
      }
      if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(11);
    });
    await wait(300);

    await clickBottomTab(ctPage, "PROBLEMS");
    await waitForOverlay(ctPage);

    // Re-render the errors panel now that overlay is visible.
    await ctPage.evaluate(() => {
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(21);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/05-problems.png` });
    await dismissOverlay(ctPage);
  });

  test("06 SEARCH RESULTS", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Inject search results.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const comp = s.ui.componentMapping[20]?.[0];
      if (comp?.service) {
        comp.service.results[2] = [
          {
            text: "def print_to_stdout() -> None:",
            path: "src/main.py",
            line: 10,
            customFields: [],
          },
          {
            text: '    print("hello world")',
            path: "src/main.py",
            line: 15,
            customFields: [],
          },
          {
            text: '    print("1. print using print(\'text\')")',
            path: "src/main.py",
            line: 51,
            customFields: [],
          },
          {
            text: "from io import print_function",
            path: "src/utils.py",
            line: 3,
            customFields: [],
          },
        ];
        if (!comp.service.query) {
          comp.service.query = { query: "print", value: "print" };
        } else {
          comp.service.query.query = "print";
        }
      }
      if (comp) comp.active = true;
      if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(20);
    });
    await wait(300);

    await clickBottomTab(ctPage, "SEARCH RESULTS");
    await waitForOverlay(ctPage);

    await ctPage.evaluate(() => {
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(20);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/06-search-results.png` });
    await dismissOverlay(ctPage);
  });

  test("07-08 Left auto-hide strip + overlay", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Pin FILESYSTEM to left edge using __ctPinPanel.
    // Content.Filesystem = 9, AutoHideEdge.Left = 0.
    const pinned = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const fsComp = s.ui.componentMapping[9]?.[0];
      if (!fsComp?.layoutItem) return "no-layout-item";
      if (!(window as any).__ctPinPanel) return "no-pin-helper";
      (window as any).__ctPinPanel(fsComp.layoutItem, 0);
      return "ok";
    });

    if (pinned !== "ok") {
      console.warn(`Pin FILESYSTEM failed: ${pinned}, using dropdown fallback`);
      // Fallback: use dropdown menu to pin the active tab.
      const stacks = ctPage.locator(".lm_stack");
      const stack = stacks.first();
      if (await stack.isVisible({ timeout: 3_000 }).catch(() => false)) {
        const toggle = stack.locator(".layout-buttons-container").first();
        await toggle.click();
        await wait(300);
        await ctPage.evaluate(() => {
          const stacks = document.querySelectorAll(".lm_stack");
          const s = stacks[0];
          if (!s) return;
          for (const item of s.querySelectorAll(".layout-dropdown-node")) {
            if (item.textContent?.trim() === "Pin to Left") {
              (item as HTMLElement).click();
              return;
            }
          }
        });
      }
    }
    await wait(1500);

    // Also pin VCS to left (now the active tab in the remaining stack).
    const pinned2 = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const vcsComp = s.ui.componentMapping[41]?.[0];
      if (!vcsComp?.layoutItem) return "no-layout-item";
      if (!(window as any).__ctPinPanel) return "no-pin-helper";
      (window as any).__ctPinPanel(vcsComp.layoutItem, 0);
      return "ok";
    });

    if (pinned2 !== "ok") {
      console.warn(`Pin VCS failed: ${pinned2}`);
    }
    await wait(1500);

    // Verify left strip has tabs.
    const leftStrip = ctPage.locator("#auto-hide-strip-left");
    const hasTabsClass = await leftStrip
      .evaluate((el) => el.classList.contains("has-tabs"))
      .catch(() => false);

    if (hasTabsClass) {
      // Dump strip debug info before screenshot.
      const stripDebug = await ctPage.evaluate(() => {
        const strip = document.getElementById("auto-hide-strip-left");
        if (!strip) return { error: "strip not found" };
        const rect = strip.getBoundingClientRect();
        const tabs = strip.querySelectorAll(".auto-hide-strip-tab");
        const tabInfo = Array.from(tabs).map((t) => ({
          text: t.textContent,
          rect: (t as HTMLElement).getBoundingClientRect(),
          styles: {
            width: getComputedStyle(t).width,
            height: getComputedStyle(t).height,
            writingMode: getComputedStyle(t).writingMode,
            display: getComputedStyle(t).display,
            visibility: getComputedStyle(t).visibility,
          },
        }));
        return {
          stripRect: { x: rect.x, y: rect.y, w: rect.width, h: rect.height },
          stripClasses: strip.className,
          stripComputedWidth: getComputedStyle(strip).width,
          stripComputedMaxWidth: getComputedStyle(strip).maxWidth,
          tabCount: tabs.length,
          tabs: tabInfo,
        };
      });
      console.log("Left strip debug:", JSON.stringify(stripDebug, null, 2));

      // Screenshot: left strip with vertical text labels.
      await ctPage.screenshot({ path: `${DIR}/07-left-strip.png` });

      // Open the overlay programmatically since the strip tab click
      // may not propagate through Karax's virtual DOM in Playwright.
      await ctPage.evaluate(() => {
        const state = (window as any).autoHideState;
        if (!state) return;
        // Find the first left-edge panel.
        const leftPanel = state.panels.find((p: any) => p.edge === 0);
        if (leftPanel) {
          // Import showOverlay - it's a module-level proc, access via
          // the strip tab's onclick handler or call directly.
          const tabs = document.querySelectorAll(
            "#auto-hide-strip-left .auto-hide-strip-tab",
          );
          if (tabs.length > 0) {
            (tabs[0] as HTMLElement).click();
          }
        }
      });
      await wait(OVERLAY_SETTLE_MS);

      // Check if overlay appeared; if not, try clicking via dispatchEvent.
      const overlayVisible = await ctPage
        .locator("#auto-hide-overlay")
        .evaluate((el) => el.classList.contains("visible"))
        .catch(() => false);

      if (!overlayVisible) {
        console.warn("Overlay did not open via click, trying dispatchEvent");
        await ctPage.evaluate(() => {
          const tab = document.querySelector(
            "#auto-hide-strip-left .auto-hide-strip-tab",
          );
          if (tab) {
            tab.dispatchEvent(new MouseEvent("click", { bubbles: true }));
          }
        });
        await wait(OVERLAY_SETTLE_MS);
      }

      // Take overlay screenshot if visible, otherwise take what we have.
      const isOverlayVisible = await ctPage
        .locator("#auto-hide-overlay")
        .evaluate((el) => el.classList.contains("visible"))
        .catch(() => false);

      await ctPage.screenshot({ path: `${DIR}/08-left-overlay.png` });
      if (isOverlayVisible) {
        await dismissOverlay(ctPage);
      }
    } else {
      // Take a diagnostic screenshot even if has-tabs wasn't set.
      console.warn("Left strip does not have has-tabs class");
      await ctPage.screenshot({ path: `${DIR}/07-left-strip-FAILED.png` });

      // Dump debug info.
      const debugInfo = await ctPage.evaluate(() => {
        const strip = document.getElementById("auto-hide-strip-left");
        const state = (window as any).autoHideState;
        return {
          stripExists: !!strip,
          stripClasses: strip?.className ?? "N/A",
          stripChildCount: strip?.childNodes?.length ?? 0,
          stripInnerHTML: (strip?.innerHTML ?? "").slice(0, 500),
          panelCount: state?.panels?.length ?? 0,
          panelEdges: state?.panels?.map(
            (p: any) => `${p.title}:edge=${p.edge}`,
          ),
        };
      });
      console.log("Left strip debug:", JSON.stringify(debugInfo, null, 2));
    }
  });

  test("09 Multi-tab caption bar", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Create a second session tab.
    await ctPage.evaluate(() => {
      if ((window as any).__ctCreateNewSession) {
        (window as any).__ctCreateNewSession();
      }
    });
    await wait(2000);

    // Verify tab bar is visible.
    const tabBar = ctPage.locator("#session-tab-bar");
    await expect(tabBar).not.toHaveClass(/single-session/, { timeout: 5_000 });

    // Click the first tab to make it active (shows active vs inactive contrast).
    const firstTab = ctPage.locator(".session-tab").first();
    await firstTab.click();
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/09-multi-tab.png` });
  });
});

// ---------------------------------------------------------------------------
// Collapsed mode screens (11-13)
// ---------------------------------------------------------------------------

test.describe("Visual Review — Collapsed Mode", () => {
  test.setTimeout(180_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => {
    ensureDefaultLayout(codetracerInstallDir);
  });
  test.afterAll(() => {
    restoreUserLayout();
  });

  test("11-13 Collapsed strip, icon zone, and side-edge tabs", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Pin FILESYSTEM and VCS to the left edge.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      // Pin FILESYSTEM (Content=9) to Left (edge=0)
      const fsComp = s.ui.componentMapping[9]?.[0];
      if (fsComp?.layoutItem && (window as any).__ctPinPanel) {
        (window as any).__ctPinPanel(fsComp.layoutItem, 0);
      }
    });
    await wait(1000);
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      // Pin VCS (Content=41) to Left (edge=0)
      const vcsComp = s.ui.componentMapping[41]?.[0];
      if (vcsComp?.layoutItem && (window as any).__ctPinPanel) {
        (window as any).__ctPinPanel(vcsComp.layoutItem, 0);
      }
    });
    await wait(1000);

    // Force collapsed mode on (bypasses maximize detection).
    await ctPage.evaluate(() => {
      if ((window as any).__ctForceCollapsedMode) {
        (window as any).__ctForceCollapsedMode(true);
      }
    });
    await wait(1000);

    // Screenshot 11: Collapsed 1px strip with accent color.
    const leftStrip = ctPage.locator("#auto-hide-strip-left");
    const hasCollapsed = await leftStrip
      .evaluate((el) => el.classList.contains("collapsed-mode"))
      .catch(() => false);
    console.log(`Left strip has collapsed-mode class: ${hasCollapsed}`);

    await ctPage.screenshot({ path: `${DIR}/11-collapsed-strip.png` });

    // Screenshot 12: Status bar with icon zone.
    // The icon zone should appear with panel icons for FILESYSTEM and VCS.
    const iconZone = ctPage.locator(".collapsed-icon-zone.has-icons");
    const iconCount = await iconZone.locator(".collapsed-icon").count()
      .catch(() => 0);
    console.log(`Collapsed icon zone: ${iconCount} icons`);

    // Take a focused screenshot of just the status bar area.
    await ctPage.screenshot({ path: `${DIR}/12-collapsed-icon-zone.png` });

    // Screenshot 13: Open overlay via clicking a status bar icon.
    // The icon has a Karax click handler that calls showOverlay.
    const firstIcon = ctPage.locator(".collapsed-icon").first();
    if ((await firstIcon.count()) > 0) {
      await firstIcon.click({ force: true });
      await wait(OVERLAY_SETTLE_MS);
    }

    // Check overlay state.
    const overlayIsVisible = await ctPage
      .locator("#auto-hide-overlay")
      .evaluate((el) => el.classList.contains("visible"))
      .catch(() => false);
    console.log(`Overlay visible: ${overlayIsVisible}`);

    // Check for side-edge tabs in the overlay.
    const sideTabCount = await ctPage.evaluate(() => {
      const container = document.getElementById("auto-hide-overlay-side-tabs");
      return {
        count: container?.querySelectorAll(".overlay-side-tab").length ?? 0,
        html: (container?.innerHTML ?? "").slice(0, 500),
      };
    });
    console.log(`Side-edge tabs:`, JSON.stringify(sideTabCount));

    await ctPage.screenshot({ path: `${DIR}/13-collapsed-overlay-side-tabs.png` });

    // Clean up: dismiss overlay and disable collapsed mode.
    await ctPage.keyboard.press("Escape");
    await wait(500);
    await ctPage.evaluate(() => {
      if ((window as any).__ctForceCollapsedMode) {
        (window as any).__ctForceCollapsedMode(false);
      }
    });
    await wait(500);
  });
});

// ---------------------------------------------------------------------------
// DeepReview mode (screen 10)
// ---------------------------------------------------------------------------

test.describe("Visual Review — DeepReview", () => {
  test.setTimeout(120_000);

  const reviewPath = path.resolve(
    __dirname,
    "..",
    "deepreview",
    "fixtures",
    "sample-review.json",
  );
  test.use({ launchMode: "deepreview", deepreviewJsonPath: reviewPath });

  test("10 DeepReview layout", async ({ ctPage }) => {
    // Wait for either DeepReview file items or the GL layout to appear.
    // DeepReview mode may take time to parse the JSON and render.
    try {
      await ctPage.waitForSelector(
        ".deepreview-file-item-compact, .lm_goldenlayout",
        { timeout: 45_000 },
      );
    } catch {
      console.warn("DeepReview selectors did not appear in time");
    }
    await wait(3000);

    await ctPage.screenshot({ path: `${DIR}/10-deepreview.png` });
  });
});
