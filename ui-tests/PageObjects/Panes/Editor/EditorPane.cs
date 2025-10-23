using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.Editor;

/// <summary>
/// Page object representing a Monaco editor pane within the layout view.
/// </summary>
public class EditorPane : TabObject
{
    public EditorPane(
        IPage page,
        ILocator root,
        string tabButtonText,
        int idNumber,
        string filePath,
        string fileName)
        : base(page, root, tabButtonText)
    {
        IdNumber = idNumber;
        FilePath = filePath;
        FileName = fileName;
        TabButtonText = tabButtonText;
    }

    /// <summary>
    /// Numeric identifier extracted from the editor component id attribute.
    /// </summary>
    public int IdNumber { get; }

    /// <summary>
    /// Full file path associated with the editor tab.
    /// </summary>
    public string FilePath { get; }

    /// <summary>
    /// File name segment extracted from <see cref="FilePath"/>.
    /// </summary>
    public string FileName { get; }

    /// <summary>
    /// Display text shown on the editor tab button.
    /// </summary>
    public string TabButtonText { get; }

    /// <summary>
    /// Locator matching all rendered line elements.
    /// </summary>
    public ILocator LineElements()
        => Root.Locator(".monaco-editor .view-lines > .view-line");

    /// <summary>
    /// Locator matching a specific line element by number.
    /// </summary>
    public ILocator LineElement(int lineNumber)
        => Root.Locator($".monaco-editor .view-lines > .view-line[data-line-number='{lineNumber}']");

    /// <summary>
    /// Locator for the gutter element associated with a specific line number.
    /// </summary>
    public ILocator GutterElement(int lineNumber)
        => Root.Locator($".monaco-editor .margin-view-overlays > .gutter[data-line='{lineNumber}']");

    /// <summary>
    /// Locator for the overlay representing the currently selected line.
    /// </summary>
    public ILocator CurrentLineOverlay()
        => Root.Locator(".monaco-editor .view-overlays .current-line");

    /// <summary>
    /// Locator for the active line number entry in the gutter.
    /// </summary>
    public ILocator ActiveLineNumberLocator()
        => Root.Locator(".monaco-editor .margin .line-numbers.active-line-number");

    /// <summary>
    /// Locator for lines highlighted by execution or manual emphasis.
    /// </summary>
    public ILocator HighlightedLineElementsLocator()
        => Root.Locator(".monaco-editor .view-lines > .view-line.line-flow-hit, " +
                         ".monaco-editor .view-lines > .view-line.highlight");

    /// <summary>
    /// Locator for lines that are rendered in a greyed-out state.
    /// </summary>
    public ILocator GrayedOutLineElementsLocator()
        => Root.Locator(".monaco-editor .view-lines > .view-line.line-flow-skip, " +
                         ".monaco-editor .view-lines > .view-line.line-flow-unknown");

    /// <summary>
    /// Locator for gutter markers showing the current debugger position.
    /// </summary>
    public ILocator GutterHighlightElementsLocator()
        => Root.Locator(".monaco-editor .margin-view-overlays > .gutter.gutter-highlight-active");

    /// <summary>
    /// Locator collecting omniscient loop control containers.
    /// </summary>
    public ILocator OmniscientLoopContainersLocator()
        => Root.Locator(".flow-loop-step-container");

    /// <summary>
    /// Returns all currently rendered line objects.
    /// </summary>
    public async Task<IReadOnlyList<EditorLine>> LinesAsync()
    {
        var locators = await LineElements().AllAsync();
        var lines = new List<EditorLine>();
        foreach (var locator in locators)
        {
            var attr = await locator.GetAttributeAsync("data-line-number");
            var lineNumber = int.TryParse(attr, out var value) ? value : -1;
            lines.Add(new EditorLine(this, locator, lineNumber));
        }
        return lines;
    }

    /// <summary>
    /// Returns a line wrapper for the provided line number.
    /// </summary>
    public EditorLine LineByNumber(int lineNumber)
    {
        var locator = LineElement(lineNumber);
        return new EditorLine(this, locator, lineNumber);
    }

    /// <summary>
    /// Determines whether an active line selection exists in the editor.
    /// </summary>
    public async Task<bool> HasActiveLineAsync()
    {
        if (await ActiveLineNumberLocator().CountAsync() > 0)
        {
            return true;
        }
        return await CurrentLineOverlay().CountAsync() > 0;
    }

    /// <summary>
    /// Returns the currently active line number if one is selected.
    /// </summary>
    public async Task<int?> ActiveLineNumberAsync()
    {
        if (await ActiveLineNumberLocator().CountAsync() == 0)
        {
            return null;
        }

        var text = await ActiveLineNumberLocator().First.TextContentAsync();
        return int.TryParse(text, out var value) ? value : null;
    }

