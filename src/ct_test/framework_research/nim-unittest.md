# Nim unittest Framework Research

## Framework Identity

| Field | Answer |
| ----- | ------ |
| Language | Nim |
| Framework | `std/unittest`, with researched status for `unittest2` and planned `unittest_parallel` |
| Framework versions researched | Nim stdlib documentation current as of 2026-06-10; `nim-lang/vscode-nim` README; `status-im/nim-unittest2` README |
| Package/project markers | `.nimble`, `nim.cfg`, `config.nims`, `tests/*.nim`, imports of `unittest`, `std/unittest`, `unittest2`, or `unittest_parallel` |
| Primary command-line tool | `nim c -r <file> [test filters...]`; `nimble test` for project-level conventions |
| CodeTracer recorder/backend used for recording | Native Nim recorder/backend, once `ct test record` is implemented |
| Minimum supported platform(s) | Same platforms as CodeTracer Nim tracing |

## Project Detection

- Detect Nim projects from `.nimble`, `nim.cfg`, `config.nims`, or `.nim` files.
- Detect framework usage from imports of `unittest`/`std/unittest`, `unittest2`, or `unittest_parallel`.
- For M2, the implemented provider is authoritative only for `std/unittest` source discovery. It reports diagnostics for `unittest2` and `unittest_parallel` instead of claiming full support.
- Nimble packages and nested test directories are supported by walking candidate `.nim` files under the workspace. Full Nimble workspace semantics are not implemented in M2.
- Commands require a working Nim compiler and any package dependencies in the user environment.

## Existing Editor Extension Research

- The primary VS Code extension is `nim-lang/vscode-nim`: <https://github.com/nim-lang/vscode-nim>
- Its README documents an experimental Test Explorer runner. It requires `unittest2 >= 0.2.4` and a configured `nim.test.entryPoint`, or Nimble `testEntryPoint`, and lists tests in VS Code's Test Explorer.
- The extension is language-server based for ordinary Nim editing and does not document `std/unittest` TestItem/CodeLens support.
- `nim-lang/langserver` README notes that listing/running tests requires `unittest2 >= 0.2.4` and a test entry point from the VS Code extension setting.
- `std/unittest` itself documents only command-line filtering by test name, suite prefix with `::`, and glob patterns. It does not expose machine-readable discovery or file/line metadata.
- `unittest2` documents a two-phase collect-and-run mode, isolated test procedures, JUnit output, and advanced listing/progress foundations. That makes it a better future source for exact discovery/run output than raw `std/unittest`, but M2 does not vendor or depend on it.
- For CodeTracer M2, source parsing is required for `std/unittest` editor placement because the framework does not report locations. The planned provider should later reconcile parsed locations with `unittest2`/`unittest_parallel` native listing when those protocols are available.

## Discovery

- Project discovery walks `.nim` candidates and parses files that import a supported unittest module.
- File discovery parses one `.nim` file and returns `suite` and `test` template calls with source ranges.
- `std/unittest` has no machine-readable discovery output.
- `std/unittest` test names are string literals passed to the `test` template. Suites are string literals passed to the `suite` template.
- Nested suites are source-derived by indentation and represented as suite selector paths.
- Skipped tests use `skip()` in the body; M2 tags tests containing `skip` only when future body analysis is added. The first implementation only locates declarations.
- Parameterized/generated tests are not a first-class `std/unittest` feature. Loop-generated or macro-generated tests require a diagnostic if they cannot be represented as stable source items.

## Location Strategy

| Source | Used? | Notes |
| ------ | ----- | ----- |
| External adapter reports exact file/range | No | Future option for `unittest2`/`unittest_parallel` native tooling. |
| Framework-native discovery reports file/line | No for `std/unittest` | Not available. |
| Language server reports test/runnable ranges | No | Nim VS Code Test Explorer path is tied to `unittest2`, not documented for stdlib. |
| Tree-sitter query rules | No | Good future replacement if a maintained Nim grammar is available in CodeTracer. |
| Language-native parser rules | Partial | M2 uses a lightweight lexical Nim scanner, not full semantic parsing. |
| Declarative pattern rules | Candidate only | `.nim` files and import markers filter candidates. |
| Regex/file-name fallback | Candidate only | No runnable `TestItem` is created from filename matching alone. |

- The M2 scanner ignores comments and strings, then recognizes `suite "name":` and `test "name":` calls.
- It intentionally does not claim macro-perfect support for aliases, dynamically computed names, templates wrapping `test`, or generated tests.
- Unsupported dynamic cases should produce diagnostics once they are detectable without false positives.

