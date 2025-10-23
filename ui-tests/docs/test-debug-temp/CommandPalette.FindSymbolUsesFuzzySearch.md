# CommandPalette.FindSymbolUsesFuzzySearch

- **Test Id:** `CommandPalette.FindSymbolUsesFuzzySearch`
- **Current Status:** Not Run (pending debugging)
- **Last Attempt:** Not yet executed in this debugging session
- **Purpose:** Runs `:sym iterate_asteroids` through the command palette and asserts the editor jumps to the symbol definition in `shield.nr`.
- **Notes:** If the palette lists no results, capture console warnings and confirm search indexes are populated.
