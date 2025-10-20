# Coding Guidelines for UI Tests V3

The third iteration of the CodeTracer UI tests aims for maintainability, determinism, and agent-friendly automation. These guidelines complement the existing `ui-tests/` rules with lessons from the Puppeteer/Selenium stack.

## General Principles

- **Async-first**: Model all browser interactions with async Playwright APIs. Avoid `.Result` or `.Wait()` calls that deadlock or introduce flakiness.
- **Deterministic selectors**: Prefer data-test attributes and semantic roles. If porting Selenium locators, translate them into resilient Playwright selectors before use.
- **Encapsulated page objects**: Keep DOM access centralised. Page objects should expose high-level behaviours (e.g., `await Editor.RunTracepointAsync()`), not raw element handles.
- **Test isolation**: Each scenario must leave CodeTracer in a clean state. Reuse the `CodeTracerSession` disposal approach from the legacy suite to avoid orphaned Electron processes.
- **Comprehensive logging**: Include structured logs or attachments when a scenario fails. These should integrate with Playwright tracing and can reference the Puppeteer project’s diagnostics helpers.

## Security and Robustness

- Validate all external inputs (file paths, environment variables) before use.
- Treat inter-process communication with care—prefer explicit timeouts and retries.
- Ensure cleanup for any resources (processes, temporary files) acquired during tests.

## Code Style

- Follow .NET naming conventions (PascalCase for types and methods, camelCase for locals).
- Group related classes within namespaces mirroring the directory structure (`UiTestsV3.Launcher`, `UiTestsV3.PageObjects.Editor`, etc.).
- Use XML documentation for public methods to clarify intent and reference spec items (e.g., `[Spec:Launcher-01]`).

## Reusing Reference Code

- When lifting code from `ui-tests/`, port only the stable patterns (launching, retry helpers) and refactor them for reuse (e.g., generic interfaces, dependency injection).
- When adopting ideas from `/home/franz/code/repos/Puppeteer`, record the origin in comments and adjust APIs to Playwright’s async model.

## Testing Strategy

- Aim for fast, hermetic smoke tests alongside longer scenario runs.
- Build helper libraries so scenarios can be exercised via `dotnet test`, `dotnet run`, or future orchestrators.
- Keep tests data-driven where possible; centralise fixtures to reduce duplication.

## Documentation & Traceability

- Update the corresponding sections in `docs/specifications.md`, `docs/development-plan.md`, and `docs/progress.md` whenever you introduce new abstractions or redesign existing ones.
- Cross-link code comments with documentation identifiers so agents can navigate easily between implementation and design rationale.
