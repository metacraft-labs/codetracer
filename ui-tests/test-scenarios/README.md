# CodeTracer Test Plan

This folder keeps the living test plan in version control so it can evolve with the codebase through regular pull requests and reviews. Test scenarios are written in Markdown to make them easy to diff, annotate, and link to automated coverage under `Tests/`.

## How the test suites are organized

- **Component suites (program-agnostic):** Event Log, Call Trace, Loading Screen, Editor, Program State Panel, Omniscience Loop Control. These cover behaviors that should work regardless of which sample program is running.
- **Program-specific flows:** Focused walkthroughs for sample programs (e.g., `noir_space_ship`, `ruby_space_ship`) that exercise end-to-end storylines and data shapes that generic component suites do not cover.
- **Platform and environment coverage:** Each case records whether it must run on Electron, Web, or both, and the OS/browser matrix (Fedora, NixOS, Ubuntu, macOS; Chrome/Chromium, Firefox, Safari).
- **Execution buckets:** Mark tests as `smoke`, `regression`, or `long-run` so CI and local runs can pick the right slice.

## Directory layout

- `suites/components/` — Program-agnostic component suites (see `event-log.md`, `call-trace.md`).
- `suites/programs/` — Program-specific flows (e.g., `noir-space-ship.md`).
- `templates/` — Authoring templates and examples to keep test cases consistent.
- `environment-matrix.md` — Canonical OS/browser matrix and coverage expectations for each delivery target.

## Test case format

Each test case follows the template in `templates/test-case-template.md`:

- **Metadata:** ID, title, suite, type (functional/regression/smoke), platforms (Electron/Web + browser), operating systems, program under test, and blocking issues if any.
- **Preconditions:** Environment setup, data, user roles, and feature flags.
- **Steps and expected results:** Numbered steps paired with concrete assertions.
- **Notes:** Traceability to page objects or automated tests, and any monitoring/log collection guidance.

## How QA teams keep this in GitHub

- Store scenarios in Markdown and review them like code. Changes ship via PRs with reviewers from QA and engineering.
- Link manual scenarios to automated tests by ID (e.g., `EL-001` implemented in `Tests/...`). Keep notes inline about gaps so automation can be added later.
- Use labels in issues/PRs to map suites and execution buckets (`suite:event-log`, `bucket:smoke`, `platform:web`), and reference this plan when proposing new coverage.
- Keep platform expectations explicit so CI pipelines can trigger the right matrix jobs (OS + browser + Electron/Web).

## Extending the plan

1. Copy `templates/test-case-template.md` into the appropriate suite file and fill in the details.
2. If a new suite is needed, create a peer Markdown file under `suites/` and add it to the navigation above.
3. Open a PR referencing the scenarios you are adding or changing, plus the automated tests (or TODO notes) that will back them.
4. When behaviors change, update both the scenarios and the linked automation so this folder stays the source of truth.
