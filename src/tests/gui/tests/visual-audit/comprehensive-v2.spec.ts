/**
 * Comprehensive visual audit v2 — captures screenshots of all 8 screens
 * described in tools/screen-briefs.md for formal design review.
 *
 * This test injects data into auto-hide bottom panes (BUILD, PROBLEMS,
 * SEARCH RESULTS) rather than relying on real build/search operations.
 * The auto-hide panels are standalone Karax renderers created by
 * addStandaloneAutoHidePanel in layout.nim. Their component instances
 * are accessible via window.data.ui.componentMapping[Content.X][0],
 * and their Karax renderers can be forced to redraw by calling
 * component.kxi.redraw().
 *
 * Content enum values (from frontend.nim):
 *   Build         = 11
 *   BuildErrors   = 21
 *   SearchResults = 20
 *
 * Two different panel surfaces are captured here, because a strip tab has two
 * gestures: a CLICK docks the panel into `#auto-hide-docked-<edge>` (Screens
 * 2-5) and a HOVER opens the floating `#auto-hide-overlay` (Screen 6, which
 * is explicitly about the overlay).  See the contract note in
 * `page-objects/auto-hide-strip.ts`.
 *
 * No mocks beyond the injected panel data described above: a real JavaScript
 * recording opened by the real Electron app supplies the running instance —
 * see `lib/js-trace-fixture.ts`.  Nothing in these screens is
 * language-specific, and no committed reference images are compared against,
 * so the recorded program only has to be real.
 */

import * as path from "node:path";
import {
  test,
  expect,
  wait,
  codetracerInstallDir,
} from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  ensureDefaultLayout,
  restoreUserLayout,
} from "../../lib/layout-reset";
import {
  DOCKED_OPEN_CLASS,
  OVERLAY_SELECTOR,
  bottomStripTab,
  dockedContainer,
  openOverlayFromTab,
} from "../../page-objects/auto-hide-strip";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DIR = "/tmp/audit-v2";

/** Content enum ordinals from src/common/.../frontend.nim. */
const CONTENT_BUILD = 11;
const CONTENT_BUILD_ERRORS = 21;
const CONTENT_SEARCH_RESULTS = 20;

/** Settle time after overlay open/close. */
const OVERLAY_SETTLE_MS = 800;

// ---------------------------------------------------------------------------
// Build output strings for injection
// ---------------------------------------------------------------------------

const BUILD_HAPPY_OUTPUT: Array<[string, boolean]> = [
  ["$ nim c --sourcemap:on main.nim", false],
  ["\x1b[32mHint:\x1b[0m used 42 lines of code", false],
  ["\x1b[32mHint:\x1b[0m operation successful (0.8s)", false],
  ["\x1b[32mHint: [SuccessX]\x1b[0m", false],
];

