import strformat, strutils, sequtils, macros, async

import ../testing_framework/test_helpers, ../../lib, ../../paths,
  ../testing_framework/codetracer_test_runner,
  ../testing_framework/extended_web_driver,
  ../testing_framework/test_helpers,
  ../page_objects/base_page,
  ../page_objects/layout_page,
  ../test_suites/regression_tests/run_to_entry,
  ../test_suites/regression_tests/event_log_jump_to_all_events,
  ../test_suites/testing_framework_tests/testing_framework_smoke_test

var suite = asyncTestSuite(
    name = "quicksort",
    beforeEach = ctBeforeEach,
    before = ctBefore,
    after = ctAfter,
    afterEach = ctAfterEach,
    defaultDomainArg = "quicksort",
    defaultModes = DEFAULT_LANGS):

  test("Jump to all events"):
    await wait(5_000)
    await jumpToAllEventsOnce(
      cstring &"{codetracerTestDir}programs/quicksort/{getExtension(runner.mode)}",
      cstring "jump_to_all_events",
      runner.mode)

discard codetracerTestEntrypoint(suite)
