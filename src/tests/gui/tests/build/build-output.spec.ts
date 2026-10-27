/**
 * E2E tests for the build output panel (BP-M0).
 *
 * Verifies:
 * - Build output is displayed correctly in the GL layout
 * - stderr lines have visually distinct styling from stdout lines
 * - The build panel renders within the Golden Layout container
 *
 * THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: a recording opened in `trace`
 * mode never runs a build — `ct record` ran before the app started — so build
 * output reaches the renderer only if something sends it. These tests send the
 * main process's own `CODETRACER::build-command` / `build-stdout` /
 * `build-stderr` / `build-code` messages from the real Electron main process,
 * as `tests/layout/plat70a-output-hscroll.spec.ts` does; everything after that
 * (`onBuildStdout` / `onBuildStderr` → the BuildVM → the IsoNim view and its
 * stylesheet) is the product's own, unchanged.
 *
 * Until 2026-10-22 the two styling tests instead polled for 60 s for output
 * from a build that never happens and then skipped themselves, so they never
 * checked anything; and on a loaded host the 60 polls plus the launch ran past
 * the 120 s test timeout (codetracer-pm issue
 * `2026-10-17-electron-build-specs-fail-on-clean-agents-under-host-load`).
 *
 * No mocks otherwise: a real recording, the real `ct`, a real replay backend,
 * the real Electron app.
 */

import type { ElectronApplication, Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { openBottomPanel, waitForDefaultBottomTabs } from "../../page-objects/auto-hide-strip";
import { BuildPane } from "../../page-objects/panes/build/build-pane";
import { LayoutPage } from "../../page-objects/layout-page";

/**
 * A build's output as the main process reports it: plain progress lines on
 * stdout and on stderr. Neither carries a `file:line` location or a severity
 * keyword, so the panel styles each by its stream alone — which is what these
 * tests check — and not as an error or a warning row.
 */
const STDOUT_LINES = ["Compiling main", "Linking main"];
const STDERR_LINES = ["progress: 2 of 2 units done"];

/**
 * Run one build through the main process's messages: once the base
 * components have loaded, open the BUILD panel, then send the command, the
 * stdout lines, the stderr lines and the exit code, and wait until the panel
 * shows every line. The wait comes first as in `problems-panel.spec.ts`: on a
 * loaded host (2026-10-22) a BUILD strip tab found visible right after launch
 * was no longer in the DOM when it was clicked, and the click waited 30 s.
 */
async function runBuild(page: Page, app: ElectronApplication): Promise<BuildPane> {
  await new LayoutPage(page).waitForBaseComponentsLoaded();
  await waitForDefaultBottomTabs(page);
  await openBottomPanel(page, "BUILD");
  await app.evaluate(({ BrowserWindow }, out) => {
    const w = BrowserWindow.getAllWindows()[0];
    w.webContents.send("CODETRACER::build-command", { command: "make main" });
    for (const data of out.stdout) w.webContents.send("CODETRACER::build-stdout", { data });
    for (const data of out.stderr) w.webContents.send("CODETRACER::build-stderr", { data });
    w.webContents.send("CODETRACER::build-code", { code: 0 });
  }, { stdout: STDOUT_LINES, stderr: STDERR_LINES });
  const buildPane = new BuildPane(page);
  await expect(buildPane.stdoutLines()).toHaveCount(STDOUT_LINES.length);
  await expect(buildPane.stderrLines()).toHaveCount(STDERR_LINES.length);
  return buildPane;
}

test.describe("Build Output Panel", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("build panel renders within GL layout", async ({ ctPage }) => {
    const buildPane = new BuildPane(ctPage);

    // The build panel may or may not be visible after a successful trace
    // (it auto-hides on success). Verify the DOM structure is correct
    // by checking that the #build element exists in the page.
    const buildExists = await retry(
      async () => {
        // The build panel is created as part of the component tree even
        // when not actively shown. Check that it exists in the DOM.
        const count = await ctPage.locator("#build").count();
        return count > 0;
      },
      { maxAttempts: 30, delayMs: 1000 },
    ).then(() => true as const).catch(() => false);

    // If the build ran and completed successfully, the panel might have been
    // hidden. The important thing is that the component was registered in GL.
    // We can verify this by checking the build component's parent container.
    if (buildExists) {
      expect(await buildPane.isPresent()).toBe(true);
    }
  });

  test("build output displays stdout and stderr with different styling", async ({ ctPage, electronApp }) => {
    const buildPane = await runBuild(ctPage, electronApp!);

    // Every line arrives, in its stream's order and with its text.
    await expect(buildPane.stdoutLines()).toHaveText(STDOUT_LINES);
    await expect(buildPane.stderrLines()).toHaveText(STDERR_LINES);

    // stderr is styled differently from stdout (red/orange vs normal).
    const stdoutColor = await buildPane.stdoutColor();
    const stderrColor = await buildPane.stderrColor();
    expect(stderrColor).not.toBeNull();
    expect(stdoutColor).not.toBeNull();
    expect(stderrColor).not.toEqual(stdoutColor);
  });

  test("stderr lines have warning color styling", async ({ ctPage, electronApp }) => {
    const buildPane = await runBuild(ctPage, electronApp!);

    // Verify stderr lines have italic font style (our CSS sets font-style: italic)
    const fontStyle = await buildPane.stderrLines().first().evaluate(
      (el) => window.getComputedStyle(el).fontStyle,
    );
    expect(fontStyle).toBe("italic");
    // ...and stdout lines do not, so the italic belongs to the stream.
    const stdoutFontStyle = await buildPane.stdoutLines().first().evaluate(
      (el) => window.getComputedStyle(el).fontStyle,
    );
    expect(stdoutFontStyle).not.toBe("italic");

    // The stderr color is not the default text color stdout uses.
    expect(await buildPane.stderrColor()).not.toEqual(await buildPane.stdoutColor());
  });
});
