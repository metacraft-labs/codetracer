using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Represents a single argument entry within a call trace record.
/// </summary>
public class CallTraceArgument
{
    private static readonly string[] DefaultOptions = { "Add value to scratchpad" };

    private readonly CallTracePane _pane;
    private readonly ILocator _root;
    private readonly ContextMenu _contextMenu;

    public CallTraceArgument(CallTracePane pane, ILocator root, ContextMenu contextMenu)
    {
        _pane = pane ?? throw new ArgumentNullException(nameof(pane));
        _root = root ?? throw new ArgumentNullException(nameof(root));
        _contextMenu = contextMenu ?? throw new ArgumentNullException(nameof(contextMenu));
    }

    /// <summary>
    /// Locator representing the argument container.
    /// </summary>
    public ILocator Root => _root;

    private ILocator NameLocator() => _root.Locator(".call-arg-name");
    private ILocator ValueLocator() => _root.Locator(".call-arg-text");

    /// <summary>
    /// Argument name as displayed in the UI.
    /// </summary>
    public async Task<string> NameAsync()
    {
        var text = await NameLocator().InnerTextAsync();
        return text?.TrimEnd('=').Trim() ?? string.Empty;
    }

    /// <summary>
    /// Value text rendered for the argument.
    /// </summary>
    public async Task<string> ValueAsync()
    {
        var text = await ValueLocator().InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Opens the context menu attached to the argument.
    /// </summary>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        await _root.ClickAsync(new() { Button = MouseButton.Right });
        await _contextMenu.WaitForVisibleAsync();
        return _contextMenu;
    }

    /// <summary>
    /// Reads the context menu entries for the argument.
    /// </summary>
    public async Task<IReadOnlyList<string>> ContextMenuEntriesAsync()
    {
        var menu = await OpenContextMenuAsync();
        var entries = await menu.GetEntriesAsync();
        await menu.DismissAsync();
        return entries.Select(e => e.Text).ToList();
    }

    /// <summary>
    /// Expected argument context menu entries.
    /// </summary>
    public IReadOnlyList<string> ExpectedContextMenuEntries => DefaultOptions;

    /// <summary>
    /// Adds the argument value to the scratchpad using the context menu.
    /// </summary>
    public async Task AddToScratchpadAsync()
    {
        var menu = await OpenContextMenuAsync();
        await menu.SelectAsync(DefaultOptions[0]);
    }

    /// <summary>
    /// Opens the inline tooltip rendering the expanded value.
    /// </summary>
    public async Task<ValueComponentView?> OpenTooltipAsync()
    {
        await _root.ClickAsync();
        await RetryHelpers.RetryAsync(async () => (await _pane.ActiveTooltipAsync()) is not null);
        return await _pane.ActiveTooltipAsync();
    }
}
