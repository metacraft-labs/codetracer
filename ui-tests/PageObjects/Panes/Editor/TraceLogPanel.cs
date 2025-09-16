using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
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
    /// </summary>
    public ILocator EditTextBox()
        => Root.Locator("textarea");

    /// <summary>
    /// Rows rendered in the trace log panel.
    /// </summary>
    public async Task<IReadOnlyList<EventRow>> EventRowsAsync()
    {
        var locators = await Root.Locator(".trace-view tbody tr").AllAsync();
        return locators.Select(l => new EventRow(l, EventElementType.TracePointEditor)).ToList();
    }
}
