# CommandPalette.FindSymbolUsesFuzzySearch

- **Test Id:** `CommandPalette.FindSymbolUsesFuzzySearch`
- **Current Status:** Blocked (keyboard shortcut gaps)
- **Last Attempt:** 2025-10-23 15:18:37Z via `direnv exec . dotnet run -- --config=/home/franz/code/repos/codetracer/ui-tests/docs/test-debug-temp/config/CommandPalette.FindSymbolUsesFuzzySearch.json --include=CommandPalette.FindSymbolUsesFuzzySearch`
- **Purpose:** Runs `:sym iterate_asteroids` through the command palette and asserts the editor jumps to the symbol definition in `shield.nr`.
- **Notes:** If the palette lists no results, capture console warnings and confirm search indexes are populated.

## Run Log

- 2025-10-23 14:55:29Z — Command `dotnet run -- --include=CommandPalette.FindSymbolUsesFuzzySearch` failed immediately: `dotnet` executable not found on PATH. Install the .NET SDK or adjust PATH before trying again.
- 2025-10-23 15:00:26Z — Launched via `direnv exec . dotnet run -- --include=CommandPalette.FindSymbolUsesFuzzySearch`. Test registry ignored the include filter and queued unrelated NoirSpaceShip scenarios; run failed with multiple `ct host did not become ready` timeouts before the target test executed. Resolved by adding a per-test `Scenarios` override (see next entry).
- 2025-10-23 15:06:55Z — Reran with focused config (`docs/test-debug-temp/config/CommandPalette.FindSymbolUsesFuzzySearch.json`) plus include flag. Runner spun up dedicated Electron/Web sessions, but both timed out waiting for the fuzzy search to highlight `shield.nr` line 1 (`RetryHelpers.RetryAsync` exhausted 10 attempts at ProgramAgnosticTests.cs:47). Console logs show command palette opened and ct host served trace 305; need to investigate why Monaco never switches tabs.
- 2025-10-23 15:18:37Z — Re-run for observation using the same config/flags. Electron/Web both reproduced the timeout (`RetryHelpers` exhaustion at ProgramAgnosticTests.cs:47) after recording trace 306. Backend-manager and ct host logs matched prior attempt; Monaco still fails to activate `shield.nr`.
- 2025-10-23 15:36:46Z — Temporarily removed from the registry while we rework platform-specific shortcuts and reliable Playwright key dispatch for Web vs Electron. Test remains blocked until re-enabled.

## Pseudo Code Walkthrough

```
1. layout = new LayoutPage(page)
2. layout.WaitForAllComponentsLoadedAsync()
3. palette = new CommandPalette(page)
4. palette.OpenAsync()
5. palette.ExecuteSymbolSearchAsync("iterate_asteroids")
6. Retry up to 10 times with delays:
     a. editors = layout.EditorTabsAsync(forceReload: true)
     b. shieldEditor = editors.First tab whose button text contains "shield.nr"
     c. If shieldEditor is null -> retry
     d. activeLine = shieldEditor.ActiveLineNumberAsync()
     e. If activeLine == 1 -> success, else retry
7. If retries exhausted -> throw TimeoutException
```

Failure occurs in step 6c/6e: the shield editor tab never appears (or never reports line 1 as active), so the retry loop times out and the test throws.
