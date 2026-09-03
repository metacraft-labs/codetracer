/**
 * THE CODE FONT SURVIVES A MODE SWITCH.
 *
 * Reported against noirstudio.dev: "the font rendering changes across the
 * board when I enter the debug mode and it never recovers (it looks wrong)."
 *
 * It was not the theme. Measured on the shipped build (`1a427e3e`), the
 * `link#theme` stylesheet stayed `default_dark_theme_electron.css` with 2558
 * parsed rules at every moment, `body` kept `SpaceGrotesk` and
 * `-webkit-font-smoothing: antialiased`, and `.lm_tab` had no transformed
 * ancestor. What changed was the EDITOR, which is most of the window:
 *
 *     before Run   .view-line  16px  SpaceMono, monospace, Menlo, ...
 *     after  Run   .view-line  12px  Menlo, Monaco, "Courier New", monospace
 *     after  Stop  .view-line  12px  Menlo, Monaco, "Courier New", monospace
 *
 * and `monaco.editor.getEditors()[0].getOption(fontFamily)` agreed:
 * `"SpaceMono, monospace"` at 16 before, Monaco's own defaults at 12 after.
 *
 * The cause was `setEditorsEditable` handing `updateOptions` a
 * `MonacoEditorOptions(readOnly: ..., minimap: ...)` object literal. A Nim
 * object literal carries every other field at its zero value, so the call
 * that meant "make these editors read-only" also said `fontSize: 0` and
 * `fontFamily: ""`. `editor.nim` already had `monacoEditorSetReadOnly` and a
 * comment explaining this exact hazard; `setEditorsEditable` had not been
 * moved onto the same pattern. Leaving debug mode calls it again, which is
 * the "never recovers" half.
 *
 * THE ASSERTION IS A COMPARISON, NOT A CONSTANT. It requires the font to be
 * the SAME before, during and after — it does not name a family or a size.
 * Changing the default code font stays a legal edit; losing it does not.
 * Naming `SpaceMono` here would also have passed on the broken build for any
 * reader who only checked the first sample.
 */

import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";

const testFolder = path.join(codetracerInstallDir, "test-programs");

type FontSample = { family: string; size: number };

/**
 * Read the editor's effective font from Monaco itself, not from the DOM.
 * Monaco writes `font-family` inline onto its own layers after measuring the
 * face, so the option is the value that actually drove layout.
 */
async function readEditorFont(page: any): Promise<FontSample> {
  await page.waitForFunction(
    () =>
      typeof (globalThis as any).monaco !== "undefined" &&
      (globalThis as any).monaco.editor.getEditors().length > 0,
    { timeout: 60_000 },
  );

  return page.evaluate(() => {
    const m = (globalThis as any).monaco;
    const editor = m.editor.getEditors()[0];
    return {
      family: editor.getOption(m.editor.EditorOption.fontFamily) as string,
      size: editor.getOption(m.editor.EditorOption.fontSize) as number,
    };
  });
}

test.describe("Editor font across a mode switch", () => {
  test.setTimeout(300_000);
  test.use({
    launchMode: "edit",
    editFolderPath: testFolder,
    deploymentMode: "web",
  });

  test("entering and leaving debug mode leaves the code font alone", async ({
    ctPage,
  }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

    const before = await readEditorFont(ctPage);
    expect(before.size, "editor font size is zero before any switch")
      .toBeGreaterThan(0);
    expect(before.family, "editor font family is empty before any switch")
      .not.toEqual("");

    // Enter debug mode.
    await ctPage.locator("#run-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".isonim-debug-controls", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    const during = await readEditorFont(ctPage);
    expect(
      during,
      `entering debug mode changed the code font: ` +
        `${JSON.stringify(before)} -> ${JSON.stringify(during)}`,
    ).toEqual(before);

    // Leave it again. This is the "never recovers" half: the same proc runs
    // on the way out, so a one-way check would miss a fix that only held in
    // one direction.
    await ctPage.locator("#stop-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".edit-mode-toolbar", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    const after = await readEditorFont(ctPage);
    expect(
      after,
      `leaving debug mode did not restore the code font: ` +
        `${JSON.stringify(before)} -> ${JSON.stringify(after)}`,
    ).toEqual(before);
  });
});
