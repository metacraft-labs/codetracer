using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.Utils;
using UiTests.Tests;

public static class NoirSpaceShipTests
{
    /// <summary>
    /// Ensure the Noir Space Ship example opens an editor tab titled "src/main.nr".
    /// </summary>
    public static async Task EditorLoadedMainNrFile(IPage page)
    {    
        var layout = new LayoutPage(page);

        await layout.WaitForAllComponentsLoadedAsync();
        
        var editors = await layout.EditorTabsAsync();
        
        if (!editors.Any(e => e.TabButtonText == "src/main.nr"))
        {
            throw new Exception("Expected editor tab 'src/main.nr' not found.");
        }
    }

    public static async Task JumpToAllEvents(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var eventLogs = await layout.EventLogTabsAsync();
        foreach (var tab in eventLogs)
        {
            if (!await tab.IsVisibleAsync()) { continue; }

            var events = (await tab.EventElementsAsync()).ToList();
            if (!await EventsInExpectedState(events, -1))
            {
                throw new FailedTestException("Events were expected to be greyed out initially.");
            }

            for (int i = 0; i < events.Count; i++)
            {
                await events[i]._root.ClickAsync();
                await RetryHelpers.RetryAsync(async () =>
                    (await events[i]._root.GetAttributeAsync("class"))?.Contains("active") == true);

                if (!await EventsInExpectedState(events, i))
                {
                    throw new FailedTestException($"Event state mismatch after jumping to index {i}.");
                }
            }
        }
    }

    private static async Task<bool> EventsInExpectedState(IReadOnlyList<EventRow> events, int currentIndex)
    {
        for (int i = 0; i < events.Count; i++)
        {
            var classes = await events[i]._root.GetAttributeAsync("class") ?? string.Empty;
            var opacityStr = await events[i]._root.EvaluateAsync<string>("el => window.getComputedStyle(el).opacity");
            var opacity = double.Parse(opacityStr, CultureInfo.InvariantCulture);

            if (currentIndex < 0)
            {
                if (!classes.Contains("future") || opacity >= 1) return false;
            }
            else if (i < currentIndex)
            {
                if (!classes.Contains("past") || opacity < 1) return false;
            }
            else if (i == currentIndex)
            {
                if (!classes.Contains("active") || opacity < 1) return false;
            }
            else
            {
                if (!classes.Contains("future") || opacity >= 1) return false;
            }
        }

        return true;
    }
}