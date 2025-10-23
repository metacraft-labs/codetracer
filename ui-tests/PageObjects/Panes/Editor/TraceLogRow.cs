using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.Editor;

/// <summary>
/// Represents a single trace log table row.
/// </summary>
public class TraceLogRow
{
    private readonly ILocator _root;
    private readonly ContextMenu _contextMenu;

    public TraceLogRow(ILocator root, ContextMenu contextMenu)
    {
        _root = root ?? throw new ArgumentNullException(nameof(root));
        _contextMenu = contextMenu ?? throw new ArgumentNullException(nameof(contextMenu));
    }

    /// <summary>
    /// Root locator for the row.
    /// </summary>
    public ILocator Root => _root;

    /// <summary>
    /// Captures the textual content displayed inside the row.
    /// </summary>
    public async Task<string> TextAsync()
    {
        var text = await _root.InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Opens the context menu for this trace row.
    /// </summary>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        await _root.ClickAsync(new() { Button = MouseButton.Right });
        await _contextMenu.WaitForVisibleAsync();
        return _contextMenu;
    }

    /// <summary>
    /// Returns the currently visible context menu entries.
    /// </summary>
    public async Task<IReadOnlyList<string>> ContextMenuEntriesAsync()
    {
        var menu = await OpenContextMenuAsync();
        var entries = await menu.GetEntriesAsync();
        await menu.DismissAsync();
        return entries.Select(e => e.Text).ToList();
    }

    /// <summary>
    /// Invokes the first context-menu entry (typically adds the value to the scratchpad).
    /// </summary>
    public async Task SelectMenuOptionAsync(string option)
    {
        var menu = await OpenContextMenuAsync();
        await menu.SelectAsync(option);
    }

    /// <summary>
    /// Backwards-compatibility wrapper for existing tests.
    /// </summary>
    public Task SelectContextMenuOptionAsync(string option)
        => SelectMenuOptionAsync(option);
}
