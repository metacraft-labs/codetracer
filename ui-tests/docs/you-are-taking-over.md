# You Are Taking Over

## Where We Landed

- **Stable suite status differs by platform**: Linux/Nix runs are stable, but current Windows non-Nix runs are blocked by Noir trace recording (`nargo trace` hang), so Noir scenarios can fail before UI assertions.
- **Loop iteration slider test** uses the flow-textbox jump (same as `SimpleLoopIterationJump`) and verifies all eight iterations. It falls back to flow-loop values when the state pane doesn’t expose `damage`.
- **Process lifecycle** is scoped: Electron and ct-host processes register with `ProcessLifecycleManager`, so cleanup only touches processes started by the current run. Each test logs `<TestId>: completed` when finished.

## Next Focus

1. **Windows unblock track**
   - Prefer Web-mode program-agnostic/layout tests using `CODETRACER_TRACE_PATH` pointing to a non-Noir trace (for example `src/tui/trace`) until Noir recording is reliable on Windows.
   - Keep Electron+Noir coverage as a follow-up track once `nargo trace` no longer hangs.
2. **Noir root-cause track**
   - Debug the `nargo trace` hang path directly on Windows non-Nix.
   - Once fixed, restore Noir-focused stable/flaky suite confidence on Windows.
3. **Improve logging controls**
   - Add a configuration flag to switch between verbose retry logging and concise mode per scenario.
   - Limit repeated retry output (e.g., summarize after N attempts).

## Quick Tests

- `direnv exec . dotnet run -- --suite=stable-tests --max-parallel=$(nproc)`
- `direnv exec . dotnet run -- --suite=flaky-tests --mode=Electron --max-parallel=1`
- `direnv exec . dotnet run -- --include=NoirSpaceShip.JumpToAllEvents --mode=Web --max-parallel=1`
- `direnv exec . dotnet run -- --config=docs/test-debug-temp/config/NoirSpaceShip.LoopIterationSliderTracksRemainingShield.json`
- `direnv exec . dotnet run -- --profile=parallel`
- `direnv exec . dotnet run -- --include=NoirSpaceShip.SimpleLoopIterationJump --include=NoirSpaceShip.EventLogJumpHighlightsActiveRow`
- `direnv exec . dotnet run -- --exclude=NoirSpaceShip.JumpToAllEvents --suite=stable-tests`
- `direnv exec . dotnet run -- --mode=Electron`
- Windows/non-Nix fallback:
  - `set CODETRACER_TRACE_PATH=<repo>\\src\\tui\\trace`
  - `dotnet run -- --mode=Web --include=Layout.NormalOperationWithValidLayout --max-parallel=1`
  - `dotnet run -- --mode=Web --include=Layout.UiFunctionalityAfterRecovery --max-parallel=1`

Review `docs/debugging.md` and `docs/test-debug-temp/*` for per-test notes before diving in. Good luck!

## Logging Controls

- Scenarios now accept `\"verboseLogging\": true` to opt into DebugLogger/console chatter when you need deep traces.
- Pass `--verbose-console` to enable verbose runner output (process counts, trace recordings, start/stop messages) for every test.
- Successful runs stay quiet and end with a colorized summary that lists total executions plus Electron/Web pass/fail counts; failures still print the same summary after error details.
