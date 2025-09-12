using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.PageObjects.Panes.VariableState;

/// <summary>
/// Program state pane holding variables and watch expressions.
/// </summary>
public class VariableStatePane : TabObject
{
    private List<VariableStateRecord> _variables = new();

    public VariableStatePane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    public ILocator WatchExpressionTextBox()
        => Root.Locator("#watch");

    public async Task<IReadOnlyList<VariableStateRecord>> ProgramStateVariablesAsync(bool forceReload = false)
    {
        if (forceReload || _variables.Count == 0)
        {
            var locators = await Root.Locator(".value-expanded").AllAsync();
            _variables = locators.Select(l => new VariableStateRecord(l)).ToList();
        }
        return _variables;
    }
}
