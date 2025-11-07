# Debugging the Startup Example

Use this guide when troubleshooting the stable multi-instance harness in `ui-tests-startup-example/`. The patterns documented here should remain valid while `ui-tests-v3/` is under construction.

## Quick Checklist

- Launch the standard dev environment (`direnv allow` or `nix develop`) from the repository root so Playwright, Node, and .NET match the production stack.
- Keep the legacy `ui-tests/` project handy to compare behaviour whenever the startup harness diverges.
- Cross-check Puppeteer/Selenium helpers in `/home/franz/code/repos/Puppeteer` when ported code behaves unexpectedly.

## Common Techniques

- **Reuse the launcher**: Import the `CodeTracerSession` pattern from `ui-tests/` (or `Helpers/CodeTracerSession.cs` here) to ensure Electron processes terminate after each run.
- **Enable tracing**: Set `PWDEBUG=1` or Playwright tracing for quick iteration; document useful traces in `docs/progress.md`.
- **Log aggressively**: Spikes can mutate frequently—write lightweight logging so you can compare runs before and after each change.

## Known Pitfalls

- **Environment leaks**: If experiments manipulate environment variables (e.g., Electron flags), reset them before returning to the stable suites.
- **API drift**: Selenium-specific helpers often assume sync APIs. Wrap them with async adapters before plugging into Playwright.
- **Forgotten cleanup**: Startup runs can leave orphan processes or temp files; prefer `await using` patterns to clean up automatically and rely on `ProcessUtilities`.
- **ct host socket mismatch**: Both the backend socket and the frontend WebSocket must share the *same* port. If you see
  ```
  Error while processing the port= parameter: invalid integer:
  ```
  or the page never reaches `#eventLog-0-dense-table-0`, ensure the launcher passes `--backend-socket-port=<n>` and `--frontend-socket=<n>` (identical values). The startup example exposes this via `Helpers/NetworkUtilities.GetFreeTcpPort()` and `Helpers/CtHostLauncher.StartHostProcess`.
- **Argument format**: `ct host` uses `--flag=value` syntax. Passing space-delimited arguments (e.g., `--frontend-socket 1234`) leaves the flag unset, and hosts collide on the default port `5000`.

## When to Update This Document

Add notes for:

- Recurrent issues hit during spikes.
- Tricks that accelerate debugging (custom scripts, helper functions).
- Differences uncovered between Puppeteer-based logic and Playwright equivalents.
