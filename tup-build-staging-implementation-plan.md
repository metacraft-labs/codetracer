# Tup Build Staging Refactor – Implementation Plan

This plan tracks the work required to implement ADR 0006 (“Stage Tup Builds Under `src/build`”).

---

## Part 1 – Establish the `src/build/` Tup Root

1. **Create the staging layout**
   - Add `src/build/` with placeholders for every directory that currently hosts a `Tupfile`.
   - Move the root `Tupfile` and each subordinate `Tupfile` into the mirrored locations (e.g., `src/build/frontend/Tupfile`), leaving `src/Tupfile.ini` anchored at the project root and keeping `Tuprules.tup` wherever is most practical.
   - Ensure the Git history retains only the relocated files (remove the old copies rather than duplicating them), and provide a `src/Tupfile` shim that delegates into `src/build/Tupfile` so existing entry points keep working.

2. **Shared path configuration**
   - Introduce `SRC_ROOT`, `BUILD_ROOT`, and `VARIANT_ROOT` variables in `src/build/Tuprules.tup`.
   - Replace hard-coded relative paths (e.g., `../bin/...`) with macros so rules are robust after the move.
   - Verify all macros expand correctly under both the default staging run and when `CONFIG_*` values switch for variants (`build-debug`).

3. **Output confinement**
   - Adjust commands so intermediate and final outputs default to `$(BUILD_ROOT)` (or a subdirectory) instead of landing inside the source tree.
   - Confirm resource-copy rules (`!tup_preserve`, `!cp`, etc.) still put assets in the expected staging paths and that downstream consumers read from the new locations.

## Part 2 – Preserve Variant Behaviour

1. **Variant path wiring**
   - Audit references to `build-debug` (and other variant directories) to ensure they resolve relative to the new staging root.
   - Update scripts or rules that assume the old `src/` root when reading `tup.config` or variant outputs.

2. **Regression tests**
   - Run `tup build-debug` in the new layout and compare the directory structure of `src/build-debug/` against a baseline (focus on executables in `bin/`, JS bundles, and resource copies).
   - Capture discrepancies and update rules or macros until parity is achieved.

3. **Generated script validation**
   - Run `tup generate tup.sh` inside `src/build/`, execute the script, and assert that all files it produces stay within `src/build/` (aside from the intentional `build-debug` tree).
   - Add automated checks (e.g., a CI script diffing `git status`) to prevent regressions.

## Part 3 – Tooling & Automation Updates

1. **CI adjustments**
   - Simplify `ci/build/dev.sh` to operate entirely within `src/build/`, removing the temporary `src/links` relocation and limiting cleanups to `src/build/` and `src/build-debug/`.
   - Update any other CI jobs that run `tup` or expect artifacts in `src/`.

2. **Developer workflows**
   - Modify `justfile` recipes, Nix shell hooks (`nix/shells/main.nix`, `armShell.nix`), and helper scripts so they `cd src/build` before invoking `tup`.
   - Double-check that commands such as `tup monitor -a` behave identically in the new location.

3. **Git hygiene**
   - Add `src/build/.gitignore` to ignore generated scripts, `.tup` state directories, and transient outputs while keeping committed `Tupfile`s tracked.
   - Remove any obsolete ignore rules from the repository root (e.g., `tup-generate.vardict`) if the new layout changes artefact names or locations.

## Part 4 – Documentation & Follow-Up

1. **Contributor docs**
   - Update build instructions (`README.md`, `docs/book`, onboarding guides) to reference `src/build/` as the entry point for `tup` workflows.
   - Highlight the difference between the staging area (`src/build/`) and variant outputs (`src/build-debug/`) to avoid confusion.

2. **Knowledge base**
   - Refresh `.agents/codebase-insights.txt` (and any other internal notes) to capture the new layout.

3. **Post-migration cleanup**
   - Remove temporary workarounds that are no longer necessary (e.g., scripts assuming outputs land in `src/`).
   - Monitor developer feedback during the first few sprints and adjust macros or documentation as needed.

---

**Milestones**
1. Land the directory move and macro updates (Part 1) with passing `tup build-debug`.
2. Validate generated scripts and CI pipelines (Part 2 & Part 3).
3. Finish documentation and cleanup tasks (Part 4), then mark ADR 0006 as **Accepted**.
