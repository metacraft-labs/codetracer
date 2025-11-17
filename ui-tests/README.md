# UI Tests Quick Reference

This repository hosts the Noir Space Ship UI automation suite. Most day‑to‑day work revolves around `direnv exec . dotnet run ...` commands that select specific suites, profiles, or individual tests. The commands below are verified against the current `TestRegistry` and `appsettings.json`.

## Common Runs

- `direnv exec . dotnet run -- --suite=stable-tests --max-parallel=$(nproc)` — run the stable suite, letting the harness schedule up to one test per CPU core.
- `direnv exec . dotnet run -- --suite=flaky-tests --max-parallel=1 --mode=Electron` — focus on the flaky suite with serialized Electron sessions for easier debugging.
- `direnv exec . dotnet run -- --config=docs/test-debug-temp/config/NoirSpaceShip.LoopIterationSliderTracksRemainingShield.json` — replay the bespoke config we keep under `docs/test-debug-temp/config`.
- `direnv exec . dotnet run -- --profile=parallel` — execute using the `parallel` profile from `appsettings.json` (both Electron and Web without stop-on-first-failure).
- `direnv exec . dotnet run -- --include=NoirSpaceShip.SimpleLoopIterationJump --include=NoirSpaceShip.EventLogJumpHighlightsActiveRow` — target two specific tests in a single invocation.
- `direnv exec . dotnet run -- --exclude=NoirSpaceShip.JumpToAllEvents --suite=stable-tests` — run the stable suite while explicitly excluding the disabled `JumpToAllEvents` case (harmless even though the test is currently unregistered).
- `direnv exec . dotnet run -- --mode=Electron` — full test registry across Electron only (Web runs are skipped).

## Temporarily Unavailable

- `direnv exec . dotnet run -- --include=NoirSpaceShip.JumpToAllEvents --mode=Web --max-parallel=1` — this fails today because `NoirSpaceShip.JumpToAllEvents` is intentionally unregistered (see the comment in `Execution/TestRegistry.cs`). Re-enable the test before using this command.

When introducing new workflows, update this list so teammates (and future automation agents) can quickly reproduce your setup.
