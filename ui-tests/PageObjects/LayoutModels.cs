using System.Collections.Generic;

namespace UtTestsExperimentalConsoleAppication.PageObjects.Models;

/// <summary>
/// Models representing the extracted state of UI components.
/// Mirrors the old Nim structures.
/// </summary>

public class VariableStateModel
{
    public string Name { get; set; } = string.Empty;
    public string ValueType { get; set; } = string.Empty;
    public string Value { get; set; } = string.Empty;
}

public class ProgramStateModel
{
    public bool IsVisible { get; set; }
    public string WatchExpression { get; set; } = string.Empty;
    public List<VariableStateModel> VariableStates { get; set; } = new();
}

public class EventDataModel
{
    public string ConsoleOutput { get; set; } = string.Empty;
}

public class EventLogModel
{
    public bool IsVisible { get; set; }
    public List<EventDataModel> Events { get; set; } = new();
    public int OfRows { get; set; }
    public string SearchString { get; set; } = string.Empty;
}

public class TracePointEditorModel
{
    public int LineNumber { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string Code { get; set; } = string.Empty;
    public List<EventDataModel> Events { get; set; } = new();
}

public class EditorModel
{
    public bool IsVisible { get; set; }
    public int HiglitedLineNumber { get; set; }
    public List<TracePointEditorModel> TracePointEditorModels { get; set; } = new();
}

public class LayoutPageModel
{
    public List<EventLogModel> EventLogTabModels { get; set; } = new();
    public List<EditorModel> EditorTabModels { get; set; } = new();
    public List<ProgramStateModel> ProgramStateTabModels { get; set; } = new();
}
