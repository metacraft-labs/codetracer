# UI Test Debugging Workspace

This temporary workspace tracks the current status of the `ui-tests` suite
while we stabilize all scenarios. Every run should start by wiping the
contents of this folder so that only the latest diagnostic notes remain.

## Current Situation
- Integrated a large set of Noir Space Ship and program-agnostic UI scenarios.
- A previous full-suite run was interrupted because one of the tests appeared
  to hang.
- Before resuming automation we need to run each test individually, confirm it
  terminates, and document any failures or long waits.
- All `WaitForReadyAsync` helpers rely on bounded Playwright waits or retry
  loops, so none of them should block indefinitely assuming Playwright’s
  default timeout (currently 30s) remains enabled.

## Debugging Plan
1. **Single-test passes**
   - Execute every test one by one using `dotnet run -- --include=<TestId>`.
   - After each run, record the outcome, logs, and any suspected hangs in the
     corresponding per-test note (see files in this folder). Only run the next
     test after the current one finishes or is cancelled.
   - If a test hangs, capture the last visible UI state or console output and
     log it here before cancelling the run.
2. **Suite-wide instrumentation**
   - Once every test has completed at least once (pass or fail), introduce
     a debug writer that records the start/end status and any exception
     call stacks to a fresh temp directory on each run. Make sure the target
     directory is wiped before every execution so artifacts only reflect the
     latest run. Keep per-test Markdown files in this folder as the durable
     history of each scenario.
3. **Full suite run**
   - After per-test passes and instrumentation are in place, run the entire
     suite (`dotnet run -- --max-parallel=<n>`), capturing debug artifacts for
     each test in its own file.
   - Collect the latest artifacts, summarize key findings in this workspace,
     and flag tests needing manual intervention.

## Files In This Folder
Each test has its own Markdown file containing:
- A short description of the scenario.
- Current status (`Not Run`, `Passing`, `Failing`, `Hangs`, etc.).
- Dates / commands used for the last attempt.
- Outstanding issues or hypotheses.

When you add new information:
- Update the test file with the new status and findings.
- If a workaround or fix is applied, capture the change in the test file.
- Keep this README aligned with the latest plan.

## Logging Knobs
- Runs are quiet by default. Use `--verbose-console` when you need per-test start/stop logs, process counts, and ct-host stdout while iterating.
- Enable deep instrumentation for a single scenario by adding `"verboseLogging": true` to its config (or to the temporary config file under `docs/test-debug-temp/config/`). That flips `DebugLogger` and retry chatter on only for that scenario.
- To capture `DebugLogger` output for every run without editing configs, export `UITESTS_DEBUG_LOG_DEFAULT=1`. Override the destination path via `UITESTS_DEBUG_LOG=/abs/path/to/log`.
- Remember to call `DebugLogger.Reset()` ahead of a focused session so the log contains only the current attempt. Retry helpers now summarize attempts after the first three, so note the summarized ranges when reporting hangs.

## Manual command examples

Run these from `ui-tests/` (after `direnv allow` or `nix develop`):

```bash
# Stable suite (Electron + Web) with ramped parallelism
direnv exec . dotnet run -- --suite=stable-tests --profile=parallel

# Flaky suite in both modes
direnv exec . dotnet run -- --suite=flaky-tests --profile=parallel

# Focus a single test in Electron only
direnv exec . dotnet run -- --include=NoirSpaceShip.CreateSimpleTracePoint --mode=Electron --max-parallel=1

# Focus the same test in Web
direnv exec . dotnet run -- --include=NoirSpaceShip.CreateSimpleTracePoint --mode=Web --max-parallel=1

# Focused run using the matching JSON config
direnv exec . dotnet run -- --config=docs/test-debug-temp/config/NoirSpaceShip.CreateSimpleTracePoint.json
```

Swap the test id / config path to match the scenario you need to reproduce.
