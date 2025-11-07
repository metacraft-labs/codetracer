# Batch Test Debugging With Agents

- **Purpose:** Capture process notes and repeatable practices for agent-assisted, per-test debugging runs in `ui-tests`.
- **Scope:** Applies to single-test executions (`dotnet run -- --include=<TestId>`) followed by eventual full-suite runs with instrumentation.

## Session Template

- **Environment Prep:** Launch from `ui-tests/`, ensure Playwright/Electron prerequisites are satisfied, and avoid parallel runs while capturing diagnostics.
- **Execution Loop:** Run one test at a time, wait for completion or manual cancel, then document outcomes in the matching Markdown file.
- **Observation Capture:** Record timestamps, commands, and noteworthy UI or console states immediately to prevent context loss.
- **Handoff Discipline:** After each run, pause for coordinator directions before starting the next test to keep sequencing traceable.

## Emerging Practices

- Use per-test config overrides (e.g., `docs/test-debug-temp/config/*.json`) when `appsettings.json` lacks a scenario for the target test; point `dotnet run` at the absolute path via `--config=<abs-path>` so Program.cs can resolve it.
- When Electron/Web shortcuts diverge, prefer disabling registry entries rather than chasing flaky key chords; document the decision in the per-test note and in this log so future agents know to re-enable once input handling stabilizes.
- Per single-test runs, set `Runner.MaxParallelInstances` ≥ 2 so both Electron and Web modes execute in parallel; ensure configs reflect this so parity issues surface quickly.
- When instrumentation is required, either export `UITESTS_DEBUG_LOG_DEFAULT=1` (global) or mark the scenario with `"verboseLogging": true` so `DebugLogger` and retry traces activate. Logs land in `ui-tests/bin/Debug/net8.0/ui-tests-debug.log` by default; clear it with `DebugLogger.Reset()` at the start of each focused test for clean timelines.
- _Pending:_ Populate with more lessons as scenarios complete (e.g., reliable cancellation key chords, log directories worth tailing, recurring failure patterns).

## Follow-Ups

- Backfill this document with links to example per-test notes that illustrate the practices above.
- Add references to instrumentation artifacts once the debug writer is implemented.
