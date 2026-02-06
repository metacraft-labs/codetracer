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
    /// Monaco editor's visible text area where code is rendered.
    /// This is the clickable area that focuses the editor.
    /// </summary>
    public ILocator MonacoViewLines()
        => Root.Locator(".monaco-editor .view-lines").First;

    /// <summary>
    /// Editable text box used to configure the trace expression.
    /// Monaco editor creates a textarea for input. The class name varies by Monaco version:
    /// - Older versions: 'inputarea'
    /// - Newer versions: 'ime-text-area'
    /// We use First to handle any duplicates.
    /// </summary>
    public ILocator EditTextBox()
        => Root.Locator("textarea.inputarea, textarea.ime-text-area").First;

    /// <summary>
    /// Types text into the trace expression editor by clicking the Monaco view area
    /// and using keyboard input. This is the recommended approach for newer Monaco versions.
    /// </summary>
    /// <param name="expression">The trace expression to type.</param>
    public async Task TypeExpressionAsync(string expression)
    {
        var viewLines = MonacoViewLines();
        await viewLines.WaitForAsync(new() { State = WaitForSelectorState.Visible, Timeout = 5000 });

        // Click on the view lines to focus the Monaco editor
        await viewLines.ClickAsync();
        await Task.Delay(200);

        var editId = $"edit-trace-{ParentPane.IdNumber}-{LineNumber}";
        var page = ParentPane.Root.Page;

        // Try to set value via Monaco API - access through data.services or global monaco
        var setViaApi = await page.EvaluateAsync<bool>(@"(args) => {
            const editId = args.editId;
            const expression = args.expression;
            const editDiv = document.getElementById(editId);
            if (!editDiv) return false;

            // Try multiple ways to access Monaco editors
            // Method 1: Via global monaco API
            const monacoEditors = window.monaco?.editor?.getEditors?.() || [];
            for (const editor of monacoEditors) {
                const domNode = editor.getDomNode();
                if (domNode && editDiv.contains(domNode)) {
                    editor.setValue(expression);
                    return true;
                }
            }

            // Method 2: Look for Monaco container's editor property
            const monacoContainer = editDiv.querySelector('.monaco-editor');
            if (monacoContainer && monacoContainer._editorInstance) {
                monacoContainer._editorInstance.setValue(expression);
                return true;
            }

            return false;
        }", new { editId, expression });

        // Always use keyboard fallback for reliability
        // Click to ensure focus
        await viewLines.ClickAsync();
        await Task.Delay(150);

        // Select all and delete existing content
        await page.Keyboard.PressAsync("Control+a");
        await Task.Delay(50);
        await page.Keyboard.PressAsync("Delete");
        await Task.Delay(50);

        // Type the expression character by character with delay for reliability
        await page.Keyboard.TypeAsync(expression, new() { Delay = 30 });
    }

    /// <summary>
    /// Rows rendered in the trace log panel.
    /// </summary>
    /// <remarks>
    /// The trace table can be rendered in different views:
    /// - .trace-view: The default view with trace rows
    /// - .chart-table .trace-table: Alternative table view with DataTables styling
    /// We check both selectors to handle view mode variations.
    /// </remarks>
    public async Task<IReadOnlyList<TraceLogRow>> TraceRowsAsync()
    {
        // Try the chart-table selector first (DataTables-based view)
        var locators = await Root.Locator(".chart-table .trace-table tbody tr").AllAsync();
        if (locators.Count == 0)
        {
            // Fall back to trace-view selector
            locators = await Root.Locator(".trace-view tbody tr").AllAsync();
        }

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

    /// <summary>
    /// The hamburger menu button that opens the dropdown containing Disable/Hide/Delete options.
    /// </summary>
    public ILocator HamburgerMenu() => Root.Locator(".hamburger-dropdown");

    /// <summary>
    /// The dropdown list container that appears when the hamburger menu is clicked.
    /// </summary>
    public ILocator DropdownList() => Root.Locator(".dropdown-list");

    /// <summary>
    /// The Disable/Enable toggle button inside the hamburger dropdown.
    /// Note: This button is only visible after opening the hamburger menu.
    /// </summary>
    public ILocator ToggleButton() => Root.Locator(".trace-disable");

    /// <summary>
    /// Opens the hamburger menu and clicks the Disable/Enable toggle button.
    /// This method handles the dropdown visibility correctly.
    /// The dropdown uses a blur handler that closes it when focus leaves the hamburger button,
    /// so we need to use JavaScript evaluation to click the toggle button reliably.
    /// </summary>
    public async Task ClickToggleButtonAsync()
    {
        var page = ParentPane.Root.Page;
        var editTraceId = $"edit-trace-{ParentPane.IdNumber}-{LineNumber}";

        // Use JavaScript to reliably toggle the disable state
        // This avoids race conditions with blur handlers
        // We find the trace panel by locating the edit-trace element and going up to its ancestor .trace
        await page.EvaluateAsync(@"(editTraceId) => {
            const editTrace = document.getElementById(editTraceId);
            if (!editTrace) {
                console.log('Could not find edit trace element:', editTraceId);
                return;
            }

            // Find the ancestor .trace element
            const trace = editTrace.closest('.trace');
            if (!trace) {
                console.log('Could not find ancestor .trace element');
                return;
            }

            // Find and click the hamburger to open dropdown
            const hamburger = trace.querySelector('.hamburger-dropdown');
            if (hamburger) {
                hamburger.click();

                // Small delay then click the disable button
                setTimeout(() => {
                    const toggleBtn = trace.querySelector('.trace-disable');
                    if (toggleBtn) {
                        toggleBtn.click();
                    }
                }, 150);
            }
        }", editTraceId);

        // Wait for the action to complete
        await Task.Delay(400);
    }

    public ILocator DisabledOverlay() => Root.Locator(".trace-disabled-overlay");
    public ILocator RunButton() => Root.Locator(".trace-run-button-svg").Nth(0);
}
