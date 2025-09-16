using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.Editor;
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

    /// <summary>
    /// Creates two tracepoints, executes them, and validates the event and trace logs.
    /// </summary>
    public static async Task CreateSimpleTracePoint(IPage page)
    {
        const int firstLine = 13;
        const int secondLine = 37;
        const string firstMessage = "This is a simple trace point";
        const string secondMessage = "This is another simple trace point";

        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        await Task.Delay(1000);

        var editors = await layout.EditorTabsAsync();
        EditorPane? editor = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            var loadedEditors = await layout.EditorTabsAsync();
            editor = loadedEditors.FirstOrDefault(e => e.TabButtonText == "src/main.nr");
            return editor is not null;
        });

        if (editor is null)
        {
            throw new TimeoutException("Expected editor tab 'src/main.nr' not found.");
        }

        // editor is now safe to use
        await editor.TabButton().ClickAsync();

        await Task.Delay(1000);

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        // await editor.JumpToLineJsAsync(firstLine);
        await editor.OpenTrace(firstLine);
        await Task.Delay(1000);
        
        var firstTracePanel = new TraceLogPanel(editor, firstLine);
        await firstTracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var firstExpression = $"log(\"{firstMessage}\")";
        await firstTracePanel.EditTextBox().FillAsync(firstExpression);

        await editor.RunTracepointsJsAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(true);
            if (events.Count == 0)
            {
                return false;
            }

            var text = await events[0].ConsoleOutputAsync();
            return text.Contains(firstMessage, StringComparison.Ordinal);
        });

        await RetryHelpers.RetryAsync(async () =>
        {
            var rows = await firstTracePanel.EventRowsAsync();
            if (rows.Count == 0)
            {
                return false;
            }

            var text = await rows[0].ConsoleOutputAsync();
            return text.Contains(firstMessage, StringComparison.Ordinal);
        });

        await editor.JumpToLineJsAsync(secondLine);
        await editor.OpenTrace(secondLine);
        var secondTracePanel = new TraceLogPanel(editor, secondLine);
        await secondTracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var secondExpression = $"log(\"{secondMessage}\")";
        await secondTracePanel.EditTextBox().FillAsync(secondExpression);

        await editor.RunTracepointsJsAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(true);
            if (events.Count == 0)
            {
                return false;
            }

            var firstText = await events[0].ConsoleOutputAsync();
            if (!firstText.Contains(firstMessage, StringComparison.Ordinal))
            {
                return false;
            }

            var lastText = await events[^1].ConsoleOutputAsync();
            return lastText.Contains(secondMessage, StringComparison.Ordinal);
        });

        await RetryHelpers.RetryAsync(async () =>
        {
            var firstRows = await firstTracePanel.EventRowsAsync();
            if (firstRows.Count == 0)
            {
                return false;
            }

            var firstTraceText = await firstRows[0].ConsoleOutputAsync();
            if (!firstTraceText.Contains(firstMessage, StringComparison.Ordinal))
            {
                return false;
            }

            var secondRows = await secondTracePanel.EventRowsAsync();
            if (secondRows.Count == 0)
            {
                return false;
            }

            foreach (var row in secondRows)
            {
                var text = await row.ConsoleOutputAsync();
                if (text.Contains(secondMessage, StringComparison.Ordinal))
                {
                    return true;
                }
            }

            return false;
        });
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