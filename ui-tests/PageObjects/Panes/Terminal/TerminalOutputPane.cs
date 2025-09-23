using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.PageObjects.Panes.Terminal;

/// <summary>
/// Page object representing the terminal output component rendered by <c>terminal_output.nim</c>.
/// </summary>
public class TerminalOutputPane : TabObject
{
    private List<TerminalOutputLine> _lines = new();

    public TerminalOutputPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    public ILocator LinesLocator => Root.Locator(".terminal-line");

    public async Task<IReadOnlyList<TerminalOutputLine>> LinesAsync(bool forceReload = false)
    {
        if (forceReload || _lines.Count == 0)
        {
            var locators = await LinesLocator.AllAsync();
            _lines = locators.Select(locator => new TerminalOutputLine(locator)).ToList();
        }

        return _lines;
    }
}
