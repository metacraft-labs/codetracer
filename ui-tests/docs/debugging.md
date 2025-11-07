# Debugging the UI Tests

Follow these steps to diagnose failures and keep the suite reliable.

## Environment Checklist

- Ensure the `ct` executable is available. `Infrastructure/CodetracerLauncher.cs` resolves it via `CODETRACER_E2E_CT_PATH` or the default build output (`src/build-debug/bin/ct`).
- Pass the correct program path to `ct record`: Noir scenarios require the directory that contains `program.json`, while Ruby/Python scenarios expect the `.rb` / `.py` file. The launcher now mirrors this behaviour so existing traces continue to build correctly.
- Confirm `CODETRACER_REPO_ROOT_PATH` if you use a non-standard checkout layout. The launcher uses it to locate `test-programs/` when recording traces.
- Verify Playwright dependencies with `npx playwright install`. The `Microsoft.Playwright` NuGet package boots browsers on first run, but explicit installation avoids surprises.
- Override configuration through `appsettings.json`, environment variables prefixed with `UITESTS_`, command-line switches (e.g. `--max-parallel=1`), or a per-run JSON file passed via `--config=/path/to/settings.json`.

## Preparing CodeTracer Builds

- Build CodeTracer with `just build-once`. The `just build` recipe keeps `tup monitor` running indefinitely and never exits, which leaves the UI suite without fresh binaries.
- If a previous run left `tup` running (look for it with `pgrep -fl tup`), terminate the process before invoking `just build-once` again; otherwise the incremental graph may refuse to rebuild and the Electron bundle will stay stale.
- For web-hosted scenarios, remember that `ct host` exposes a single socket: pass `--backend-socket-port=<n>` and `--frontend-socket=<n>` (identical value) when launching. Using separate ports or space-delimited arguments (e.g., `--frontend-socket 1234`) leaves the flag unset and the browser will fail to connect.

## Running Tests Locally

1. From the repository root, enter the `ui-tests` directory:

    ```bash
    cd ui-tests
    ```

2. Trust the direnv configuration (first run only) so the Nix flake environment loads automatically whenever you enter the folder:

    ```bash
    direnv allow
    ```

    If you do not use direnv, launch the shell manually with `nix develop` before proceeding.

3. Build and launch the suite:

    ```bash
    ./dotnet_build.sh
    dotnet run -- --include=NoirSpaceShip.CreateSimpleTracePoint
    ```

Before running UI tests after code changes, rebuild Codetracer once:

```bash
nix develop . -c just build-once
```

Avoid `just build`; it never releases the terminal and leaves `tup` running.

`./dotnet_build.sh` configures the environment consistently with CI (including Nix wrappers) before `dotnet run` executes the hosted test runner. Provide additional arguments after `--` to tweak behaviour:

- `--max-parallel=1` limits execution to a single scenario at a time (useful while debugging).
- `--mode=Web` or `--mode=Electron` restricts runs to the specified runtime. By default both Electron and Web suites execute for every scenario.
- `--include=<TestId>` / `--exclude=<TestId>` filter by test identifiers (e.g. `NoirSpaceShip.CreateSimpleTracePoint`). Scenario identifiers from `appsettings.json` also work.
- `--config=/tmp/run.json` merges an additional JSON configuration file at the highest precedence. Use this to maintain experiment-specific overrides outside source control.
- Reproduce the parallel recording stress test with:

  ```bash
  nix shell nixpkgs#dotnet-sdk_8 --command bash -lc 'cd ui-tests && dotnet run -- --max-parallel=1'
  nix shell nixpkgs#dotnet-sdk_8 --command bash -lc 'cd ui-tests && dotnet run -- --max-parallel=32'
  ```

`UiTestApplication` performs pre/post-run sanitation via `ProcessLifecycleManager`: stray `ct`, `electron`, or `backend-manager` processes are logged and terminated before new sessions start. The Electron executor (`Execution/ElectronTestSessionExecutor.cs`) and the web executor (`Execution/WebTestSessionExecutor.cs`) both dispose their `CodeTracerSession`/`WebTestSession` instances with `await using`, ensuring Playwright and the spawned processes shut down even during debugger stops.

### Manual launch quick reference

Run these from the repository root (after `cd ui-tests` and `direnv allow` or `nix develop`):

```bash
# Full suite: stable tests across Electron & Web with ramped parallelism
direnv exec . dotnet run -- --suite=stable-tests --profile=parallel

# Full suite: flaky list (Electron + Web)
direnv exec . dotnet run -- --suite=flaky-tests --profile=parallel

# Single test in both modes (default profile picks up Electron and Web)
direnv exec . dotnet run -- --include=NoirSpaceShip.CreateSimpleTracePoint --profile=parallel

# Single test in Electron only
direnv exec . dotnet run -- --include=NoirSpaceShip.CreateSimpleTracePoint --mode=Electron --max-parallel=1

# Single test in Web only
direnv exec . dotnet run -- --include=NoirSpaceShip.CreateSimpleTracePoint --mode=Web --max-parallel=1

# Single test with a slimmed config file (keeps CLI short)
direnv exec . dotnet run -- --config=docs/test-debug-temp/config/NoirSpaceShip.CreateSimpleTracePoint.json
```

