# Tup Build Staging Refactor – Implementation Plan

This plan tracks the work required to implement ADR 0006 (“Stage Tup Builds Under `src/build`”).

---

## Part 1 – Establish the `src/build/` Tup Root

1. **Create the staging layout**
   - Add `src/build/` with placeholders for every directory that currently hosts a `Tupfile`.
   - Move the root `Tupfile` and each subordinate `Tupfile` into the mirrored locations (e.g., `src/build/frontend/Tupfile`), leaving `Tupfile.ini` anchored at the project root and keeping `Tuprules.tup` wherever is most practical.
   - Ensure the Git history retains only the relocated files (remove the old copies rather than duplicating them). `tup` now runs directly from `src/build/`, so no compatibility shim in `src/Tupfile` is required.

2. **Shared path configuration**
   - Retain per-file `SRC_DIR` variables for referencing source directories; no additional global macros (`SRC_ROOT`, `BUILD_ROOT`, `VARIANT_ROOT`) are necessary.
   - Review staged Tupfiles to confirm outputs route into the staging tree using the existing `SRC_DIR` pattern.

3. **Output confinement**
   - Ensure commands emit intermediate and final outputs into `src/build/` (for live runs) or `src/build-debug/build/` (for variant builds) instead of the source tree.
   - Confirm resource-copy rules (`!cp_preserve`, etc.) still put assets in the expected staging paths and that downstream consumers read from the new locations.

## Part 2 – Preserve Variant Behaviour

1. **Variant path wiring**
   - Audit references to `build-debug` (and other variant directories) to ensure they resolve relative to the new staging root.
   - Update scripts or rules that assume the old `src/build-debug/bin` layout so they target `src/build-debug/build/**` instead.

2. **Regression tests**
   - Run `tup build-debug` in the new layout and compare the directory structure of `src/build-debug/` against a baseline (focus on executables in `bin/`, JS bundles, and resource copies).
   - Capture discrepancies and update rules until parity is achieved; ensure the `build-debug/build` subtree contains the expected artifacts.

3. **Generated script validation**
   - Run `tup generate tup.sh` inside `src/build/`, execute the script, and confirm the outputs stay within the staging area (`src/build/`) and `src/build-debug/build/`.
   - Document the required clean-up before returning to the live monitor: `cd src/build && git clean -fx .` followed by `cd ../build-debug && git clean -fx .`.
   - Add automated checks (e.g., a CI script diffing `git status`) to prevent regressions.

## Part 3 – Tooling & Automation Updates

1. **CI adjustments**
   - Simplify `ci/build/dev.sh` to operate entirely within `src/build/`, removing the temporary `src/links` relocation and limiting cleanups to `src/build/` and `src/build-debug/build/`.
   - Update any other CI jobs that run `tup` or expect artifacts in `src/`, including the post-`tup.sh` cleaning sequence.

2. **Developer workflows**
   - Modify `justfile` recipes, Nix shell hooks (`nix/shells/main.nix`, `armShell.nix`), and helper scripts so they `cd src/build` before invoking `tup` and expect outputs in `src/build-debug/build/`.
   - Double-check that commands such as `tup monitor -a` behave identically in the new location after cleaning.

3. **Git hygiene**
   - Add `src/build/.gitignore` to ignore generated scripts, `.tup` state directories, and transient outputs while keeping committed `Tupfile`s tracked.
   - Remove any obsolete ignore rules from the repository root (e.g., `tup-generate.vardict`) if the new layout changes artefact names or locations.

## Part 4 – Documentation & Follow-Up

1. **Contributor docs**
   - Update build instructions (`README.md`, `docs/book`, onboarding guides) to reference `src/build/` as the entry point for `tup` workflows.
   - Highlight the difference between the staging area (`src/build/`) and variant outputs (`src/build-debug/build/`) to avoid confusion.
   - Document the clean-up sequence required after running a generated script so developers can return to live `tup` runs without residual artifacts.

2. **Knowledge base**
   - Refresh `.agents/codebase-insights.txt` (and any other internal notes) to capture the new layout.

3. **Post-migration cleanup**
   - Remove temporary workarounds that are no longer necessary (e.g., scripts assuming outputs land in `src/` or `src/build-debug/bin`).
   - Monitor developer feedback during the first few sprints and adjust documentation or supporting scripts as needed.

---

**Milestones**
1. Land the directory move and macro updates (Part 1) with passing `tup build-debug`.
2. Validate generated scripts and CI pipelines (Part 2 & Part 3).
3. Finish documentation and cleanup tasks (Part 4), then mark ADR 0006 as **Accepted**.
