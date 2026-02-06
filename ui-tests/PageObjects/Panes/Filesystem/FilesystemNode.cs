using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.Filesystem;

/// <summary>
/// Represents a single filesystem entry rendered by the jstree component.
/// </summary>
public class FilesystemNode
{
    private readonly FilesystemPane _pane;
    private readonly ILocator _nodeLocator;
    private readonly ILocator _anchorLocator;
    private readonly ContextMenu _contextMenu;

    public FilesystemNode(FilesystemPane pane, ILocator nodeLocator, ContextMenu contextMenu)
    {
        _pane = pane ?? throw new ArgumentNullException(nameof(pane));
        _nodeLocator = nodeLocator ?? throw new ArgumentNullException(nameof(nodeLocator));
        _anchorLocator = _nodeLocator.Locator("> a.jstree-anchor");
        _contextMenu = contextMenu;
    }

    /// <summary>
    /// Node locator (the &lt;li&gt; element).
    /// </summary>
    public ILocator NodeLocator => _nodeLocator;

    /// <summary>
    /// Anchor locator representing the clickable label.
    /// </summary>
    public ILocator AnchorLocator => _anchorLocator;

    /// <summary>
    /// Display name of the node.
    /// </summary>
    public async Task<string> NameAsync()
    {
        var text = await AnchorLocator.InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Depth level reported by jstree (1-based).
    /// </summary>
    public async Task<int> LevelAsync()
    {
        var attr = await NodeLocator.GetAttributeAsync("aria-level");
        return int.TryParse(attr, out var level) ? level : -1;
    }

    /// <summary>
    /// Indicates whether the node is currently expanded.
    /// </summary>
    public async Task<bool> IsExpandedAsync()
    {
        var classAttr = await NodeLocator.GetAttributeAsync("class") ?? string.Empty;
        return classAttr.Split(' ').Contains("jstree-open", StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Indicates whether the node is a leaf.
    /// </summary>
    public async Task<bool> IsLeafAsync()
    {
        var classAttr = await NodeLocator.GetAttributeAsync("class") ?? string.Empty;
        return classAttr.Split(' ').Contains("jstree-leaf", StringComparer.OrdinalIgnoreCase);
    }

    private ILocator ToggleLocator()
        => NodeLocator.Locator("> i.jstree-ocl");

    /// <summary>
    /// Expands the node if it is currently collapsed.
    /// </summary>
    public async Task ExpandAsync()
    {
        if (await IsLeafAsync() || await IsExpandedAsync())
        {
            return;
        }

        await ToggleLocator().ClickAsync();
        await RetryHelpers.RetryAsync(IsExpandedAsync);
    }

    /// <summary>
    /// Collapses the node if it is currently expanded.
    /// </summary>
    public async Task CollapseAsync()
    {
        if (await IsLeafAsync() || !await IsExpandedAsync())
        {
            return;
        }

        await ToggleLocator().ClickAsync();
        await RetryHelpers.RetryAsync(async () => !await IsExpandedAsync());
    }

    /// <summary>
    /// Performs a standard (left) click on the anchor label.
    /// </summary>
    public Task LeftClickAsync() => AnchorLocator.ClickAsync();

    /// <summary>
    /// Performs a right-click on the anchor label and returns the context menu handler.
    /// </summary>
    /// <remarks>
    /// jstree uses jQuery-based event handling that binds to 'contextmenu.jstree' events
    /// on '.jstree-anchor' elements. The handler requires both clientX/clientY and pageX/pageY
    /// coordinates. We dispatch a proper MouseEvent with all required coordinates and use
    /// jQuery's trigger for maximum compatibility.
    /// </remarks>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        // First ensure the element is visible and scrolled into view
        await AnchorLocator.ScrollIntoViewIfNeededAsync();

        // Wait a short moment for jstree to fully initialize
        await Task.Delay(150);

        // Get the element's bounding box for positioning
        var box = await AnchorLocator.BoundingBoxAsync();
        if (box == null)
        {
            throw new InvalidOperationException("Filesystem node anchor is not visible or has no bounding box.");
        }

        // Perform a right-click on the anchor to trigger jstree's contextmenu handler.
        // NOTE: jstree's vakata-contextmenu appears to not render properly in the
        // Electron test environment. Multiple approaches have been tried:
        // - Playwright ClickAsync with MouseButton.Right
        // - Page.Mouse.ClickAsync with right button
        // - jQuery event triggering
        // - Direct jstree.show_contextmenu() API call
        // None of these successfully show the #vakata-contextmenu element.
        // This may be an Electron-specific issue or a jstree configuration issue.
        await AnchorLocator.ClickAsync(new LocatorClickOptions
        {
            Button = MouseButton.Right
        });

        await _contextMenu.WaitForVisibleAsync();
        return _contextMenu;
    }

    /// <summary>
    /// Retrieves the visible context menu option labels for this node.
    /// </summary>
    public async Task<IReadOnlyList<string>> ContextMenuOptionsAsync()
    {
        var menu = await OpenContextMenuAsync();
        var entries = await menu.GetEntriesAsync();
        await menu.DismissAsync();
        return entries.Select(e => e.Text).ToList();
    }

    /// <summary>
    /// Selects an option from the context menu.
    /// </summary>
    public async Task SelectContextMenuOptionAsync(string option)
    {
        var menu = await OpenContextMenuAsync();
        await menu.SelectAsync(option);
    }
}
