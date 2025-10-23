using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.VariableState;

/// <summary>
/// Represents a single variable entry in the Program State pane.
/// </summary>
public class VariableStateRecord
{
    private readonly ILocator _root;

    private ValueComponentView ValueView => new(_root);
    private ContextMenu ContextMenu => new(_root.Page);

    public VariableStateRecord(ILocator root)
    {
        _root = root;
    }

    public Task<string> NameAsync()
        => ValueView.NameAsync();

    public Task<string?> ValueTypeAsync()
        => ValueView.ValueTypeAsync();

    public async Task<string?> ValueAsync()
    {
        var value = await ValueView.ValueTextAsync();
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    public ValueComponentView ValueComponent => ValueView;

    /// <summary>
    /// Ensures the value history is visible and returns the available entries.
    /// </summary>
    public async Task<IReadOnlyList<ValueHistoryEntry>> HistoryEntriesAsync()
    {
        if (!await ValueView.HasHistoryToggleAsync())
        {
            return new List<ValueHistoryEntry>();
        }

        await ValueView.ToggleHistoryAsync();

        var historyContainer = _root.Locator(".inline-history .history-value");
        await historyContainer.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        var entries = await historyContainer.AllAsync();

        return entries
            .Select(entry => new ValueHistoryEntry(entry, ContextMenu))
            .ToList();
    }
}
