/**
 * Ported to the scenarios src/tests/scenarios/auto-hide/pin-creates-strip-tab.yaml,
 * strip-tab-click-docks.yaml, overlay-hover-and-dismiss.yaml,
 * unpin-restores-pane.yaml, pin-to-different-edges.yaml, editor-unpin.yaml,
 * persisted-pin-restored.yaml, pinned-files-layout-not-reset.yaml,
 * sidebar-toggles-independently.yaml, sidebar-modes-restored-*.yaml,
 * sidebar-invalid-*-mode.yaml and sidebar-empty-edges.yaml; kept for the two
 * cases that read the saved state back from disk (the pinned set, and the
 * sidebar presentation across a relaunch), which no input can observe.
 *
 * Auto-hide panes E2E tests.
 *
 * Verifies the pin-to-edge workflow: pinning panels to edge strips, docking
 * a panel by clicking its strip tab, previewing it in the slide-in overlay by
 * hovering the tab, unpinning back to the GL layout, and dismissing the
 * overlay via Escape / backdrop click.
 *
 * **Click docks, hover previews.**  Every test below that opens
 * `#auto-hide-overlay` does so by *hovering* a strip tab.  A click reparents
 * the panel into `#auto-hide-docked-<edge>-content` instead and never touches
 * the overlay — see the contract note in `page-objects/auto-hide-strip.ts`
 * for why (commit `03b787734`).
 *
 * DOM elements under test (defined in index.html and rendered by
 * auto_hide.nim / auto_hide_overlay.nim):
 *   #auto-hide-layout-row        — flex row: left strip + #ROOT + right strip
 *   #auto-hide-strip-left        — left edge strip (ID, flex item beside GL)
 *   #auto-hide-strip-right       — right edge strip (ID, flex item beside GL)
 *   #auto-hide-bottom-strip      — bottom strip hosted inside #status-base;
 *                                  its tabs are DIRECT children (the pre-
 *                                  redesign wrapper element is retired —
 *                                  see page-objects/auto-hide-strip.ts)
 *   .auto-hide-strip-tab         — individual tab within a strip
 *   #auto-hide-docked-bottom     — inline docked container a tab CLICK opens
 *   #auto-hide-overlay           — slide-in overlay container a tab HOVER opens
 *   #auto-hide-overlay-title     — title text inside the (hidden) overlay
 *                                  header; readable in the DOM, never painted
 *   #context-menu-container      — right-click menu on a strip tab; its
 *                                  "Unpin" item is the ONLY unpin affordance
 *                                  left (the overlay header is display:none
 *                                  since a6151510e, and the per-tab buttons
 *                                  that replaced it were deleted in 1af471302)
 *   #auto-hide-backdrop          — click-to-dismiss backdrop behind overlay
 *   .context-menu-item           — a row in that menu; the pin/close/maximise
 *                                  commands moved here when the stack-header
 *                                  .layout-buttons-container dropdown was
 *                                  removed as a duplicate affordance
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.
 * The strip/overlay DOM is built by `layout.nim` the same way for every
 * recorded language — see `lib/js-trace-fixture.ts`
 * `recordChromeTraceFixture`.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { ctUserConfigDir } from "../../lib/ct-home";

import { test, expect, restartTraceFolderElectron } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  DEFAULT_BOTTOM_TAB_COUNT,
  OVERLAY_SELECTOR,
  bottomStripTabs,
  dockedContainer,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

/** Timeout for waiting on UI elements/transitions. */
const WAIT_TIMEOUT_MS = 15000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Right-click the active tab of the first visible GL stack and click the
 * context-menu item whose text matches `itemText` (e.g. "Pin to Bottom").
 *
 * The stack-header `.layout-buttons-container` dropdown this helper used to
 * drive was removed — every action it carried is on the tab's right-click
 * menu (`addPanelTransferContextMenu` in `ui/layout.nim`), which is now the
 * only way to reach them.  That menu renders into `#context-menu-container`
 * as `.context-menu-item` rows.
 *
 * Note the label change that came with the move: the dropdown's "Close all"
 * is "Close" on the context menu.
 *
 * Returns the title text of the active tab in the stack that was acted
 * upon, so tests can assert which panel was pinned.
 */
