# UI Tests V3 Sandbox

This directory hosts the experimental rebuild of the CodeTracer UI test framework. The goal is to re-imagine the suite with stronger abstractions, richer fixtures, and tighter automation support while we keep the legacy `ui-tests/` project untouched for reference.

Key resources:

- `docs/specifications.md` captures the architectural requirements for the next-generation framework.
- `docs/development-plan.md` breaks the specs into actionable milestones.
- `docs/progress.md` tracks completed work to keep alignment with stakeholders.
- `docs/debugging.md`, `docs/extending-the-suite.md`, and `docs/coding-guidelines.md` mirror the current project’s documentation, updated for the new architecture.

## Feature Snapshot (derived from the retired startup prototype)

The previous `ui-tests-startup-example/` reference application has been removed from the repository, but its patterns now live in this documentation set.

- **Parallel Startup (Electron + Web)** – Follow `docs/launching-multi-instance.md` for the orchestration that launches multiple Electron windows alongside `ct host` instances while sharing socket ports correctly.
- **Process Hygiene** – `docs/launching-multi-instance.md` and `docs/debugging.md` describe the pre/post-run cleanup necessary to prevent leaks when spawning multiple CodeTracer sessions.
- **Environment Normalisation** – The same guides capture monitor sizing, zoom resets, and the `--flag=value` syntax required by `ct host`.
- **Documented Troubleshooting** – Consolidated debugging steps now live under `docs/debugging.md`; consult it instead of the removed startup example.

Reference projects:

- `ui-tests/`: demonstrates the existing Electron-based Playwright flow for CodeTracer.
- *Retired prototypes*: The former `ui-tests-startup-example/` and `ui-tests-playground/` projects have been removed. Their lessons are captured in this documentation set; no external folders are required.
- `/home/franz/code/repos/Puppeteer`: historical Selenium/Puppeteer suite containing patterns slated for reuse.

All new work happens here; once V3 stabilises we can deprecate or migrate the legacy suite.
