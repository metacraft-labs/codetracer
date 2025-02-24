import
  sequtils, strutils, strformat, sets, macros, jsffi, async, jsconsole, algorithm, os, std/json,
  ../../../lib,
  ../../testing_framework/test_helpers,
  ../../testing_framework/selenium_web_driver,
  ../../testing_framework/extended_web_driver,
  ../../testing_framework/test_runner,
  ../../page_objects/layout_page,
  ../../page_objects/layout_page_model

proc strartProgramAndPressRunToEntryTest*(filePath: cstring, fileName: cstring): Future[void] {.async.} =
  let layoutPage = LayoutPage()

  #TEST_TODO: use dynamic wait instead
  await wait(10000)
  await layoutPage.runToEntryButton.click()

  #TEST_TODO: use dynamic wait instead
  await wait(2000)
  let editorTabs = await layoutPage.editorTabs(true)

  for tab in editorTabs:
    if tab.tabButtonText == "NO SOURCE":
      raise UnexpectedTestResult.newException(&"""An "NO SOURCE" tab has been opened.
  Steps to reproduce:
  1. Open code tracer using {filePath}/{fileName}
  2. Click on the run to entry button

  Expected result:
  CodeTracer should jump to apropiate line of code

  Actual result:
  A new tab with the title "Unknown" has been opened""")

