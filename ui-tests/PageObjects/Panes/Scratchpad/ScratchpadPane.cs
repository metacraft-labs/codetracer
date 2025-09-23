using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.PageObjects.Panes.Scratchpad;

/// <summary>
/// Page object for the scratchpad pane that stores user-selected values.
/// </summary>
public class ScratchpadPane : TabObject
{
    private List<ScratchpadValueView> _values = new();

    public ScratchpadPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    public ILocator ValuesContainer => Root.Locator(".value-components-container");

    public async Task<IReadOnlyList<ScratchpadValueView>> ValuesAsync(bool forceReload = false)
    {
        if (forceReload || _values.Count == 0)
        {
            var locators = await ValuesContainer.Locator(".scratchpad-value-view").AllAsync();
            _values = locators.Select(locator => new ScratchpadValueView(locator)).ToList();
        }

        return _values;
    }
}
