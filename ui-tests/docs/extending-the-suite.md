# Extending the Test Suite

This guide explains how the UiTests solution is organized and how to add new coverage safely.

## Project Layout

- `Helpers/` contains utilities for launching CodeTracer (`CodetracerLauncher`, `PlaywrightLauncher`) and bridging to external services.
- `PageObjects/` models the application's UI. Pages compose panes, components, and layout primitives. Reuse these models instead of querying the DOM directly inside tests.
- `Tests/` holds scenario-level flows. `Tests/TestRunner.cs` is the entry point executed by `dotnet run` or the Playwright CLI.
- `Utils/` includes generic helpers such as retry utilities for stabilizing flaky async flows.

## Adding a Page Object

1. Identify the UI surface you want to model and create a matching class under `PageObjects/`.
2. Inject `IPage` or parent component handles through the constructor; avoid global state.
3. Expose high-level operations (e.g., `SelectEventAsync`) rather than raw locator properties to keep call sites concise.
4. Document each public method with XML comments describing the user behavior being automated.

## Creating a New Scenario Test

1. Add a method to an existing test class or introduce a new class beneath `Tests/ProgramSpecific/` (or another logical folder).
2. Launch the application via `PlaywrightLauncher.LaunchAsync` (returns a `CodeTracerSession`) and retrieve a page using `PlaywrightLauncher.GetAppPageAsync`. Always dispose the session (`await using var session = ...`) so the Electron process terminates when the test finishes.
3. Compose the scenario using page objects. Keep assertions localized and express them through clear exception messages.
4. Register the scenario in `Tests/TestRunner.cs` so it executes as part of the main flow.

## Reusing Helpers

- Use `RetryHelpers.RetryAsync` for operations that might require polling.
- Leverage existing components from `PageObjects/Panes/**` to interact with logs, editors, and panels.
- Before adding a new helper, search (`rg`) for similar logic to avoid duplication.

## Keeping Docs in Sync

Every time you add a new pattern or helper, add a section here that explains when and how it should be used. Doing so keeps both humans and AI agents productive when navigating the suite.