Adjust `--include` / `--suite` values to match the identifiers in `Execution/TestRegistry.cs` and `appsettings.json`.

## Logging Controls

- Runs stay quiet by default; only the final summary prints unless a test fails. Pass `--verbose-console` (sets `Runner.VerboseConsole=true`) when you need per-test start/stop messages, process snapshots, and ct-host stdout on the console.
- Individual scenarios can opt into deep instrumentation by setting `"verboseLogging": true` on the scenario entry (or in a focused config). That flips on `DebugLogger`, retry traces, and pane-level logging for just that test.
- To enable `DebugLogger` globally without touching configs, set `UITESTS_DEBUG_LOG_DEFAULT=1` before running `dotnet run`. Override the destination with `UITESTS_DEBUG_LOG=/abs/path/to/log`.
- Retry helpers now emit detailed output for the first three attempts and then summarize ranges (e.g., "attempts 4-8 failed") to keep debug logs readable.

## Capturing Additional Diagnostics

- Wrap flaky assertions with `RetryHelpers.RetryAsync` and log contextual data (like locator text) before rethrowing.
- Enable Playwright tracing by setting `PWDEBUG=1` before launching the test runner. This allows stepping through actions in a headed browser.
- If Electron pages fail to appear, inspect the logs emitted by `Execution/ElectronTestSessionExecutor`. The service polls `http://localhost:<port>/json/version`; network proxies or stale Electron builds usually explain a missing CDP endpoint. Web-browser failures typically surface in the `ct host` logs streamed by `Infrastructure/CtHostLauncher`.
- Configure `UITESTS_DEBUG_LOG` when you need the debug log somewhere other than `bin/Debug/net8.0`. Remember to call `DebugLogger.Reset()` at the beginning of instrumentation-heavy runs so timestamps remain meaningful.

## Common Failure Modes

- **Process startup**: If `Infrastructure/CodetracerLauncher.IsCtAvailable` resolves to false, rebuild CodeTracer or set `CODETRACER_E2E_CT_PATH` to a valid binary before running `dotnet run`.
- **CDP negotiation**: Electron builds that reject `--remote-debugging-port=<port>` (error: `bad option: --remote-debugging-port=####`) prevent Playwright from attaching. Ensure your `ct` bundle ships an Electron binary with remote debugging enabled or update to a compatible build.
- **Electron environment leaks**: Global variables like `ELECTRON_RUN_AS_NODE=1` cause Electron to behave like the Node runtime and reject debug flags. The Electron executor strips these, but confirm your shell configuration does not reintroduce them when running `ct` directly.
- **Element not found**: Double-check selectors in the corresponding page object. Prefer waiting for the component with `WaitForAsync` before interacting.
- **Component wait stalls**: If the run appears to hang inside `layout.WaitForAllComponentsLoadedAsync`, check `ui-tests/bin/Debug/net8.0/ui-tests-debug.log` (or the path in `UITESTS_DEBUG_LOG`). Each component wait logs the selector and final count, making it clear which pane never loaded.
- **Iterative troubleshooting**: Treat debugging as a staged process. When a run fails early (e.g., during page load), later steps appear broken simply because they never executed. Use targeted `DebugLogger` calls (or temporary console output) to bracket the flow: identify the last message that prints and the first one that does not, then fix only the code between those markers. After the root cause is resolved, remove the temporary logging and move to the next failing stage.
- **Flaky timing**: Replace raw `Task.Delay` calls with retries that assert the final state (see `Tests/ProgramSpecific/NoirSpaceShipTests.cs` for patterns).

## Case Study: Page Load vs. Click Failures

During the work on `NoirSpaceShip.CalculateDamageCalltraceNavigation`, the suite appeared to hang during the call-trace click steps even though the real culprit was an earlier wait: `layout.WaitForAllComponentsLoadedAsync()` never returned, so none of the click logic executed. By adding temporary `DebugLogger.Log(...)` statements before each stage, we saw the last message that printed (“Waiting for all components to load”) and realised the call-trace code had not yet run. Fixing the component selector resolved the wait; only then did it make sense to revisit the Monaco navigation.

When you encounter similar symptoms:

1. Add short-lived logging before and after the suspect code path.
2. Re-run the test and inspect `ui-tests-debug.log` to find the last message that prints and the first that does not.
3. Focus your fix on the small region between those two messages.
4. Remove the temporary logging once the stage passes, then move on to the next failing block.

This disciplined, incremental approach prevents chasing downstream issues before the upstream blockers are resolved.

## When to Update This Document

Any time you uncover a new class of failure or a useful diagnostic command, document it here with reproduction tips so future runs—automated or manual—can recover faster.