    /// <summary>
    /// Retrieves all lines currently highlighted by execution state markers.
    /// </summary>
    public async Task<IReadOnlyList<EditorLine>> HighlightedLinesAsync()
    {
        var lineNumbers = new HashSet<int>();
        var lineLocators = await HighlightedLineElementsLocator().AllAsync();
        foreach (var locator in lineLocators)
        {
            var attr = await locator.GetAttributeAsync("data-line-number");
            if (int.TryParse(attr, out var value) && value > 0)
            {
                lineNumbers.Add(value);
            }
        }

        var gutterLocators = await GutterHighlightElementsLocator().AllAsync();
        foreach (var gutter in gutterLocators)
        {
            var attr = await gutter.GetAttributeAsync("data-line");
            if (int.TryParse(attr, out var value) && value > 0)
            {
                lineNumbers.Add(value);
            }
        }

        return lineNumbers.Select(LineByNumber).ToList();
    }

    /// <summary>
    /// Retrieves all lines currently rendered in a greyed-out state.
    /// </summary>
    public async Task<IReadOnlyList<EditorLine>> GrayedOutLinesAsync()
    {
        var lineNumbers = new HashSet<int>();
        var lineLocators = await GrayedOutLineElementsLocator().AllAsync();
        foreach (var locator in lineLocators)
        {
            var attr = await locator.GetAttributeAsync("data-line-number");
            if (int.TryParse(attr, out var value) && value > 0)
            {
                lineNumbers.Add(value);
            }
        }

        return lineNumbers.Select(LineByNumber).ToList();
    }

    /// <summary>
    /// Convenience helper returning the numeric identifier for a given line object.
    /// </summary>
    public int LineNumber(EditorLine line) => line.LineNumber;

    /// <summary>
    /// Invokes the frontend helper to navigate to the specified line number.
    /// </summary>
    public async Task JumpToLineJsAsync(int lineNumber)
    {
        if (lineNumber <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(lineNumber), "Line number must be positive.");
        }

        await Page.EvaluateAsync(
            @"({ line }) => {
                if (typeof gotoLine !== 'function') {
                    throw new Error('gotoLine is not available.');
                }
                gotoLine(line);
            }",
            new { line = lineNumber });
    }

    /// <summary>
    /// Toggles a tracepoint at the requested line through the frontend API.
    /// </summary>
    public async Task OpenTrace(int lineNumber)
    {
        if (lineNumber <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(lineNumber), "Line number must be positive.");
        }

        if (string.IsNullOrWhiteSpace(FilePath))
        {
            throw new InvalidOperationException("Editor pane does not expose a valid file path.");
        }

        var editorLine = LineByNumber(lineNumber);
        if (await editorLine.HasTracepointAsync())
        {
            return;
        }

        await Page.EvaluateAsync(
            @"({ path, line }) => {
                if (typeof toggleTracepoint !== 'function') {
                    throw new Error('toggleTracepoint is not available.');
                }
                toggleTracepoint(path, line);
            }",
            new { path = FilePath, line = lineNumber });
    }

    /// <summary>
    /// Runs all configured tracepoints via the exposed frontend helper.
    /// </summary>
    public async Task RunTracepointsJsAsync()
    {
        await Page.EvaluateAsync(
            @"() => {
                if (typeof runTracepoints !== 'function') {
                    throw new Error('runTracepoints is not available.');
                }

                const globalData =
                    (typeof window !== 'undefined' && window.data)
                        ? window.data
                        : (typeof globalThis !== 'undefined' ? globalThis.data : undefined);

                if (!globalData) {
                    throw new Error('Global data object is not available.');
                }

                runTracepoints(globalData);
            }");
    }

    /// <summary>
    /// Returns currently active omniscient loop control groups.
    /// </summary>
    public async Task<IReadOnlyList<OmniscientLoopControls>> ActiveLoopControlsAsync()
    {
        var containers = await OmniscientLoopContainersLocator().AllAsync();
        return containers.Select(locator => new OmniscientLoopControls(locator)).ToList();
    }

    /// <summary>
    /// Gathers all flow values currently rendered across visible lines.
    /// </summary>
    public async Task<IReadOnlyList<FlowValue>> FlowValuesAsync()
    {
        var lines = await LinesAsync();
        var values = new List<FlowValue>();
        foreach (var line in lines)
        {
            values.AddRange(await line.FlowValuesAsync());
        }

        return values;
    }

    /// <summary>
    /// Opens the trace log panel for the provided line.
    /// </summary>
    public async Task<TraceLogPanel> OpenTracePointAsync(EditorLine line)
    {
        if (line.LineNumber <= 0)
        {
            throw new InvalidOperationException("Cannot open a trace point without a valid line number.");
        }

        await line.GutterElement().ClickAsync();
        var panel = new TraceLogPanel(this, line.LineNumber);
        await panel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        return panel;
    }

    /// <summary>
    /// Opens the trace log panel for a specific line number.
    /// </summary>
    public Task<TraceLogPanel> OpenTracePointAsync(int lineNumber)
        => OpenTracePointAsync(LineByNumber(lineNumber));

    /// <summary>
    /// Provides the highlighted line number, falling back to -1 if none is present.
    /// </summary>
    public async Task<int> HighlightedLineNumberAsync()
        => (await ActiveLineNumberAsync()) ?? -1;

    /// <summary>
    /// Returns the currently visible line wrappers.
    /// </summary>
    public Task<IReadOnlyList<EditorLine>> VisibleLinesAsync() => LinesAsync();
}
