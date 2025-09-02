using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UtTestsExperimentalConsoleAppication.PageObjects;

namespace UtTestsExperimentalConsoleAppication.PageObjects.Panes.EventLog;

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
}
