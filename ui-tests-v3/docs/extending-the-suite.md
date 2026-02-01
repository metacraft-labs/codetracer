# Extending the V3 Test Suite

This document explains how we plan to add features to the next-generation CodeTracer UI tests hosted under `ui-tests-v3/`.

## Design Goals

- Lean on Playwright for deterministic UI automation, leveraging lessons learned from the legacy `ui-tests/` project.
- Port advanced test utilities—data fixtures, visual assertions, workflow helpers—from the Puppeteer/Selenium project while adapting them to async Playwright conventions.
- Keep the framework modular so that adding a new product surface requires minimal boilerplate.

## Planned Structure

Although the V3 code has not yet been implemented, the target layout will mirror the following high-level organisation:

- `src/Launcher/`: abstractions for starting CodeTracer (and other targets) with pluggable environment configuration.
- `src/PageObjects/`: page, pane, and component models with a shared locator vocabulary.
- `src/Scenarios/`: end-to-end flows composed from page objects, each returning rich telemetry for debugging.
- `tests/`: executable entry points (e.g., `dotnet test` or custom runners) that orchestrate scenarios and report status.

## How to Add New Capabilities

1. Review the relevant patterns in the legacy projects:

- For Electron launch mechanics, inspect `ui-tests/Execution/ElectronTestSessionExecutor.cs` and `ui-tests/Infrastructure/CodetracerLauncher.cs`.
- For reusable test utilities, look at `/home/franz/code/repos/Puppeteer`.

1. Update `docs/specifications.md` with any new requirements or architectural considerations.
2. Break the work into actionable tasks in `docs/development-plan.md`.
3. Implement the feature under a dedicated namespace in `ui-tests-v3/`, maintaining high cohesion and low coupling.
4. Document the change in `docs/progress.md`, noting any deviations from the plan or additional follow-up work.

## Documentation Expectations

- Each public class or module must include XML documentation that explains intent, dependencies, and links to relevant specs.
- Complex flows should have inline comments briefly explaining non-obvious logic, especially when porting from the Puppeteer stack.

## Keeping This Guide Current

Update this document whenever:

- New architectural layers are introduced (e.g., service virtualization, fixtures).
- The project layout changes.
- Reusable patterns emerge while porting code from the reference repositories.
