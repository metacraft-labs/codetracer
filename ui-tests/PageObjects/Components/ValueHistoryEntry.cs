using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Components;

/// <summary>
/// Represents a single entry in a value history timeline.
/// </summary>
public class ValueHistoryEntry
{
    private readonly ILocator _root;
    private readonly ContextMenu _contextMenu;

    public ValueHistoryEntry(ILocator root, ContextMenu contextMenu)
    {
        _root = root ?? throw new ArgumentNullException(nameof(root));
        _contextMenu = contextMenu ?? throw new ArgumentNullException(nameof(contextMenu));
    }

    public ILocator Root => _root;

    /// <summary>
    /// Returns the value text rendered in the entry.
    /// </summary>
    public async Task<string> ValueTextAsync()
    {
        var text = await _root.InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Opens the context menu for this history entry.
    /// </summary>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        await _root.ClickAsync(new() { Button = MouseButton.Right });
        await _contextMenu.WaitForVisibleAsync();
        return _contextMenu;
    }

    /// <summary>
    /// Retrieves the visible context menu entries.
    /// </summary>
    public async Task<IReadOnlyList<string>> ContextMenuEntriesAsync()
    {
        var menu = await OpenContextMenuAsync();
        var entries = await menu.GetEntriesAsync();
        await menu.DismissAsync();
        return entries.Select(e => e.Text).ToList();
    }

    /// <summary>
    /// Selects the "Add to scratchpad" option.
    /// </summary>
    public async Task AddToScratchpadAsync()
    {
        var menu = await OpenContextMenuAsync();
        await menu.SelectAsync("Add to scratchpad");
    }
}
