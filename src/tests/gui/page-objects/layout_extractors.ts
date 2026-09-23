import { EditorTab, EventLogTab, ProgramStateTab, TracePointEditor } from "./layout_page";
import type { Page } from "@playwright/test";
import type {
  CalltraceModel,
  PointListModel,
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

/**
 * PLAT-40. The call trace's rows as the desktop drew them: each row's
 * `.call-text` is `<name> #<index>`, and the model keeps the name.
 */
export async function extractCalltraceModel(page: Page): Promise<CalltraceModel> {
  const texts = await page
    .locator(".calltrace-view .call-text")
    .evaluateAll((els) => els.map((e) => (e.textContent ?? "").trim()));
  return {
    isVisible: texts.length > 0,
    calls: texts
      .map((t) => t.replace(/\s+#\d+\s*$/, "").trim())
      .filter((name) => name.length > 0)
      .map((name) => ({ name })),
  };
}

/**
 * PLAT-40. The Breakpoints & Tracepoints pane's rows: kind, and the location's
 * file BASE name and line (`<path>:<line>`).
 */
export async function extractPointListModel(page: Page): Promise<PointListModel> {
  const rows = await page
    .locator(".point-list-component .point-list-row")
    .evaluateAll((els) =>
      els.map((e) => ({
        kind: (e.querySelector(".point-list-kind")?.textContent ?? "").trim(),
        location: (e.querySelector(".point-list-location")?.textContent ?? "").trim(),
      })),
    );
  const visible =
    (await page.locator(".point-list-component").count()) > 0;
  return {
    isVisible: visible,
    points: rows.map((r) => {
      const colon = r.location.lastIndexOf(":");
      const path = colon > 0 ? r.location.slice(0, colon) : r.location;
      const line = colon > 0 ? parseInt(r.location.slice(colon + 1), 10) : 0;
      return {
        kind: r.kind,
        fileName: path.slice(path.lastIndexOf("/") + 1),
        lineNumber: Number.isFinite(line) ? line : 0,
      };
    }),
  };
}
