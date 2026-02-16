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
    private readonly IPage _page;
    private readonly ILocator _nodeLocator;
    private readonly ILocator _anchorLocator;
    private readonly ContextMenu _contextMenu;

    public FilesystemNode(FilesystemPane pane, IPage page, ILocator nodeLocator, ContextMenu contextMenu)
    {
        _pane = pane ?? throw new ArgumentNullException(nameof(pane));
        _page = page ?? throw new ArgumentNullException(nameof(page));
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
    /// on '.jstree-anchor' elements. We use jstree's show_contextmenu API directly
    /// because: (1) native DOM events don't trigger jQuery-bound handlers, (2) jQuery
    /// trigger fires the handler but vakata context creation may fail in Electron,
    /// (3) Playwright's right-click can be intercepted by Electron's default menu.
    /// </remarks>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        // First ensure the element is visible and scrolled into view
        await AnchorLocator.ScrollIntoViewIfNeededAsync();

        // Wait for jstree to fully process any pending events (folder expansion, etc.)
        await Task.Delay(500);

        // Get the jstree node ID from the parent <li> element
        var nodeId = await NodeLocator.GetAttributeAsync("id");

        // Call $.vakata.context.show() directly to create the context menu.
        // Previous approaches (jQuery trigger, show_contextmenu, _show_contextmenu) all
        // failed because jstree's intermediary code calls activate_node which triggers
        // CodeTracer's changed.jstree handler, causing a re-render that disrupts the
        // context menu creation. By calling vakata.context.show() directly, we bypass
        // all jstree event handling.
        await _page.EvaluateAsync(@"(nodeId) => {
            const jq = window.$ || window.jQuery;
            if (!jq) {
                throw new Error('jQuery is not available');
            }

            if (!jq.vakata || !jq.vakata.context || !jq.vakata.context.show) {
                throw new Error('$.vakata.context is not available - jstree contextmenu module may not be loaded');
            }

            // Get the jstree instance to obtain the default items
            const tree = jq('.filesystem').jstree(true);
            if (!tree) {
                throw new Error('jstree instance not found');
            }

            const node = tree.get_node(nodeId);
            if (!node) {
                throw new Error('jstree node not found: ' + nodeId);
            }

            // Get the menu items by calling jstree's default items function
            const itemsFn = tree.settings.contextmenu.items;
            let items;
            if (typeof itemsFn === 'function') {
                items = itemsFn.call(tree, node);
            } else {
                items = itemsFn;
            }

            if (!items || typeof items !== 'object') {
                throw new Error('contextmenu items is empty or not an object');
            }

            // Get anchor element for positioning
            const anchor = document.getElementById(nodeId + '_anchor');
            if (!anchor) {
                throw new Error('anchor element not found for node: ' + nodeId);
            }
            const rect = anchor.getBoundingClientRect();

            // Mark the anchor with jstree-context class (as jstree's _show_contextmenu does)
            jq(anchor).addClass('jstree-context');
            tree._data.contextmenu.visible = true;

            // Call vakata.context.show directly with the anchor reference and items
            jq.vakata.context.show(jq(anchor), {
                'x': rect.left + rect.width / 2,
                'y': rect.top + rect.height
            }, items);
        }", nodeId);

        // Wait for context menu using Playwright's WaitForAsync with reasonable timeout
        // The jstree context menu plugin creates a .vakata-context element
        await _contextMenu.Container.WaitForAsync(new()
        {
            State = WaitForSelectorState.Visible,
            Timeout = 10000
        });

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
