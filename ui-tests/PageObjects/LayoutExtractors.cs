using System.Threading.Tasks;
using UiTests.PageObjects.Models;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.VariableState;

namespace UiTests.PageObjects;

/// <summary>
/// Helper methods that convert page objects to their model representations.
/// </summary>
public static class LayoutExtractors
{
    public static async Task<ProgramStateModel> ExtractModelAsync(VariableStatePane tab)
    {
        var model = new ProgramStateModel
        {
            IsVisible = await tab.IsVisibleAsync(),
            WatchExpression = string.Empty,
            VariableStates = new()
        };

        if (model.IsVisible)
        {
            var vars = await tab.ProgramStateVariablesAsync(true);
            foreach (var v in vars)
            {
                var variable = new VariableStateModel
                {
                    Name = await v.NameAsync() ?? string.Empty,
                    ValueType = await v.ValueTypeAsync() ?? string.Empty,
                    Value = await v.ValueAsync() ?? string.Empty
                };
                model.VariableStates.Add(variable);
            }
        }
        return model;
    }

    public static async Task<EventLogModel> ExtractModelAsync(EventLogPane tab)
    {
        var model = new EventLogModel
        {
            IsVisible = await tab.IsVisibleAsync(),
            Events = new(),
            OfRows = 0,
            SearchString = string.Empty
        };

        if (model.IsVisible)
        {
            var events = await tab.EventElementsAsync(true);
            foreach (var e in events)
            {
                model.Events.Add(new EventDataModel { ConsoleOutput = await e.ConsoleOutputAsync() });
            }
            model.OfRows = await tab.OfRowsAsync();
        }

        return model;
    }

    public static async Task<TracePointEditorModel> ExtractModelAsync(LayoutPage.TracePointEditor editor)
    {
        var model = new TracePointEditorModel
        {
            LineNumber = editor.LineNumber,
            FileName = editor.ParentEditorTab.FileName,
            Code = await editor.EditTextBox.TextContentAsync() ?? string.Empty,
            Events = new()
        };

        var events = await editor.EventElementsAsync(true);
        foreach (var e in events)
        {
            model.Events.Add(new EventDataModel { ConsoleOutput = await e.ConsoleOutputAsync() });
        }

        return model;
    }

    public static async Task<EditorModel> ExtractModelAsync(LayoutPage.EditorTab tab)
    {
        var model = new EditorModel
        {
            IsVisible = await tab.IsVisibleAsync(),
            HiglitedLineNumber = -1,
            TracePointEditorModels = new()
        };

        if (model.IsVisible)
        {
            model.HiglitedLineNumber = await tab.HighlightedLineNumberAsync();
            var rows = await tab.VisibleTextRowsAsync();
            _ = rows.Count; // ensure traversal
        }
        return model;
    }

    public static async Task<LayoutPageModel> ExtractLayoutPageModelAsync(LayoutPage page)
    {
        var model = new LayoutPageModel
        {
            EventLogTabModels = new(),
            EditorTabModels = new(),
            ProgramStateTabModels = new()
        };

        var eventLogs = await page.EventLogTabsAsync(true);
        foreach (var tab in eventLogs)
            model.EventLogTabModels.Add(await ExtractModelAsync(tab));

        var editors = await page.EditorTabsAsync(true);
        foreach (var tab in editors)
            model.EditorTabModels.Add(await ExtractModelAsync(tab));

        var programStates = await page.ProgramStateTabsAsync(true);
        foreach (var tab in programStates)
            model.ProgramStateTabModels.Add(await ExtractModelAsync(tab));

        return model;
    }
}
