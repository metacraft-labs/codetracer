import { test, expect } from "@playwright/test";
import {
  page,
  readyOnEntryTest as readyOnEntry,
  loadedEventLog,
  ctRun,
} from "../../lib/ct_helpers";
import { LayoutPage } from "../../page-objects/layout_page";

// Drive ct host/browser mode instead of Electron for this test.
process.env.CODETRACER_TEST_IN_BROWSER = "1";

// Record/replay a known program before the suite.
ctRun("noir_space_ship/");

test("browser reload rebinds IPC and keeps UI responsive", async () => {
  await readyOnEntry();

  const layout = new LayoutPage(page);
  const initialLogs = await layout.eventLogTabs(true);
  expect(initialLogs.length).toBeGreaterThan(0);

  // Reload the browser page (forces a fresh socket.io connection).
  await page.reload();
  await loadedEventLog();

  const afterReloadLogs = await layout.eventLogTabs(true);
  expect(afterReloadLogs.length).toBeGreaterThan(0);

  const rows = await afterReloadLogs[0].eventElements(true);
  expect(rows.length).toBeGreaterThan(0);
});
