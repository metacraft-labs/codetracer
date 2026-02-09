## DeepReview Test Plan
##
## This file documents the test cases for M3: DeepReview GUI - Local .dr File Loading.
## The tests verify that the ``--deepreview <path>`` CLI argument correctly loads
## a DeepReview JSON export file and renders it in the CodeTracer GUI.
##
## Implementation note: actual Playwright E2E tests live in ``tsc-ui-tests/``
## and require a full Electron build + launch. This file serves as a reference
## for the required test coverage.
##
## =========================================================================
## Test 1: CLI argument parsing
## =========================================================================
## - Invoke the application with ``--deepreview <valid-json-file>``
## - Assert that ``data.startOptions.withDeepReview`` is ``true``
## - Assert that ``data.startOptions.deepReview`` is non-nil and contains
##   the expected ``commitSha`` from the JSON file
##
## =========================================================================
## Test 2: File list sidebar rendering
## =========================================================================
## - Load a DeepReview JSON with 3 files
## - Assert that the ``.deepreview-file-list`` contains 3 items
## - Assert each item shows the correct basename
## - Assert the first item has the ``selected`` class by default
##
## =========================================================================
## Test 3: Coverage highlighting
## =========================================================================
## - Load a DeepReview JSON with coverage data
## - Assert that executed lines have the ``deepreview-line-executed`` decoration
## - Assert that unreachable lines have ``deepreview-line-unreachable``
## - Assert that partial lines have ``deepreview-line-partial``
##
## =========================================================================
## Test 4: Inline variable values
## =========================================================================
## - Load a DeepReview JSON with flow data containing variable values
## - Assert that inline decorations appear with the ``deepreview-inline-value``
##   class showing the variable name and value
## - Assert that truncated values display an ellipsis marker
##
## =========================================================================
## Test 5: File switching
## =========================================================================
## - Load a multi-file DeepReview JSON
## - Click on the second file in the sidebar
## - Assert the second file item now has the ``selected`` class
## - Assert the editor content updates to reflect the second file
## - Assert decorations update to match the second file's coverage
##
## =========================================================================
## Test 6: Execution slider
## =========================================================================
## - Load a DeepReview JSON with multiple function executions
## - Assert the execution slider is visible and shows "1/N"
## - Move the slider to a different execution index
## - Assert the inline value decorations update accordingly
##
## =========================================================================
## Test 7: Loop iteration slider
## =========================================================================
## - Load a DeepReview JSON with loop data
## - Assert the loop slider is visible
## - Move the slider to a different iteration
## - Assert the UI updates the displayed iteration count
##
## =========================================================================
## Test 8: Call trace panel
## =========================================================================
## - Load a DeepReview JSON with call trace data
## - Assert the ``.deepreview-calltrace`` panel is visible
## - Assert the root node name and execution count are displayed
## - Assert child nodes are rendered with indentation
##
## =========================================================================
## Test 9: Empty/missing data handling
## =========================================================================
## - Load a DeepReview JSON with no files (empty ``files`` array)
## - Assert the component renders without errors
## - Assert a placeholder message is shown
## - Load with nil/missing call trace: assert no crash
## - Load with a file that has no coverage data: assert no crash
##   and the coverage badge shows "--"
