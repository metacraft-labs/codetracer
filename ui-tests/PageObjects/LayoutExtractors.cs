using System.Threading.Tasks;
using UiTests.PageObjects.Models;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.VariableState;
using UiTests.PageObjects.Panes.Editor;

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

    public static async Task<TracePointEditorModel> ExtractModelAsync(TraceLogPanel panel)
    {
        var model = new TracePointEditorModel
        {
            LineNumber = panel.LineNumber,
            FileName = panel.ParentPane.FileName,
            Code = await panel.EditTextBox().TextContentAsync() ?? string.Empty,
            Events = new()
        };

        var events = await panel.EventRowsAsync();
        foreach (var e in events)
        {
            model.Events.Add(new EventDataModel { ConsoleOutput = await e.ConsoleOutputAsync() });
        }

        return model;
    }

    public static async Task<EditorModel> ExtractModelAsync(EditorPane tab)
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
            var lines = await tab.VisibleLinesAsync();
            _ = lines.Count; // ensure traversal
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
