# Debugging the UI Tests

Follow these steps to diagnose failures and keep the suite reliable.

## Environment Checklist

- Ensure the `ct` executable is available. `Helpers/CodetracerLauncher.cs` resolves it via `CODETRACER_E2E_CT_PATH` or the default build output (`src/build-debug/bin/ct`).
- Confirm the `CODETRACER_REPO_ROOT_PATH` environment variable if you use a non-standard checkout layout.
- Verify Playwright dependencies by running `npx playwright install`. The `Microsoft.Playwright` NuGet package will bootstrap browsers on first run, but explicit installation avoids surprises.

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
    dotnet run
    ```

`./dotnet_build.sh` configures the environment consistently with CI (including Nix wrappers) before `dotnet run` executes the UI scenarios. Ensure the direnv/Nix shell stays active while running the commands above. For targeted runs, invoke individual methods through the `TestRunner` or attach a debugger to the `UiTests` executable.

`PlaywrightLauncher.LaunchAsync` now returns a `CodeTracerSession`; always dispose it (`await using`) so the Electron process shuts down even when debugging from VS Code.

## Capturing Additional Diagnostics

- Wrap flaky assertions with `RetryHelpers.RetryAsync` and log contextual data (like locator text) before rethrowing.
- Enable Playwright tracing by setting `PWDEBUG=1` before launching the test runner. This allows stepping through actions in a headed browser.
- Use `PlaywrightLauncher.GetAppPageAsync` to wait for the correct window. If it times out, inspect the CodeTracer process logs under the directory reported by `CodetracerLauncher.CtInstallDir`.

## Common Failure Modes

- **Process startup**: If `PlaywrightLauncher.IsCtAvailable` returns false, rebuild CodeTracer or set `CODETRACER_E2E_CT_PATH` to a valid binary.
- **CDP negotiation**: Electron builds that reject `--remote-debugging-port=<port>` (error: `bad option: --remote-debugging-port=####`) prevent Playwright from attaching. Ensure your `ct` bundle ships an Electron binary with remote debugging enabled or update to a compatible build.
- **Electron environment leaks**: Global variables like `ELECTRON_RUN_AS_NODE=1` cause Electron to behave like the Node runtime and reject debug flags. The UI launcher removes these, but confirm your shell configuration does not reintroduce them when running `ct` directly.
- **Element not found**: Double-check selectors in the corresponding page object. Prefer waiting for the component with `WaitForAsync` before interacting.
- **Flaky timing**: Replace raw `Task.Delay` calls with retries that assert the final state (see `Tests/ProgramSpecific/NoirSpaceShipTests.cs` for patterns).

## When to Update This Document

Any time you uncover a new class of failure or a useful diagnostic command, document it here with reproduction tips so future runs—automated or manual—can recover faster.
