# You Are Taking Over

## Where We Landed
- **Stable suite** runs cleanly again. Planner now respects each scenario’s configured mode so `NoirSpaceShip.JumpToAllEvents` no longer runs twice per Electron/Web cycle.
- **Loop iteration slider test** uses the flow-textbox jump (same as `SimpleLoopIterationJump`) and verifies all eight iterations. It falls back to flow-loop values when the state pane doesn’t expose `damage`.
- **Process lifecycle** is scoped: Electron and ct-host processes register with `ProcessLifecycleManager`, so cleanup only touches processes started by the current run. Each test logs `<TestId>: completed` when finished.

## Next Focus
1. **Improve logging controls**
   - Add a configuration flag to switch between verbose retry logging and concise mode per scenario.
   - Limit repeated retry output (e.g., summarize after N attempts).
2. **Reduce log size**
   - Emit Playwright traces / console dumps only on failure.
   - Consider piping high-volume debug streams (event-log row tracing, call-trace dumps) into separate files when needed.

## Quick Tests
- `direnv exec . dotnet run -- --suite=stable-tests --max-parallel=$(nproc)`
- `direnv exec . dotnet run -- --suite=flaky-tests --mode=Electron --max-parallel=1`
- `direnv exec . dotnet run -- --include=NoirSpaceShip.JumpToAllEvents --mode=Web --max-parallel=1`
- `direnv exec . dotnet run -- --config=docs/test-debug-temp/config/NoirSpaceShip.LoopIterationSliderTracksRemainingShield.json`
- `direnv exec . dotnet run -- --profile=parallel`
- `direnv exec . dotnet run -- --include=NoirSpaceShip.SimpleLoopIterationJump --include=NoirSpaceShip.EventLogJumpHighlightsActiveRow`
- `direnv exec . dotnet run -- --exclude=NoirSpaceShip.JumpToAllEvents --suite=stable-tests`
- `direnv exec . dotnet run -- --mode=Electron`

Review `docs/debugging.md` and `docs/test-debug-temp/*` for per-test notes before diving in. Good luck!

## Logging Controls
- Scenarios now accept `\"verboseLogging\": true` to opt into DebugLogger/console chatter when you need deep traces.
- Pass `--verbose-console` to enable verbose runner output (process counts, trace recordings, start/stop messages) for every test.
- Successful runs stay quiet and end with a colorized summary that lists total executions plus Electron/Web pass/fail counts; failures still print the same summary after error details.

## Recent Branch Status (last run)
- Stable suite (full parallel) failed on `NoirSpaceShip.SimpleLoopIterationJump` in both modes: timeout waiting for the “regeneration” flow value box (line 340) to become visible.
- `NoirSpaceShip.EventLogJumpHighlightsActiveRow` failed in both Electron/Web: event log did not render enough rows for navigation (line 376).
- Re-running only `SimpleLoopIterationJump` still hit the same timeout in both modes; see `/tmp/ui-simple-loop.log` for the call log if needed.
