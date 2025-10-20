# Coding Guidelines for the Playground

The playground trades polish for speed, but a few guardrails ensure experiments remain understandable and portable.

## Minimal Standards

- **Async-aware**: Default to async Playwright APIs even for spikes, so migrating code to `ui-tests-v3/` is painless.
- **Clear naming**: Use descriptive filenames and namespaces that hint at the experiment’s goal (e.g., `LauncherSpike`, `ReportingPrototype`).
- **Comment intent**: Add short comments or docstrings describing why a spike exists and what questions it answers.
- **Version hints**: Note the origin of copied code (`ui-tests`, `Puppeteer project`) and document modifications.

## Safety Considerations

- Avoid hardcoding credentials or secrets; use environment variables or mocked services.
- Ensure experiments clean up resources (processes, temp files, network ports) automatically.
- When testing destructive behaviours, isolate them in dedicated scripts and call out risks in the comments.

## Readiness to Promote

Before moving a playground component into `ui-tests-v3/`, verify:

- It follows the stricter V3 coding guidelines.
- Tests or scripts exist to exercise the component.
- Documentation and progress logs reflect the latest learnings.
