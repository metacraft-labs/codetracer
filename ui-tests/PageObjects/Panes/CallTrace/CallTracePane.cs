using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Pane representing the call trace view.
/// </summary>
public class CallTracePane : TabObject
{
    public CallTracePane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    public async Task<IReadOnlyList<CallTraceRecord>> RecordsAsync()
    {
        var locators = await Root.Locator("tbody tr").AllAsync();
        return locators.Select(l => new CallTraceRecord(l)).ToList();
    }
}
