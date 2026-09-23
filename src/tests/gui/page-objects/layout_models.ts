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

export interface LayoutPageModel {
  eventLogTabModels: EventLogModel[];
  editorTabModels: EditorModel[];
  programStateTabModels: ProgramStateModel[];
}
