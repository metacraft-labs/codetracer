using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Components;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Pane representing the call trace view and its rendered call hierarchy.
/// </summary>
public class CallTracePane : TabObject
{
    private readonly ContextMenu _contextMenu;
    private List<CallTraceEntry> _entries = new();

    public CallTracePane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
        _contextMenu = new ContextMenu(page);
    }

    /// <summary>
    /// Locator referencing the scrolling container of call trace lines.
    /// </summary>
    public ILocator LinesContainer()
        => Root.Locator(".calltrace-lines");

    /// <summary>
    /// Locator for the search input.
    /// </summary>
    public ILocator SearchInput()
        => Root.Locator(".calltrace-search-input");

    /// <summary>
    /// Locator for the search results popup.
    /// </summary>
    public ILocator SearchResultsContainer()
        => Root.Locator(".call-search-results");

    /// <summary>
    /// Waits until call trace entries are rendered.
    /// </summary>
    public Task WaitForReadyAsync()
        => RetryHelpers.RetryAsync(async () =>
            await LinesContainer().Locator(".calltrace-call-line").CountAsync() > 0);

    /// <summary>
    /// Retrieves all currently visible call entries.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceEntry>> EntriesAsync(bool forceReload = false)
    {
        if (forceReload || _entries.Count == 0)
        {
            await WaitForReadyAsync();
            var roots = await LinesContainer().Locator(".calltrace-call-line").AllAsync();
            _entries = roots
                .Select(locator => new CallTraceEntry(this, locator, _contextMenu))
                .ToList();
        }

        return _entries;
    }

    /// <summary>
    /// Clears the cached entry list so the next access reloads the DOM.
    /// </summary>
    public void InvalidateEntries() => _entries.Clear();

    /// <summary>
    /// Finds the first call trace entry whose function name matches <paramref name="functionName"/>.
    /// </summary>
    public async Task<CallTraceEntry?> FindEntryAsync(string functionName, bool forceReload = false)
    {
        var entries = await EntriesAsync(forceReload);
        foreach (var entry in entries)
        {
            var name = await entry.FunctionNameAsync();
            if (string.Equals(name, functionName, StringComparison.OrdinalIgnoreCase))
            {
                return entry;
            }
        }

        return null;
    }

    /// <summary>
    /// Performs a search query within the call trace pane.
    /// </summary>
    public async Task SearchAsync(string query)
    {
        await SearchInput().FillAsync(query);
        await SearchInput().PressAsync("Enter");
        await RetryHelpers.RetryAsync(async () =>
            await SearchResultsContainer().Locator(".search-result").CountAsync() > 0);
    }

    /// <summary>
    /// Clears the search field.
    /// </summary>
    public async Task ClearSearchAsync()
    {
        await SearchInput().FillAsync(string.Empty);
        await RetryHelpers.RetryAsync(async () =>
            await SearchResultsContainer().Locator(".search-result").CountAsync() == 0);
    }

    /// <summary>
    /// Returns the tooltip value currently rendered (if any).
    /// </summary>
    public async Task<ValueComponentView?> ActiveTooltipAsync()
    {
        var tooltip = Root.Locator(".call-tooltip");
        if (await tooltip.CountAsync() == 0)
        {
            return null;
        }

        return new ValueComponentView(tooltip.Locator(".value-expanded").First);
    }
}