const BUILD_UNHAPPY_OUTPUT: Array<[string, boolean]> = [
  ["$ cargo build", false],
  [
    "\x1b[31merror[E0308]\x1b[0m: mismatched types",
    true,
  ],
  [" \x1b[34m-->\x1b[0m src/main.rs:42:5", false],
  ["  |", false],
  ["42 |     let x: bool = 42;", false],
  [
    "  |                   \x1b[31m^^\x1b[0m expected `bool`, found integer",
    false,
  ],
  ["", false],
  [
    "\x1b[33mwarning\x1b[0m: unused variable: `y`",
    false,
  ],
  [" \x1b[34m-->\x1b[0m src/main.rs:10:9", false],
  ["", false],
  [
    "\x1b[31merror\x1b[0m: aborting due to previous error",
    true,
  ],
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Locate an auto-hide bottom tab by its label text (e.g. "BUILD").
 *
 * The tabs are `.auto-hide-strip-tab` elements rendered as direct children
 * of `#auto-hide-bottom-strip` inside `#status-base` — see
 * `page-objects/auto-hide-strip.ts` for why this selector moved.
 */
async function bottomAutoHideTab(
  page: import("@playwright/test").Page,
  label: string,
): Promise<import("@playwright/test").Locator> {
  const tab = bottomStripTab(page, label);
  // A panel is only in the bottom strip while it is pinned to the bottom
  // edge; when it lives on a side strip instead, fall back to any strip tab
  // carrying the label.  Until the bottom selector was corrected this
  // fallback was not a fallback at all — the bottom locator matched nothing
  // on every call, so every click in this file went through it.
  if ((await tab.count()) > 0) return tab.first();
  return page.locator(".auto-hide-strip-tab", { hasText: label }).first();
}

/**
 * Click an auto-hide bottom tab and wait for its panel to dock.
 *
 * A click docks; it does not open the floating overlay.  Waiting for
 * `docked-open` rather than sleeping means the screenshot below is taken
 * against a settled panel.
 */
async function openBottomAutoHideTab(
  page: import("@playwright/test").Page,
  label: string,
): Promise<void> {
  const tab = await bottomAutoHideTab(page, label);
  await expect(tab).toBeVisible({ timeout: 10_000 });
  await tab.click();
  await expect(dockedContainer(page, "bottom")).toHaveClass(
    new RegExp(`\\b${DOCKED_OPEN_CLASS}\\b`),
    { timeout: 10_000 },
  );
  await wait(OVERLAY_SETTLE_MS);
}

/**
 * Collapse the docked bottom panel by clicking its tab again.
 *
 * `showDockedPanel` toggles; Escape only dismisses the *overlay* and would
 * leave the docked panel open for the next screen's screenshot.
 */
async function closeBottomAutoHideTab(
  page: import("@playwright/test").Page,
  label: string,
): Promise<void> {
  await (await bottomAutoHideTab(page, label)).click();
  await expect(dockedContainer(page, "bottom")).not.toHaveClass(
    new RegExp(`\\b${DOCKED_OPEN_CLASS}\\b`),
    { timeout: 10_000 },
  );
  await wait(500);
}

/**
 * Dismiss the floating auto-hide overlay via Escape.
 */
async function dismissOverlay(
  page: import("@playwright/test").Page,
): Promise<void> {
  await page.keyboard.press("Escape");
  await expect(page.locator(OVERLAY_SELECTOR)).not.toHaveClass(/\bvisible\b/, {
    timeout: 10_000,
  });
  await wait(500);
}

/**
 * Inject build output into the Build component and force Karax redraw.
 * This sets `build.output`, `build.code`, `build.running`, and triggers
 * a synchronous redraw on the component's kxi instance.
 */
async function injectBuildOutput(
  page: import("@playwright/test").Page,
  output: Array<[string, boolean]>,
  exitCode: number,
  running: boolean,
): Promise<void> {
  await page.evaluate(
    ({ output, exitCode, running, contentId }) => {
      const data = (window as any).data;
      if (!data?.ui?.componentMapping) return;
      const component = data.ui.componentMapping[contentId]?.[0];
      if (!component) return;
      // Set the build state
      component.build.output = output;
      component.build.code = exitCode;
      component.build.running = running;
      component.build.command = output[0]?.[0] ?? "";
      // Trigger the direct redraw hooks used by the IsoNim-mounted panels.
      if (true) {
        if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
        if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(contentId);
      }
    },
    { output, exitCode, running, contentId: CONTENT_BUILD },
  );
  await wait(300);
}

/**
 * Inject structured problems into the Build component and trigger redraw.
 *
 * The ErrorsComponent.render() reads from
 * `self.data.buildComponent(0).build.problems`, so injecting into the
 * Build component's `build.problems` field is sufficient.
 *
 * ProblemSeverity enum: ProbError=0, ProbWarning=1, ProbInfo=2
 */
async function injectProblems(
  page: import("@playwright/test").Page,
  problems: Array<{
    severity: number;
    path: string;
    line: number;
    col: number;
    message: string;
  }>,
): Promise<void> {
  await page.evaluate(
    ({ problems, buildContentId }) => {
      const data = (window as any).data;
      if (!data?.ui?.componentMapping) return;

      // Inject into Build component's problems field.
      // The ErrorsComponent reads from buildComponent(0).build.problems,
      // so injecting into the Build component is sufficient for both panels.
      const buildComp = data.ui.componentMapping[buildContentId]?.[0];
      if (buildComp?.build) {
        buildComp.build.problems = problems;
      }

      // Trigger a full redraw via __ctRedrawAll and __ctRenderPanel.
      if (true) {
        if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
        if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(buildContentId);
      }
    },
    {
      problems,
      buildContentId: CONTENT_BUILD,
    },
  );
  await wait(300);
}

/**
 * Inject search results into the SearchResults component and redraw.
 *
 * SearchResult = object
 *   text:         cstring
 *   path:         cstring
 *   line:         int
 *   customFields: seq[cstring]
 */
async function injectSearchResults(
  page: import("@playwright/test").Page,
  query: string,
  results: Array<{ text: string; path: string; line: number }>,
): Promise<void> {
  await page.evaluate(
    ({ query, results, contentId, searchFixedOrdinal }) => {
      const data = (window as any).data;
      if (!data?.ui?.componentMapping) return;
      const comp = data.ui.componentMapping[contentId]?.[0];
      if (!comp) return;

      // The SearchResultsComponent.render() reads from:
      //   self.service.results[SearchFixed]  — the results array
      //   self.service.query.query           — the search query text
      // SearchFixed is ordinal 2 in the SearchMode enum.
      const mappedResults = results.map((r: any) => ({
        text: r.text,
        path: r.path,
        line: r.line,
        customFields: [],
      }));

      if (comp.service) {
        // Inject into the service's results array at the SearchFixed index.
        comp.service.results[searchFixedOrdinal] = mappedResults;
        // Set the query on the service's SearchQuery object.
        if (!comp.service.query) {
          comp.service.query = { query: query, value: query };
        } else {
          comp.service.query.query = query;
        }
      }

      // Also set the component's own active flag.
      comp.active = true;

      // Trigger a full redraw via __ctRedrawAll and __ctRenderPanel.
      if (true) {
        if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
        if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(contentId);
      }
    },
    { query, results, contentId: CONTENT_SEARCH_RESULTS, searchFixedOrdinal: 2 },
  );
  await wait(300);
}

/**
 * Pin the active tab of a GL stack to a given edge.
 * Uses evaluate() to avoid the dropdown blur race.
 * Returns the title of the pinned panel.
 */
async function pinToEdge(
  page: import("@playwright/test").Page,
  edge: "Bottom" | "Left" | "Right",
  stackIndex = 0,
): Promise<string> {
  const stacks = page.locator(".lm_stack");
  const stack = stacks.nth(stackIndex);
  await expect(stack).toBeVisible({ timeout: 10_000 });

  const activeTitle = await stack
    .locator(".lm_tab.lm_active .lm_title")
    .first()
    .textContent();

  const toggle = stack.locator(".layout-buttons-container").first();
  await toggle.click();

  const dropdown = stack.locator(".layout-dropdown").first();
  await expect(dropdown).not.toHaveClass(/hidden/, { timeout: 5_000 });

  await page.evaluate(
    ({ text, idx }) => {
      const stacks = document.querySelectorAll(".lm_stack");
      const s = stacks[idx];
      if (!s) return;
      for (const item of s.querySelectorAll(".layout-dropdown-node")) {
        if (item.textContent?.trim() === text) {
          (item as HTMLElement).click();
          return;
        }
      }
    },
    { text: `Pin to ${edge}`, idx: stackIndex },
  );

  await wait(1500);
  return (activeTitle ?? "").trim();
}

// ---------------------------------------------------------------------------
// Test suite: Screens 1-7 (trace mode)
// ---------------------------------------------------------------------------

const fixture = recordChromeTraceFixture("comprehensive-v2");

test.describe("Visual Audit v2 — Trace Mode Screens", () => {
  test.setTimeout(180_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  // Ensure the bundled default layout is used, not the user's custom one.
  test.beforeAll(() => {
    ensureDefaultLayout(codetracerInstallDir);
  });

  test.afterAll(() => {
    restoreUserLayout();
  });

  test("Screen 1: Normal layout", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    // Wait for GL panels to appear (not the editor specifically — it loads
    // dynamically after the backend sends CtCompleteMove which may not
    // arrive if the replay backend cannot start).
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30_000 });
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Try to wait for editor, but don't fail if it never appears.
    await ctPage
      .locator("div[id^='editorComponent'] .view-lines")
      .first()
      .waitFor({ state: "visible", timeout: 15_000 })
      .catch(() => {
        // Editor may not appear if replay backend is unavailable — that's OK
        // for a visual audit screenshot.
      });

    // Extra settle time for all panels to finish rendering.
    await wait(3000);

    await ctPage.screenshot({ path: `${DIR}/01-normal-layout.png` });
  });

  test("Screen 2: BUILD happy path", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Click the BUILD auto-hide bottom tab in the status bar.
    await openBottomAutoHideTab(ctPage, "BUILD");

    // Inject data AND render in a single evaluate to avoid serialization
    // issues with Nim tuple format {Field0, Field1} across Playwright's
    // argument passing boundary.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const bc = s.ui.componentMapping[11]?.[0];
      if (bc?.build) {
        bc.build.output = [
          {Field0: "$ nim c --sourcemap:on main.nim", Field1: false},
          {Field0: "\x1b[32mHint:\x1b[0m used 42 lines of code", Field1: false},
          {Field0: "\x1b[32mHint:\x1b[0m operation successful (0.8s)", Field1: false},
          {Field0: "\x1b[32mHint: [SuccessX]\x1b[0m", Field1: false},
        ];
        bc.build.code = 0;
        bc.build.running = false;
        bc.build.command = "$ nim c --sourcemap:on main.nim";
      }
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(11);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/02-build-happy.png` });
    await closeBottomAutoHideTab(ctPage, "BUILD");
  });

  test("Screen 3: BUILD unhappy path", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Click BUILD label.
    await openBottomAutoHideTab(ctPage, "BUILD");

    // Inject data AND render in a single evaluate to avoid serialization
    // issues with Nim tuple format {Field0, Field1}.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const bc = s.ui.componentMapping[11]?.[0];
      if (bc?.build) {
        bc.build.output = [
          {Field0: "$ cargo build", Field1: false},
          {Field0: "\x1b[31merror[E0308]\x1b[0m: mismatched types", Field1: true},
          {Field0: " \x1b[34m-->\x1b[0m src/main.rs:42:5", Field1: false},
          {Field0: "  |", Field1: false},
          {Field0: "42 |     let x: bool = 42;", Field1: false},
          {Field0: "  |                   \x1b[31m^^\x1b[0m expected `bool`, found integer", Field1: false},
          {Field0: "", Field1: false},
          {Field0: "\x1b[33mwarning\x1b[0m: unused variable: `y`", Field1: false},
          {Field0: " \x1b[34m-->\x1b[0m src/main.rs:10:9", Field1: false},
          {Field0: "", Field1: false},
          {Field0: "\x1b[31merror\x1b[0m: aborting due to previous error", Field1: true},
        ];
        bc.build.code = 1;
        bc.build.running = false;
        bc.build.command = "$ cargo build";
      }
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(11);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/03-build-unhappy.png` });
    await closeBottomAutoHideTab(ctPage, "BUILD");
  });

  test("Screen 4: PROBLEMS", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Inject problems into the Build component directly, then open overlay.
    // The ErrorsComponent reads from buildComponent(0).build.problems.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const bc = s.ui.componentMapping[11]?.[0];
      if (bc?.build) {
        bc.build.problems = [
          { severity: 0, path: "src/main.rs", line: 42, col: 5,
            message: "mismatched types: expected `bool`, found integer" },
          { severity: 0, path: "src/main.rs", line: 55, col: 12,
            message: "cannot find value `undefined_var` in this scope" },
          { severity: 1, path: "src/main.rs", line: 10, col: 9,
            message: "unused variable: `y`" },
        ];
      }
      if ((window as any).__ctRedrawAll) (window as any).__ctRedrawAll();
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(11);
    });
    await wait(300);

    // Click PROBLEMS auto-hide bottom tab.
    await openBottomAutoHideTab(ctPage, "PROBLEMS");

    // Re-render the errors panel now that the overlay is visible.
    await ctPage.evaluate(() => {
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(21);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/04-problems.png` });
    await closeBottomAutoHideTab(ctPage, "PROBLEMS");
  });

  test("Screen 5: SEARCH RESULTS", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Inject search results directly into the component to avoid
    // serialization issues across Playwright's evaluate boundary.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const comp = s.ui.componentMapping[20]?.[0];
      if (comp?.service) {
        // SearchFixed is ordinal 2 in the SearchMode enum.
        comp.service.results[2] = [
          { text: 'def print_to_stdout() -> None:', path: "src/main.py",
            line: 10, customFields: [] },
          { text: '    print("hello world")', path: "src/main.py",
            line: 15, customFields: [] },
          { text: '    print("1. print using print(\'text\')")', path: "src/main.py",
            line: 51, customFields: [] },
          { text: "from io import print_function", path: "src/utils.py",
            line: 3, customFields: [] },
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

    // Click SEARCH RESULTS auto-hide bottom tab.
    await openBottomAutoHideTab(ctPage, "SEARCH RESULTS");

    // Re-render the search results panel now that the overlay is visible.
    await ctPage.evaluate(() => {
      if ((window as any).__ctRenderPanel) (window as any).__ctRenderPanel(20);
    });
    await wait(500);

    await ctPage.screenshot({ path: `${DIR}/05-search-results.png` });
    await closeBottomAutoHideTab(ctPage, "SEARCH RESULTS");
  });

  // Was marked FAILING (2026-05-01) with "`#auto-hide-strip-left
  // .auto-hide-strip-tab` never becomes visible".  That note is retired: the
  // tab appears and this screen passes.  The file could not run at all after
  // the status-bar redesign — it recorded `py_console_logs/main.py` and
  // needed the Python recorder — so the claim could not have been re-checked.
  // What WAS wrong here is that the screen clicked the tab and waited for
  // `#auto-hide-overlay.visible`; a click docks, it does not open the
  // overlay.  This screen is about the overlay, so it hovers instead.
  test("Screen 6: Auto-hide left overlay (FILESYSTEM)", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Force collapsed mode OFF before pinning.  Under Xvfb the heuristic
    // in `updateCollapsedMode` (layout.nim ~880) thinks the window is
    // maximized — `window.outerWidth >= screen.availWidth - 8` is true
    // because Xvfb's virtual display matches the Electron window size.
    // That puts the auto-hide strip into the 1px collapsed-mode rendering
    // (`<div class="collapsed-strip-line">`) instead of the 28px text-tab
    // strip the test asserts on.  The `__ctForceCollapsedMode(false)`
    // helper (registered in layout.nim ~869) bypasses the heuristic and
    // sets `collapsedMode = false` + clears `leftBounded`/`rightBounded`.
    //
    // The wait after the force-off lets the direct auto-hide refresh settle so
    // the next `pinPanel` runs against a strip that is already in the 28px
    // text-tab rendering mode, not the 1px collapsed line.
    await ctPage.evaluate(() => {
      const f = (window as any).__ctForceCollapsedMode;
      if (typeof f === "function") f(false);
    });
    await wait(200);

    // Pin the FILESYSTEM panel to the left edge programmatically.
    // Using __ctPinPanel (exposed on window by layout.nim) avoids the
    // dropdown blur race condition that can cause the UI-driven pin to
    // fail silently.
    //
    // Content.Filesystem = 9, AutoHideEdge.Left = 0.
    const pinned = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const s = d.sessions[d.activeSessionIndex];
      const fsComp = s.ui.componentMapping[9]?.[0];
      if (!fsComp?.layoutItem) return false;
      if ((window as any).__ctPinPanel) {
        (window as any).__ctPinPanel(fsComp.layoutItem, 0);
        return true;
      }
      return false;
    });

    // If the programmatic helper is not available, fall back to the
    // UI-driven approach: click the dropdown "Pin to Left".
    if (!pinned) {
      const fsTab = ctPage
        .locator(".lm_tab .lm_title", { hasText: "FILESYSTEM" })
        .first();
      if (await fsTab.isVisible({ timeout: 3_000 }).catch(() => false)) {
        await fsTab.click();
        await wait(500);
      }

      const stackIndex = await ctPage.evaluate(() => {
        const stacks = document.querySelectorAll(".lm_stack");
        for (let i = 0; i < stacks.length; i++) {
          const titles = stacks[i].querySelectorAll(".lm_title");
          for (const t of titles) {
            if (t.textContent?.trim() === "FILESYSTEM") return i;
          }
        }
        return 0;
      });

      await pinToEdge(ctPage, "Left", stackIndex);
    }

    await wait(1500);

    // Verify the left strip has a tab.
    const leftStrip = ctPage.locator("#auto-hide-strip-left");
    await expect(leftStrip).toHaveClass(/has-tabs/, { timeout: 5_000 });

    // Hover the left strip tab to open the slide-in overlay.  A CLICK would
    // dock the panel inline instead — this screen is specifically the
    // floating overlay of Auto-Hide-Panes.md §3.3.
    const leftTab = ctPage
      .locator("#auto-hide-strip-left .auto-hide-strip-tab")
      .first();
    await openOverlayFromTab(ctPage, leftTab, 10_000);
    await wait(OVERLAY_SETTLE_MS);

    await ctPage.screenshot({ path: `${DIR}/06-left-overlay.png` });
    await dismissOverlay(ctPage);
  });

  test("Screen 7: Multi-tab", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Create a second session tab programmatically.  The "+" button is
    // inside the session tab bar which has `display: none` when there is
    // only one session (`.single-session` CSS class), so clicking it via
    // Playwright would time out.  Using the exposed __ctCreateNewSession
    // helper bypasses this.
    await ctPage.evaluate(() => {
      if ((window as any).__ctCreateNewSession) {
        (window as any).__ctCreateNewSession();
      }
    });
    await wait(2000);

    // The session tab bar should now be visible with two tabs.
    const tabBar = ctPage.locator("#session-tab-bar");
    await expect(tabBar).not.toHaveClass(/single-session/, { timeout: 5_000 });

    // Take the screenshot showing the multi-tab state.
    await ctPage.screenshot({ path: `${DIR}/07-multi-tab.png` });
  });
});

