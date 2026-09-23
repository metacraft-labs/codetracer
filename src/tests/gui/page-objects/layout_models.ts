/** Models representing the extracted state of UI components.
 * These mirror the old Nim models from layout_page_model.nim.
 */

export interface VariableStateModel {
  name: string;
  valueType: string;
  value: string;
}

export interface ProgramStateModel {
  isVisible: boolean;
  watchExpression: string;
  variableStates: VariableStateModel[];
}

export interface EventDataModel {
  consoleOutput: string;
}

export interface EventLogModel {
  isVisible: boolean;
  events: EventDataModel[];
  ofRows: number;
  searchString: string;
}

export interface TracePointEditorModel {
  lineNumber: number;
  fileName: string;
  code: string;
  events: EventDataModel[];
}

export interface EditorModel {
  isVisible: boolean;
  higlitedLineNumber: number;
  tracePointEditorModels: TracePointEditorModel[];
}

/** PLAT-40. One call-trace row: the call's name. */
export interface CallRowModel {
  name: string;
}

export interface CalltraceModel {
  isVisible: boolean;
  calls: CallRowModel[];
}

/** PLAT-40. One breakpoint/tracepoint row: its kind and its file base name and line. */
export interface PointRowModel {
  kind: string;
  fileName: string;
  lineNumber: number;
}

export interface PointListModel {
  isVisible: boolean;
  points: PointRowModel[];
}

/** PLAT-41. The transport controls a pane offers, by label. */
export interface TransportModel {
  isVisible: boolean;
  actions: string[];
}

/** PLAT-41. One flow row: where, and which expression. */
export interface FlowRowModel {
  location: string;
  expression: string;
}

export interface FlowPaneModel {
  isVisible: boolean;
  rows: FlowRowModel[];
}

/** PLAT-41. Where the debugger is in the recording, and its last tick. */
export interface TimelineModel {
  isVisible: boolean;
  currentTick: number;
  lastTick: number;
}

/** PLAT-41. The file tree's entries, as labels, in reading order. */
export interface FileTreeModel {
  isVisible: boolean;
  entries: string[];
}

export interface LayoutPageModel {
  eventLogTabModels: EventLogModel[];
  editorTabModels: EditorModel[];
  programStateTabModels: ProgramStateModel[];
}
