# UI Tests V3 Specifications

This document captures the target capabilities and architectural constraints for the next-generation CodeTracer UI test framework.

## High-Level Objectives

1. **Unified Launcher**: Provide a reusable service that starts CodeTracer (Electron) and alternative runtimes with configurable environment variables, drawing on the current `ui-tests/Helpers/PlayrwightLauncher.cs`.
2. **Extensible Page Objects**: Build a modular page object model that covers the primary CodeTracer UI surfaces and can be extended without duplicating locators. Leverage the abstraction patterns found in `/home/franz/code/repos/Puppeteer`.
3. **Scenario Orchestration**: Support declarative scenario definitions with built-in retries, error capture, and telemetry.
4. **Multi-Channel Reporting**: Generate structured run outputs consumable by CI pipelines and AI agents (JSON summaries, screenshots, traces).
5. **Agent-Friendly APIs**: Expose a programmatic interface (e.g., gRPC/REST or direct .NET APIs) that allows automation agents to launch, monitor, and debug scenarios.

## Functional Requirements

- **Launcher**
  - [Spec-LAUNCH-01] Start CodeTracer with Playwright over CDP using the same environment variables as the legacy suite.
  - [Spec-LAUNCH-02] Allow custom startup scripts (e.g., Puppeteer/Selenium workflows) via dependency injection.
  - [Spec-LAUNCH-03] Provide lifecycle hooks (BeforeLaunch, AfterLaunch, OnShutdown).
  - Implementation reference: see `docs/launching-multi-instance.md` for the latest multi-instance startup flow derived from `ui-tests-startup-example/`.
- **Page Objects**
  - [Spec-PO-01] Support lazy locator resolution and automatic waiting semantics.
  - [Spec-PO-02] Enable composition (panes/pages/components) with shared interfaces.
  - [Spec-PO-03] Document each object with links back to this spec and reference implementations.
- **Scenarios**
  - [Spec-SC-01] Define scenarios declaratively (YAML/JSON or fluent APIs) with metadata like tags, owners, and risk level.
  - [Spec-SC-02] Provide deterministic retries with exponential backoff (inspired by Puppeteer retry helpers).
  - [Spec-SC-03] Capture Playwright traces and console logs on failure.
- **Reporting**
  - [Spec-REP-01] Emit machine-readable run summaries (JSON) suitable for ingestion by dashboards.
  - [Spec-REP-02] Include artifact bundling (screenshots, DOM snapshots) under a consistent directory structure.
- **Agent APIs**
  - [Spec-API-01] Offer a .NET library entry point to launch scenarios and stream progress events.
  - [Spec-API-02] Provide hooks for future remote execution (e.g., orchestrators, cloud agents).

## Non-Functional Requirements

- Tests must execute deterministically under the Nix-provided toolchain.
- Components should be designed for high cohesion and low coupling, enabling independent evolution.
- All public APIs require XML documentation and spec references.
- The framework must support headless and headed execution modes.

## Reference Materials

- **Legacy Playwright Suite** (`ui-tests/`): Source of truth for Electron launch mechanics, retry patterns, and environment management.
- **Puppeteer/Selenium Project** (`/home/franz/code/repos/Puppeteer`): Source for advanced fixture management, reusable action patterns, and reporting ideas.
- **Multi-Instance Launch Guide** (`docs/launching-multi-instance.md`): Step-by-step startup and troubleshooting notes extracted from `ui-tests-startup-example/`.

## Open Questions

- Should scenario definitions rely on config files (YAML/JSON) or strongly typed builders?
- What is the minimal viable reporting format for CI integrations?
- Can we reuse portions of the Puppeteer project’s Selenium-specific utilities directly, or do they need a full rewrite for Playwright?

Document answers to these questions in `docs/progress.md` as the project evolves.
