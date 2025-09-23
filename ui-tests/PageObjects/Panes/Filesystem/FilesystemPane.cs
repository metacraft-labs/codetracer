using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;

namespace UiTests.PageObjects.Panes.Filesystem;

/// <summary>
/// Page object for the filesystem tree rendered by <c>filesystem.nim</c>.
/// </summary>
public class FilesystemPane : TabObject
{
    private List<FilesystemTreeNode> _cachedNodes = new();

    public FilesystemPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    /// <summary>
    /// Root container for the <c>jstree</c> instance.
    /// </summary>
    public ILocator TreeContainer => Root.Locator(".filesystem");

    /// <summary>
    /// Returns wrappers for all currently rendered tree nodes.
    /// </summary>
    public async Task<IReadOnlyList<FilesystemTreeNode>> NodesAsync(bool forceReload = false)
    {
        if (forceReload || _cachedNodes.Count == 0)
        {
            var locators = await TreeContainer.Locator("li.jstree-node").AllAsync();
            _cachedNodes = locators.Select(locator => new FilesystemTreeNode(locator)).ToList();
        }

        return _cachedNodes;
    }

    /// <summary>
    /// Returns a node wrapper identified by the <c>li</c> element id.
    /// </summary>
    public FilesystemTreeNode NodeById(string nodeId)
        => new(TreeContainer.Locator($"li#{nodeId}"));

    /// <summary>
    /// Captures the current filesystem tree into a serialisable snapshot for assertions.
    /// </summary>
    public async Task<IReadOnlyList<FilesystemNodeSnapshot>> VisibleSnapshotAsync()
    {
        const string script = @"(root) => {
            const nodes = Array.from(root.querySelectorAll('li.jstree-node'));
            return nodes.map(node => ({
                id: node.id,
                text: node.querySelector(':scope > a.jstree-anchor')?.textContent?.trim() ?? '',
                level: Number(node.getAttribute('aria-level') ?? '0'),
                isLeaf: node.classList.contains('jstree-leaf'),
                isExpanded: node.classList.contains('jstree-open'),
                parentId: node.parentElement?.closest('li.jstree-node')?.id ?? null
            }));
        }";

        var raw = await TreeContainer.EvaluateAsync<FilesystemNodeData[]>(script)
                  ?? System.Array.Empty<FilesystemNodeData>();

        var byId = raw.ToDictionary(node => node.Id);
        foreach (var node in raw)
        {
            node.Path = BuildPath(node, byId);
        }

        return raw.Select(node => node.ToSnapshot()).ToList();
    }

    private static string BuildPath(FilesystemNodeData node, IDictionary<string, FilesystemNodeData> byId)
    {
        var segments = new List<string>();
        var current = node;
        while (true)
        {
            if (!string.IsNullOrEmpty(current.Text))
            {
                segments.Add(current.Text);
            }

            if (string.IsNullOrEmpty(current.ParentId) || !byId.TryGetValue(current.ParentId!, out current!))
            {
                break;
            }
        }

        segments.Reverse();
        return string.Join('/', segments);
    }

    private sealed class FilesystemNodeData
    {
        public string Id { get; set; } = string.Empty;
        public string Text { get; set; } = string.Empty;
        public int Level { get; set; }
        public bool IsLeaf { get; set; }
        public bool IsExpanded { get; set; }
        public string? ParentId { get; set; }
        public string Path { get; set; } = string.Empty;

        public FilesystemNodeSnapshot ToSnapshot() => new()
        {
            Id = Id,
            Name = Text,
            Level = Level,
            IsLeaf = IsLeaf,
            IsExpanded = IsExpanded,
            ParentId = ParentId,
            Path = Path,
        };
    }
}

/// <summary>
/// Represents a single filesystem entry in snapshot form.
/// </summary>
public class FilesystemNodeSnapshot
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int Level { get; set; }
    public bool IsLeaf { get; set; }
    public bool IsExpanded { get; set; }
    public string? ParentId { get; set; }
    public string Path { get; set; } = string.Empty;
}
