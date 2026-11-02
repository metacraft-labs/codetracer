// Placing the Visual Replay tabs on a layout that is already up.
//
// When a trace finishes loading, `applyVisualReplayTabsToResolvedConfig`
// adds or removes the Visual Replay tabs. If the panes are already built it
// reads the live layout with `saveLayout()` — a RESOLVED config — and loads the
// edited copy back. GoldenLayout's `loadLayout` takes an UNRESOLVED config, so
// handing it the resolved one threw `value.trimStart is not a function` on the
// first size it parsed, and the panes were never rebuilt: a browser against
// `ct host` came up with no editor.
//
// Which order happens depends on how long the replay takes to start, so a
// fast host never reaches the live-layout path. This test reaches it on
// purpose: it waits for the panes, then places the tabs again
// (`window.__ctApplyVisualReplayTabs`), and asserts the layout is rebuilt with
// its panes and nothing threw.
//
// No stand-ins: a real `ct host`, a real replay, a real browser.

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });
test.setTimeout(180_000);

test("placing the Visual Replay tabs on a live layout keeps its panes", async ({ ctPage }) => {
  const layout = new LayoutPage(ctPage);
  await layout.waitForAllComponentsLoaded();

  const pageErrors: string[] = [];
  const layoutErrors: string[] = [];
  ctPage.on("pageerror", (e) => pageErrors.push(e.message));
  ctPage.on("console", (m) => {
    const text = m.text();
    if (text.includes("layout: cannot") || text.includes("GoldenLayout rejected")) {
      layoutErrors.push(text);
    }
  });

  const editorsBefore = await ctPage.locator("div[id^='editorComponent']").count();
  expect(editorsBefore).toBeGreaterThan(0);

  await ctPage.evaluate(() => (window as any).__ctApplyVisualReplayTabs());

  // The rebuilt layout has its panes again.
  await layout.waitForAllComponentsLoaded();
  expect(await ctPage.locator("div[id^='editorComponent']").count()).toBeGreaterThan(0);
  expect(pageErrors).toEqual([]);
  expect(layoutErrors).toEqual([]);
});
