import
  /layout_page,
  ../testing_framework/extended_web_driver,
  base_page,
  async,
  strutils,
  lib,
  strformat,
  sequtils,
  sets,
  macros,
  os,
  jsffi,
  jsconsole,
  tables,
  /layout_page_model

proc extractModel*(tab: ProgramStateTab): Future[ProgramStateModel] {.async.} =
  var tabModel = newProgramStateModel()
  for variable in (await tab.programStateVariables(true)):
    var variableModel = VariableStateModel()
    variableModel.name = $(await variable.name())
    variableModel.valueType = $(await variable.valueType())
    variableModel.value = $(await variable.value())
    tabmodel.variableStates.add(variableModel)
  return tabModel

proc extractModel*(tab: EventLogTab): Future[EventLogModel] {.async.} =
  var model = newEventLogModel()

  model.isVisible = await tab.isVisible()

  if model.isVisible:
    let eventElements = await tab.eventElements(true)
    for eventElement in eventElements:
      var eventData = EventDataModel()

      # eventData.tickCount = await tickCount(eventElement)
      # eventData.index = await index(eventElement)
      eventData.consoleOutput = $(await consoleOutput(eventElement))

      model.events.add(eventData)

    #model.rows = await tab.rows
    #echo &"######### rows: {model.rows}"
    #model.toRow = await tab.toRow
    #echo &"######### toRow: {model.toRow}"
    model.ofRows = await tab.ofRows
    #echo &"######### ofRows: {model.ofRows}"

  return model

proc extractModel*(traceEditor: TracepointEditor): Future[TracePointEditorModel] {.async.} =
  var traceModel = newTracePointEditorModel()

  traceModel.fileName = $(traceEditor.parentEditorTab.fileName)
  traceModel.lineNumber = traceEditor.lineNumber

  traceModel.code = $(await traceEditor.editTextBox.text())

  let eventElements = await eventElements(traceEditor, true)

  for eventElement in eventElements:
    var eventModel = newEventDataModel()
    # eventModel.tickCount = await eventElement.tickCount()
    eventModel.consoleOutput = $(await eventElement.consoleOutput())
    traceModel.events.add(eventModel)

  return traceModel

proc extractModel*(tab: EditorTab): Future[EditorModel] {.async.} =
  var model = newEditorModel()

  model.isVisible = await tab.isVisible()

  if model.isVisible:
    model.higlitedLineNumber = await tab.highlightedLineNumber()

    let tracePointEditors = await tab.tracePointEditors()
    for tracePointEditor in tracePointEditors:
      model.tracePointEditorModels.add(await tracePointEditor.extractModel())

    # var textRows = await tab.visibleTextRows
    # for textRow in textRows:
    #   model.visibleLinesOfCode.add($(await textRow.root.text))

  return model

proc extractModel*(page: LayoutPage): Future[LayoutPageModel] {.async.} =
  var layoutPageModel = newLayoutPageModel()

  let eventLogTabs = await page.eventLogtabs(true)
  for tab in eventLogtabs:
    let tabModel = await extractModel(tab)
    layoutPageModel.eventlogtabModels.add(tabModel)

  let editorTabs = await page.editorTabs(true)
  for tab in editorTabs:
    let tabModel = await extractModel(tab)
    layoutPageModel.editorTabModels.add(tabModel)

  let programStateTabs = await page.programStateTabs(true)
  for tab in programStateTabs:
    let tabModel = await extractModel(tab)
    layoutPageModel.programStateTabModels.add(tabModel)

  return layoutPageModel