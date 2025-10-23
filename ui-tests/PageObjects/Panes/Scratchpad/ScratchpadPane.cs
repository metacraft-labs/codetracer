using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.Scratchpad;

/// <summary>
/// Page object wrapping the scratchpad pane and its stored values.
/// </summary>
public class ScratchpadPane : TabObject
{
    private List<ScratchpadEntry> _entries = new();

    public ScratchpadPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    /// <summary>
    /// Locator targeting the container that renders scratchpad values.
    /// </summary>
    public ILocator EntriesContainer()
        => Root.Locator(".value-components-container");

    /// <summary>
    /// Retrieves the currently visible scratchpad entries.
    /// </summary>
    public async Task<IReadOnlyList<ScratchpadEntry>> EntriesAsync(bool forceReload = false)
    {
        if (forceReload || _entries.Count == 0)
        {
            var entryRoots = await EntriesContainer()
                .Locator(".scratchpad-value-view")
                .AllAsync();
            _entries = entryRoots
                .Select(locator => new ScratchpadEntry(locator))
                .ToList();
        }

        return _entries;
    }

    /// <summary>
    /// Returns the number of entries currently displayed.
    /// </summary>
    public Task<int> EntryCountAsync()
        => EntriesContainer().Locator(".scratchpad-value-view").CountAsync();

    /// <summary>
    /// Waits until the scratchpad renders at least <paramref name="count"/> entries.
    /// </summary>
    public Task WaitForEntryCountAsync(int count)
        => RetryHelpers.RetryAsync(async () => await EntryCountAsync() >= count);

    /// <summary>
    /// Waits for a new entry to appear based on a previous baseline.
    /// </summary>
    public Task WaitForNewEntryAsync(int previousCount)
        => WaitForEntryCountAsync(previousCount + 1);

    /// <summary>
    /// Locates the first entry whose expression label matches <paramref name="expression"/>.
    /// Returns <c>null</c> when no such entry exists.
    /// </summary>
    public async Task<ScratchpadEntry?> FindEntryAsync(string expression, bool forceReload = false)
    {
        var entries = await EntriesAsync(forceReload);
        foreach (var entry in entries)
        {
            var expr = await entry.ExpressionAsync();
            if (expr == expression)
            {
                return entry;
            }
        }

        return null;
    }

    /// <summary>
    /// Computes the current entries keyed by their expression label.
    /// </summary>
    public async Task<Dictionary<string, ScratchpadEntry>> EntryMapAsync(bool forceReload = false)
    {
        var map = new Dictionary<string, ScratchpadEntry>(StringComparer.OrdinalIgnoreCase);
        var entries = await EntriesAsync(forceReload);
        foreach (var entry in entries)
        {
            var expr = await entry.ExpressionAsync();
            map[expr] = entry;
        }

        return map;
    }

    /// <summary>
    /// Clears the cached entry list, forcing a fresh query on the next access.
    /// </summary>
    public void InvalidateCache()
    {
        _entries.Clear();
    }

    /// <summary>
    /// Waits until an entry matching <paramref name="expression"/> appears and returns it.
    /// </summary>
    public async Task<ScratchpadEntry> WaitForEntryAsync(string expression)
    {
        ScratchpadEntry? found = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            InvalidateCache();
            found = await FindEntryAsync(expression, forceReload: true);
            return found is not null;
        });

        return found!;
    }
}
