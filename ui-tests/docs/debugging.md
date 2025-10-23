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

`./dotnet_build.sh` configures the environment consistently with CI (including Nix wrappers) before `dotnet run` executes the hosted test runner. Provide additional arguments after `--` to tweak behaviour:

- `--max-parallel=1` limits execution to a single scenario at a time (useful while debugging).
- `--mode=Web` or `--mode=Electron` restricts runs to the specified runtime. By default both Electron and Web suites execute for every scenario.
- `--include=<TestId>` / `--exclude=<TestId>` filter by test identifiers (e.g. `NoirSpaceShip.CreateSimpleTracePoint`). Scenario identifiers from `appsettings.json` also work.
- `--config=/tmp/run.json` merges an additional JSON configuration file at the highest precedence. Use this to maintain experiment-specific overrides outside source control.

`UiTestApplication` performs pre/post-run sanitation via `ProcessLifecycleManager`: stray `ct`, `electron`, or `backend-manager` processes are logged and terminated before new sessions start. The Electron executor (`Execution/ElectronTestSessionExecutor.cs`) and the web executor (`Execution/WebTestSessionExecutor.cs`) both dispose their `CodeTracerSession`/`WebTestSession` instances with `await using`, ensuring Playwright and the spawned processes shut down even during debugger stops.

## Capturing Additional Diagnostics

- Wrap flaky assertions with `RetryHelpers.RetryAsync` and log contextual data (like locator text) before rethrowing.
- Enable Playwright tracing by setting `PWDEBUG=1` before launching the test runner. This allows stepping through actions in a headed browser.
- If Electron pages fail to appear, inspect the logs emitted by `Execution/ElectronTestSessionExecutor`. The service polls `http://localhost:<port>/json/version`; network proxies or stale Electron builds usually explain a missing CDP endpoint. Web-browser failures typically surface in the `ct host` logs streamed by `Infrastructure/CtHostLauncher`.

## Common Failure Modes

- **Process startup**: If `Infrastructure/CodetracerLauncher.IsCtAvailable` resolves to false, rebuild CodeTracer or set `CODETRACER_E2E_CT_PATH` to a valid binary before running `dotnet run`.
- **CDP negotiation**: Electron builds that reject `--remote-debugging-port=<port>` (error: `bad option: --remote-debugging-port=####`) prevent Playwright from attaching. Ensure your `ct` bundle ships an Electron binary with remote debugging enabled or update to a compatible build.
- **Electron environment leaks**: Global variables like `ELECTRON_RUN_AS_NODE=1` cause Electron to behave like the Node runtime and reject debug flags. The Electron executor strips these, but confirm your shell configuration does not reintroduce them when running `ct` directly.
- **Element not found**: Double-check selectors in the corresponding page object. Prefer waiting for the component with `WaitForAsync` before interacting.
- **Flaky timing**: Replace raw `Task.Delay` calls with retries that assert the final state (see `Tests/ProgramSpecific/NoirSpaceShipTests.cs` for patterns).

## When to Update This Document

Any time you uncover a new class of failure or a useful diagnostic command, document it here with reproduction tips so future runs—automated or manual—can recover faster.
