using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.Filesystem;

/// <summary>
/// Wrapper around a single <c>jstree</c> node rendered in the filesystem pane.
/// </summary>
public class FilesystemTreeNode
{
    private readonly ILocator _root;

    public FilesystemTreeNode(ILocator root)
    {
        _root = root;
    }

    /// <summary>
    /// Underlying list item element (<c>li.jstree-node</c>).
    /// </summary>
    public ILocator Root => _root;

    /// <summary>
    /// Anchor element used for left/right clicks.
    /// </summary>
    public ILocator Anchor => _root.Locator(":scope > a.jstree-anchor");

    /// <summary>
    /// Locator for the collapse/expand toggle rendered by jstree.
    /// </summary>
    public ILocator ToggleIcon => _root.Locator(":scope > i.jstree-ocl");

    public Task<string?> IdAsync() => _root.GetAttributeAsync("id");

    public async Task<string?> NameAsync()
    {
        var text = await Anchor.TextContentAsync();
        return text?.Trim();
    }

    public async Task<int> LevelAsync()
    {
        var attr = await _root.GetAttributeAsync("aria-level");
        return int.TryParse(attr, out var value) ? value : 0;
    }

    public async Task<bool> IsLeafAsync()
        => await HasClassAsync("jstree-leaf");

    public async Task<bool> IsExpandedAsync()
        => await HasClassAsync("jstree-open");

    public async Task<bool> IsSelectedAsync()
        => await HasClassAsync("jstree-clicked");

    /// <summary>
    /// Clicks the toggle icon to expand or collapse the node.
    /// </summary>
    public Task ToggleAsync() => ToggleIcon.ClickAsync();

    /// <summary>
    /// Performs a primary click on the anchor element.
    /// </summary>
    public Task LeftClickAsync()
        => Anchor.ClickAsync(new() { Button = MouseButton.Left });

    /// <summary>
    /// Performs a context click (right click) on the anchor element.
    /// </summary>
    public Task RightClickAsync()
        => Anchor.ClickAsync(new() { Button = MouseButton.Right });

    /// <summary>
    /// Returns immediate child nodes.
    /// </summary>
    public async Task<IReadOnlyList<FilesystemTreeNode>> ChildrenAsync()
    {
        var children = await _root.Locator(":scope > ul > li.jstree-node").AllAsync();
        return children.Select(child => new FilesystemTreeNode(child)).ToList();
    }

    private async Task<bool> HasClassAsync(string className)
    {
        var attr = await _root.GetAttributeAsync("class") ?? string.Empty;
        return attr.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                   .Contains(className, StringComparer.Ordinal);
    }
}
