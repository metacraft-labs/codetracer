import strformat, strutils, sequtils, macros, async, ../../lang

import  ../../lib, ../../paths,
  ../testing_framework/codetracer_test_runner,
  ../testing_framework/extended_web_driver,
  ../testing_framework/test_helpers,
  ../page_objects/base_page,
  ../page_objects/layout_page,
  ../test_suites/regression_tests/run_to_entry,
  ../test_suites/regression_tests/event_log_jump_to_all_events,
  ../test_suites/testing_framework_tests/testing_framework_smoke_test,
  ../test_suites/regression_tests/menu_find_all_elements,
  ../test_suites/regression_tests/layout_page_object_tests,
  ../test_suites/regression_tests/tracepoint_tests


var suite = asyncTestSuite(
    name = "rr_gdb_ui_tests",
    beforeEach = ctBeforeEach,
    before = ctBefore,
    after = ctAfter,
    afterEach = ctAfterEach,
    defaultDomainArg = "rr_gdb",
    defaultModes = DEFAULT_LANGS):

  test("Event log: Jump to all events"):
   echo runner.mode
   await jumpToAllEventsOnce(
     cstring &"{codetracerTestDir}programs/rr_gdb/{getExtension(runner.mode)}",
     cstring "jump_to_all_events",
     runner.mode)

  test("Testing Framework: Element not found, Execute async script"):
    await testingFrameworkElementNotFoundExceptionTest()
    await testingFrameworkExecuteAsyncScriptTest()

  test("Menu: Find All Elements", {LangC}):
    await findAllMenuElements()

  test("Try Editor Pane Locators", {LangRust}):
    await tryEditorPaneLocators()

  test("Tracepoint: simpleTracepointReload", {LangRust}):
    await wait(5_000)
    await simpleTracepointReload(17)


discard codetracerTestEntrypoint(suite)
