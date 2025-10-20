# UI Tests Playground

This directory is a sandbox for prototyping ideas before they graduate into the `ui-tests-v3/` rebuild. Expect the code here to be volatile—use it to spike concepts, evaluate tooling, and document findings before hardening them for the next-generation framework.

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

3. **Run the playground harness**
   ```
   LD_LIBRARY_PATH=$(jq -r '.LD_LIBRARY_PATH' ct_paths.json) \
   dotnet run --project ui-tests-playground/Playground.csproj
   ```
   - The harness records a Noir sample trace, launches three Electron scenarios, and spins up three `ct host` instances in parallel (each reuses a single socket port for both frontend and backend).
   - Fullscreen behaviour is handled automatically: the Playwright context uses the detected monitor dimensions and emits a `resize` event after loading the page, so the CodeTracer UI fills the window.

4. **Inspect logs**
   The runner prints per-scenario progress and logs `ct host` arguments (e.g., `--frontend-socket=<port>`). Post-run inspection in the output confirms that no stray `ct`/Electron processes remain.

## Documentation

- `docs/debugging.md` – tooling tips for diagnosing playground scenarios.
- `docs/extending-the-suite.md` – conventions for adding or organising spikes.
- `docs/coding-guidelines.md` – lightweight standards to keep prototypes readable.
- `docs/specifications.md` – quick notes capturing hypotheses and desired outcomes.
- `docs/development-plan.md` – short-lived task lists for active experiments.
- `docs/progress.md` – running log of insights worth upstreaming.

## References

- `ui-tests/` – the stable Playwright-based suite currently powering CodeTracer UI tests.
- `ui-tests-v3/` – structured rebuild that will eventually replace the legacy suite.
- `/home/franz/code/repos/Puppeteer` – legacy Selenium/Puppeteer project providing APIs and helpers to port.

When a playground spike proves useful, migrate the polished pieces into `ui-tests-v3/` and record the outcome in both progress logs.
