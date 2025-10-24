using System;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.EventLog;

/// <summary>
/// Type of event element within an event log style table.
/// </summary>
public enum EventElementType
{
    NotSet,
    EventLog,
    TracePointEditor
}

/// <summary>
/// Represents a single row within the event log.
/// </summary>
public class EventRow
{
    public readonly ILocator _root;
    public readonly EventElementType _elementType;

    public EventRow(ILocator root, EventElementType elementType)
    {
        _root = root;
        _elementType = elementType;
    }

    public async Task<int> TickCountAsync()
    {
        var text = await _root.Locator(".rr-ticks-time").TextContentAsync();
        return int.TryParse(text, out var value) ? value : 0;
    }

    public async Task<int> IndexAsync()
    {
        var text = await _root.Locator(".eventLog-index").TextContentAsync();
        return int.TryParse(text, out var value) ? value : 0;
    }

    public async Task<string> ConsoleOutputAsync()
    {
        var selector = ".eventLog-text";
        if (_elementType == EventElementType.TracePointEditor)
        {
            selector = ".trace-values";
            //return await _root.Locator(selector).GetAttributeAsync("innerHTML") ?? string.Empty;
            return await _root.Locator(selector).TextContentAsync() ?? string.Empty;
        }
        return await _root.Locator(selector).TextContentAsync() ?? string.Empty;
    }

    public async Task<bool> IsHighlightedAsync()
    {
        var classes = await _root.GetAttributeAsync("class") ?? string.Empty;
        return classes.Contains("eventLog-selected", StringComparison.OrdinalIgnoreCase)
            || classes.Contains("active", StringComparison.OrdinalIgnoreCase)
            || classes.Contains("selected", StringComparison.OrdinalIgnoreCase);
    }

    public async Task ClickAsync()
    {
        var index = await IndexAsync();
        DebugLogger.Log($"EventRow: clicking row index {index}");
        await _root.ClickAsync();
        DebugLogger.Log($"EventRow: click completed for row index {index}");
    }
}
