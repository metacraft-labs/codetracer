import strformat, strutils, sequtils, macros, async, ../../lang

import ../testing_framework/test_helpers, ../../lib, ../../paths,
  ../testing_framework/codetracer_test_runner,
  ../testing_framework/extended_web_driver,
  ../testing_framework/test_helpers,
  ../page_objects/base_page,
  ../page_objects/layout_page,
  ../test_suites/regression_tests/run_to_entry,
  ../test_suites/regression_tests/event_log_jump_to_all_events,
  ../test_suites/regression_tests/tracepoint_tests,
  ../test_suites/testing_framework_tests/testing_framework_smoke_test,
  ../test_suites/regression_tests/menu_find_all_elements,
  ../page_objects/layout_page_model


var suite = asyncTestSuite(
    name = "fibonacci",
    beforeEach = ctBeforeEach,
    before = ctBefore,
    after = ctAfter,
    afterEach = ctAfterEach,
    defaultDomainArg = "fibonacci",
    defaultModes = DEFAULT_LANGS):

    test("C compare trace point snapshots", {LangC}):
      await wait(7500)
      var tracepoints: seq[TracePointEditorModel] = @[]

      var lineNumber: int
      var fileName: string
      var code: string

      lineNumber = 6
      fileName = "fibonacci.c"
      code = "log(n)"
      tracepoints.add(newTracePointEditorModel(lineNumber, fileName, code))

      lineNumber = 8
      fileName = "fibonacci.c"
      code = "log(n)"
      tracepoints.add(newTracePointEditorModel(lineNumber, fileName, code))

      lineNumber = 10
      fileName = "fibonacci.c"
      code = "log(n)"
      tracepoints.add(newTracePointEditorModel(lineNumber, fileName, code))

      let filePath = cstring &"{codetracerTestDir}programs/fibonacci/{getExtension(runner.mode)}"
      let testName = cstring "compare_trace_snapshots"


      await compareTracePointSnapshots(tracepoints, filePath, testName)


discard codetracerTestEntrypoint(suite)
