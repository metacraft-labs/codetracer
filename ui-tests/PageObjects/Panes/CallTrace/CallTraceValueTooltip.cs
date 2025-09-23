using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Represents the tooltip that appears when expanding argument values.
/// </summary>
public class CallTraceValueTooltip
{
    private readonly ILocator _root;

    public CallTraceValueTooltip(ILocator root)
    {
        _root = root;
    }

    public ILocator Root => _root;

    /// <summary>
    /// Returns the value component views rendered inside the tooltip.
    /// </summary>
    public async Task<IReadOnlyList<ValueComponentView>> ValuesAsync()
    {
        var components = await _root.Locator(":scope > .value-expanded").AllAsync();
        return components.Select(locator => new ValueComponentView(locator)).ToList();
    }
}
