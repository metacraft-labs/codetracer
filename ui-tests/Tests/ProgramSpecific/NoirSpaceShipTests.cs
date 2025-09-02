
using Microsoft.Playwright;
using UtTestsExperimentalConsoleAppication.PageObjects;

public static class NoirSpaceShipTests
{
    /// <summary>
    /// Ensure the Noir Space Ship example opens an editor tab titled "src/main.nr".
    /// </summary>
    public static async Task EditorLoadedMainNrFile(IPage page)
    {
        // TODO: write a retry find element function and place it in utils/RetryHelper
        // TODO: use the helper from the previoud comment to create a wait function that confirms that at leas one editor tab is visible, place it it utils/WaitHelper
        // TODO: Call the wait from the preious comment here
        
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
        // TODO: wait until a editor has been found

        var eventLogs = await layout.EventLogTabsAsync();
        foreach (var tab in eventLogs)
        {
            if (!await tab.IsVisibleAsync()) { continue; }

            // check that at first all events are grayed out
            var events = await tab.EventElementsAsync();
            foreach (var e in events)
            {
                // jump to an event by clicking on it
                await e._root.ClickAsync();
            }

            // TODO: check that the current event is not greyed out as well as all before it

            // TODO: check that all events after the current one are still grayed out

            // TODO: throw an FailedTestException if not true
        }
    }
}