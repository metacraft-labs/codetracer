# UI Tests Startup Example

This directory is a **stable reference implementation** for launching multiple CodeTracer instances in parallel (Electron and web/`ct host`). Unlike `ui-tests-playground/`, the code here should remain relatively unchanged so other projects—particularly `ui-tests-v3/`—can copy known-good patterns for startup, orchestration, and troubleshooting.

## Getting Started

1. **Ensure the dev shell is active**
   ```
   direnv allow
   ```
   or enter the flake shell manually with `nix develop`. This step provisions the toolchain (`nim`, `dotnet`, Electron, etc.) and writes `ct_paths.json`, which supplies the runtime `LD_LIBRARY_PATH` for `ct`.

2. **Build the Electron bundle once**
   ```
   just build-once
   ```
   Use `just build-once` instead of `just build`; the latter keeps `tup monitor` running and never exits.

3. **Run the startup harness**
   ```
   LD_LIBRARY_PATH=$(jq -r '.LD_LIBRARY_PATH' ct_paths.json) \
   dotnet run --project ui-tests-startup-example/Playground.csproj
   ```
   - The harness records a Noir sample trace, launches three Electron scenarios, and spins up three `ct host` instances in parallel (each reuses a single socket port for both frontend and backend).
   - Fullscreen behaviour is handled automatically: the Playwright context uses the detected monitor dimensions and emits a `resize` event after loading the page, so the CodeTracer UI fills the window.

4. **Inspect logs**
   The runner prints per-scenario progress and logs `ct host` arguments (e.g., `--frontend-socket=<port>`). Post-run inspection in the output confirms that no stray `ct`/Electron processes remain.

## Documentation

- `docs/debugging.md` – tooling tips for diagnosing multi-instance startup scenarios.
- `docs/extending-the-suite.md` – conventions for adding or organising additional experiments inside this reference.
- `docs/coding-guidelines.md` – lightweight standards to keep examples readable.
- `docs/specifications.md` – quick notes capturing hypotheses and desired outcomes.
- `docs/development-plan.md` – short-lived task lists for any incremental improvements.
- `docs/progress.md` – running log of insights worth upstreaming to `ui-tests-v3/`.

### Key Helpers

- `Helpers/CtHostLauncher.cs` – wraps `ct host` startup, ensuring `--backend-socket-port` and `--frontend-socket` share the same value.
- `Helpers/ProcessUtilities.cs` – handles pre/post-run cleanup so parallel launches don’t leak processes.
- `Helpers/NetworkUtilities.cs` – reserves free TCP ports defensively.
- `Helpers/MonitorUtilities.cs` – normalises window size/position for Playwright.

## References

- `ui-tests/` – the stable Playwright-based suite currently powering CodeTracer UI tests.
- `ui-tests-v3/` – structured rebuild that will eventually replace the legacy suite (references this project for startup guidance).
- `/home/franz/code/repos/Puppeteer` – legacy Selenium/Puppeteer project providing APIs and helpers to port.

Use this project as the canonical example for orchestrating stable startup flows. When new scenarios are proven here, port them into `ui-tests-v3/` and record the outcome in both progress logs.