## Selectors and Stable IDs

- Single `std/unittest` selector: the test name argument, optionally qualified as `suite path::test name`.
- File selector: the source file path. A future runner compiles and runs that file.
- Project selector: the workspace root or Nimble test entry point.
- Suite selector: `suite path::`.
- Stable `TestItem.id`: provider/language/framework/file plus normalized selector.
- Duplicate test selectors in one file are ambiguous for single-test execution and must be diagnosed before run support is enabled.

## Execution Commands

| Operation | Command |
| --------- | ------- |
| Discover project | Source parse in `ct-test`; no stdlib command exists. |
| Discover file | Source parse in `ct-test`; no stdlib command exists. |
| Run project | Future: `nimble test` or configured project command. |
| Run file | Future: `nim c -r {file}` |
| Run single test | Future: `nim c -r {file} "{selector}"` |
| Run with JSON/event output | Not available in `std/unittest`; requires output parsing or adapter instrumentation. |
| Run with no color/no progress UI | `NIMTEST_NO_COLOR=1` or `NIMTEST_COLOR=never` where supported. |
| Run with deterministic ordering if supported | Source order is the default for stdlib tests. |

## Recording Commands

- Future single-test recording wraps `nim c -r {file} "{selector}"` with the CodeTracer Nim recorder.
- Batch/file recording should produce one trace per selected test once selector-level execution and trace metadata are wired.
- `std/unittest` has no per-test trace metadata hook, so CodeTracer must store selector/file metadata at launch time or instrument the runner.

## Entry Point Identification

- Source entry point is the line/range of the `test` template call.
- Runtime entry should eventually be the generated test body or `unittest` formatter callback around `testStarted`.
- `std/unittest` callbacks expose test names but not source locations.
- Setup/teardown and nested suites affect execution context but not M2 source ranges.

## Output and Result Capture

- Whole-run stdout/stderr can be captured from the test process.
- `std/unittest` prints test started/ended messages, but robust per-test attribution requires parsing or custom formatter instrumentation.
- JUnit output is not part of `std/unittest`; `unittest2` documents JUnit-compatible reports.
- Crashes and compile failures must be represented as diagnostic/error events in later milestones.

## Parallelism, Isolation, and Scheduling

- `std/unittest` runs sequentially in process.
- CodeTracer can run one process per selector for isolation once run support exists, but shared files/databases/ports remain user test concerns.
- `unittest_parallel` is planned to provide the stronger listing/running protocol for future parallel scheduling.

## Incremental Testing

- M2 discovery cache is keyed by file hash and relevant Nim config files.
- Future affected-test analysis can use import graphs, Nim compile dependency data, or trace-derived call data.
- Config invalidators: `.nimble`, `nim.cfg`, `config.nims`, and future `ct-test` framework config.

## Adapter Implementation Plan

- Nim module name: `ct_test/frameworks/nim_unittest.nim`
- Provider ID: `nim-unittest`
- Adapter manifest path: none for M2
- External adapter binary: none for M2
- Location strategy: lexical parser source ranges for stdlib declarations
- Declarative tree-sitter/pattern rules file: none for M2
- Implemented commands: `detect`, `discoverProject`, `discoverFile`, `locateTests`
- Not implemented in M2: `run`, `record`, `parseEvent`, `mapTraceEntryPoints`
- Declarative behavior: candidate `.nim` files and config markers
- Imperative behavior: import detection, source scanning, selector construction, diagnostics
- Contract feedback: final provider API should let external adapters report exact ranges, while lightweight parser/pattern rules remain valid for frameworks like stdlib Nim unittest.

## Fixture and Test Plan

- Minimal fixture project: `src/ct_test/fixtures/nim_unittest_project`
- Fixture cases:
  - passing test
  - failing test
  - skipped test via `skip()`
  - nested suites
  - commented-out tests and string literals containing fake tests
  - async-shaped test body using a proc call without requiring async runtime execution
  - unsupported `unittest2`/`unittest_parallel` imports
- Required `ct test discover` assertions: provider id, schema version, source lines, selectors, ignored comments/strings, project aggregation, unsupported diagnostics.
- Run/record/trace-open assertions are deferred because M2 implements discovery only.

## Risks and Open Questions

- `std/unittest` has no native discovery or structured result output.
- Macro-generated or dynamically named tests cannot be discovered reliably by M2.
- Duplicate selectors need a stronger policy before single-test run support.
- `unittest2` Test Explorer support should be researched from source before implementing that adapter.
- `unittest_parallel` protocol must be frozen before CodeTracer claims native list/run/record capabilities for it.
