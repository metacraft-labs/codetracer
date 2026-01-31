You are taking over the UI test debugging effort.

## Documents To Review First

1. `ui-tests/docs/you-are-taking-over.md` – latest summary, lessons learned, and remaining tasks.
2. `ui-tests/docs/test-debug-temp/README.md` – overview of the debugging workspace and plan.
3. Per-test status files under `ui-tests/docs/test-debug-temp/` (one Markdown file per test id). Each lists the scenario intent and current status.

## Immediate Workflow

1. **Orient yourself**
   - Skim `ui-tests/docs/you-are-taking-over.md` for the latest status (current blockers, open tasks, logging locations).
   - Read the relevant per-test Markdown file under `docs/test-debug-temp/` before touching that scenario.
   - Enable logging only when needed: pass `--verbose-console` for full runner chatter, add `"verboseLogging": true` to the scenario (or set `UITESTS_DEBUG_LOG_DEFAULT=1`) when you need `DebugLogger` output, and reset the log (`DebugLogger.Reset()`) before each focused run.

2. **Run a single test**
   - Use `direnv exec . dotnet run -- --include=<TestId>` (add `--config=docs/test-debug-temp/config/<TestId>.json` when available to focus the plan).
   - Treat any “run the test(s)” request as applying only to the explicitly named scenario (e.g. “let’s focus on test X” means launch **only** test X).
   - Execute each requested test exactly once unless the coordinator explicitly adds “and fix any problems.”
   - When verbose logging is enabled, watch `ui-tests/bin/Debug/net8.0/ui-tests-debug.log` (or the path from `UITESTS_DEBUG_LOG`) as the run progresses.
   - If the run fails, add targeted `DebugLogger` calls to bracket the suspicious section, rerun, and fix the earliest failing stage **only when the request explicitly says “and fix any problems.”** Otherwise record the failure and wait for new instructions.

3. **Document immediately**
   - Update the matching Markdown file with status, timestamp, command, and key observations (especially the last successful log message and the failing step).
   - Note any instrumentation changes in `docs/test-debug-temp/README.md` if they affect the overall workflow.

4. **Next steps once tests are stable**
   - Prototype the per-test artifact writer described in the README (fresh temp directory per run, status + exception data).
   - Run the full suite with the new instrumentation (`dotnet run -- --max-parallel=<n>`), collect artifacts, and summarize in the README.

## Response Style

- Keep updates concise and structured. Reference test ids explicitly.
- When editing documentation, follow the Markdown structure already in place.
- Run each requested test *once* unless the coordinator’s message includes “and fix any problems,” in which case you may rerun as needed while iterating on a fix.
- When the coordinator highlights a specific test id, scope all commands, logging, and investigation to that test until new instructions arrive.
- If you change the instrumentation or add scripts, note them in the README.

Good luck!
