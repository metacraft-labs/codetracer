# GoogleTest M10 research notes

## Detection

- Project files: `CMakeLists.txt` commonly contains `find_package(GTest)`,
  `GTest::gtest_main`, `gtest_discover_tests`, or `gtest_add_tests`.
- Source files: `#include <gtest/gtest.h>`, `#include <gmock/...>`, and
  macros `TEST`, `TEST_F`, `TEST_P`.
- Build artifacts: a CMake build with `enable_testing()` usually writes
  `CTestTestfile.cmake` entries for GoogleTest executables when
  `gtest_discover_tests` or `add_test` is used.

## Discovery and list output

- Framework-native list command: `<test-executable> --gtest_list_tests`.
- Output groups tests by suite line ending in `.`, followed by indented test
  names. Parameterized tests are listed with generated instance names.
- The list output does not include source file or range. M10 reconciles
  source macro selectors such as `MathTest.AddsNumbers` with listed selectors.

## Run commands

- Project scope: run the executable with no filter, or `ctest --test-dir build`
  when CTest owns all executables.
- File scope: GoogleTest has no first-class source-file filter. M10 can run
  the selectors parsed from a file or use a conservative executable run.
- Single test: `<test-executable> --gtest_filter=Suite.Test`.

## Source locations

- Common source macros: `TEST(Suite, Name)`, `TEST_F(Fixture, Name)`,
  `TEST_P(Fixture, Name)`.
- Source ranges are produced by a lightweight parser that masks comments and
  strings and tracks macro call start/end positions. This covers common
  multiline macros but not arbitrary preprocessor metaprogramming.

## Output and status capture

- Exit code `0` means the selected tests passed. Non-zero means failure or
  runner error.
- Standard output contains the human-readable per-test log. GoogleTest XML
  can provide structured results but is not required for M10.

## Recording

- Native recording should wrap the exact single-test command with
  `ct-mcr record --use-interpose --output <trace.ct> -- <test-executable>
  --gtest_filter=Suite.Test`.
- M10 only advertises single-test recording. Project/file recording remains
  unsupported because it would produce broad traces with ambiguous test
  attribution.

## Limitations

- Generated/typed/parameterized test instance names can differ from macro
  selectors; those are marked with lower confidence unless list output
  confirms the exact selector.
- GoogleTest does not expose source ranges in list output.
- Executable discovery from arbitrary build systems remains best-effort.
