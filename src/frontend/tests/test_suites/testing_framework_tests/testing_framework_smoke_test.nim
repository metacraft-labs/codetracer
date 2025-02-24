import
  sequtils, strutils, strformat, sets, macros, jsffi, async, jsconsole, algorithm, os, std/json, # os because `/`
  #chronicles,
  ../../../lib,
  ../../testing_framework/test_helpers,
  ../../testing_framework/selenium_web_driver,
  ../../testing_framework/extended_web_driver,
  ../../testing_framework/test_runner,
  ../../page_objects/layout_page,
  ../../page_objects/layout_page_model


#this tests if the testing framework itself is functioning as expected
proc testingFrameworkElementNotFoundExceptionTest*() {.async.} =
  var extendedDriver = test_helpers.driver

  var missingButton = findElement(extendedDriver, cstring"#noSuchButton", SelectorType.css)
  let missingButtonWaitTimes = 3

  var didThrowElementNotFoundException = false
  try:
    await missingButton.click()
    await wait(defaultWaitInterval)
  except ElementNotFoundException:
    didThrowElementNotFoundException = true

  if didThrowElementNotFoundException == false:
    raise Exception.newException("element not found exception was expected but not thrown")

  assertAreEqual(missingButton.waitElementRetryCount, missingButtonWaitTimes)

proc testingFrameworkExecuteAsyncScriptTest*() {.async.} =
  var layoutPage = LayoutPage()
  #await layoutPage.menuRootButton.click()
  await layoutPage.menuRootButton.jsClick()
  await wait(1000)
  await layoutPage.menuSearchTextBox.jsSendKeys("Zoom in\n")
  #await layoutPage.menuRootButton.jsSendKeys("Zoom in")

  await wait(1000)

  #await layoutPage.menuSearchTextBox.jsSendKeys("Zoom in")



  await wait(3000)
  #discard await executeAsyncScript(test_helpers.driver, "window.alert('test')")
