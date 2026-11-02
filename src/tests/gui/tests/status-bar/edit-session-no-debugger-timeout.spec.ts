/**
 * An edit launch has no replay engine, but still needs its toolbar bound.
 * This exercises the real Electron launch handler: the defect is in ui_js's
 * IPC bootstrap, outside the headless ViewModels. No test doubles are used.
 * Observe the real request liveness interval rather than suppressing errors
 * or replacing DAP: an unsolicited initialize used to expire after 30 s.
 */
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";
import { topbarSurfaceSelector } from "../../page-objects/debug-toolbar-ids";

test.use({
  launchMode: "edit",
  editFolderPath: path.resolve(__dirname, "../../../../../test-programs"),
});

test("edit session keeps its toolbar without a debugger timeout", async ({ ctPage }) => {
  test.setTimeout(90_000);
  await expect(ctPage.locator(topbarSurfaceSelector("editCommands"))).toBeVisible();
  await ctPage.evaluate(() => {
    const status = document.querySelector("#status");
    if (!status) throw new Error("edit session did not mount its status bar");
    const observed: string[] = [status.textContent ?? ""];
    (window as any).__editStatusMessages = observed;
    new MutationObserver(() => observed.push(status.textContent ?? ""))
      .observe(status, { subtree: true, childList: true, characterData: true });
  });
  // This is the product's 30-second DAP liveness timer, plus a margin. A
  // readiness assertion above makes the absence check non-vacuous.
  await ctPage.waitForTimeout(32_000);
  const messages = await ctPage.evaluate(() => (window as any).__editStatusMessages as string[]);
  expect(messages.join("\n")).not.toMatch(/initialize got no answer from the debugger/);
  // Read retained notifications too: slow startup can let the 30-second
  // timer fire before Playwright attaches the DOM observer, and notices
  // can disappear from the strip without leaving this history.
  const history = await ctPage.evaluate(() => {
    const data = (window as any).data;
    const session = data?.sessions?.[data.activeSessionIndex];
    const notifications = session?.ui?.status?.notifications;
    if (!Array.isArray(notifications)) {
      throw new Error("edit session did not expose its notification history");
    }
    return notifications.map((notice: { text: string }) => notice.text);
  });
  expect(history.join("\n")).not.toMatch(/initialize got no answer from the debugger/);
  await expect(ctPage.locator(topbarSurfaceSelector("editCommands"))).toBeVisible();
});
