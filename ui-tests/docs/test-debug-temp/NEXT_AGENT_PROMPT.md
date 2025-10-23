You are taking over the UI test debugging effort.

## Documents To Review First
1. `ui-tests/docs/test-debug-temp/README.md` – overview of the debugging workspace and plan.
2. Per-test status files under `ui-tests/docs/test-debug-temp/` (one Markdown file per test id). Each lists the scenario intent and current status (“Not Run” for now).

## Immediate Task
1. Run each test individually using `dotnet run -- --include=<TestId>` (from `ui-tests/` with the correct environment). After every run:
   - Update the corresponding Markdown file with the result (Pass/Fail/Hangs), timestamp, command used, and debug notes. Proceed to the next test only after receiving confirmation from the user.
   - If a test hangs, describe the last observable UI state or logs before you cancel it.
2. Once all tests have individual notes:
   - Prototype a debugging hook that writes per-test result metadata (status + exception message/stack) into a fresh temp directory on each full-suite run, wiping that directory before each execution.
   - Document the directory location and format back in `README.md`.
3. With instrumentation in place, run the full suite (e.g., `dotnet run -- --max-parallel=<n>`), collect per-test debug artifacts, and summarize findings.

## Response Style
- Keep updates concise and structured. Reference test ids explicitly.
- When editing documentation, follow the Markdown structure already in place.
- If you change the instrumentation or add scripts, note them in the README.

Good luck!
