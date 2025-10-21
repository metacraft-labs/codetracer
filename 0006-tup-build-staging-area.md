# ADR 0006: Stage Tup Builds Under `src/build`

- **Status:** Proposed
- **Date:** 2025-10-21
- **Deciders:** Codetracer Build & Tooling Maintainers
- **Consulted:** Desktop Packaging, CI & Release Engineering, Developer Experience
- **Informed:** Runtime Leads, Support, Product Management

## Context

The `tup` build root currently lives directly under `src/`, with `Tupfile`, `Tuprules.tup`, and a constellation of subordinate `Tupfile`s spread across the source tree. This layout works when `tup` runs in FUSE mode, but `tup generate` emits shell scripts whose commands write artifacts (executables in `bin/`, JS bundles, copied resources, etc.) straight into the source tree. CI (`ci/build/dev.sh`) therefore jumps through hoops—temporarily moving `src/links`, running `git clean -xfd src/`, and manually restoring symlinks—to keep the repository tidy. Developers face the same issue when they need the generated script for environments where FUSE is unavailable.

We tried `tup generate --builddir …` to sandbox the outputs, but the option is too buggy for our workload (incorrect relative paths and missing variant awareness). As a result, the source directory accumulates transient build files, complicating `git status`, forcing frequent cleans, and making it risky to script `tup.sh` execution inside packaging or CI jobs.

## Decision

We will move the entire Tup configuration into a dedicated staging area at `src/build/`, so that both `tup` FUSE runs and generated scripts create or modify files only inside that subtree while still producing the expected variant outputs (`build-debug/`, etc.).

1. **Establish `src/build/` as the staging tree:** Relocate the root `Tupfile` (providing a thin wrapper in `src/Tupfile` if needed) and every subordinate `Tupfile` under a mirrored directory structure rooted at `src/build/`, while keeping `Tupfile.ini` anchored in `src/` so the Tup root remains the project root. Each rule will reference sources in `../` (or higher) as needed, but outputs and intermediate files stay under `src/build/` by default.
2. **Centralize path conventions:** Introduce helper variables in `Tuprules.tup` (e.g., `SRC_ROOT`, `BUILD_ROOT`, `VARIANT_ROOT`) so recipes can target `src/build/` during generated executions while still honoring variant directories such as `src/build-debug/` when `CONFIG_DEBUG=1` or when explicit output directories are required.
3. **Git hygiene:** Add a scoped `.gitignore` inside `src/build/` that admits `tup.sh`, generated metadata (`*.tup` state, temporary outputs), and any new staging directories while keeping declarative build files tracked.
4. **Tooling alignment:** Update `ci/build/dev.sh`, `justfile`, and shell/Nix helpers to invoke `tup` from `src/build/`. The CI clean step will narrow to `git clean -xfd src/build/` instead of the whole source tree, and hacks that relocate `src/links` become unnecessary.
5. **Documentation & onboarding:** Refresh contributor docs to explain the new layout, clarifying that FUSE-based workflows (`tup monitor`) and generated scripts both operate inside `src/build/`, while `tup build-debug` continues to populate `src/build-debug/`.

## Alternatives Considered

- **Continue using `tup generate` in `src/`:** Rejected; it keeps polluting the source tree and forces manual hygiene steps that are easy to forget.
- **Rely on `tup generate --builddir`:** Rejected because upstream bugs break our rules (incorrect include paths and missing variant-specific outputs).
- **Wrap `tup.sh` in custom sandboxing scripts:** Adds maintenance overhead without addressing the root problem that the Tup metadata lives inside the source tree.

## Consequences

- **Positive:** Generated scripts run cleanly without mangling tracked files; CI simplifications; consistent developer experience across environments lacking FUSE; easier to inspect or purge build artifacts via `git clean src/build`.
- **Neutral/Enabling:** Establishes clearer separation between declarative build metadata and source assets, paving the way for additional variants or build caching under `src/build/`.
- **Negative:** Requires refactoring every `Tupfile` path to account for the new root; risk of path mistakes during migration; temporary churn for developers with pending Tup changes.
- **Risks & Mitigations:** Misconfigured outputs could still escape the sandbox—mitigate by adding integration tests that run `tup generate` + `tup.sh` and assert the set of touched paths. Variant parity must be verified by running `tup build-debug` before and after the move within CI.

## Key Locations

- `src/Tupfile`, `src/Tuprules.tup`, and all `src/**/Tupfile` instances that define the current build graph.
- `ci/build/dev.sh`, `justfile`, and `nix/shells/*.nix` scripts that `cd src` before invoking `tup`.
- `src/build-debug/tup.config` and any logic that depends on variant output directories.
- Documentation under `docs/` and contributor guides describing the build workflow.

## Implementation Notes

1. Mirror the existing Tup hierarchy under `src/build/`, keeping directory-by-directory `Tupfile`s collocated with their rules while adjusting relative paths for inputs and outputs; retain `src/Tupfile.ini` at the root and add a lightweight `src/Tupfile` shim that delegates into `src/build/Tupfile`.
2. Define shared path macros (e.g., `SRC_ROOT = $(TUP_CWD)/../../..`) so recipes can reference the actual sources without brittle `../../..` sequences, and expose a `BUILD_ROOT` for staging outputs.
3. Create a `.gitignore` within `src/build/` that ignores generated scripts, logs, and `tup` state directories but keeps the committed `Tupfile`s tracked.
4. Update tooling (`ci`, `just`, Nix shells) to execute `tup` from `src/build/`, ensuring variant commands still find `build-debug/tup.config`.
5. Add CI coverage that runs both `tup generate` + generated script and `tup build-debug` to confirm artifacts remain confined to `src/build/` and `src/build-debug/`.

## Status & Next Steps

- Draft ADR for review (this document).
- Prototype the directory move on a feature branch to validate path macros and variant compatibility.
- Once validated, mark this ADR **Accepted** and execute the implementation plan alongside automated regression coverage.
