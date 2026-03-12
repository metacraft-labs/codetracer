import {
  test,
  expect,
  readyOnEntryTest as readyOnEntry,
  loadedEventLog,
} from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout_page";

// Record/replay a known program before the suite.
// Use browser mode (ct host + chromium) since this test exercises browser reload.
test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });

test("browser reload rebinds IPC and keeps UI responsive", async ({ ctPage }) => {
  await readyOnEntry(ctPage);

  const layout = new LayoutPage(ctPage);
  const initialLogs = await layout.eventLogTabs(true);
  expect(initialLogs.length).toBeGreaterThan(0);

  // Reload the browser page (forces a fresh socket.io connection).
  await ctPage.reload();
  await loadedEventLog(ctPage);

  const afterReloadLogs = await layout.eventLogTabs(true);
  expect(afterReloadLogs.length).toBeGreaterThan(0);

  const rows = await afterReloadLogs[0].eventElements(true);
  expect(rows.length).toBeGreaterThan(0);
});
