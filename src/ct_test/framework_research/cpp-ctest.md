# CTest M10 research notes

## Detection

- Project files: `CMakeLists.txt` containing `enable_testing()` or `add_test`.
- Build artifacts: `CTestTestfile.cmake` in the build tree or project root.
- CTest is treated as an executable-level fallback, not a source framework.

## Discovery and list output

- Native list command: `ctest --test-dir <build-dir> -N`.
- Output contains lines like `Test #1: fallback_smoke`.
- `CTestTestfile.cmake` also contains `add_test(...)` entries that can be
  parsed without running CTest.

## Run commands

- Project scope: `ctest --test-dir <build-dir> --output-on-failure`.
- Single test: `ctest --test-dir <build-dir> --output-on-failure -R
  ^test_name$`.
- File scope: unsupported. CTest has no portable source-file mapping.

## Source locations

- CTest does not know source ranges for GoogleTest/Catch2 macros. The fallback
  provider reports locations in `CTestTestfile.cmake` for the `add_test`
  entries.
- Source-level locations should come from framework providers when available.

## Output and status capture

- CTest exit code `0` means selected tests passed.
- Non-zero means at least one selected test failed or CTest itself errored.
- `--output-on-failure` captures failing test output.

## Recording

- M10 does not advertise CTest recording. CTest can wrap many executables and
  has no stable framework-native single-test command, so trace attribution
  would be ambiguous.

## Limitations

- Executable-level fallback cannot map a CTest test back to source macros.
- Generated CTest files vary by generator and helper module.
- Regex selection with `-R` can match multiple tests if names are not unique;
  M10 anchors the regex to reduce accidental matches.
