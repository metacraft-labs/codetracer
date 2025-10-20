# Managing Playground Experiments

Although the playground is intentionally loose, keeping light structure makes it easier to promote successful ideas into `ui-tests-v3/`.

## Organisation Guidelines

- Create subdirectories by theme (e.g., `launcher-spikes/`, `reporting-prototypes/`).
- Co-locate quick documentation (README snippets, diagrams) with each spike so context is never lost.
- When borrowing code from `ui-tests/` or `/home/franz/code/repos/Puppeteer`, record the origin and differences inline.

## Experiment Lifecycle

1. **Ideation** – Capture the hypothesis in `docs/specifications.md` (playground section).
2. **Implementation** – Build the spike inside the relevant subdirectory.
3. **Observation** – Log results, benchmarks, and caveats in `docs/progress.md`.
4. **Promotion** – When ready, extract the reusable portions into `ui-tests-v3/` and mark the playground spike as merged or obsolete.

## Documentation Expectations

- Even throwaway prototypes should include comments explaining intent and referencing spec items.
- If a spike introduces new dependencies or environment requirements, document them in `docs/debugging.md`.

## Cleanup

- Remove stale prototypes once migrated to avoid confusion.
- Update `docs/development-plan.md` with next steps or blockers after each iteration.

Keeping the playground tidy ensures the V3 rebuild can absorb learnings quickly.
