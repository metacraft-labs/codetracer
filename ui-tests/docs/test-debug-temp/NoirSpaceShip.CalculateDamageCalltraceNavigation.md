# NoirSpaceShip.CalculateDamageCalltraceNavigation

- **Test Id:** `NoirSpaceShip.CalculateDamageCalltraceNavigation`
- **Current Status:** Failing (state never updates)
- **Last Attempt:** 2025-10-23 15:47:03Z via `direnv exec . dotnet run -- --config=/home/franz/code/repos/codetracer/ui-tests/docs/test-debug-temp/config/NoirSpaceShip.CalculateDamageCalltraceNavigation.json --include=NoirSpaceShip.CalculateDamageCalltraceNavigation`
- **Purpose:** Uses the call trace pane to jump from `status_report` to `calculate_damage`, verifying editor focus and state pane values update accordingly.
- **Notes:** Watch for hangs while waiting for call trace entries/state variables. Collect screenshots or DOM dumps if the call trace fails to populate.

## Run Log

- 2025-10-23 15:42:38Z — Runner exited without executing because the supplied config only defined the now-disabled command palette scenario (`command-palette-fuzzy-search`). Need a Noir-specific config or rely on default `appsettings.json` before retrying.
- 2025-10-23 15:45:52Z — Re-ran with default config and `--include` flag. Planner still scheduled all Noir scenarios (include filter seemingly ignored), leading to unrelated failures (`NoirSpaceShip.JumpToAllEvents`, `CreateSimpleTracePoint`, `EditorLoadedMainNrFile`). Need to craft a dedicated config/Scenario entry for this test before the next attempt.
- 2025-10-23 15:47:03Z — Focused config (`config/NoirSpaceShip.CalculateDamageCalltraceNavigation.json`) limited execution to this test. Both Electron and Web variants timed out in `RetryHelpers` while waiting for `shield.nr` to highlight line 22 after activating `calculate_damage`. Call trace entries located successfully, but Monaco never reported the expected active line; state pane assertions were never reached.
- 2025-10-23 15:57:28Z — Added `ExpandChildrenAsync` and broadened call-trace click targets (fallbacks + forced double click). Electron/Web still fail: call trace marks entries selected, but Monaco cursor remains `<null>` despite expanded children. Logging shows the DOM for `calculate_damage` is rendered, yet navigation never jumps. Need deeper instrumentation (e.g., evaluate frontend navigation handler or inspect `calltrace` events) before proceeding.
- 2025-10-23 16:22:39Z — Instrumented waits/clicks with `DebugLogger` (see `ui-tests/bin/Debug/net8.0/ui-tests-debug.log`). Logs confirm activation attempts fire, retries exhaust, and Monaco still reports a null active line.
- 2025-10-23 16:22:39Z — Instrumented waits/clicks with `DebugLogger` (see `ui-tests/bin/Debug/net8.0/ui-tests-debug.log`). Logs confirm activation attempts fire, retries exhaust, and Monaco still reports a null active line.
- 2025-10-23 16:53:02Z — After fixing component selectors, waits complete and the scenario reaches the call trace steps, but both Electron/Web variants still time out waiting for `shield.nr` line 22; call trace clicks log as executed, yet Monaco's active line never updates.
- 2025-10-23 16:36:51Z — Enhanced component wait errors now point at the `filesystem` pane never loading (final count 0). Click logging still does not trigger because the test fails before reaching the call trace steps.