async function clickDropdownItem(
  ctPage: import("@playwright/test").Page,
  itemText: string,
  stackIndex = 0,
): Promise<string> {
  // Find the stack's active tab title before acting, so we know
  // which panel will be pinned.
  const stacks = ctPage.locator(".lm_stack");
  const stack = stacks.nth(stackIndex);
  await expect(stack).toBeVisible({ timeout: 10_000 });

  // The active tab label lives inside .lm_tab.lm_active .lm_title
  const activeTab = stack.locator(".lm_tab.lm_active").first();
  const activeTitle = await activeTab.locator(".lm_title").first().textContent();

  // Open the tab's context menu.  The handler calls preventDefault, so the
  // browser's own menu never appears.
  await activeTab.click({ button: "right" });

  const menu = ctPage.locator("#context-menu-container");
  await expect(menu).toBeVisible({ timeout: WAIT_TIMEOUT_MS });

  const menuItem = menu.locator(".context-menu-item", { hasText: itemText });
  await expect(menuItem.first()).toBeVisible({ timeout: WAIT_TIMEOUT_MS });

  const layoutUpdatedPromise = ctPage.evaluate(() => {
    return new Promise<void>((resolve) => {
      window.addEventListener('ct:layoutUpdated', () => resolve(), { once: true });
    });
  });

  // Click via the DOM API: the menu closes itself on any document click, so
  // a synthetic click is steadier than routing one through the page.
  await ctPage.evaluate((text) => {
    const items = document.querySelectorAll(
      "#context-menu-container .context-menu-item",
    );
    for (const item of items) {
      if (item.textContent?.trim() === text) {
        (item as HTMLElement).click();
        return;
      }
    }
  }, itemText);

  // Wait for the deterministic layoutUpdated signal before returning
  await layoutUpdatedPromise;

  return (activeTitle ?? "").trim();
}

/**
 * Pin the active tab of a given GL stack to the specified edge.
 * Returns the title of the panel that was pinned.
 */
async function pinToEdge(
  ctPage: import("@playwright/test").Page,
  edge: "Bottom" | "Left" | "Right",
  stackIndex = 0,
): Promise<string> {
  return clickDropdownItem(ctPage, `Pin to ${edge}`, stackIndex);
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

const fixture = recordChromeTraceFixture("auto-hide-panes");


// ---------------------------------------------------------------------------
// #608 (M41) — the pinned set must survive a restart, and pinning FILES must
// not destroy the saved layout.
//
// Before the fix, `ui/layout.nim` posted the serialised auto-hide state to
// `CODETRACER::save-auto-hide-state` and NOTHING listened on that channel —
// the string occurred at exactly one site in the whole repository, the send —
// while `restoreAutoHideState` had zero call sites.  So a pinned panel was
// simply gone on the next launch, and because pinning removes the component
// from the GoldenLayout tree, pinning FILES additionally made
// `isValidLayoutConfig` reject the saved layout, at which point
// `resetLayoutToDefault` DELETED it.  That is the "customisations lost with
// no visible error" half of the report.
//
// The headless guard for the same invariants (the serialised shape, and the
// validator consulting the auto-hide state) is
// `src/tests/gui/tests/layout/layout_config_roundtrip_test.nim`.
// ---------------------------------------------------------------------------

/**
 * The isolated config directory the GUI fixtures point the app at.
 * `lib/fixtures.ts` assigns `process.env.CODETRACER_HOME` at import time, so
 * this is already the per-run directory by the time the spec body runs.
 */
const userConfigDir = ctUserConfigDir();
const autoHideStatePath = path.join(userConfigDir, "auto_hide_state.json");

/** Content ordinals from `common_types/codetracer_features/frontend.nim`. */
const CONTENT_FILESYSTEM = 9;
const CONTENT_EVENT_LOG = 8;
/** `AutoHideEdge` ordinals from `ui/auto_hide.nim`: Left = 0, Right = 1, Bottom = 2. */
const EDGE_LEFT = 0;

function removeIfPresent(target: string): void {
  if (fs.existsSync(target)) fs.unlinkSync(target);
}


function pinnedFilesystemPanel() {
  return {
    edge: EDGE_LEFT,
    title: "FILES",
    content: CONTENT_FILESYSTEM,
    componentId: 0,
    overlayWidth: 320,
    overlayHeight: 0,
    config: {
      type: "component",
      componentType: "genericUiComponent",
      componentState: {
        id: 0,
        label: "filesystemComponent-0",
        content: CONTENT_FILESYSTEM,
        isEditor: false,
      },
      title: "FILES",
    },
  };
}

test.describe("Auto-hide state survives a restart", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test.afterEach(() => {
    // Never leak a pinned panel into a later test in this worker: the config
    // directory is shared and the fixture only resets `default_layout.json`.
    removeIfPresent(autoHideStatePath);
  });

  test("pinning a panel writes the auto-hide state to disk", async ({ ctPage }) => {
    removeIfPresent(autoHideStatePath);

    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    const pinnedTitle = await pinToEdge(ctPage, "Left", 0);

    // The write is an async IPC round trip through the index process, so poll
    // rather than assert once.
    await expect(() => {
      expect(fs.existsSync(autoHideStatePath)).toBe(true);
      const saved = JSON.parse(fs.readFileSync(autoHideStatePath, "utf8"));
      expect(Array.isArray(saved.panels)).toBe(true);
      const titles = saved.panels.map((panel: { title: string }) => panel.title);
      expect(titles).toContain(pinnedTitle);
    }).toPass({ timeout: WAIT_TIMEOUT_MS });

    // The persisted entry must carry everything a restore needs and nothing
    // that cannot survive a process boundary.
    const saved = JSON.parse(fs.readFileSync(autoHideStatePath, "utf8"));
    const entry = saved.panels.find(
      (panel: { title: string }) => panel.title === pinnedTitle,
    );
    expect(entry).toBeTruthy();
    expect(entry.config).toBeTruthy();
    expect(entry.config.componentState).toBeTruthy();
    expect(entry).toHaveProperty("edge");
    expect(entry).toHaveProperty("overlayWidth");
    expect(entry).toHaveProperty("overlayHeight");
    for (const transient of ["liveElement", "domTab", "containerElement", "isUnpinning"]) {
      expect(entry).not.toHaveProperty(transient);
    }
  });
});

