using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Components;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.Filesystem;

/// <summary>
/// Page object encapsulating the filesystem tree component.
/// </summary>
public class FilesystemPane : TabObject
{
    private const string TreeSelector = ".filesystem";
    private static readonly string[] DefaultContextMenuEntries = { "Create", "Rename", "Delete", "Edit" };

    private readonly ContextMenu _contextMenu;

    public FilesystemPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
        _contextMenu = new ContextMenu(
            page,
            containerSelector: "#vakata-contextmenu",
            itemSelector: ".vakata-contextmenu-item",
            hintSelector: ".vakata-contextmenu-shortcut");
    }

    /// <summary>
    /// Locator matching the jstree root element.
    /// </summary>
    public ILocator TreeLocator => Root.Locator(TreeSelector);

    /// <summary>
    /// Expected default context-menu entries provided by jstree.
    /// </summary>
    public IReadOnlyList<string> ExpectedContextMenuEntries => DefaultContextMenuEntries;

    /// <summary>
    /// Waits until the filesystem tree is rendered.
    /// </summary>
    public Task WaitForReadyAsync()
        => TreeLocator.WaitForAsync(new() { State = WaitForSelectorState.Visible });

    private static string NodeSelectorForLevel(int level)
        => $"li.jstree-node[aria-level='{level}']";

    private static string AnchorSelectorForLevel(int level)
        => $"{NodeSelectorForLevel(level)} > a.jstree-anchor";

    private async Task<ILocator> LocateNodeAsync(string name, int level)
    {
        var anchors = await TreeLocator
            .Locator(AnchorSelectorForLevel(level))
            .Filter(new() { HasTextString = name })
            .AllAsync();

        foreach (var anchor in anchors)
        {
            var node = anchor.Locator("..");
            if (await node.CountAsync() > 0)
            {
                return node;
            }
        }

        throw new InvalidOperationException($"Filesystem node '{name}' at level {level} was not found.");
    }

    private async Task<FilesystemNode> NodeBySegmentsAsync(IReadOnlyList<string> segments, bool expandIntermediate)
    {
        if (segments.Count == 0)
        {
            throw new ArgumentException("At least one segment must be provided.", nameof(segments));
        }

        await WaitForReadyAsync();

        ILocator? currentNodeLocator = null;

        for (var index = 0; index < segments.Count; index++)
        {
            var level = index + 1;
            var name = segments[index];
            currentNodeLocator = await LocateNodeAsync(name, level);
            var node = new FilesystemNode(this, currentNodeLocator, _contextMenu);
            if (expandIntermediate && index < segments.Count - 1)
            {
                await node.ExpandAsync();
                await RetryHelpers.RetryAsync(async () =>
                {
                    var childSelector = NodeSelectorForLevel(level + 1);
                    return await currentNodeLocator
                        .Locator($"> ul > {childSelector}")
                        .CountAsync() > 0;
                }, maxAttempts: 20, delayMs: 200);
            }
        }

        return new FilesystemNode(this, currentNodeLocator!, _contextMenu);
    }

    /// <summary>
    /// Retrieves a node using the provided breadcrumb path.
    /// </summary>
    public Task<FilesystemNode> NodeByPathAsync(params string[] segments)
        => NodeBySegmentsAsync(segments, expandIntermediate: true);

    /// <summary>
    /// Enumerates all node anchors currently rendered in the tree.
    /// </summary>
    public async Task<IReadOnlyList<FilesystemNode>> VisibleNodesAsync()
    {
        await WaitForReadyAsync();

        var nodes = await TreeLocator.Locator("li.jstree-node").AllAsync();
        return nodes.Select(locator => new FilesystemNode(this, locator, _contextMenu)).ToList();
    }
}
