using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Represents a rendered call entry inside the call trace pane.
/// </summary>
public class CallTraceRecord
{
    private static readonly Regex MinWidthRegex = new("min-width:\\s*([\\d.]+)px", RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private const double CallOffsetWidthPx = 20.0; // Matches CALL_OFFSET_WIDTH_PX in calltrace.nim

    private readonly ILocator _root;

    public CallTraceRecord(ILocator root)
    {
        _root = root;
    }

    public ILocator Root => _root;

    private ILocator OffsetLocator => _root.Locator(":scope > span");
    private ILocator RecordContainer => _root.Locator(":scope .calltrace-child");
    private ILocator CallContainer => RecordContainer.Locator(":scope > div.call-child-box");
    private ILocator CallTextLocator => RecordContainer.Locator(":scope .call-text");
    private ILocator ArgumentsContainer => RecordContainer.Locator(":scope .call-args");
    private ILocator ReturnTextLocator => RecordContainer.Locator(":scope .return .return-text");
    private ILocator ToggleLocator => RecordContainer.Locator(":scope .toggle-call");
    private ILocator ToggleIconLocator => ToggleLocator.Locator(":scope > div");

    /// <summary>
    /// Returns the rendered depth of the call based on the <c>min-width</c> offset span.
    /// </summary>
    public async Task<int> DepthAsync()
    {
        var style = await OffsetLocator.GetAttributeAsync("style") ?? string.Empty;
        var match = MinWidthRegex.Match(style);
        if (match.Success && double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var pixels))
        {
            return (int)Math.Round(pixels / CallOffsetWidthPx);
        }

        return 0;
    }

    /// <summary>
    /// Returns whether the record is marked as currently selected.
    /// </summary>
    public async Task<bool> IsSelectedAsync()
    {
        var classes = await _root.GetAttributeAsync("class") ?? string.Empty;
        return classes.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains("event-selected", StringComparer.Ordinal);
    }

    /// <summary>
    /// Returns the full text rendered for the function name and call number.
    /// </summary>
    public async Task<string?> RawCallTextAsync()
    {
        if (await CallTextLocator.CountAsync() == 0)
        {
            return null;
        }

        var text = await CallTextLocator.First.TextContentAsync();
        return text?.Trim();
    }

    /// <summary>
    /// Extracts the function name from the call text.
    /// </summary>
    public async Task<string?> FunctionNameAsync()
    {
        var raw = await RawCallTextAsync();
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }

        var hashIndex = raw.IndexOf('#');
        return hashIndex >= 0 ? raw[..hashIndex].Trim() : raw;
    }

    /// <summary>
    /// Extracts the numeric call identifier from the call text when present.
    /// </summary>
    public async Task<int?> CallNumberAsync()
    {
        var raw = await RawCallTextAsync();
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }

        var hashIndex = raw.IndexOf('#');
        if (hashIndex < 0)
        {
            return null;
        }

        var numberPart = raw[(hashIndex + 1)..].Trim();
        return int.TryParse(numberPart, out var number) ? number : null;
    }

    /// <summary>
    /// Returns the call key extracted from the element id (e.g. <c>local-call-0</c>).
    /// </summary>
    public async Task<string?> CallKeyAsync()
    {
        if (await CallContainer.CountAsync() == 0)
        {
            return null;
        }

        var id = await CallContainer.First.GetAttributeAsync("id");
        if (string.IsNullOrEmpty(id))
        {
            return null;
        }

        var segments = id.Split('-');
        return segments.Length > 2 ? string.Join('-', segments.Skip(2)) : segments.LastOrDefault();
    }

    public async Task<bool> HasToggleAsync()
        => await ToggleIconLocator.Locator(".collapse-call-img").CountAsync() > 0;

    public async Task<bool> HasDotIndicatorAsync()
        => await ToggleIconLocator.Locator(".dot-call-img").CountAsync() > 0;

    public async Task<bool> IsExpandedAsync()
        => await ToggleIconLocator.Locator(".collapse-call-img.active").CountAsync() > 0;

    /// <summary>
    /// Clicks the expand/collapse toggle if present.
    /// </summary>
    public async Task ToggleAsync()
    {
        if (!await HasToggleAsync())
        {
            throw new InvalidOperationException("The call record does not expose an expand/collapse toggle.");
        }

        await ToggleLocator.ClickAsync();
    }

    /// <summary>
    /// Returns the call arguments rendered for this record.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceArgument>> ArgumentsAsync()
    {
        if (await ArgumentsContainer.CountAsync() == 0)
        {
            return new List<CallTraceArgument>();
        }

        var args = await ArgumentsContainer.Locator(":scope .call-arg").AllAsync();
        return args.Select(locator => new CallTraceArgument(locator)).ToList();
    }

    /// <summary>
    /// Returns the textual return value if one is rendered.
    /// </summary>
    public async Task<string?> ReturnValueAsync()
    {
        if (await ReturnTextLocator.CountAsync() == 0)
        {
            return null;
        }

        var text = await ReturnTextLocator.First.TextContentAsync();
        return text?.Trim();
    }

    /// <summary>
    /// Returns tooltips associated with arguments of this call.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceValueTooltip>> TooltipsAsync()
    {
        if (await ArgumentsContainer.CountAsync() == 0)
        {
            return new List<CallTraceValueTooltip>();
        }

        var tooltips = await ArgumentsContainer.Locator(":scope .call-tooltip").AllAsync();
        return tooltips.Select(locator => new CallTraceValueTooltip(locator)).ToList();
    }
}