// No mocks: seed the real persisted layout, then exercise the production
// controls and IPC persistence in Electron. The saved entries describe real
// Filesystem/Event Log components, just as a previous app launch would save.
test.describe("Independent sidebar presentation", () => {
  test.setTimeout(120_000);
  test.use({
    sourcePath: fixture.traceDir,
    launchMode: "trace-folder",
    preserveAutoHideState: true,
  });

  function seedModes(leftMinimal?: unknown, rightMinimal?: unknown) {
    const right = {
      ...pinnedFilesystemPanel(),
      edge: 1,
      title: "EVENTS",
      content: CONTENT_EVENT_LOG,
      componentId: 1,
      config: {
        type: "component",
        componentType: "genericUiComponent",
        componentState: { id: 1, label: "eventLogComponent-1", content: CONTENT_EVENT_LOG },
        title: "EVENTS",
      },
    };
    fs.mkdirSync(userConfigDir, { recursive: true });
    fs.writeFileSync(autoHideStatePath, JSON.stringify({
      panels: [pinnedFilesystemPanel(), right], leftMinimal, rightMinimal,
    }));
  }

  test.beforeEach(() => seedModes());
  test.afterEach(() => removeIfPresent(autoHideStatePath));

  const leftHost = "#auto-hide-collapsed-icon-zone";
  const rightHost = "#auto-hide-collapsed-icon-zone-right";

  async function modes(page: import("@playwright/test").Page, left: boolean, right: boolean) {
    for (const [edge, minimal] of [["left", left], ["right", right]] as const) {
      const strip = page.locator(`#auto-hide-strip-${edge}`);
      await expect(strip).toHaveClass(minimal ? /collapsed-mode/ : /^(?!.*collapsed-mode)/);
      // The sidebar toggle is in the status bar in both modes, never on the strip.
      await expect(strip.locator(".auto-hide-mode-button")).toHaveCount(0);
      const host = page.locator(edge === "left" ? leftHost : rightHost);
      await expect(host).toBeVisible();
      await expect(host.locator(".auto-hide-restore-button")).toHaveClass(minimal ? /sidebar-close/ : /sidebar-open/);
    }
  }

  test("visible controls independently switch all four combinations and preserve live panels", async ({ ctPage, electronApp }) => {
    await new LayoutPage(ctPage).waitForTraceLoaded();
    await modes(ctPage, false, false); // Legacy state defaults to normal.
    await waitForDefaultBottomTabs(ctPage, WAIT_TIMEOUT_MS);

    // Keep the right panel docked while changing the left presentation.
    await ctPage.locator("#auto-hide-strip-right .auto-hide-strip-tab").click();
    await expect(dockedContainer(ctPage, "right")).toHaveClass(/docked-open/);
    await ctPage.getByRole("button", { name: "Use minimal left sidebar", exact: true }).click();
    await modes(ctPage, true, false);
    await expect(dockedContainer(ctPage, "right")).toHaveClass(/docked-open/);
    await expect(ctPage.locator(`${leftHost} button`).first()).toHaveAccessibleName("Use normal left sidebar");
    await expect(ctPage.locator(`${leftHost} button`).last()).toHaveAccessibleName("FILES");

    await ctPage.getByRole("button", { name: "Use minimal right sidebar", exact: true }).click();
    await modes(ctPage, true, true);
    await expect(dockedContainer(ctPage, "right")).not.toHaveClass(/docked-open/);
    await expect(ctPage.locator(`${rightHost} button`).last()).toHaveAccessibleName("Use normal right sidebar");
    await expect(ctPage.locator(`${rightHost} button`).first()).toHaveAccessibleName("EVENTS");
    const leftBox = await ctPage.locator(leftHost).boundingBox();
    const rightBox = await ctPage.locator(rightHost).boundingBox();
    expect(leftBox!.x).toBeLessThan(10);
    expect(rightBox!.x).toBeGreaterThan((await ctPage.evaluate(() => window.innerWidth)) / 2);
    await ctPage.screenshot({ path: test.info().outputPath("independent-minimal-sidebars.png") });
    // Icons reveal the actual assigned edge. Keep a reference to a live DOM
    // node so closing/reopening through a mode switch proves it was retained.
    await ctPage.locator(leftHost).getByRole("button", { name: "FILES", exact: true }).click();
    await expect(ctPage.locator(OVERLAY_SELECTOR)).toHaveClass(/auto-hide-overlay-left/);
    await ctPage.evaluate(() => {
      (window as any).__sidebarLiveNode = document.querySelector("#auto-hide-overlay-content")?.firstElementChild;
    });
    await ctPage.getByRole("button", { name: "Use normal left sidebar", exact: true }).click();
    await modes(ctPage, false, true);
    await ctPage.getByRole("button", { name: "Use minimal left sidebar", exact: true }).click();
    await expect(ctPage.locator(OVERLAY_SELECTOR)).not.toHaveClass(/visible/);
    await ctPage.locator(leftHost).getByRole("button", { name: "FILES", exact: true }).click();
    expect(await ctPage.evaluate(() => (window as any).__sidebarLiveNode ===
      document.querySelector("#auto-hide-overlay-content")?.firstElementChild)).toBe(true);
    await ctPage.keyboard.press("Escape");
    await ctPage.locator(rightHost).getByRole("button", { name: "EVENTS", exact: true }).click();
    await expect(ctPage.locator(OVERLAY_SELECTOR)).toHaveClass(/auto-hide-overlay-right/);
    await ctPage.keyboard.press("Escape");

    await ctPage.getByRole("button", { name: "Use normal right sidebar", exact: true }).click();
    await modes(ctPage, true, false);
    expect(electronApp).not.toBeNull();
    await electronApp!.evaluate(({ BrowserWindow }) => {
      const win = BrowserWindow.getAllWindows()
        .find((w: { isDestroyed(): boolean; isVisible(): boolean }) => !w.isDestroyed() && w.isVisible())!;
      win.setSize(1400, 900);
      win.maximize();
      win.unmaximize();
    });
    await modes(ctPage, true, false);
    await expect(() => {
      const saved = JSON.parse(fs.readFileSync(autoHideStatePath, "utf8"));
      expect([saved.leftMinimal, saved.rightMinimal]).toEqual([true, false]);
    }).toPass();
    // Restart the real app. A bare renderer reload does not repeat the index
    // process's one-time init IPC, so it cannot test the startup restore path.
    const restarted = await restartTraceFolderElectron(electronApp!, fixture.traceDir);
    try {
      await modes(restarted.page, true, false);
      // Native button keyboard activation restores the left strip.
      await restarted.page.getByRole("button", { name: "Use normal left sidebar", exact: true }).focus();
      await restarted.page.keyboard.press("Enter");
      await modes(restarted.page, false, false);
      await expect(bottomStripTabs(restarted.page)).toHaveCount(DEFAULT_BOTTOM_TAB_COUNT);
    } finally {
      await restarted.teardown();
    }
  });

});
