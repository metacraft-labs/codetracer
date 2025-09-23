using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Pane representing the call trace view and its interactions.
/// </summary>
public class CallTracePane : TabObject
{
    private List<CallTraceRecord> _records = new();

    public CallTracePane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
        ContextMenu = new ContextMenu(page);
    }

    /// <summary>
    /// Shared context menu helper used by call trace entries and arguments.
    /// </summary>
    public ContextMenu ContextMenu { get; }

    public ILocator RecordsLocator => Root.Locator(".calltrace-call-line");
    public ILocator SearchInputLocator => Root.Locator(".calltrace-search-input");
    public ILocator SearchResultsContainer => Root.Locator(".call-search-results");

    /// <summary>
    /// Returns the rendered call trace records. Results are cached until <paramref name="forceReload"/> is true.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceRecord>> RecordsAsync(bool forceReload = false)
    {
        if (forceReload || _records.Count == 0)
        {
            var locators = await RecordsLocator.AllAsync();
            _records = locators.Select(locator => new CallTraceRecord(locator)).ToList();
        }

        return _records;
    }

    /// <summary>
    /// Focuses the search box so callers can send keyboard input.
    /// </summary>
    public Task FocusSearchAsync() => SearchInputLocator.FocusAsync();

    /// <summary>
    /// Sets the search query text.
    /// </summary>
    public Task SetSearchTextAsync(string text) => SearchInputLocator.FillAsync(text ?? string.Empty);

    /// <summary>
    /// Returns the current text in the search box.
    /// </summary>
    public Task<string> SearchTextAsync() => SearchInputLocator.InputValueAsync();

    /// <summary>
    /// Returns the visible search results as plain text entries.
    /// </summary>
    public async Task<IReadOnlyList<string>> VisibleSearchResultsAsync()
    {
        if (!await SearchResultsContainer.IsVisibleAsync())
        {
            return new List<string>();
        }

        var texts = await SearchResultsContainer.Locator(".search-result").AllInnerTextsAsync();
        return texts.Select(t => t.Trim()).ToList();
    }

    /// <summary>
    /// Returns currently visible tooltips that show expanded argument values.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceValueTooltip>> VisibleTooltipsAsync()
    {
        var tooltips = await Root.Locator(".call-tooltip").AllAsync();
        return tooltips.Select(locator => new CallTraceValueTooltip(locator)).ToList();
    }
}
