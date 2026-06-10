# Catch2 M10 research notes

## Detection

- Project files: `CMakeLists.txt` commonly contains `find_package(Catch2 3)`,
  `Catch2::Catch2WithMain`, or `catch_discover_tests`.
- Source files: `#include <catch2/catch_test_macros.hpp>`, `TEST_CASE`,
  `SCENARIO`, and `SECTION`.
- Build artifacts: CMake/CTest files are present when `catch_discover_tests`
  or explicit `add_test` registration is used.

## Discovery and list output

- Framework-native list command: `<test-executable> --list-tests` or
  `<test-executable> --list-tests --verbosity high`.
- Listed test names match the string passed to `TEST_CASE` or `SCENARIO`.
- Catch2 sections are not standalone test selectors in list output; they are
  execution paths inside a test case. M10 records `SECTION` ranges as
  source-only suite/context items when found.

## Run commands

- Project scope: run the executable with no selector, or use CTest when CMake
  owns all test registration.
- File scope: Catch2 has no source-file selector. M10 can run parsed test
  cases from a file individually when a catalog is available; the command
  builder exposes the executable fallback.
- Single test: `<test-executable> "test name"`.

## Source locations

- `TEST_CASE("name", "[tags]")` and `SCENARIO("name")` produce case items.
- `SECTION("name")` is tracked as source context under the previous test case
  where feasible.
- The M10 parser masks comments and strings before matching macro names, so
  commented-out and string-literal examples are ignored.

## Output and status capture

- Exit code `0` means pass. Non-zero means failed assertions or runner error.
- Human-readable stdout/stderr is captured. Catch2 XML/JUnit reporters can
  improve structured result parsing in a later slice.

## Recording

- Native recording wraps a single-test command:
  `ct-mcr record --use-interpose --output <trace.ct> -- <test-executable>
  "test name"`.
- M10 attempts real recording only when `CODETRACER_CT_MCR_CMD`, `ct-mcr`, or
  the sibling `codetracer-native-recorder/ct_cli/ct_cli` is available.

## Limitations

- Section-level single recording is not precise in M10 because Catch2 selects
  test cases, not individual sections, through the stable CLI selector.
- Hidden tests and tag expressions are not expanded into separate selectors.
- Arbitrary generated macro names are out of scope for the lightweight parser.
