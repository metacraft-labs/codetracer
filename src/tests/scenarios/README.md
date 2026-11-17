# CodeTracer's scenarios

CodeTracer's user-level tests, written once in the
[DemoVideoScript](https://github.com/metacraft-labs/DemoVideoScript) scenario format and
run against every front-end: the desktop (Electron, through Playwright), the terminal
(`codetracer-tui`, through TermAssert) and the GPUI window (through GuiAssert, by
vision). The VS Code extension's binding lives in `codetracer-vscode-extension`, beside
its WebDriverIO suites.

A scenario is a **stage** — set-up code called by name: record a program, write a
project, plant a configuration file, start the front-end — followed by **steps** that are
only what a user does and sees: keys, chords, typing, clicks, drags and the wheel aimed at
page objects, observations of what is on screen, and waits on named conditions. A step
cannot call into CodeTracer, so a scenario cannot pass by doing something no user can do.

```yaml
scenario: 1
name: tracing/trace-macro-at-caret
pack: codetracer
stage:
  - use: nim-project
  - use: open-recording
steps:
  - wait: { until: replay-idle, timeout: 120s }
  - click: { at: 'editor[file="tracing.nim"]/line[number="26"]', anchor: text-start }
  - expect: { at: 'editor[file="tracing.nim"]', assert: "caret-at(26)" }
  - chord: { bound: editor.trace-macro-at-cursor }
    settle: false
  - wait: { until: { at: session-strip, count: 2 }, timeout: 180s }
  - expect: { at: 'editor[file="tracing.nim"]', assert: "stopped-within(3, 4)" }
```

## What is here

| Path | What |
| ---- | ---- |
| `pack/codetracer.pack.yaml` | The page objects (roles), their properties, named assertions and sync conditions; the stages' signatures |
| `stages/` | The stages, once, in Nim (`ct_stages.nim`); `ct-scenario-stage` runs them for the desktop's binding |
| `resolver/` | The binding resolver for the native front-ends: `chord: { bound: <operation> }` is the chord the shared keymap router resolves |
| `bindings/playwright/` | The desktop: the DOM read with the page objects' selectors; the resolver asks the window's router |
| `bindings/termassert/` | The terminal: the screen read cell by cell (`ct_tui_screen.nim`) |
| `bindings/guiassert/` | The GPUI window: pixels and OCR, as the screen oracle reads them |
| `lanes/` | Which scenarios each flavour runs, in which timing modes |
| `inventory/` | Every UI test of the repository, classified, and what ports it |
| `<area>/*.yaml` | The scenarios |
| `tests/` | Scenarios the pack's own checks run (the deliberately broken one) |

## Running

```sh
just scenario-build                 # dvs, ct-scenario-stage and the three flavours
just scenario-lint                  # every scenario against the pack
just scenario-lane terminal         # one lane
just scenario-lane-xvfb electron    # the desktop and GPUI need a display
bash ci/test/scenarios.sh run terminal src/tests/scenarios/tracing/trace-macro-at-caret.yaml \
  --mode realistic --record always  # one scenario
```

The runner and the backends are sibling checkouts at the revisions `repro.lock` pins
(`ci/test/scenarios.sh` names them). The desktop flavour needs `just build-once`, the
terminal `just build-tui`, the GPUI flavour the windowed `codetracer-gpui` and
GuiAssert's helpers (`GUI_ASSERT_HELPER_DIR`).

## Recordings

A failed run leaves its recording under `build/scenario-runs/<scenario>/<backend>/<run-id>/`
and the runner prints the directory: `manifest.json` (every step, what it resolved and
observed, its timing), a still and a state file per step, `failure/` (the failing
observation and the screen at that moment) and the session's cast or video. Read the
manifest first and open the media only at the failing step. CI uploads the recordings of
failed runs.

## Writing a scenario

- Name page objects by what a user sees: `editor[file="main.py"]/line[number="12"]`,
  `call-trace/call[name="solve"]`, `context-menu/menu-item[label="Show value origin"]`.
- Every input waits for the window to settle; work that continues after it (a recording
  loading, a trace being made) is a named wait: `replay-idle`, `editor.loaded`, or an
  observation (`until: { at: session-strip, count: 2 }`). Never a sleep.
- Set-up that is not something a user does belongs in the stage. If a test needs a stage
  procedure that does not exist, add it to `stages/ct_stages.nim` and declare it in the
  pack.
- A property a front-end cannot show (a colour on the terminal, a caret the GPUI window
  draws without a cell) is declared unreadable by that binding; the scenario is then
  `unsupported` there, and the lane says so rather than passing it.
- Add the scenario to the lanes it runs on, and name it in the inventory row of the test it
  ports.
