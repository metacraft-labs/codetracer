# Debugging the UI Tests V3 Prototype

This guide outlines how to diagnose issues while rebuilding the new CodeTracer UI test framework.

## Environment Checklist

- Ensure the legacy `ui-tests/` project still builds and runs—its Playwright-based Electron launcher remains the authoritative reference for invoking CodeTracer.
- Confirm the Puppeteer reference project (`/home/franz/code/repos/Puppeteer`) builds; we will gradually port its Selenium helpers into Playwright abstractions.
- Use the `nix develop` shell (or trust `.envrc`) from the repository root so that the pinned .NET/Node toolchains match the current suite.

## Running Experiments

The V3 project does not yet ship runnable code. While prototyping:

1. Start from the existing `ui-tests/` launch flow (`./dotnet_build.sh` + `dotnet run`) to reproduce baseline behaviour.
2. Scaffold new runners under `ui-tests-v3/` and validate them in isolation using the same environment variables (`CODETRACER_*`) that the legacy suite exports.
3. When porting logic from the Puppeteer project, create spike scripts that exercise the imported helpers against a dummy browser instance before wiring them into Playwright.

## Capturing Diagnostics

- Reuse the `CodeTracerSession` disposal pattern from `ui-tests/` to guarantee Electron shuts down between runs.
- Enable Playwright tracing (`PWDEBUG=1`) when working on the new harness. Document findings in `docs/progress.md`.
- When the new suite begins driving CodeTracer, record any environment variables or preconditions that differ from the legacy setup. Update `docs/specifications.md` accordingly.

## Common Failure Modes

- **Electron rejects debugging flags**: verify `ELECTRON_RUN_AS_NODE` and `ELECTRON_NO_ATTACH_CONSOLE` are unset before launching `ct`; the legacy `PlaywrightLauncher` shows the correct environment preparation.
- **Selenium-specific APIs**: when porting utilities from the Puppeteer repository, ensure they are adapted to Playwright idioms (async/await, locator usage) before integration.
- **Toolchain drift**: if `dotnet` or `node` versions differ between the legacy and experimental projects, realign the flake inputs to avoid subtle runtime differences.

## When to Update This Document

Add troubleshooting steps whenever you encounter:

- New environment variables required by the V3 harness.
- Failures specific to the migrated Selenium/Puppeteer functionality.
- Lessons learned while stabilising the rebuild that future contributors—or automation agents—should know.
