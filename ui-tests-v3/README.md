# UI Tests V3 Sandbox

This directory hosts the experimental rebuild of the CodeTracer UI test framework. The goal is to re-imagine the suite with stronger abstractions, richer fixtures, and tighter automation support while we keep the legacy `ui-tests/` project untouched for reference.

Key resources:

- `docs/specifications.md` captures the architectural requirements for the next-generation framework.
- `docs/development-plan.md` breaks the specs into actionable milestones.
- `docs/progress.md` tracks completed work to keep alignment with stakeholders.
- `docs/debugging.md`, `docs/extending-the-suite.md`, and `docs/coding-guidelines.md` mirror the current project’s documentation, updated for the new architecture.

## Feature Snapshot (using `ui-tests-startup-example/` as reference)

- **Parallel Startup (Electron + Web)** – See `ui-tests-startup-example/Playground.csproj` for the orchestration that launches three Electron windows alongside three `ct host` instances while sharing socket ports correctly.
- **Process Hygiene** – `Helpers/ProcessUtilities.cs` in the startup example documents how pre/post-run cleanup prevents leaks when spawning multiple CodeTracer sessions.
- **Environment Normalisation** – The startup example’s `MonitorUtilities` and `CtHostLauncher` demonstrate window sizing, zoom resets, and the `--flag=value` syntax required by `ct host`.
- **Documented Troubleshooting** – `ui-tests-startup-example/docs/debugging.md` provides stable guidance for multi-instance debugging; use it as the canonical reference until V3 absorbs the patterns.

Reference projects:

- `ui-tests/`: demonstrates the existing Electron-based Playwright flow for CodeTracer.
- `ui-tests-startup-example/`: stable snapshot of the multi-instance startup flow; treat this as the go-to reference while V3 evolves.
- `ui-tests-playground/`: volatile prototyping area for ideas that will eventually feed into V3 (expect breaking changes).
- `/home/franz/code/repos/Puppeteer`: historical Selenium/Puppeteer suite containing patterns slated for reuse.

All new work happens here; once V3 stabilises we can deprecate or migrate the legacy suite.
