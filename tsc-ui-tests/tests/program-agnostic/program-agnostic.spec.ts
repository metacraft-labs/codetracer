/**
 * Port of ui-tests/Tests/ProgramAgnostic/ProgramAgnosticTests.cs
 *
 * Program-agnostic tests that work across any traced program.
 * Uses the noir_space_ship trace as the default test subject.
 *
 * Only ViewMenuOpensEventLogAndScratchpad is currently active in the C#
 * test registry. The remaining tests are marked test.skip because the C#
 * suite also has them commented out (keyboard emulation issues across
 * Electron and Web runtimes).
 */

import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test.describe("ProgramAgnostic", () => {
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  test("view menu opens event log and scratchpad", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Verify Event Log component exists
    const eventLogs = await layout.eventLogTabs(true);
    expect(eventLogs.length).toBeGreaterThan(0);
    const eventLog = eventLogs[0];

    // Click on Event Log tab button to ensure it's selected
    await eventLog.tabButton().click();
    expect(await eventLog.isVisible()).toBe(true);

    // Verify Event Log has loaded content (not just an empty container)
    await retry(async () => {
      const rows = await eventLog.root
        .locator("table.dataTable tbody tr")
        .count();
      return rows > 0;
    });

    // Verify Scratchpad component exists
    const scratchpads = await layout.scratchpadTabs(true);
    expect(scratchpads.length).toBeGreaterThan(0);
    const scratchpad = scratchpads[0];

    // Click on Scratchpad tab button to make it visible
    await scratchpad.tabButton().click();

    // Verify we can switch back to Event Log
    await eventLog.tabButton().click();
    expect(await eventLog.isVisible()).toBe(true);
  });

  test.skip("command palette switch theme updates styles", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const palette = new CommandPalette(ctPage);
    await palette.open();
    await palette.executeCommand("Mac Classic Theme");

    await retry(async () => {
      const theme =
        (await ctPage.evaluate(
          "() => document.querySelector('#theme')?.dataset?.theme ?? ''",
        )) ?? "";
      return (theme as string).toLowerCase() === "mac_classic";
    });

    await palette.open();
    await palette.executeCommand("Default Dark Theme");

    await retry(async () => {
      const theme =
        (await ctPage.evaluate(
          "() => document.querySelector('#theme')?.dataset?.theme ?? ''",
        )) ?? "";
      return (theme as string).toLowerCase() === "default_dark";
    });
  });

  test.skip("command palette find symbol uses fuzzy search", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const palette = new CommandPalette(ctPage);
    await palette.open();
    await palette.executeSymbolSearch("iterate_asteroids");

    await retry(async () => {
      const editors = await layout.editorTabs(true);
      const shieldEditor = editors.find((e) =>
        e.tabButtonText.toLowerCase().includes("shield.nr"),
      );
      if (!shieldEditor) return false;
      const activeLine = await shieldEditor.activeLineNumber();
      return activeLine === 1;
    });
  });

  test.skip(
    "debugger controls step buttons reflect busy state",
    async ({ ctPage }) => {
      const layout = new LayoutPage(ctPage);
      await layout.waitForAllComponentsLoaded();

      await layout.nextButton().click();

      await retry(async () => {
        const text = await layout.operationStatus().innerText();
        return text.toLowerCase().includes("busy");
      });

      await retry(async () => {
        const text = await layout.operationStatus().innerText();
        return text.toLowerCase().includes("ready");
      });
    },
  );

  test.skip("event log filter trace vs recorded", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const eventLog = (await layout.eventLogTabs())[0];
    await eventLog.tabButton().click();

    const baselineCount = await eventLog.rowCount();
    expect(baselineCount).toBeGreaterThan(0);

    await eventLog.activateTraceEventsFilter();
    await sleep(300);
    const traceCount = await eventLog.rowCount();

    await eventLog.activateRecordedEventsFilter();
    await sleep(300);
    const recordedCount = await eventLog.rowCount();

    expect(recordedCount).toBeGreaterThanOrEqual(baselineCount);
    expect(traceCount).toBeLessThanOrEqual(recordedCount);
  });

  test.skip("editor shortcuts ctrl+f8 ctrl+f11", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const mainEditor = (await layout.editorTabs()).find((e) =>
      e.tabButtonText.toLowerCase().includes("src/main.nr"),
    );
    expect(mainEditor).toBeDefined();
    await mainEditor!.tabButton().click();

    await ctPage.keyboard.press("Control+F8");

    await retry(async () => {
      const line = await mainEditor!.activeLineNumber();
      return line !== null && line > 0;
    });

    const shieldEditor = (await layout.editorTabs(true)).find((e) =>
      e.tabButtonText.toLowerCase().includes("shield.nr"),
    );
    expect(shieldEditor).toBeDefined();
    await shieldEditor!.tabButton().click();

    await ctPage.keyboard.press("Control+F11");

    await retry(async () => {
      const line = await mainEditor!.activeLineNumber();
      return line === 1;
    });
  });
});
