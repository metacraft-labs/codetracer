# Startup Example Maintenance Plan

Unlike the structured V3 roadmap, this plan lists lightweight tasks for keeping the reference implementation sharp without introducing churn.

## Current Focus Areas

1. **Launcher Validation**
   - Periodically verify `PlaywrightLauncher` and `CtHostLauncher` against the latest CodeTracer builds.
   - Compare startup times vs. the legacy `ui-tests/` harness to catch regressions early.
2. **Diagnostics Enhancements**
   - Capture Playwright traces plus custom JSON metadata for both Electron and web runs.
   - Evaluate bundling strategies for CI uploads.
3. **Helper Sync**
   - Isolate key utilities from `/home/franz/code/repos/Puppeteer` or `ui-tests/` when parity is required.
   - Wrap them with async Playwright calls and log incompatibilities before copying into `ui-tests-v3/`.

## Workflow Tips

- Keep tasks small (hours, not days).
- Record findings and next steps in `docs/progress.md`.
- Move completed experiments into `ui-tests-v3/` once stabilised and remove them from this list.
