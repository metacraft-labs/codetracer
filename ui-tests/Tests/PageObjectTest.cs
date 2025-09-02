using System;
using System.Linq;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UtTestsExperimentalConsoleAppication.PageObjects;
using UtTestsExperimentalConsoleAppication.PageObjects.Models;

namespace UtTestsExperimentalConsoleAppication.Tests;

/// <summary>
/// Test methods exercising the page objects.
/// </summary>
public static class PageObjectTests
{
    /// <summary>
    /// Basic smoke test that traverses the main layout and ensures locators work.
    /// </summary>
    public static async Task PageObjectsSmokeTestAsync(IPage page)
    {
        var layout = new LayoutPage(page);

        await layout.RunToEntryButton().IsVisibleAsync();
        await layout.ContinueButton().IsVisibleAsync();
        await layout.NextButton().IsVisibleAsync();

        var eventModels = new List<EventDataModel>();
        var eventLogs = await layout.EventLogTabsAsync();
        foreach (var tab in eventLogs)
        {
            await tab.IsVisibleAsync();
            var events = await tab.EventElementsAsync();
            foreach (var e in events)
            {
                System.Console.WriteLine(await e.ConsoleOutputAsync());
                await e._root.ClickAsync();
            }
        }

        var stateTabs = await layout.ProgramStateTabsAsync();
        foreach (var tab in stateTabs)
        {
            var vars = await tab.ProgramStateVariablesAsync();
            foreach (var v in vars)
            {
                await v.NameAsync();
                await v.ValueTypeAsync();
                await v.ValueAsync();
            }
        }

        var editors = await layout.EditorTabsAsync();
        foreach (var ed in editors)
        {
            await ed.HighlightedLineNumberAsync();
            await ed.VisibleTextRowsAsync();
        }

        // run extractor as a final step
        await LayoutExtractors.ExtractLayoutPageModelAsync(layout);
    }
}
