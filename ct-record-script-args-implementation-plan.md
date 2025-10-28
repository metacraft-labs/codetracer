# `ct record` Script Argument Handling – Implementation Plan

This plan tracks the work required to implement ADR 0006 (“Preserve Script Arguments in `ct record`”).

---

## Phase 1 – CLI parser and configuration

1. **Update confutils schema**
   - Change `CodetracerConf.recordArgs` to use `restOfArgs` so all tokens after `<program>` are collected verbatim.
   - Adjust validation to ensure at least one argument remains (the target program) and to surface a clear error if it is missing.
2. **Revise CLI help and usage**
   - Refresh the generated `ct record --help` output to document the new signature (`[--]` separator, examples with script flags).
   - Verify other help surfaces (docs when running `ct help record`, desktop UI tooltips) render the updated wording.
3. **Regression tests for parsing**
   - Introduce CLI-level tests that invoke `ct record` with leading-dash script arguments (e.g., `--lf`, `-k=test`) and confirm the subprocess receives them unchanged.
   - Include coverage for edge cases: `ct record script.py` (no args), `ct record script.py --` (empty tail), and `ct record script.py -- -weird` (arguments that begin with `--` after the delimiter).

## Phase 2 – Backend propagation & compatibility

1. **Audit db-backend launcher**
   - Confirm `src/ct/db_backend_record.nim` continues to treat tokens after the program path as opaque; add explicit tests if missing.
   - Ensure the recorded command line accurately reflects forwarded arguments in telemetry/trace metadata when applicable.
2. **Align UI and automation entry points**
   - Update `recordWithRestart` / `ct run` flows to pass the revised argument vector, including optional `--` delimiters, without reinterpreting tokens.
   - Verify the desktop UI (and any scripts invoking `ct record` programmatically) still launches successfully with script arguments containing `--`.
3. **Documentation & samples**
   - Refresh developer documentation (`docs/book`, onboarding guides, release notes) with examples that demonstrate passing script flags and the optional delimiter.
   - Call out backward-compatibility expectations and note that scripts no longer require shim wrappers to use their own CLI options.

## Phase 3 – Validation & rollout

1. **End-to-end recording checks**
   - Add integration tests (or expand existing ones) that run `ct record` against representative Python projects requiring flags (e.g., pytest filters) and ensure traces import successfully.
   - Exercise failure paths (missing program, missing interpreter) to confirm error messaging still matches expectations.
2. **QA & release readiness**
   - Coordinate with QA Automation to run smoke tests on primary platforms, verifying both CLI and UI workflows.
   - Update release notes and communicate the change to Support / Developer Experience teams ahead of rollout.
3. **Post-merge monitoring**
   - Track user feedback and telemetry for regressions in `ct record` usage. Be prepared to iterate on documentation if users need more guidance on the optional `--` separator.

---

**Milestones**
1. Merge CLI schema + help updates with regression coverage (Phase 1).
2. Complete backend/UI alignment and documentation refresh (Phase 2).
3. Finish end-to-end validation and ship the change (Phase 3).
