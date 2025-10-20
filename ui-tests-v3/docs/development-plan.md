# Development Plan for UI Tests V3

This plan decomposes the specifications into manageable milestones. Update statuses as work progresses.

## Phase 1 – Foundations

1. **Environment Bootstrap**
   - Replicate the existing Nix/direnv workflow within `ui-tests-v3/`.
   - Validate that `dotnet`, Playwright, and Node versions match the legacy suite.
2. **Launcher Prototype (Spec-LAUNCH-01/02/03)**
   - Port the `CodeTracerSession` concept into the new namespace.
   - Abstract environment preparation (Electron flags, CODETRACER_* variables).
   - Expose lifecycle hooks for custom launch behaviour.
3. **Baseline Documentation**
   - Ensure `docs/debugging.md`, `docs/coding-guidelines.md`, and `docs/extending-the-suite.md` remain aligned with discoveries.

## Phase 2 – Page Objects & Utilities

1. **Core Page Objects (Spec-PO-01/02/03)**
   - Define base classes/interfaces for pages, panes, and components.
   - Port representative models (e.g., Layout page, Editor pane) from the legacy suite.
2. **Utility Layer**
   - Adapt retry helpers and wait strategies from `/home/franz/code/repos/Puppeteer`.
   - Introduce data fixtures to seed CodeTracer scenarios.

## Phase 3 – Scenario Orchestration

1. **Scenario Definition Model (Spec-SC-01)**
   - Decide between declarative configs vs. fluent APIs.
   - Implement tagging, metadata, and ownership conventions.
2. **Execution Engine (Spec-SC-02/03)**
   - Integrate deterministic retries and telemetry capture.
   - Store Playwright traces, console logs, and screenshot artifacts.

## Phase 4 – Reporting & Agent APIs

1. **Reporting Pipeline (Spec-REP-01/02)**
   - Create JSON summary schema and artifact bundling.
   - Provide CLI output for quick developer feedback.
2. **Automation Interface (Spec-API-01/02)**
   - Expose .NET APIs to launch scenarios programmatically.
   - Prototype remote execution hooks (event streams, cancellation).

## Phase 5 – Migration & Stabilisation

1. **Parity Scenarios**
   - Reimplement key Noir Space Ship scenarios using the new framework.
   - Compare runtime stability vs. the legacy suite.
2. **Documentation & Handoff**
   - Update specs with final decisions.
   - Prepare a migration guide for deprecating the legacy project.
3. **Reference Cleanup**
   - Remove remaining references to the legacy Puppeteer/Selenium project from documentation and code comments once V3 fully replaces the old suite.

Track milestone completion in `docs/progress.md` and refine this plan as new requirements emerge.
