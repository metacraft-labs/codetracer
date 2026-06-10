# Python pytest Framework Research

## Framework Identity

| Field | Answer |
| ----- | ------ |
| Language | Python |
| Framework | pytest |
| Framework versions researched | pytest 7+ behavior, pytest 9 docs where available |
| Package/project markers | `pytest.ini`, `[tool.pytest.ini_options]` in `pyproject.toml`, `[pytest]` in `tox.ini` or `setup.cfg`, candidate `test_*.py` and `*_test.py` files |
| Primary command-line tool | `python -m pytest` |
| CodeTracer recorder/backend used for recording | Python recorder, not wired in M5 |
| Minimum supported platform(s) | Same as CodeTracer Python recording support; source discovery is platform-independent |

## Project Detection

- Detect explicit pytest configuration first: `pytest.ini`, `pyproject.toml`,
  `tox.ini`, and `setup.cfg`.
- Without config, scan candidate files named `test_*.py` or `*_test.py` and
  require source-discoverable pytest-style items before enabling the provider.
- If pytest config is present, pytest is the default Python provider and the
  default unittest provider should stand down unless explicitly requested.
- Monorepos can contain multiple pytest roots; M5 treats the requested
  workspace as one root and records config files in the discovery cache inputs.

## Existing Editor Extension Research

- VS Code's Python extension supports pytest and unittest through the built-in
  VS Code Testing UI. Its user docs say pytest discovery defaults to Python
  files named `test_*.py` or `*_test.py`, and that if both pytest and unittest
  are enabled only pytest runs.
- VS Code Testing API `TestItem`s carry `uri` and `range`; extensions decide
  how and when to discover tests, including lazy open-file discovery and full
  workspace discovery.
- Current `microsoft/vscode-python` pytest support uses a bundled pytest plugin
  under `python_files/vscode_pytest`. Discovery runs pytest with
  `--collect-only`, builds a test tree from `session.items`, uses pytest node
  IDs as run IDs, and includes source line data. Function/item lines come from
  pytest item metadata; class lines are recovered with `inspect.getsourcelines`.
- The extension has special handling for parametrized tests: pytest collected
  cases become children under a function node whose ID is based on the original
  function name, while case names retain the bracketed parameter section.
- Choices to copy: use framework collection as the authority before execution,
  use source-derived locations for editor immediacy, keep selectors in pytest
  node ID form, and report collection errors as diagnostics.
- Gap to avoid: depending only on text output from `pytest --collect-only`.
  CodeTracer should eventually use a small Python adapter/plugin that emits
  normalized JSON with file/range/nodeid/status data.

Sources:

- VS Code Python testing docs:
  https://code.visualstudio.com/docs/python/testing
- VS Code Testing API docs:
  https://code.visualstudio.com/api/extension-guides/testing
- VS Code pytest plugin source:
  https://github.com/microsoft/vscode-python/blob/main/python_files/vscode_pytest/__init__.py
- pytest invocation docs:
  https://docs.pytest.org/en/stable/how-to/usage.html
- pytest collection customization docs:
  https://docs.pytest.org/en/stable/example/pythoncollection.html

## Discovery

- Project discovery: `python -m pytest --collect-only` from the workspace root
  is the authoritative future path.
- File discovery: `python -m pytest --collect-only {file}`.
- M5 source discovery parses Python files directly for pytest-style functions,
  `Test*` classes, and `test_*` methods in `Test*` classes. It ignores comments
  and strings before parsing.
- Parametrized functions are represented as one source item tagged
  `parametrize`; exact generated parameter cases require pytest collection.
- Skip and xfail decorators are represented as tags, not as execution results.
- Native pytest collection can report node IDs and line numbers, but M5 does
  not require pytest to be installed for source discovery tests.

## Location Strategy