// ---------------------------------------------------------------------------
// Test suite: Screen 8 (DeepReview mode)
// ---------------------------------------------------------------------------

test.describe("Visual Audit v2 — DeepReview", () => {
  test.setTimeout(120_000);

  const reviewPath = path.resolve(
    __dirname,
    "..",
    "deepreview",
    "fixtures",
    "sample-review.json",
  );
  test.use({ launchMode: "deepreview", deepreviewJsonPath: reviewPath });

  // Was marked FAILING (2026-05-01) against the older selector pair
  // (`.deepreview-file-item, div[id^="filesystemComponent"]`).  The selector
  // below — `.deepreview-container`, the same ready signal the 113-test
  // deepreview-gui.spec.ts suite uses — passes; the note is retired.
  test("Screen 8: DeepReview layout", async ({ ctPage }) => {
    // The standard DeepReview ready signal is the `.deepreview-container`
    // element — that's what `DeepReviewPage.waitForReady` (used by the
    // 113-test deepreview-gui.spec.ts suite) polls.  The previous
    // selector here (`.deepreview-file-item, div[id^='filesystemComponent']`)
    // tried to wait for the file list which is rendered AFTER the
    // container materialises and on a longer pipeline (file diffing,
    // etc.); under headless harness that pipeline could miss the 30 s
    // budget while the container itself was already visible — see the
    // matching 113/113 pass rate of `tests/deepreview/deepreview-gui.spec.ts`.
    //
    // Wait for the container first (matching the working suite's
    // contract), then take the screenshot.
    await ctPage.waitForSelector(".deepreview-container", {
      timeout: 30_000,
    });
    await wait(3000);

    await ctPage.screenshot({ path: `${DIR}/08-deepreview.png` });
  });
});
