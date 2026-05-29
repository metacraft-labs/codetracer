import * as fs from "node:fs";
import * as path from "node:path";
import { test, expect, loadedEventLog, readyOnEntryTest } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import { TraceLogPanel } from "../../page-objects/panes/editor/trace-log-panel";

test.describe("generate faithful webp animations", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(600_000);

  const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");

  test.describe("omniscience", () => {
    test.use({
      sourcePath: path.resolve(repoRoot, "examples", "noir_test"),
      launchMode: "trace",
      deploymentMode: "web",
    });

    test("capture omniscience animation", async ({ ctPage }) => {
      ctPage.on("console", msg => console.log(`[BROWSER] ${msg.type()}: ${msg.text()}`));
      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await layout.waitForEditorLoaded();

      // Switch to inline flow mode using robust evaluation
      await ctPage.evaluate(() => {
        const d = (window as any).data;
        if (!d) return;
        d.config.flow.ui = "inline";
        d.config.flow.realFlowUI = 1; // FlowInline
        const switchFlowUI = (value: unknown) => {
          if (typeof value !== "object" || value === null) return;
          const candidate = value as { switchFlowUI?: unknown };
          if (typeof candidate.switchFlowUI === "function") {
            candidate.switchFlowUI(1);
          }
        };
        // Trigger redraw
        if (d.ui && d.ui.componentMapping) {
            for (const group of d.ui.componentMapping) {
                if (!group) continue;
                for (const comp of Object.values(group)) {
                    if (!comp) continue;
                    // Switch UI for any component that supports it
                    for (const key of Object.keys(comp)) {
                        switchFlowUI((comp as Record<string, unknown>)[key]);
                    }
                    switchFlowUI(comp);
                }
            }
        }
      });
      await ctPage.waitForTimeout(2000);

      // Step forward to enter the loop context using F11 (Step Into)
      for (let i = 0; i < 15; i++) {
        await ctPage.keyboard.press("F11");
        await ctPage.waitForTimeout(1000);
      }

      // Mimic stepping through the loop
      for (let i = 0; i < 5; i++) {
        await ctPage.keyboard.press("F10");
        await ctPage.waitForTimeout(1000);
      }
    });
  });

  test.describe("tracepoint", () => {
    test.use({
      sourcePath: path.resolve(repoRoot, "examples", "noir_test"),
      launchMode: "trace",
    });

    test("capture tracepoint animation", async ({ ctPage }) => {
      /**
       * A left-click on the Monaco gutter sets a *breakpoint*, not a
       * tracepoint (see `lineActionClick` in src/frontend/ui/editor.nim).
       * Tracepoints are created through `toggleTrace` — exposed to tests as
       * the `window.toggleTracepoint` helper and wrapped by the editor
       * page object's `openTrace`.  `toggleTrace` mounts an inline trace
       * view-zone in the editor (the `.trace` panel keyed
       * `#edit-trace-<id>-<line>`), NOT a separate "TRACEPOINT" GoldenLayout
       * tab — so the proof a tracepoint was set is that the inline
       * `TraceLogPanel` becomes visible.
       */
      await readyOnEntryTest(ctPage);

      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await layout.waitForEditorLoaded();

      // The noir flow recording's entry source is `main.nr`; select that
      // editor explicitly rather than relying on tab ordering.
      let editor: Awaited<ReturnType<typeof layout.editorTabs>>[number] | undefined;
      await retry(async () => {
        const tabs = await layout.editorTabs();
        editor = tabs.find((t) =>
          t.tabButtonText.toLowerCase().includes("main.nr"),
        ) ?? tabs[0];
        return editor !== undefined;
      }, { maxAttempts: 60, delayMs: 1000 });
      await editor!.clickTab();
      await expect(editor!.root.locator(".monaco-editor")).toBeVisible({
        timeout: 30_000,
      });

      // Set a tracepoint on line 14 (`println(i + 1)` inside the loop) via
      // the supported tracepoint API and confirm its inline trace panel
      // mounted.
      const traceLine = 14;
      await editor!.openTrace(traceLine);
      const tracePanel = new TraceLogPanel(editor!, traceLine);
      await tracePanel.root.waitFor({ state: "visible", timeout: 30_000 });
      await ctPage.waitForTimeout(2000);
    });
  });

  test.describe("calltrace", () => {
    test.use({
      sourcePath: path.resolve(repoRoot, "examples", "zk_dungeon2"),
      launchMode: "trace",
      deploymentMode: "web",
    });

    test("capture calltrace animation", async ({ ctPage }) => {
      await ctPage.locator(".location-path").waitFor({ state: "visible", timeout: 60_000 });
      await ctPage.locator(".location-path").click();

      await ctPage.locator(".lm_tab", { hasText: "CALLTRACE" }).click();
      await ctPage.waitForTimeout(1000);

      // Expand call nodes
      const expandIcons = ctPage.locator(".toggle-call");
      if (await expandIcons.first().isVisible()) {
        await expandIcons.first().click();
        await ctPage.waitForTimeout(500);
        await expandIcons.nth(1).click();
        await ctPage.waitForTimeout(1000);
      }

      // Search in calltrace
      const search = ctPage.locator(".calltrace-search-input");
      await search.fill("safe");
      await ctPage.waitForTimeout(2000);
    });
  });

  test.describe("state-and-history", () => {
    test.use({
      sourcePath: path.resolve(repoRoot, "examples", "noir_nested_loops_test"),
      launchMode: "trace",
    });

    test("capture state-and-history animation", async ({ ctPage }) => {
      /**
       * TODO: Faithfully recreate state-and-history.webp.
       *
       * Challenge: This animation needs to capture the user's focus shifting between
       * variable updates in the STATE panel and custom expressions in the SCRATCHPAD.
       *
       * Recommended approach:
       * 1. Perform a more complex sequence of steps (F10/F11) that specifically
       *    triggers interesting variable transitions in the selected program.
       * 2. Add an interaction with the loop iteration slider to show history scrubbing.
       * 3. Ensure the SCRATCHPAD is populated with at least one expression before toggling.
       */
      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await layout.waitForEditorLoaded();

      // Step around to show state changes
      for (let i = 0; i < 5; i++) {
        await ctPage.keyboard.press("F10");
        await ctPage.waitForTimeout(800);
      }

      // Toggle tabs
      await ctPage.locator(".lm_tab", { hasText: "STATE" }).click();
      await ctPage.waitForTimeout(1000);
      await ctPage.locator(".lm_tab", { hasText: "SCRATCHPAD" }).click();
      await ctPage.waitForTimeout(1000);
    });
  });

  test.describe("eventlog and terminal", () => {
    test.use({
      sourcePath: path.resolve(repoRoot, "examples", "noir_nested_loops_test"),
      launchMode: "trace",
      deploymentMode: "web",
    });

    test("capture eventlog animation", async ({ ctPage }) => {
      ctPage.on("console", msg => console.log(`[BROWSER] ${msg.type()}: ${msg.text()}`));
      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await layout.waitForEditorLoaded();

      const eventLogTab = ctPage.locator(".lm_tab", { hasText: "EVENT LOG" });
      await eventLogTab.click();
      await ctPage.waitForTimeout(1000);

      const scrollBody = ctPage.locator(".dt-scroll-body");
      await scrollBody.evaluate(el => el.scrollTo({ top: 1000, behavior: 'smooth' }));
      await ctPage.waitForTimeout(2000);
      await scrollBody.evaluate(el => el.scrollTo({ top: 0, behavior: 'smooth' }));
      await ctPage.waitForTimeout(2000);
    });

    test("capture terminal animation", async ({ ctPage }) => {
      ctPage.on("console", msg => console.log(`[BROWSER] ${msg.type()}: ${msg.text()}`));
      const layout = new LayoutPage(ctPage);
      await layout.waitForTraceLoaded();
      await layout.waitForEditorLoaded();

      await ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" }).click();
      await ctPage.waitForTimeout(1000);

      const terminal = ctPage.locator(".isonim-terminal-output pre");
      await terminal.evaluate(el => el.scrollTo({ top: 500, behavior: 'smooth' }));
      await ctPage.waitForTimeout(2000);
    });
  });
});
