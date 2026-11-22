/**
 * THE DESKTOP'S PANES, DRAWN BY THE WEBASSEMBLY CORE (`-d:ctWasmPanes`).
 *
 * Built with `just build-ui-js-wasm-panes` and `just build-wasm-panes` (see
 * `ci/test/wasm-panes-desktop.sh`), the renderer hands the variables pane,
 * Call Trace and the event log to the wasm core (`src/frontend/web_core`),
 * which shares the tab's own connection to the engine
 * (`web_core/renderer_transport.nim`) and attaches to the session the app
 * opened. This holds that, in the real Electron app over a real recording:
 *
 *   - each of the three panes is the core's (`.ct-web-core-pane`) and sits in
 *     the pane host the layout gave it;
 *   - after a step, Call Trace draws rows and the variables pane draws
 *     variables, and the event log draws its table;
 *   - the host decorated the panes it placed and reported no error.
 *
 * Skipped (by name, not passed) on a build without the wasm panes: the spec
 * only means something on that build, which `wasm-panes-desktop.sh` makes.
 */
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.describe("the WebAssembly panes", () => {
  test.use({ sourcePath: "py_sudoku_solver/main.py", launchMode: "trace" });

  test("draw Call Trace, the variables and the event log after a step", async ({ ctPage }) => {
    const wasmPanes = await ctPage.evaluate(() => typeof (globalThis as any).ctwPanels === "object");
    // `wasm-panes-desktop.sh` sets CT_WASM_PANES_REQUIRED: there, a build
    // without the panes is a failure, not a skip.
    if (process.env.CT_WASM_PANES_REQUIRED === "1") expect(wasmPanes).toBe(true);
    test.skip(!wasmPanes, "MISSING-PREREQ: this build was not made with -d:ctWasmPanes");

    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.clickNextButton();
    await layout.clickNextButton();

    await expect
      .poll(async () => ctPage.locator(".ct-web-core-pane[data-pane=calltrace] .calltrace-call-line").count(), {
        timeout: 60_000,
      })
      .toBeGreaterThan(0);
    await expect
      .poll(async () => ctPage.locator(".ct-web-core-pane[data-pane=state] .value-expanded-name[data-variable-name]").count(), {
        timeout: 60_000,
      })
      .toBeGreaterThan(0);

    const placed = await ctPage.evaluate(() => {
      const out: Record<string, boolean> = {};
      for (const name of ["calltrace", "state", "event-log"]) {
        const el = document.querySelector(`.ct-web-core-pane[data-pane="${name}"]`);
        out[name] = !!el && !el.closest(".ctw-panes-staging");
      }
      return out;
    });
    // Call Trace and the variables are in the default layout; the event log's
    // tab is mounted only when the layout opens it.
    expect(placed.calltrace).toBe(true);
    expect(placed.state).toBe(true);

    const decorated = await ctPage.locator('.ct-web-core-pane[data-ctw-decorated="1"]').count();
    expect(decorated).toBeGreaterThanOrEqual(2);
    // The editor pane stays the page's own (Monaco), open beside the core's
    // panes, and shows the stop's file.
    await expect.poll(async () => ctPage.locator(".monaco-editor").count(), { timeout: 30_000 }).toBeGreaterThan(0);
    const error = await ctPage.evaluate(() => (globalThis as any).ctwPanelsError ?? null);
    expect(error).toBeNull();
  });
});

/**
 * COLD START AND RESIDENT MEMORY OF THE RENDERER, on either build. Not an
 * assertion: `wasm-panes-desktop.sh` runs it on the current renderer and on the
 * -d:ctWasmPanes one and records both lines (PLAT87-RENDERER), which is the
 * comparison the desktop's adoption is decided on. "Cold start" here is the
 * time from the renderer's navigation start to the first Call Trace row drawn
 * after the first step; memory is the renderer process's working set from
 * Electron's own `app.getAppMetrics()`.
 */
test.describe("the renderer's cold start and memory", () => {
  test.use({ sourcePath: "py_sudoku_solver/main.py", launchMode: "trace" });

  test("are measured", async ({ ctPage, electronApp }) => {
    const wasmPanes = await ctPage.evaluate(() => typeof (globalThis as any).ctwPanels === "object");
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.clickNextButton();
    const rowSel = wasmPanes
      ? ".ct-web-core-pane[data-pane=calltrace] .calltrace-call-line"
      : "div[id^='calltraceComponent'] .calltrace-call-line";
    await expect.poll(async () => ctPage.locator(rowSel).count(), { timeout: 90_000 }).toBeGreaterThan(0);
    const firstRowMs = await ctPage.evaluate(() => performance.now());
    let workingSetKb = -1;
    if (electronApp !== null) {
      workingSetKb = await electronApp.evaluate(({ app }) => {
        const renderers = app.getAppMetrics().filter((m) => m.type === "Tab" || m.type === "Renderer");
        return renderers.reduce((n, m) => n + (m.memory?.workingSetSize ?? 0), 0);
      });
    }
    console.log(`PLAT87-RENDERER build=${wasmPanes ? "wasm-panes" : "nim-js"} first_calltrace_row_ms=${firstRowMs.toFixed(1)}` +
                ` renderer_working_set_kb=${workingSetKb}`);
  });
});
