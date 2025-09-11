
using Microsoft.Playwright;
using UtTestsExperimentalConsoleAppication.PageObjects;

public static class NoirSpaceShipTests
{
    /// <summary>
    /// Ensure the Noir Space Ship example opens an editor tab titled "src/main.nr".
    /// </summary>
    public static async Task EditorLoadedMainNrFile(IPage page)
    {    
        var layout = new LayoutPage(page);
        var editors = await layout.EditorTabsAsync();
        if (!editors.Any(e => e.TabButtonText == "src/main.nr"))
        {
            throw new Exception("Expected editor tab 'src/main.nr' not found.");
        }
    }

    public static async Task JumpToAllEvents(IPage page)
    {
        var layout = new LayoutPage(page);

        var eventLogs = await layout.EventLogTabsAsync();
        foreach (var tab in eventLogs)
        {
            if (!await tab.IsVisibleAsync()) { continue; }

            var events = await tab.EventElementsAsync();
            foreach (var e in events)
            {
                // jump to an event by clicking on it
                await e._root.ClickAsync();
            }
        }
    }
}