# You Are Taking Over

## Recent Progress
- Stable suite (`stable-tests` profile) is clean: Electron/Web variants of `NoirSpaceShip.EditorLoadedMainNrFile` and `NoirSpaceShip.CalculateDamageCalltraceNavigation` pass after the monitor-targeting/CDP move updates.
- Flaky suite still fails across the board. Electron and Web runs are now interleaved (ramped parallelism) and both windows start on HDMI-3, but every Noir/trace scenario in the flaky list times out or misses selectors — see `docs/test-debug-temp/logs/flaky-tests-latest.log` for the current error signatures.
- Added CDP + `wmctrl` fallbacks so Electron windows respect the requested monitor, and ramped the scheduler so parallelism increases gradually instead of spiking at startup.

## Lessons Learned
- Tackle failures in order: if page load waits never finish, later steps (“clicks don’t work”) are red herrings. Always fix the earliest broken stage before investigating downstream behaviour.
- Use temporary logging/`DebugLogger.Log` to bracket suspicious code. Note the last message that prints and the first one that doesn’t; focus on that slice.
- Remove instrumentation once a stage is stable to keep logs clean for the next agent.

## Where to Look for Guidance
- `docs/debugging.md` – updated troubleshooting patterns (component waits, iterative debugging case study).
- `docs/test-debug-temp/README.md` – workspace status, per-test workflow, instrumentation plan.
- `docs/test-debug-temp/*.md` – per-scenario notes; check `NoirSpaceShip.CalculateDamageCalltraceNavigation.md` and `NoirSpaceShip.JumpToAllEvents.md` for the latest findings.
- `docs/test-debug-temp/BatchDebuggingWithAgents.md` – quick logistics for running single tests and maintaining logs.

## Remaining Focus Areas
- **Flaky suite triage**: every scenario in `flaky-tests` is currently failing (timeouts, missing context menu options, ct host start failures). The next agent should pick a single failing test, reproduce once, and work forward from the earliest error message.
- **Loop iteration slider**: `NoirSpaceShip.LoopIterationSliderTracksRemainingShield` now depends on activating `iterate_asteroids` in the call trace (or jumping to `shield.nr:14`) before waiting on `.flow-loop-slider`; see the per-test note for the updated Playwright drag workflow.
- **Flow loop controls**: the loop state pane only exposes `i`, `initial_shield`, `masses`, `remaining_shield`, and `shield_regen_percentage` when parked on line 1. A new test should confirm we can pick iterations via the loop textarea; once that passes, revisit `LoopIterationSliderTracksRemainingShield` to collect `damage`/`regeneration` after stepping deeper (breakpoint + F8).
- **Call-trace Monaco navigation**: `NoirSpaceShip.CalculateDamageCalltraceNavigation` still relies on the workaround (richer active-line detection). Investigate Monaco telemetry when time permits so we can remove the extra logging.
- **Artifact writer**: once a few flaky cases are stable, implement the per-test artifact capture described in the workspace README so CI has structured outputs.

## Getting Started
1. Review the documents above (especially the per-test Markdown files) before running anything.
2. Use `direnv exec . dotnet run -- --include=<TestId>` for isolated runs; configs in `docs/test-debug-temp/config/` narrow the plan to a single test.
3. Keep `ui-tests/bin/Debug/net8.0/ui-tests-debug.log` open while debugging; reset it with `DebugLogger.Reset()` when instrumenting new stages.
