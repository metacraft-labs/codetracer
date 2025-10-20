# Playground Development Plan

Unlike the structured V3 roadmap, this plan lists lightweight tasks for ongoing experiments. Update frequently as spikes evolve.

## Current Focus Areas

1. **Launcher Middleware Spike**
   - Prototype environment mutators (Electron flags, telemetry hooks).
   - Compare startup times vs. the legacy `PlaywrightLauncher`.
2. **Reporting Enhancements**
   - Capture Playwright traces plus custom JSON metadata.
   - Evaluate bundling strategies for CI uploads.
3. **Selenium Helper Port**
   - Isolate key utilities from `/home/franz/code/repos/Puppeteer`.
   - Wrap them with async Playwright calls and log incompatibilities.

## Workflow Tips

- Keep tasks small (hours, not days).
- Record findings and next steps in `docs/progress.md`.
- Move completed experiments into `ui-tests-v3/` once stabilised and remove them from this list.
