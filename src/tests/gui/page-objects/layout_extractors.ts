import { EditorTab, EventLogTab, ProgramStateTab, TracePointEditor } from "./layout_page";
import type {
  EventDataModel,
  EventLogModel,
  EditorModel,
  LayoutPageModel,
  ProgramStateModel,
  TracePointEditorModel,
  VariableStateModel,
} from "./layout_models";
import { LayoutPage } from "./layout_page";

/** Convert a ProgramStateTab to a model representation. */
export async function extractProgramStateModel(tab: ProgramStateTab): Promise<ProgramStateModel> {
  const model: ProgramStateModel = {
    isVisible: await tab.isVisible(),
    watchExpression: "",
    variableStates: [],
  };

  if (model.isVisible) {
    const vars = await tab.programStateVariables(true);
    for (const v of vars) {
      const variable: VariableStateModel = {
        name: await v.name(),
        valueType: await v.valueType(),
        value: await v.value(),
      };
      model.variableStates.push(variable);
    }
  }

  return model;
}

/** Convert an EventLogTab to its model. */
export async function extractEventLogModel(tab: EventLogTab): Promise<EventLogModel> {
  const model: EventLogModel = {
    isVisible: await tab.isVisible(),
    events: [],
    ofRows: 0,
    searchString: "",
  };

  if (model.isVisible) {
    const events = await tab.eventElements(true);
    for (const e of events) {
      const item: EventDataModel = { consoleOutput: await e.consoleOutput() };
      model.events.push(item);
    }
    model.ofRows = await tab.getOfRows();
  }

  return model;
}

/** Convert a TracePointEditor to a model. */
export async function extractTracePointEditorModel(editor: TracePointEditor): Promise<TracePointEditorModel> {
  const model: TracePointEditorModel = {
    lineNumber: editor.lineNumber,
    fileName: editor.parentEditorTab.fileName,
    code: await editor.editTextBox().textContent() ?? "",
    events: [],
  };

  const events = await editor.eventElements(true);
  for (const e of events) {
    const item: EventDataModel = { consoleOutput: await e.consoleOutput() };
    model.events.push(item);
  }
  return model;
}

/** Convert an EditorTab to a model. */
export async function extractEditorModel(tab: EditorTab): Promise<EditorModel> {
  const model: EditorModel = {
    isVisible: await tab.isVisible(),
    higlitedLineNumber: -1,
    tracePointEditorModels: [],
  };

  if (model.isVisible) {
    model.higlitedLineNumber = await tab.highlightedLineNumber();
    const editors = await tab.visibleTextRows();
    // unused rows but ensures access
    void editors.length;
  }

  return model;
}

/** Convert an entire LayoutPage to a model. */
export async function extractLayoutPageModel(page: LayoutPage): Promise<LayoutPageModel> {
  const model: LayoutPageModel = {
    eventLogTabModels: [],
    editorTabModels: [],
    programStateTabModels: [],
  };

  const eventLogs = await page.eventLogTabs(true);
  for (const tab of eventLogs) {
    model.eventLogTabModels.push(await extractEventLogModel(tab));
  }

  const editors = await page.editorTabs(true);
  for (const tab of editors) {
    model.editorTabModels.push(await extractEditorModel(tab));
  }

  const states = await page.programStateTabs(true);
  for (const tab of states) {
    model.programStateTabModels.push(await extractProgramStateModel(tab));
  }

  return model;
}
