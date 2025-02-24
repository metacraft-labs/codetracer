import
  /layout_page, ../testing_framework/extended_web_driver, base_page, async, strutils, lib, strformat, sequtils, sets, macros, os, jsffi, jsconsole, tables

type CallTraceStateModel* = ref object of RootObj

type VariableStateModel* = ref object of RootObj
  name*: string
  valueType*: string
  value*: string

type ProgramStateModel* = ref object of RootObj
  isVisible*: bool
  watchExpression*: string
  variableStates*: seq[VariableStateModel]

proc newProgramStateModel*(): ProgramStateModel =
  var model = ProgramStateModel()
  model.variablestates = @[]
  return model

type EventDataModel* = ref object of RootObj
  # tickCount*: int
  # index*: int
  consoleOutput*: string

proc newEventDataModel*(): EventDataModel =
  var model = EventDataModel()
  # model.tickCount = -1
  # model.index = -1
  model.consoleOutput = "Bug in newEventDataModel data extraction"

  return model

type EventLogModel* = ref object of RootObj
  isVisible*: bool
  events*: seq[EventDataModel]
  ofRows*: int
  searchString*: string

type TracePointEditorModel* = ref object of RootObj
  lineNumber*: int
  fileName*: string
  code*: string
  events*: seq[EventDataModel]

proc newTracePointEditorModel*(lineNumber: int = -1,
                              fileName: string = "newTracePointEditorModel filename not set",
                              code: string = "newTracePointEdotModel code not set"):
                              TracePointEditorModel =
  var model = TracePointEditorModel()
  model.filename = filename
  model.code = code
  model.lineNumber = lineNumber
  model.events = @[]
  return model

proc newEventLogModel*(): EventLogModel =
  var eventLogModel = EventLogModel()
  eventLogModel.events = @[]
  return eventLogModel

type EditorModel* = ref object of RootObj
  isVisible*: bool
  higlitedLineNumber*: int
  # visibleLinesOfCode*: seq[string]
  tracePointEditorModels*: seq[TracePointEditorModel]

proc newEditorModel*(): EditorModel =
  var model = EditorModel()
  # model.visibleLinesOfCode = @[]
  model.tracePointEditorModels = @[]
  return model

type LayoutPageModel* = ref object of RootObj
  eventLogTabModels*: seq[EventLogModel]
  editorTabModels*: seq[EditorModel]
  programStateTabModels*: seq[ProgramStateModel]

proc newLayoutPageModel*(): LayoutPageModel =
  var layoutPageModel = LayoutPageModel()
  layoutPageModel.eventLogTabModels = @[]
  layoutPageModel.editorTabModels = @[]
  layoutPageModel.programStateTabModels = @[]

  return layoutPageModel


