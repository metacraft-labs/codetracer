using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.Terminal;

/// <summary>
/// Represents a rendered line in the terminal output component.
/// </summary>
public class TerminalOutputLine
{
    private readonly ILocator _root;

    public TerminalOutputLine(ILocator root)
    {
        _root = root;
    }

    public ILocator Root => _root;

    /// <summary>
    /// Extracts the numeric identifier from the line id (e.g. <c>terminal-line-5</c>).
    /// </summary>
    public async Task<int?> LineNumberAsync()
    {
        var id = await _root.GetAttributeAsync("id");
        if (string.IsNullOrEmpty(id))
        {
            return null;
        }

        var parts = id.Split('-');
        return int.TryParse(parts.LastOrDefault(), out var value) ? value : null;
    }

    public async Task<IReadOnlyList<TerminalOutputSegment>> SegmentsAsync()
    {
        var locators = await _root.Locator(":scope > div").AllAsync();
        return locators.Select(locator => new TerminalOutputSegment(locator)).ToList();
    }

    public async Task<bool> IsGreyedOutAsync()
    {
        var segments = await SegmentsAsync();
        if (segments.Count == 0)
        {
            return false;
        }

        var states = await Task.WhenAll(segments.Select(segment => segment.StateAsync()));
        return states.All(state => state == TerminalLineState.Future);
    }

    /// <summary>
    /// Clicks the first segment in the line.
    /// </summary>
    public async Task ClickAsync(MouseButton button = MouseButton.Left)
    {
        var segments = await SegmentsAsync();
        if (segments.Count == 0)
        {
            throw new InvalidOperationException("No terminal segments are available for clicking.");
        }

        await segments[0].ClickAsync(button);
    }
}

public enum TerminalLineState
{
    Past,
    Active,
    Future,
}

/// <summary>
/// Represents a single clickable segment (event) within a terminal line.
/// </summary>
public class TerminalOutputSegment
{
    private readonly ILocator _root;

    public TerminalOutputSegment(ILocator root)
    {
        _root = root;
    }

    public ILocator Root => _root;

    public async Task<string?> TextAsync()
    {
        var text = await _root.InnerTextAsync();
        return text?.Trim();
    }

    public async Task<TerminalLineState> StateAsync()
    {
        var classes = await _root.GetAttributeAsync("class") ?? string.Empty;
        var parts = classes.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Contains("active", StringComparer.Ordinal))
        {
            return TerminalLineState.Active;
        }

        if (parts.Contains("future", StringComparer.Ordinal))
        {
            return TerminalLineState.Future;
        }

        return TerminalLineState.Past;
    }

    public Task ClickAsync(MouseButton button = MouseButton.Left)
        => _root.ClickAsync(new() { Button = button });
}
