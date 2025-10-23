using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.Editor;

/// <summary>
/// Represents a single flow value rendered alongside the editor.
/// </summary>
public class FlowValue
{
    private static readonly string[] DefaultContextMenuEntries =
    {
        "Jump to value",
        "Add value to scratchpad",
        "Add all values to scratchpad"
    };

    private readonly ILocator _root;
    private readonly ContextMenu _contextMenu;

    public FlowValue(ILocator root, ContextMenu contextMenu)
    {
        _root = root ?? throw new ArgumentNullException(nameof(root));
        _contextMenu = contextMenu ?? throw new ArgumentNullException(nameof(contextMenu));
    }

    /// <summary>
    /// Root locator (the value box span element).
    /// </summary>
    public ILocator Root => _root;

    /// <summary>
    /// Friendly name associated with the flow value (if rendered).
    /// </summary>
    public async Task<string> NameAsync()
    {
        var nameLocator = _root.Locator("xpath=preceding-sibling::span[contains(@class,'value-name')]" );
        if (await nameLocator.CountAsync() > 0)
        {
            var text = await nameLocator.Last.InnerTextAsync();
            return text?.TrimEnd(':').Trim() ?? string.Empty;
        }

        var fallback = await _root.GetAttributeAsync("data-expression");
        return fallback ?? string.Empty;
    }

    /// <summary>
    /// Textual representation of the value.
    /// </summary>
    public async Task<string> ValueTextAsync()
    {
        var text = await _root.InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Returns the expected context menu entries for a flow value.
    /// </summary>
    public IReadOnlyList<string> ExpectedContextMenuEntries => DefaultContextMenuEntries;

    /// <summary>
    /// Opens the context menu for this flow value.
    /// </summary>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        await _root.ClickAsync(new() { Button = MouseButton.Right });
        await _contextMenu.WaitForVisibleAsync();
        return _contextMenu;
    }

    /// <summary>
    /// Reads the available context menu entries.
    /// </summary>
    public async Task<IReadOnlyList<string>> ContextMenuEntriesAsync()
    {
        var menu = await OpenContextMenuAsync();
        var entries = await menu.GetEntriesAsync();
        await menu.DismissAsync();
        return entries.Select(e => e.Text).ToList();
    }

    /// <summary>
    /// Selects a specific context menu option.
    /// </summary>
    public async Task SelectContextMenuOptionAsync(string option)
    {
        var menu = await OpenContextMenuAsync();
        await menu.SelectAsync(option);
    }
}