| Source | Used? | Notes |
| ------ | ----- | ----- |
| External adapter reports exact file/range | Future | Best final shape: Python adapter/plugin around pytest collection |
| Framework-native discovery reports file/line | Future | `session.items` and pytest item location are authoritative before execution |
| Language server reports test/runnable ranges | No | Not needed for M5 |
| Tree-sitter query rules | Future option | Good declarative replacement for the M5 lightweight parser |
| Language-native parser rules | M5 partial | Lightweight lexical parser over sanitized source |
| Declarative pattern rules | Candidate files only | `test_*.py`, `*_test.py`, `Test*`, `test_*` |
| Regex/file-name fallback | Candidate files only | Never creates runnable items by itself |

Before execution, CodeTracer should reconcile source items with pytest native
node IDs. If a source selector does not appear in collection output, the GUI
should mark it stale or show a diagnostic.

## Selectors and Stable IDs

- Single test selector: `tests/test_file.py::test_name` or
  `tests/test_file.py::TestClass::test_method`.
- File selector: workspace-relative file path.
- Project selector: workspace root with no explicit selector.
- Parameterized native selectors append `[case-id]`; M5 creates the parent
  function selector and tags it as parametrized.
- Stable `TestItem.id`: provider/language/framework/relative file plus pytest
  selector.

## Execution Commands

| Operation | Command |
| --------- | ------- |
| Discover project | `python -m pytest --collect-only --color=no` |
| Discover file | `python -m pytest --collect-only --color=no {file}` |
| Run project | `python -m pytest -q --color=no` |
| Run file | `python -m pytest -q --color=no {file}` |
| Run single test | `python -m pytest -q --color=no {selector}` |
| Run with JSON/event output | Future adapter/plugin JSON stream |
| Run with no color/no progress UI | `--color=no -q` |
| Run with deterministic ordering if supported | Default collection order unless plugin/config changes it |

## Recording Commands

- `ct test record` should wrap the same pytest selector command with the
  Python recorder.
- Single-test recording can produce one trace per selected pytest node.
- File/project recording likely needs one framework process per test when
  per-test traces are required.
- M5 does not wire recorder invocation or trace metadata.

## Entry Point Identification

- Entry point is the test function or test method body for source-discovered
  items.
- Pytest fixtures and setup/teardown run before/after the item and must be
  represented in trace metadata once recording is wired.
- Parameterized tests share a function source range but have distinct native
  pytest node IDs after collection.

## Output and Result Capture

- Whole-run stdout/stderr can be captured from the pytest process.
- Per-test output should come from a pytest adapter/plugin using pytest hooks,
  or from JUnit XML as a weaker fallback.
- Status, duration, failure text, skip reason, and xfail status are available
  through pytest reports.
- M5 exposes no event parser.

## Parallelism, Isolation, and Scheduling

- Pytest itself is serial by default; `pytest-xdist` provides parallel workers.
- CodeTracer can run one process per selected test for independent recording,
  but fixtures using databases, ports, or global state may need exclusive
  scheduling.

## Incremental Testing

- Discovery cache invalidates on source file hash and pytest config files.
- Future affected-test analysis can combine import graph data, coverage, and
  CodeTracer trace dependencies.

## Adapter Implementation Plan

- Nim module name: `frameworks/python_pytest.nim`
- Provider ID: `python-pytest`
- Adapter manifest path: future
- External adapter binary: future Python adapter/plugin likely needed
- Location strategy: M5 parser now, pytest-native collection reconciliation
  before execution later
- Required commands implemented by the module: `detect`, `discoverProject`,
  `discoverFile`, `locateTests`; `run`, `record`, `parseEvent`, and
  `mapTraceEntryPoints` return explicit unsupported diagnostics.
- Final provider contract should allow external adapters to report exact
  location ranges and generated parameter cases.

## Fixture and Test Plan

- Fixture project: `src/ct_test/fixtures/python_pytest_project`
- Cases: plain functions, `Test*` methods, parametrized functions/methods,
  skip, xfail, fake tests in comments and strings.
- Required assertions: selectors, ranges, provider ID, project aggregation,
  CLI JSON schema, command construction, unsupported record diagnostics.

## Risks and Open Questions

- Source-only parsing does not expand generated/parametrized cases.
- Custom pytest naming options are only documented in M5, not parsed.
- Import-time collection failures are not visible until native collection is
  wired.
