import
  sequtils, strutils, strformat, sets, macros, jsffi, async, jsconsole, algorithm, os, std/json,
  ../../../lib,
  ../../testing_framework/test_helpers,
  ../../testing_framework/selenium_web_driver,
  ../../testing_framework/extended_web_driver,
  ../../testing_framework/test_runner,
  ../../page_objects/layout_page,
  ../../page_objects/layout_page_model

proc findAllMenuElements*(): Future[void] {.async.} =
  var layoutPage = LayoutPage()
  for key, value in layoutPage.menuItemChain:
    echo await (await layoutPage.menuItem(key)).text
