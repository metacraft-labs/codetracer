using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.EventLog;

/// <summary>
/// Event log pane containing multiple event rows.
/// </summary>
public class EventLogPane : TabObject
{
    private List<EventRow> _events = new();

    public EventLogPane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
    }

    public ILocator FooterContainer() => Root.Locator(".data-tables-footer");

    public ILocator RowsInfoContainer() => FooterContainer().Locator(".data-tables-footer-info");

    public async Task<int> RowsAsync()
    {
        var klass = await FooterContainer().GetAttributeAsync("class");
        var m = Regex.Match(klass ?? string.Empty, @"(\d*)to");
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
        }

    public async Task<int> ToRowAsync()
    {
        var text = await RowsInfoContainer().TextContentAsync();
        var m = Regex.Match(text ?? string.Empty, @"(\d*)\sof");
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
    }

    public async Task<int> OfRowsAsync()
    {
        var text = await RowsInfoContainer().TextContentAsync();
        var m = Regex.Match(text ?? string.Empty, @"of\s(\d*)");
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
    }

    private async Task<IReadOnlyList<ILocator>> EventElementRootsAsync()
        => await Root.Locator(".eventLog-dense-table tbody tr").AllAsync();

    public async Task<IReadOnlyList<EventRow>> EventElementsAsync(bool forceReload = false)
    {
        if (forceReload || _events.Count == 0)
        {
            var roots = await EventElementRootsAsync();
            _events = roots.Select(r => new EventRow(r, EventElementType.EventLog)).ToList();
        }
        return _events;
    }

    public Task<int> RowCountAsync(bool forceReload = false)
        => Root.Locator(".eventLog-dense-table tbody tr").CountAsync();

    public async Task<EventRow> RowByIndexAsync(int index, bool forceReload = false)
    {
        DebugLogger.Log($"EventLogPane: locating row {index} (forceReload={forceReload})");
        var rows = await EventElementsAsync(forceReload);
        foreach (var row in rows)
        {
            if (await row.IndexAsync() == index)
            {
                DebugLogger.Log($"EventLogPane: found row {index}");
                return row;
            }
        }

        DebugLogger.Log($"EventLogPane: row {index} not found");
        throw new InvalidOperationException($"Event log row with index {index} was not found.");
    }

    private ILocator FilterButton()
        => Root.GetByText("Filter", new() { Exact = true }).First;

    private ILocator DropdownRoot()
        => Page.Locator("#dropdown-container-id");

    public async Task ActivateTraceEventsFilterAsync()
    {
        await FilterButton().ClickAsync();
        var traceButton = DropdownRoot().GetByText("Trace events", new() { Exact = true });
        await traceButton.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        await traceButton.ClickAsync();
        await Page.Keyboard.PressAsync("Escape");
        await Page.WaitForTimeoutAsync(100);
    }

    public async Task ActivateRecordedEventsFilterAsync()
    {
        await FilterButton().ClickAsync();
        var recordedButton = DropdownRoot().GetByText("Recorded events", new() { Exact = true });
        await recordedButton.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        await recordedButton.ClickAsync();
        await Page.Keyboard.PressAsync("Escape");
        await Page.WaitForTimeoutAsync(100);
    }
}
