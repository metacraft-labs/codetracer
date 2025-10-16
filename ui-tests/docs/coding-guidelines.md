# Coding Guidelines

The UiTests project targets .NET 8 (`UiTests.csproj`) and relies on Microsoft Playwright for browser automation. Keep automated agents in mind when authoring new code by staying consistent, deterministic, and well documented.

## General Principles

- Prefer small, composable helpers over ad-hoc logic baked into tests. Reuse existing abstractions in `Helpers/` and `Utils/` before introducing new ones.
- Embrace async all the way through: Playwright APIs are asynchronous, so avoid `.Result` or `.GetAwaiter().GetResult()` in favor of `await`.
- Keep tests idempotent. Reset state between steps instead of depending on the execution order.
- Add XML documentation for public classes and methods. Summaries should explain intent, not just restate the signature.

## Playwright Usage

- Launch browsers through `Helpers/PlaywrightLauncher` so that the CodeTracer process and environment variables are configured consistently.
- When selecting elements, prefer semantic or data-test selectors. Avoid brittle selectors such as positional XPath where possible.
- Always await Playwright tasks. Missing `await` frequently results in race conditions that are hard to catch deterministically.

## Error Handling

- Replace `Console.WriteLine` checks with explicit assertions or exceptions (see `Tests/ProgramSpecific/NoirSpaceShipTests.cs` for examples). This keeps failures obvious for both humans and automation.
- When throwing exceptions, provide actionable messages that describe the observed state, not just what was expected.
- Be mindful of timeouts. Prefer short, targeted retries over large unconditional `Task.Delay` calls, and ensure every wait has a clear upper bound.

## Naming and Structure

- Organize page object models under `PageObjects/`, mirroring the UI hierarchy (pages, panes, components).
- Group scenario tests under `Tests/` using folders such as `ProgramSpecific/` to keep domain-specific flows isolated.
- Use descriptive method names like `EditorLoadedMainNrFile` that communicate the behavior under test.
- Follow .NET naming conventions (PascalCase for methods and classes, camelCase for locals).

## Documentation

- Update the docs in this folder whenever you add new helpers or patterns. Include links to source files when possible to aid quick navigation.
- If you discover environment prerequisites (env vars, Playwright versions, etc.), document them immediately so other agents can get unblocked quickly.
