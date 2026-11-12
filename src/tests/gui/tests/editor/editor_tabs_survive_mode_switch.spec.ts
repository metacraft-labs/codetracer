/** Ported to the scenarios src/tests/scenarios/editor/tabs-survive-mode-switch.yaml
 * and editor/trace-session-keeps-its-source-editor.yaml; kept for its rejected
 * saved-layout case, which corrupts the saved debug layout in localStorage
 * mid-session (no input path, and no stage reaches the page's storage).
 *
 * Real Electron regression: mode layouts share the session's editor working set.
 * No mocks: files open through Files, transitions use Ctrl+F5 and Stop, and
 * assertions read both GoldenLayout's tabs and the live Monaco instances.
 */
import * as path from "node:path";
import type { Page } from "@playwright/test";
import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { enterDebugMode, stopToEditMode } from "../../lib/mode-switch";

async function snapshot(page: Page) {
  return page.evaluate(() => {
    const data = (globalThis as any).data;
    const tabs: string[] = [];
    const activeTabs: string[] = [];
    const visit = (node: any) => {
      if (node.componentType === "editorComponent") tabs.push(node.componentState.label);
      if (node.type === "stack") {
        const active = node.content[node.activeItemIndex ?? 0];
        if (active?.componentType === "editorComponent") activeTabs.push(active.componentState.label);
      }
      for (const child of node.content ?? []) visit(child);
    };
    const config = data.ui.layout.saveLayout();
    visit(config.root ?? config);
    const active = data.services.editor.active as string;
    const editors = Object.fromEntries(tabs.map((file) => {
      const editor = data.ui.editors[file]?.monacoEditor;
      return [file, {
        editorId: editor?.getId(),
        modelId: editor?.getModel()?.id,
        text: editor?.getModel()?.getValue(),
        selection: editor?.getSelection(),
        scrollTop: editor?.getScrollTop(),
        scrollLeft: editor?.getScrollLeft(),
      }];
    }));
    const editor = data.ui.editors[active]?.monacoEditor;
    const node = editor?.getDomNode();
    const box = node?.getBoundingClientRect();
    const paintedLines = node ? Array.from(node.querySelectorAll(".view-line"))
      .filter((line: any) => {
        const rect = line.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }).length : 0;
    return { tabs, activeTabs, active, editors,
      activePanelAgrees: data.ui.activeEditorPanel === data.ui.editors[active]?.layoutItem?.parent,
      paintedLines, visible: !!node?.isConnected && box.width > 0 && box.height > 0 };
  });
}

async function assertWorkingSet(page: Page, before: Awaited<ReturnType<typeof snapshot>>) {
  await expect.poll(async () => (await snapshot(page)).tabs,
    { message: "the entering layout dropped, reordered or resurrected editor tabs" })
    .toEqual(before.tabs);
  const after = await snapshot(page);
  expect(after.active, "the active source file changed during the layout swap").toBe(before.active);
  expect(after.activeTabs).toEqual(before.activeTabs);
  expect(after.activePanelAgrees, "editor shortcuts point at another stack").toBe(true);
  expect(after.editors, "a layout swap changed a buffer or selection").toEqual(before.editors);
  expect(after.visible, "the active Monaco editor is detached or has no painted box").toBe(true);
  expect(after.paintedLines, "the active source editor has no painted code lines").toBeGreaterThan(0);
}

async function openFile(page: Page, folder: string) {
  const tree = page.locator(".filesystem").first();
  const entry = tree.locator(".jstree-anchor").filter({ hasText: new RegExp(`^${folder}$`) }).first();
  await expect(entry).toBeVisible();
  const parent = entry.locator("..");
  if ((await parent.getAttribute("aria-expanded")) !== "true") {
    await parent.locator(":scope > .jstree-ocl").click();
  }
  await parent.locator(".jstree-anchor").filter({ hasText: /^main\.py$/ }).first().click();
  await expect.poll(async () => (await snapshot(page)).active).toContain(`${folder}/main.py`);
}

test.describe("An edit session keeps its open editor tabs across modes", () => {
  test.use({ launchMode: "edit", deploymentMode: "electron",
    editFolderPath: path.join(codetracerInstallDir, "test-programs") });
  test.setTimeout(0);

  test("a rejected saved layout falls back with the same editor working set", async ({ ctPage }) => {
    await expect(ctPage.locator(".view-line").first()).toBeVisible();
    await openFile(ctPage, "calc");
    const before = await snapshot(ctPage);
    await ctPage.evaluate(() => {
      const data = (globalThis as any).data;
      const saved = data.ui.layoutConfig.fromResolved(data.ui.layout.saveLayout());
      const breakStack = (node: any): boolean => {
        if (node.type === "stack" && node.content.every((item: any) =>
          item.componentType !== "editorComponent")) {
          node.activeItemIndex = 999;
          return true;
        }
        return (node.content ?? []).some(breakStack);
      };
      if (!breakStack(saved.root)) throw new Error("no auxiliary stack to corrupt");
      data.ui.modeLayouts[0] = null;
      localStorage.setItem("CODETRACER_MODE_LAYOUT_DEBUG", JSON.stringify(saved));
    });
    await enterDebugMode(ctPage);
    await assertWorkingSet(ctPage, before);
    await expect(ctPage.getByText(/debug layout could not be restored and was reset/).first())
      .toBeVisible();
    await stopToEditMode(ctPage);
    await assertWorkingSet(ctPage, before);
  });
});
