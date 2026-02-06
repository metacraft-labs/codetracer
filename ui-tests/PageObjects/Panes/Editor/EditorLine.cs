using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.Editor;

/// <summary>
/// Represents a single rendered line inside an editor pane.
/// </summary>
public class EditorLine
{
    public EditorLine(EditorPane parentPane, ILocator root, int lineNumber)
    {
        ParentPane = parentPane;
        Root = root;
        LineNumber = lineNumber;
    }

    /// <summary>
    /// Parent editor pane hosting the line.
    /// </summary>
    public EditorPane ParentPane { get; }

    /// <summary>
    /// Locator representing the text portion of the line.
    /// </summary>
    public ILocator Root { get; }

    /// <summary>
    /// Line number as rendered by Monaco. A value of -1 indicates that the attribute was not available.
    /// </summary>
    public int LineNumber { get; }

    private void EnsureValidLineNumber()
    {
        if (LineNumber <= 0)
        {
            throw new InvalidOperationException("This editor line does not expose a valid line number.");
        }
    }

    /// <summary>
    /// Gutter element aligned with this line.
    /// </summary>
    public ILocator GutterElement()
    {
        EnsureValidLineNumber();
        return ParentPane.GutterElement(LineNumber);
    }

    /// <summary>
    /// Line number text within the gutter.
    /// </summary>
    public ILocator GutterLineNumberElement()
        => GutterElement().Locator(".gutter-line");

    /// <summary>
    /// Enabled tracepoint icon within the gutter.
    /// </summary>
    public ILocator GutterTraceIcon()
        => GutterElement().Locator(".gutter-trace");

    /// <summary>
    /// Disabled tracepoint icon within the gutter.
    /// </summary>
    public ILocator GutterDisabledTraceIcon()
        => GutterElement().Locator(".gutter-disabled-trace");

    /// <summary>
    /// Enabled breakpoint glyph inside the gutter.
    /// </summary>
    public ILocator GutterBreakpointEnabledIcon()
        => GutterElement().Locator(".gutter-breakpoint-enabled");

    /// <summary>
    /// Disabled breakpoint glyph inside the gutter.
    /// </summary>
    public ILocator GutterBreakpointDisabledIcon()
        => GutterElement().Locator(".gutter-breakpoint-disabled");

    /// <summary>
    /// Error state breakpoint glyph inside the gutter.
    /// </summary>
    public ILocator GutterBreakpointErrorIcon()
        => GutterElement().Locator(".gutter-breakpoint-error");

    /// <summary>
    /// Placeholder element indicating no breakpoint is set.
    /// </summary>
    public ILocator GutterNoBreakpointPlaceholder()
        => GutterElement().Locator(".gutter-no-breakpoint");

    /// <summary>
    /// Placeholder element indicating no tracepoint is set.
    /// </summary>
    public ILocator GutterNoTracePlaceholder()
        => GutterElement().Locator(".gutter-no-trace");

    /// <summary>
    /// Marker highlighting the current debugger location in the gutter.
    /// </summary>
    public ILocator GutterHighlightMarker()
        => GutterElement().Locator(".gutter-highlight-active");

    /// <summary>
    /// Omniscient flow values displayed in a loop context.
    /// </summary>
    public ILocator FlowLoopValueElements()
        => Root.Locator(".flow-loop-value");

    /// <summary>
    /// Omniscient flow values displayed for parallel executions.
    /// </summary>
    public ILocator FlowParallelValueElements()
        => Root.Locator(".flow-parallel-value");

    /// <summary>
    /// Variable name labels for loop flow values.
    /// </summary>
    public ILocator FlowLoopValueNameElements()
        => Root.Locator(".flow-loop-value-name");

    /// <summary>
    /// Variable name labels for parallel flow values.
    /// </summary>
    public ILocator FlowParallelValueNameElements()
        => Root.Locator(".flow-parallel-value-name");

    /// <summary>
    /// Editable expression field for omniscient loop values.
    /// </summary>
    public ILocator FlowLoopTextarea()
        => Root.Locator(".flow-loop-textarea");

    /// <summary>
    /// Multi-line value boxes rendered beside the code line.
    /// </summary>
    public ILocator FlowMultilineValueBoxes()
        => Root.Locator(".flow-multiline-value-box");

    /// <summary>
    /// Pointer element associated with multi-line value boxes.
    /// </summary>
    public ILocator FlowMultilineValuePointers()
        => Root.Locator(".flow-multiline-value-pointer");

    /// <summary>
    /// Returns all flow values currently attached to this line.
    /// </summary>
    /// <remarks>
    /// Note: Flow values are typically rendered as Monaco content widgets and may not
    /// be direct children of line elements. For comprehensive flow value discovery,
    /// consider using <see cref="EditorPane.FlowValuesAsync"/> instead.
    /// </remarks>
    public async Task<IReadOnlyList<FlowValue>> FlowValuesAsync()
    {
        var selector = ".flow-parallel-value-box, .flow-inline-value-box, .flow-loop-value-box, .flow-multiline-value-box";
        var locators = await Root.Locator(selector).AllAsync();
        var menu = new ContextMenu(ParentPane.Root.Page);
        var values = new List<FlowValue>();
        foreach (var locator in locators)
        {
            values.Add(new FlowValue(locator, menu));
        }

        return values;
    }

    /// <summary>
    /// Determines whether this line currently displays any breakpoint glyph.
    /// </summary>
    public async Task<bool> HasBreakpointAsync()
    {
        var breakpointLocator = GutterElement()
            .Locator(".gutter-breakpoint-enabled, .gutter-breakpoint-disabled, .gutter-breakpoint-error");
        return await breakpointLocator.CountAsync() > 0;
    }

    /// <summary>
    /// Determines whether this line currently has a tracepoint glyph.
    /// </summary>
    public async Task<bool> HasTracepointAsync()
    {
        var traceLocator = GutterElement().Locator(".gutter-trace, .gutter-disabled-trace");
        return await traceLocator.CountAsync() > 0;
    }

    /// <summary>
    /// Indicates whether the line hosts a tracepoint that is disabled.
    /// Returns <c>false</c> when no tracepoint is present.
    /// </summary>
    public async Task<bool> IsTracepointDisabledAsync()
    {
        if (!await HasTracepointAsync())
        {
            return false;
        }

        return await GutterDisabledTraceIcon().CountAsync() > 0;
    }

    /// <summary>
    /// Determines whether the line shows an error glyph in the gutter.
    /// </summary>
    public async Task<bool> HasErrorIconAsync()
        => await GutterBreakpointErrorIcon().CountAsync() > 0;

    /// <summary>
    /// Retrieves the rendered text for this line as shown by Monaco.
    /// </summary>
    public async Task<string> LineTextAsync()
    {
        var text = await Root.InnerTextAsync();
        return text?.Replace('\u00A0', ' ') ?? string.Empty;
    }

    /// <summary>
    /// Retrieves omniscient flow values rendered next to this line.
    /// </summary>
    public async Task<IReadOnlyList<string>> FlowParallelValuesAsync()
    {
        var values = new List<string>();
        var valueLocators = await FlowParallelValueElements().AllAsync();
        foreach (var locator in valueLocators)
        {
            var text = await locator.TextContentAsync();
            if (!string.IsNullOrWhiteSpace(text))
            {
                values.Add(text.Trim());
            }
        }

        return values;
    }
}
