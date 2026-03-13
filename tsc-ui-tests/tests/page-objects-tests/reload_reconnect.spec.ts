import {
  test,
  expect,
} from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

// Record/replay a known program before the suite.
// Use browser mode (ct host + chromium) since this test exercises browser reload.
test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });
test.setTimeout(120_000);

test("browser reload rebinds IPC and keeps UI responsive", async ({ ctPage }) => {
  const layout = new LayoutPage(ctPage);
  await layout.waitForAllComponentsLoaded();

  const initialLogs = await layout.eventLogTabs(true);
  expect(initialLogs.length).toBeGreaterThan(0);

  // Reload the browser page (forces a fresh socket.io connection).
  await ctPage.reload();

  // After reload, create a fresh LayoutPage and wait for components to reload.
  const reloadedLayout = new LayoutPage(ctPage);
  await reloadedLayout.waitForAllComponentsLoaded();

  const afterReloadLogs = await reloadedLayout.eventLogTabs(true);
  expect(afterReloadLogs.length).toBeGreaterThan(0);

  const rows = await afterReloadLogs[0].eventElements(true);
  expect(rows.length).toBeGreaterThan(0);
});
