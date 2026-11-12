/**
 * A source opened from the Files pane opens under the path the recording
 * names it by, and becomes the active editor (Filesystem-Pane.md, "Opening a
 * file").
 *
 * The tree of a recording is rooted in the sources the recording carries
 * (`files/src/...`, GitHub #785), so its entries are RELATIVE: `src/shield.nr`.
 * Every step, breakpoint and move names the file by its absolute path under
 * the recording's workdir. The pane used to open the tree's relative path: the
 * new tab was keyed `src/shield.nr`, a breakpoint pressed into it was set on a
 * path no step has, and the stop's editor (`main.nr`) stayed the active one.
 *
 * Real stack: `ct record` of `noir_space_ship`, the desktop, its replay. Nothing
 * is stubbed.
 */
import { test, expect, readyOnEntryTest as readyOnEntry } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.describe("Files pane opens a recorded source", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  test("a file that is not open opens under the recording's path, as the active editor", async ({
    ctPage,
  }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.waitForFilesystemLoaded();

    // The stop's file names the recording's workdir: `<workdir>/src/main.nr`.
    const entryPath: string = await ctPage.evaluate(
      () => String((window as any).data.services.editor.active ?? ""),
    );
    expect(entryPath, "the entry stop opens main.nr by its absolute path").toMatch(
      /^\/.*\/src\/main\.nr$/,
    );
    const workdirSrc = entryPath.slice(0, -"main.nr".length);

    const filesystem = (await layout.filesystemTabs(true))[0];
    await filesystem.clickTab();
    await filesystem.waitForReady();
    const shield = await filesystem.nodeByPath("source folders", "src", "shield.nr");
    await shield.leftClick();

    const expected = `${workdirSrc}shield.nr`;
    await expect
      .poll(
        () =>
          ctPage.evaluate(() => {
            const d = (window as any).data;
            return {
              active: String(d.services.editor.active ?? ""),
              editors: Object.keys(d.ui.editors ?? {}).filter((k) => k.endsWith("shield.nr")),
            };
          }),
        { timeout: 30_000, message: "shield.nr opens as the active editor, by its recorded path" },
      )
      .toEqual({ active: expected, editors: [expected] });

    // And its tab is the one on screen.
    await expect
      .poll(async () => {
        const editors = await layout.editorTabs(true);
        const tab = editors.find((editor) => editor.fileName === "shield.nr");
        return tab ? await tab.root.isVisible() : false;
      })
      .toBe(true);
  });
});
