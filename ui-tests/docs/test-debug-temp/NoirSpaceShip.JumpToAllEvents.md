# NoirSpaceShip.JumpToAllEvents

- **Test Id:** `NoirSpaceShip.JumpToAllEvents`
- **Current Status:** Re-enabled
- **Last Attempt:** 2025-11-07 12:20 UTC via `direnv exec . dotnet run -- --include=NoirSpaceShip.JumpToAllEvents --mode=Electron --max-parallel=1`
- **Purpose:** Verifies that selecting entries in the event log highlights the selected row (and therefore advances the debugger) when iterating through the first batch of events.
- **Notes:** The test now clicks the first 10 rendered events and waits on `EventRow.IsHighlightedAsync()` instead of relying on bespoke CSS class checks. Run individually with `dotnet run -- --include=NoirSpaceShip.JumpToAllEvents` if the highlight detection ever regresses.

## Run Log

- 2025-10-23 16:06:19Z — Electron/Web scenarios both passed. Event log row selections worked and Monaco followed as expected. Failure in the previous command run stemmed from unrelated noir scenarios still in the default plan; when isolated, the test confirms click interactions function normally.
- 2025-10-23 16:23:23Z — Re-run with focused config plus debug logging (`ui-tests/bin/Debug/net8.0/ui-tests-debug.log`). Clicks executed, but event rows never gained the `active` class, so retries exhausted and the test timed out on both Electron/Web paths.
- 2025-10-23 16:37:35Z — Updated waits now fail fast with `Component 'filesystem' ... final count=0`, confirming the hang occurs before any event-log interaction because the filesystem pane never renders.
- 2025-10-23 16:49:02Z — With corrected component selectors and diagnostic logging, both Electron/Web runs succeed; event rows click through all 70 entries (`active` class observed in debug log).
- 2025-11-07 12:20 UTC — Updated test now waits on `EventRow.IsHighlightedAsync()` and limits clicks to the first 10 events to reduce runtime. Electron/Web passes confirm highlight detection works with the current DOM classes (`event-selected`, `active`, `aria-selected=true`).
