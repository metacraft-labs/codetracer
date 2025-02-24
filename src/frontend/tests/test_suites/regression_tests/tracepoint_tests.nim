import
  std / [
    sequtils, strutils, strformat, sets,
    macros, jsffi, async, jsconsole,
    algorithm, os, json
  ],
  lib,
  ../../testing_framework/test_helpers,
  ../../testing_framework/selenium_web_driver,
  ../../testing_framework/extended_web_driver,
  ../../testing_framework/test_runner,
  ../../page_objects/layout_page,
  ../../page_objects/layout_page_model,
  ../../page_objects/layout_page_model_extractors,
  ../../../lang

type TestParameters = object
  folderPath: cstring
  fileName: cstring
  isSourceGenerated: bool
  sourceGeneratorFilePath: cstring

proc newTestParameters(): TestParameters =
  var testPatrameters = TestParameters()

  #currently there are no lists or objects to be initialized but if such
  #are added in the future to TestParameters then it should be done here

  return testPatrameters

proc getTestParamsFromEnvironment(): TestParameters =
  let json = JSON.parse(nodeProcess.argv[2])
  let testParameters = cast[TestParameters](json)
  return testParameters

proc simpleTracepointReload*(lineNumber: int): Future[void] {.async.} =
  var layoutPage = LayoutPage()

  var editor = (await layoutPage.editorTabs)[0]

  var tracePointEditor = await editor.openTracePointEditor(lineNumber)

  for i in 0 .. 5:
    await tracePointEditor.editTextBox.sendKeys(&"log({i})")
    await layoutPage.runTracePoints()
    await wait(1000)
    let snapshot = await layoutPage.extractModel()

    if snapshot.editorTabModels[0].tracePointEditorModels[0].events[0].consoleOutput != &"{i}={i}":
      raise UnexpectedTestResult.newException(&"Trace points do not refresh after {i} reloads")


proc compareTracePointSnapshots*(traceModels: seq[TracePointEditorModel], filePath: cstring, testName: cstring): Future[void] {.async.} =
  let expectedFilePath = &"{filePath}/{testName}_expected.txt"
  let actualFilePath = &"{filePath}/{testName}_actual.txt"

  let page = LayoutPage()

  var snapshots: seq[LayoutPageModel] = @[]

  for traceModel in traceModels:
    let tracePoint = await openTracePointEditor(page, traceModel)
    await page.runTracePoints()
    
    # TODO: add dynamic wait
    await wait(5000)

    snapshots.add(await extractModel(page))

  let expectedFileExists = await pathExists(expectedFilePath)
  if not expectedFileExists:
    echo &"Creating new expected file at: {expectedFilePath}"
    for snapshot in snapshots:
      discard await fsPromises.appendFile(expectedFilePath, &"{%snapshot}\n")
  else:
    # clear the current expected file with the line of code below
    discard await fsPromises.writeFile(actualFilePath, cstring "", js{})

    for snapshot in snapshots:
      discard await fsPromises.appendFile(actualFilePath, &"{%snapshot}\n")



