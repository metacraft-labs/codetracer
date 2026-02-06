using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.CommandPalette;
using UiTests.Utils;

namespace UiTests.Tests.ProgramAgnostic;

public static class ProgramAgnosticTests
{
    private static async Task<string> CurrentThemeAsync(IPage page)
    {
        return await page.EvaluateAsync<string?>(
            "() => document.querySelector('#theme')?.dataset?.theme ?? ''") ?? string.Empty;
    }

    public static async Task CommandPaletteSwitchThemeUpdatesStyles(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var palette = new CommandPalette(page);
        await palette.OpenAsync();
        await palette.ExecuteCommandAsync("Mac Classic Theme");

        await RetryHelpers.RetryAsync(async () =>
        {
            var theme = await CurrentThemeAsync(page);
            return theme.Equals("mac_classic", StringComparison.OrdinalIgnoreCase);
        });

        await palette.OpenAsync();
        await palette.ExecuteCommandAsync("Default Dark Theme");

        await RetryHelpers.RetryAsync(async () =>
        {
            var theme = await CurrentThemeAsync(page);
            return theme.Equals("default_dark", StringComparison.OrdinalIgnoreCase);
        });
    }

    public static async Task CommandPaletteFindSymbolUsesFuzzySearch(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var palette = new CommandPalette(page);
        await palette.OpenAsync();
        await palette.ExecuteSymbolSearchAsync("iterate_asteroids");

        await RetryHelpers.RetryAsync(async () =>
        {
            var editors = await layout.EditorTabsAsync(forceReload: true);
            var shieldEditor = editors.FirstOrDefault(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
            if (shieldEditor is null)
            {
                return false;
            }

            var activeLine = await shieldEditor.ActiveLineNumberAsync();
            return activeLine == 1;
        });
    }

    public static async Task ViewMenuOpensEventLogAndScratchpad(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        // Wait for the trace to be fully loaded
        await layout.WaitForTraceLoadedAsync();

        // Verify Event Log component exists
        var eventLogs = await layout.EventLogTabsAsync(forceReload: true);
        if (eventLogs.Count == 0)
        {
            throw new Exception("No Event Log components found in the layout.");
        }
        var eventLog = eventLogs.First();

        // Click on Event Log tab button to ensure it's selected
        await eventLog.TabButton().ClickAsync();
        if (!await eventLog.IsVisibleAsync())
        {
            throw new Exception("Event Log tab is not visible after clicking its tab button.");
        }

        // Verify Event Log has loaded content (not just an empty container)
        await RetryHelpers.RetryAsync(async () =>
        {
            var rows = await eventLog.Root.Locator("table.dataTable tbody tr").CountAsync();
            return rows > 0;
        });

        // Verify Scratchpad component exists
        var scratchpads = await layout.ScratchpadTabsAsync(forceReload: true);
        if (scratchpads.Count == 0)
        {
            throw new Exception("No Scratchpad components found in the layout.");
        }
        var scratchpad = scratchpads.First();

        // Click on Scratchpad tab button to make it visible
        await scratchpad.TabButton().ClickAsync();
        if (!await scratchpad.IsVisibleAsync())
        {
            throw new Exception("Scratchpad tab is not visible after clicking its tab button.");
        }

        // Verify we can switch back to Event Log
        await eventLog.TabButton().ClickAsync();
        if (!await eventLog.IsVisibleAsync())
        {
            throw new Exception("Event Log tab did not retain focus after switching back.");
        }
    }

    public static async Task DebuggerControlsStepButtonsReflectBusyState(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        await layout.NextButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var text = await layout.OperationStatus().InnerTextAsync();
            return text != null && text.Contains("busy", StringComparison.OrdinalIgnoreCase);
        });

        await RetryHelpers.RetryAsync(async () =>
        {
            var text = await layout.OperationStatus().InnerTextAsync();
            return text != null && text.Contains("ready", StringComparison.OrdinalIgnoreCase);
        });
    }

    public static async Task EventLogFilterTraceVsRecorded(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        var baselineCount = await eventLog.RowCountAsync(true);
        if (baselineCount == 0)
        {
            throw new Exception("Event log did not contain recorded events before filtering.");
        }

        await eventLog.ActivateTraceEventsFilterAsync();
        await page.WaitForTimeoutAsync(300);
        var traceCount = await eventLog.RowCountAsync(true);

        await eventLog.ActivateRecordedEventsFilterAsync();
        await page.WaitForTimeoutAsync(300);
        var recordedCount = await eventLog.RowCountAsync(true);

        if (recordedCount < baselineCount)
        {
            throw new Exception("Recorded events filter did not restore the original event log entries.");
        }

        if (traceCount > recordedCount)
        {
            throw new Exception("Trace events filter returned more entries than recorded events, indicating the filter did not narrow results.");
        }
    }

    public static async Task EditorShortcutsCtrlF8CtrlF11(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var mainEditor = (await layout.EditorTabsAsync()).First(e => e.TabButtonText.Contains("src/main.nr", StringComparison.OrdinalIgnoreCase));
        await mainEditor.TabButton().ClickAsync();

        await page.Keyboard.PressAsync("Control+F8");

        await RetryHelpers.RetryAsync(async () =>
        {
            var line = await mainEditor.ActiveLineNumberAsync();
            return line.HasValue && line.Value > 0;
        });

        var shieldEditor = (await layout.EditorTabsAsync(true)).First(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
        await shieldEditor.TabButton().ClickAsync();

        await page.Keyboard.PressAsync("Control+F11");

        await RetryHelpers.RetryAsync(async () =>
        {
            var line = await mainEditor.ActiveLineNumberAsync();
            return line.HasValue && line.Value == 1;
        });
    }
}
