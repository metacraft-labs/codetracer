# Managing Startup Example Enhancements

The startup example should remain stable, but small targeted improvements may still happen. Keep a light structure so successful ideas can move into `ui-tests-v3/` without drifting from this reference.

## Organisation Guidelines

- Create subdirectories by theme (e.g., `launcher-spikes/`, `reporting-prototypes/`) if you add focused scenarios.
- Co-locate quick documentation (README snippets, diagrams) with each spike so context is never lost.
- When borrowing code from `ui-tests/` or `/home/franz/code/repos/Puppeteer`, record the origin and differences inline.

## Experiment Lifecycle

1. **Ideation** – Capture the hypothesis in `docs/specifications.md` (startup example section).
2. **Implementation** – Build the scenario inside the relevant subdirectory.
3. **Observation** – Log results, benchmarks, and caveats in `docs/progress.md`.
4. **Promotion** – When ready, extract the reusable portions into `ui-tests-v3/` and mark the startup example scenario as merged or obsolete.

## Documentation Expectations

- Even throwaway prototypes should include comments explaining intent and referencing spec items.
- If a spike introduces new dependencies or environment requirements, document them in `docs/debugging.md`.

## Cleanup

- Remove stale prototypes once migrated to avoid confusion.
- Update `docs/development-plan.md` with next steps or blockers after each iteration.

Keeping the startup example tidy ensures the V3 rebuild can absorb learnings quickly.
