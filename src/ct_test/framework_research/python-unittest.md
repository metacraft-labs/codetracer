# Python unittest Framework Research

## Framework Identity

| Field | Answer |
| ----- | ------ |
| Language | Python |
| Framework | unittest |
| Framework versions researched | Python 3 standard library unittest |
| Package/project markers | unittest-style files/classes/methods, VS Code unittest settings, `test*.py` default discovery pattern |
| Primary command-line tool | `python -m unittest` |
| CodeTracer recorder/backend used for recording | Python recorder, not wired in M5 |
| Minimum supported platform(s) | Same as Python standard library support and CodeTracer Python recording support |

## Project Detection

- Default provider detects unittest only when pytest config is absent.
- It scans Python files whose names contain `test` and requires a
  `unittest.TestCase` or imported `TestCase` subclass with `test*` methods.
- Explicit provider use can still call `python-unittest` directly in tests or a
  future CLI selector even if pytest config is present.
- Native unittest discovery imports test modules, so environment setup and
  importability matter.

## Existing Editor Extension Research

- VS Code's Python extension supports `unittest` through the same built-in
  Testing UI as pytest. Docs state the default `unittestArgs` search looks for
  Python files with `test` in the name in the top-level folder; file pattern and
  top-level directory are configurable.
- The docs also state that when both pytest and unittest are enabled, the
  Python extension only runs pytest.
- VS Code Testing API placement still depends on extension-provided `TestItem`
  ranges.
- Current VS Code Python discussions note the rewritten adapter uses unittest
  itself to discover tests and imports code during discovery.
- `unittest` native discovery returns `TestSuite`/`TestCase` objects, not a
  stable editor range model. Ranges should therefore be source-derived and
  reconciled with native selectors.

Sources:

- VS Code Python testing docs:
  https://code.visualstudio.com/docs/python/testing
- VS Code Testing API docs:
  https://code.visualstudio.com/api/extension-guides/testing
- Microsoft vscode-python unittest adapter discussion:
  https://github.com/microsoft/vscode-python/discussions/22604
- Python unittest documentation:
  https://docs.python.org/3/library/unittest.html

## Discovery

- Project discovery: `python -m unittest discover -s . -p test*.py -t .`.
- File discovery: `python -m unittest {module}`.
- Single test discovery/execution selector:
  `{module}.{TestCaseSubclass}.{test_method}`.
- M5 source discovery parses sanitized Python source and creates suite items for
  `unittest.TestCase`/`TestCase` subclasses plus case items for their `test*`
  methods.
- `unittest.skip` decorators are represented as tags only.
- `subTest` cases are not represented as separate source items because they are
  runtime-generated inside one method.

## Location Strategy

| Source | Used? | Notes |
| ------ | ----- | ----- |
| External adapter reports exact file/range | Future | Useful if a Python adapter combines unittest discovery with AST ranges |
| Framework-native discovery reports file/line | No | Native unittest discovery does not provide a reliable range contract |
| Language server reports test/runnable ranges | No | Not needed in M5 |
| Tree-sitter query rules | Future option | Good declarative replacement for the M5 parser |
| Language-native parser rules | M5 partial | Lightweight source parser over sanitized source |
| Declarative pattern rules | Candidate files/classes/methods | `test*.py`, `TestCase`, `test*` |
| Regex/file-name fallback | Candidate files only | Never creates runnable items by itself |

## Selectors and Stable IDs

- Single test selector:
  `tests.test_sample.CalculatorCase.test_adds`.
- File selector: module name derived from the workspace-relative file path.
- Project selector: `discover -s . -p test*.py -t .`.
- Subtests have no stable source selector in M5.
- Stable `TestItem.id`: provider/language/framework/relative file plus
  unittest selector.

## Execution Commands

| Operation | Command |
| --------- | ------- |
| Discover project | `python -m unittest discover -s . -p test*.py -t .` |
| Discover file | `python -m unittest {module}` |
| Run project | `python -m unittest discover -s . -p test*.py -t .` |
| Run file | `python -m unittest {module}` |
| Run single test | `python -m unittest {module}.{Class}.{method}` |
| Run with JSON/event output | Future adapter JSON stream |
| Run with no color/no progress UI | unittest has plain text output by default |
| Run with deterministic ordering if supported | unittest loader sorts test method names by default |

## Recording Commands

- `ct test record` should wrap `python -m unittest {selector}` with the Python
  recorder for one trace per selected method.
- File/project recording should probably enumerate methods first and record
  them individually.
- M5 does not invoke the recorder.

## Entry Point Identification

- Entry point is the `test*` method on a `unittest.TestCase` subclass.
- `setUp`, `tearDown`, class fixtures, and `subTest` blocks need trace metadata
  once recording is wired.

## Output and Result Capture

- Whole-run stdout/stderr are process-level streams.
- Per-test status, duration, failure text, errors, and skip reasons need a
  custom `unittest.TextTestResult` or adapter-produced JSON stream.
- M5 exposes no event parser.

## Parallelism, Isolation, and Scheduling

- Standard unittest is serial.
- One process per selected test is viable for recording, subject to shared
  fixtures and external resources.

## Incremental Testing

- Discovery cache invalidates on source file hash and Python testing config
  files.
- Future affected-test logic can use imports, coverage, and trace dependencies.

## Adapter Implementation Plan

- Nim module name: `frameworks/python_unittest.nim`
- Provider ID: `python-unittest`
- Adapter manifest path: future
- External adapter binary: future Python adapter likely needed for structured
  per-test events.
- Location strategy: M5 parser now, native unittest selector reconciliation
  before execution later.
- Required commands implemented by the module: `detect`, `discoverProject`,
  `discoverFile`, `locateTests`; `run`, `record`, `parseEvent`, and
  `mapTraceEntryPoints` return explicit unsupported diagnostics.

## Fixture and Test Plan

- Fixture project: `src/ct_test/fixtures/python_unittest_project`
- Cases: `unittest.TestCase` subclasses, methods, skip decorator, imported
  `TestCase`, fake tests in comments and strings, non-TestCase class with
  `test*` method.
- Required assertions: selectors, ranges, provider precedence against pytest,
  CLI JSON schema, command construction, unsupported record diagnostics.

## Risks and Open Questions

- Source-only parsing handles direct `unittest.TestCase` and imported
  `TestCase`, but not aliases or dynamically generated subclasses.
- Native discovery imports test modules, so collection can fail for reasons the
  source parser cannot see.
- `subTest` cannot be represented as independent M5 items.
