using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;
using UiTests.PageObjects.Panes.EventLog;

namespace UiTests.PageObjects.Panes.Editor;

/// <summary>
/// Represents the trace log panel associated with a specific editor line.
/// </summary>
public class TraceLogPanel
{
    public TraceLogPanel(EditorPane parentPane, int lineNumber)
    {
        ParentPane = parentPane;
        LineNumber = lineNumber;
    }

    /// <summary>
    /// Parent editor pane where the trace panel originated.
    /// </summary>
    public EditorPane ParentPane { get; }

    /// <summary>
    /// Line number that owns this trace log panel.
    /// </summary>
    public int LineNumber { get; }

    /// <summary>
    /// Root locator of the trace log panel element.
    /// </summary>
    public ILocator Root
        => ParentPane.Root.Locator($"xpath=//*[@id='edit-trace-{ParentPane.IdNumber}-{LineNumber}']/ancestor::*[@class='trace']");

    /// <summary>
    /// Editable text box used to configure the trace expression.
    /// Monaco editor creates a textarea with class 'inputarea'. The element also has
    /// 'monaco-mouse-cursor-text' class when focused. We use First to handle any duplicates.
    /// </summary>
    public ILocator EditTextBox()
        => Root.Locator("textarea.inputarea").First;

    /// <summary>
    /// Rows rendered in the trace log panel.
    /// </summary>
    public async Task<IReadOnlyList<TraceLogRow>> TraceRowsAsync()
    {
        var locators = await Root.Locator(".trace-view tbody tr").AllAsync();
        var menu = new ContextMenu(ParentPane.Root.Page);
        return locators.Select(l => new TraceLogRow(l, menu)).ToList();
    }

    /// <summary>
    /// Backwards-compatible accessor returning the legacy event row wrapper.
    /// </summary>
    public async Task<IReadOnlyList<EventRow>> EventRowsAsync()
    {
        var traceRows = await TraceRowsAsync();
        return traceRows
            .Select(row => new EventRow(row.Root, EventElementType.TracePointEditor))
            .ToList();
    }

    public ILocator ToggleButton() => Root.Locator(".trace-disable");
    public ILocator DisabledOverlay() => Root.Locator(".trace-disabled-overlay");
    public ILocator RunButton() => Root.Locator(".trace-run-button-svg").Nth(0);
}
