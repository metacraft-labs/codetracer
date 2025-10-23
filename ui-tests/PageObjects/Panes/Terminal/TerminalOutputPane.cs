using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.PageObjects.Panes.Terminal;

/// <summary>
/// Wraps the terminal output component within the layout.
/// </summary>
public class TerminalOutputPane : TabObject
{
    private List<TerminalLine> _lines = new();

    public TerminalOutputPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    /// <summary>
    /// Locator for the &lt;pre&gt; block containing terminal lines.
    /// </summary>
    public ILocator LinesContainer()
        => Root.Locator("pre");

    /// <summary>
    /// Returns the currently rendered terminal lines.
    /// </summary>
    public async Task<IReadOnlyList<TerminalLine>> LinesAsync(bool forceReload = false)
    {
        if (forceReload || _lines.Count == 0)
        {
            var roots = await LinesContainer().Locator(".terminal-line").AllAsync();
            _lines = roots.Select(locator => new TerminalLine(locator)).ToList();
        }

        return _lines;
    }

    /// <summary>
    /// Provides direct access to a terminal line by index.
    /// </summary>
    public async Task<TerminalLine?> LineByIndexAsync(int index, bool forceReload = false)
    {
        var lines = await LinesAsync(forceReload);
        foreach (var line in lines)
        {
            if (await line.LineIndexAsync() == index)
            {
                return line;
            }
        }

        return null;
    }
}
