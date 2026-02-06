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
    /// Checks if this flow value supports scratchpad operations.
    /// </summary>
    /// <remarks>
    /// Stdout flow values (with class flow-std-default-box) don't support
    /// scratchpad operations. They can be identified by their ID pattern:
    /// - Regular values: flow-{mode}-value-box-{i}-{step}-{expression}
    /// - Stdout values: flow-{mode}-value-box-{i}-{step} (no expression)
    /// </remarks>
    public async Task<bool> SupportsScratchpadAsync()
    {
        // Check if this is a stdout box which doesn't support scratchpad
        var classAttr = await _root.GetAttributeAsync("class");
        if (classAttr?.Contains("flow-std-default-box", StringComparison.OrdinalIgnoreCase) == true)
        {
            return false;
        }

        // Also check the ID pattern - regular values have expression name in the ID
        var id = await _root.GetAttributeAsync("id");
        if (string.IsNullOrEmpty(id))
        {
            return true; // Assume it supports scratchpad if no ID
        }

        // ID pattern: flow-{mode}-value-box-{i}-{step}-{expression}
        // Stdout pattern: flow-{mode}-value-box-{i}-{step}
        // Count hyphens: regular has at least 6 parts, stdout has only 5
        var parts = id.Split('-');
        return parts.Length >= 6;
    }

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
    /// <remarks>
    /// Flow values are rendered in Monaco content widgets which can interfere with
    /// standard Playwright right-click events. We use JavaScript to dispatch a
    /// contextmenu event directly to ensure reliable triggering.
    /// </remarks>
    public async Task<ContextMenu> OpenContextMenuAsync()
    {
        // First ensure the element is visible and scrolled into view
        await _root.ScrollIntoViewIfNeededAsync();

        // Get the element's bounding box for positioning
        var box = await _root.BoundingBoxAsync();
        if (box == null)
        {
            throw new InvalidOperationException("Flow value element is not visible or has no bounding box.");
        }

        // Dispatch contextmenu event via JavaScript for reliable triggering
        // in Monaco content widgets which may not receive standard click events
        await _root.EvaluateAsync(@"(element) => {
            const rect = element.getBoundingClientRect();
            const event = new MouseEvent('contextmenu', {
                bubbles: true,
                cancelable: true,
                view: window,
                button: 2,
                buttons: 2,
                clientX: rect.left + rect.width / 2,
                clientY: rect.top + rect.height / 2
            });
            element.dispatchEvent(event);
        }");

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
        // For "Add value to scratchpad", use the more reliable CTRL+click method
        if (option.Contains("Add value to scratchpad", StringComparison.OrdinalIgnoreCase))
        {
            await AddToScratchpadAsync();
            return;
        }

        var menu = await OpenContextMenuAsync();
        await menu.SelectAsync(option);
    }

    /// <summary>
    /// Adds this flow value to the scratchpad using CTRL+click.
    /// </summary>
    /// <remarks>
    /// Flow values support CTRL+click as a shortcut to add to scratchpad.
    /// This is more reliable than using the context menu in Monaco content widgets.
    /// </remarks>
    public async Task AddToScratchpadAsync()
    {
        await _root.ScrollIntoViewIfNeededAsync();

        // Use CTRL+click which directly triggers the add-to-scratchpad action
        // without needing to open the context menu
        await _root.ClickAsync(new LocatorClickOptions
        {
            Modifiers = new[] { KeyboardModifier.Control }
        });
    }
}
