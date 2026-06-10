# Editor-Based Test Recording

CodeTracer can expose `ct test` actions next to tests in the editor when a
provider can map discovered tests back to source lines. The controls are built
from the same catalog and event stream used by `ct test discover`, `ct test run`,
and `ct test record`.

## Where Controls Appear

The default placement is the editor gutter. Runnable test lines show compact
actions for:

- `Run`: run the selected test through `ct test run`.
- `Record`: record the selected test through `ct test record`.
- `Open`: open the last trace recorded for that test, when one exists.
- Status: show the latest known state, such as `passed`, `failed`, or
  `recording`.

The prototype also supports `above-line`, `both`, and `disabled` placements.
M15 selects `gutter` as the default because it keeps source layout stable,
preserves scroll anchors, and leaves multi-line test bodies readable. Above-line
controls are useful when more status text is needed, but they consume vertical
space and can make dense test files harder to scan. The `both` placement is
best reserved for debugging the feature because it duplicates actions and adds
visual noise.

## Running And Recording

Use the editor controls on a discovered test line:

1. Run a test with `Run`.
2. Record a test with `Record`.
3. Open the latest recorded trace with `Open`.

Recording opens the created trace through the configured tab policy. The current
GUI contract supports opening in the current tab or a new tab, and carries the
test id, trace path, trace id, recording id, and requested tab policy to the
trace-open layer.

Output from the test command is attached to the test state and diagnostics are
shown when discovery, running, or recording fails before a trace is created.
Failure diagnostics do not open an empty trace.

## Keyboard And Accessibility

Each editor action has a stable command name:

- `ct.test.run`
- `ct.test.record`
- `ct.test.openLastTrace`
- `ct.test.status`

Rendered controls expose an accessibility label and title for every action.
The status action is informational and disabled; run, record, and open-last-trace
are command actions when available.

## Toolchains And Recorder Configuration

Editor recording depends on the same command-line setup as `ct test`:

- The `ct` command must be available from the CodeTracer build or installed
  package.
- Language providers must be able to discover tests for the open file.
- Recorder binaries and language toolchains must be available on `PATH` or
  configured through the usual CodeTracer environment variables.
- In this workspace, the Nix development shell and `.envrc` auto-detect common
  sibling recorder repositories. Run `scripts/build-siblings.sh --check` to see
  which sibling artifacts are missing, and `just build-siblings` to build them
  through each sibling repo's `direnv exec` environment. For native Rust
  recording, ensure the native recorder from `codetracer-native-recorder` is
  built. For Python, ensure the Python recorder and the project test runner,
  such as `pytest`, are installed.

## Current Limitations

- Controls appear only for tests that providers can map to source lines.
- Some frameworks support file-level recording but not reliable single-test
  recording; those providers should report a diagnostic instead of exposing an
  unavailable action.
- Full Electron GUI coverage should run through `just test-gui`, which builds
  the frontend, builds sibling recorder artifacts, and starts Xvfb for
  Playwright/Electron on Linux. The M15 headless acceptance tests exercise the
  ViewModel and rendered control contract when the full GUI harness cannot be
  run in the current environment.
