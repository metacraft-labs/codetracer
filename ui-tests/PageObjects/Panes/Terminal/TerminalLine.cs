using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.Terminal;

/// <summary>
/// Represents a single rendered line inside the terminal output pane.
/// </summary>
public class TerminalLine
{
    private readonly ILocator _root;

    public TerminalLine(ILocator root)
    {
        _root = root ?? throw new ArgumentNullException(nameof(root));
    }

    /// <summary>
    /// Locator of the terminal line container.
    /// </summary>
    public ILocator Root => _root;

    private ILocator StateContainer()
        => _root.Locator("> div").First;

    /// <summary>
    /// Zero-based identifier extracted from the line DOM id.
    /// </summary>
    public async Task<int> LineIndexAsync()
    {
        var idAttr = await _root.GetAttributeAsync("id");
        if (idAttr is null)
        {
            return -1;
        }

        var suffix = idAttr.Split('-').LastOrDefault();
        return int.TryParse(suffix, out var index) ? index : -1;
    }

    /// <summary>
    /// Returns the current temporal state (past, active, future) inferred from CSS classes.
    /// </summary>
    public async Task<string> StateAsync()
    {
        var classAttr = await StateContainer().GetAttributeAsync("class") ?? string.Empty;
        return classAttr.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? string.Empty;
    }

    /// <summary>
    /// Indicates whether the line is styled as grayed-out (future output).
    /// </summary>
    public async Task<bool> IsGrayedOutAsync()
    {
        var state = await StateAsync();
        return string.Equals(state, "future", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Extracts the textual content of the line.
    /// </summary>
    public async Task<string> TextAsync()
    {
        var text = await _root.InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Clicks the terminal line using the specified mouse button.
    /// </summary>
    public Task ClickAsync(MouseButton button = MouseButton.Left)
        => _root.ClickAsync(new() { Button = button });
}
