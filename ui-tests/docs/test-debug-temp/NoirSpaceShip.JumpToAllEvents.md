# NoirSpaceShip.JumpToAllEvents

- **Test Id:** `NoirSpaceShip.JumpToAllEvents`
- **Current Status:** Passing
- **Last Attempt:** 2025-10-23 16:49:02Z via `direnv exec . dotnet run -- --config=/home/franz/code/repos/codetracer/ui-tests/docs/test-debug-temp/config/NoirSpaceShip.JumpToAllEvents.json`
- **Purpose:** Verifies that selecting entries in the event log advances the debugger and highlights the expected row after each jump.
- **Notes:** Run individually with `dotnet run -- --include=NoirSpaceShip.JumpToAllEvents` and capture whether the event log ever stops updating or the test times out.

## Run Log

- 2025-10-23 16:06:19Z — Electron/Web scenarios both passed. Event log row selections worked and Monaco followed as expected. Failure in the previous command run stemmed from unrelated noir scenarios still in the default plan; when isolated, the test confirms click interactions function normally.
- 2025-10-23 16:23:23Z — Re-run with focused config plus debug logging (`ui-tests/bin/Debug/net8.0/ui-tests-debug.log`). Clicks executed, but event rows never gained the `active` class, so retries exhausted and the test timed out on both Electron/Web paths.
- 2025-10-23 16:37:35Z — Updated waits now fail fast with `Component 'filesystem' ... final count=0`, confirming the hang occurs before any event-log interaction because the filesystem pane never renders.
- 2025-10-23 16:49:02Z — With corrected component selectors and diagnostic logging, both Electron/Web runs succeed; event rows click through all 70 entries (`active` class observed in debug log).
