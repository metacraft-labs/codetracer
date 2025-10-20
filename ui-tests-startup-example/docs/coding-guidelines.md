# Coding Guidelines for the Startup Example

The startup example prioritises clarity and repeatability. A few guardrails keep the reference easy to adopt in `ui-tests-v3/`.

## Minimal Standards

- **Async-aware**: Default to async Playwright APIs so migrating code to `ui-tests-v3/` is painless.
- **Clear naming**: Use descriptive namespaces that hint at scenarios (e.g., `Helpers`, `StartupFlows`).
- **Comment intent**: Add short comments or docstrings describing why a scenario exists and what questions it answers.
- **Version hints**: Note the origin of copied code (`ui-tests`, `Puppeteer project`) and document modifications.

## Safety Considerations

- Avoid hardcoding credentials or secrets; use environment variables or mocked services.
- Ensure experiments clean up resources (processes, temp files, network ports) automatically.
- When testing destructive behaviours, isolate them in dedicated scripts and call out risks in the comments.

## Readiness to Promote

Before moving a startup example component into `ui-tests-v3/`, verify:

- It follows the stricter V3 coding guidelines.
- Tests or scripts exist to exercise the component.
- Documentation and progress logs reflect the latest learnings.
