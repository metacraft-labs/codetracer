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
- For parallel runs (Electron + `ct host`), mirror the logging and cleanup hooks from `ui-tests-startup-example/ProcessUtilities.cs`—the reference implementation prints pre/post process inventories to expose leaks quickly.

## Launching Multiple Instances

Follow the sequence documented in `docs/launching-multi-instance.md`. Highlights:

- Reserve one TCP port for the HTTP listener and a second free port for socket.io, then assign **the same value** to both `--backend-socket-port` and `--frontend-socket`.
- Pass options in `--flag=value` form; space-delimited arguments cause `ct host` to fall back to port `5000`.
- After Playwright connects, reset zoom (`Control+0`) and fire a `resize` event so CodeTracer fills the browser window on all monitors.
- Dispose Playwright contexts and browsers with `await using`; terminate any lingering `ct`, Electron, or Node processes in `finally`.

## Common Failure Modes

- **Electron rejects debugging flags**: verify `ELECTRON_RUN_AS_NODE` and `ELECTRON_NO_ATTACH_CONSOLE` are unset before launching `ct`; the legacy `PlaywrightLauncher` shows the correct environment preparation.
- **ct host exits immediately**: check `[ct host:<label>]` logs for `Error while processing the port=` or `EADDRINUSE`. Re-run the port allocation routines described above.
- **Timeout waiting for `#eventLog-0-dense-table-0`**: ensure `CtHostLauncher.WaitForServerAsync` succeeded—HTTP 200 responses confirm the host is alive before Playwright navigates.
- **UI loads at incorrect size**: confirm the monitor detection (`MonitorUtilities.DetectMonitors`) returned sane coordinates and that the resize event executes after navigation.
- **Iterative troubleshooting**: Failures that occur during the initial load (for example, a component wait) make every later step appear broken because those steps never run. Add focused `DebugLogger` calls to bracket the suspect region, note the last message that prints and the first that does not, fix only the code between those log markers, then remove the temporary instrumentation before continuing.
- **Selenium-specific APIs**: when porting utilities from the Puppeteer repository, ensure they are adapted to Playwright idioms (async/await, locator usage) before integration.
- **Toolchain drift**: if `dotnet` or `node` versions differ between the legacy and experimental projects, realign the flake inputs to avoid subtle runtime differences.

## When to Update This Document

Add troubleshooting steps whenever you encounter:

- New environment variables required by the V3 harness.
- Failures specific to the migrated Selenium/Puppeteer functionality.
- Lessons learned while stabilising the rebuild that future contributors—or automation agents—should know.

### Example: Waits vs. Clicks

While debugging `ui-tests/NoirSpaceShip.CalculateDamageCalltraceNavigation`, the suite appeared to fail inside the call-trace click logic, but logging showed the real issue was earlier: `layout.WaitForAllComponentsLoadedAsync()` never completed, so the click code never ran. After instrumenting the wait with `DebugLogger` and fixing the selector, the test advanced and the click behaviour became the next true problem. Use the same playbook here—log around the suspect path, fix the earliest failing stage, remove the temporary logging, then iterate on the next issue.
