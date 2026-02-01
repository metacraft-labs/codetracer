# You Are Taking Over

## Context from `ui-tests/`

- Recent debugging in the legacy suite exposed a key lesson: if `layout.WaitForAllComponentsLoadedAsync()` stalls, every later step (clicks, assertions) appears broken. We added `DebugLogger` calls to bracket each stage, fixed the component selectors, and only then pursued the genuine Monaco navigation issue.
- Logging now lives at `ui-tests/bin/Debug/net8.0/ui-tests-debug.log` (configurable via `UITESTS_DEBUG_LOG`). The same helper exists in V3; reuse it here when isolating failures.

## Documents to Read First

- `docs/debugging.md` – V3-specific troubleshooting, including the updated “iterative troubleshooting” and waits-vs-clicks example.
- `docs/development-plan.md` – current scope of the startup harness.
- `docs/progress.md` – active spikes and outstanding tasks.

## Workflow Reminders

1. Run single tests with `direnv exec . dotnet run -- --include=<TestId>` (add `--config=<path>` when you want a focused plan).
2. Reset the debug log (`DebugLogger.Reset()`) at the start of each investigation so timestamps stay meaningful.
3. After fixing a stage, remove temporary instrumentation before moving on.

## Next Steps

- Port the component-wait instrumentation from `ui-tests` if the V3 layout still relies on stale selectors.
- Continue the one-by-one scenario pass, documenting outcomes in the per-test Markdown files under `docs/tests/`.
- Schedule the per-test artifact writer once the core scenarios stop timing out.
