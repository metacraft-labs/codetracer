# Debugging Experiments in the Playground

Use this guide when troubleshooting spikes inside `ui-tests-playground/`.

## Quick Checklist

- Launch the standard dev environment (`direnv allow` or `nix develop`) from the repository root so Playwright, Node, and .NET match the production stack.
- Keep the legacy `ui-tests/` project handy to compare behaviour whenever an experiment diverges.
- Cross-check Puppeteer/Selenium helpers in `/home/franz/code/repos/Puppeteer` when ported code behaves unexpectedly.

## Common Techniques

- **Reuse the launcher**: Import the `CodeTracerSession` pattern from `ui-tests/` to ensure Electron processes terminate after each run.
- **Enable tracing**: Set `PWDEBUG=1` or Playwright tracing for quick iteration; document useful traces in `docs/progress.md`.
- **Log aggressively**: Spikes can mutate frequently—write lightweight logging so you can compare runs before and after each change.

## Known Pitfalls

- **Environment leaks**: If experiments manipulate environment variables (e.g., Electron flags), reset them before returning to the stable suites.
- **API drift**: Selenium-specific helpers often assume sync APIs. Wrap them with async adapters before plugging into Playwright.
- **Forgotten cleanup**: Playground work can leave orphan processes or temp files; prefer `await using` patterns to clean up automatically.

## When to Update This Document

Add notes for:

- Recurrent issues hit during spikes.
- Tricks that accelerate debugging (custom scripts, helper functions).
- Differences uncovered between Puppeteer-based logic and Playwright equivalents.
