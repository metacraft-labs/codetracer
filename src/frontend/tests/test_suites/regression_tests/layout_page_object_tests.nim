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


# this test is for rr_gdb.rs only
proc tryEditorPaneLocators*(): Future[void] {.async.} =
  # todo: replace the wait below with waitPageLoad function
  await wait(5000)

  let layoutPage = LayoutPage()

  var firstStateTab = (await layoutPage.programStateTabs)[0]

  #await firstStateTab.watchExpressionTextBox.click()

  var firstEditorTab = (await layoutPage.editorTabs)[0]

  var textRows = (await firstEditorTab.visibleTextRows())

  var tracePoint = await firstEditorTab.openTracePointEditor(138)

  await wait(250)

  await tracePoint.editTextBox.sendKeys("log(1)")

  await wait(250)

  await layoutPage.runTracePoints()

  await wait(2000)

  var snapshot = await layoutPage.extractModel()

  let expectedText = "\"1=1\""
  if $(%snapshot.editorTabModels[0].tracePointEditorModels[0].events[0].consoleOutput) != expectedText:
    raise UnexpectedTestResult.newException(&"Problem reading Tracelog editor events, expexted: {expectedText}, actual: {$(%snapshot.editorTabModels[0].tracePointEditorModels[0].events[0].consoleOutput)}")

  let expectedEventCount = 2
  if snapshot.editorTabModels[0].tracePointEditorModels[0].events.len != expectedEventCount:
    raise UnexpectedTestResult.newException(&"Problem reading Tracelog editor events, expected trace event count: {expectedEventCount} events, actual: {snapshot.editorTabModels[0].tracePointEditorModels[0].events.len}")

  return


