# UI Tests V3 Sandbox

This directory hosts the experimental rebuild of the CodeTracer UI test framework. The goal is to re-imagine the suite with stronger abstractions, richer fixtures, and tighter automation support while we keep the legacy `ui-tests/` project untouched for reference.

Key resources:

- `docs/specifications.md` captures the architectural requirements for the next-generation framework.
- `docs/development-plan.md` breaks the specs into actionable milestones.
- `docs/progress.md` tracks completed work to keep alignment with stakeholders.
- `docs/debugging.md`, `docs/extending-the-suite.md`, and `docs/coding-guidelines.md` mirror the current project’s documentation, updated for the new architecture.

Reference projects:

- `ui-tests/`: demonstrates the existing Electron-based Playwright flow for CodeTracer.
- `ui-tests-playground/`: rapid prototyping area for ideas that will eventually feed into V3.
- `/home/franz/code/repos/Puppeteer`: historical Selenium/Puppeteer suite containing patterns slated for reuse.

All new work happens here; once V3 stabilises we can deprecate or migrate the legacy suite.
