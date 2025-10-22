# Tup Build Staging Refactor – Status

## Completed
- Relocated the entire Tup graph to `src/build/`, with `Tupfile.ini` still rooted in `src/`; `tup` now runs directly from the staging tree and no `src/Tupfile` shim is needed.
- Standardized on per-file `SRC_DIR` handling for relocated Tupfiles, added `!cp_preserve` plus `src/build/.gitignore`, and refreshed `.agents/codebase-insights.txt`; no further Tupfile edits are planned.
- Validated the build: both `tup` and `tup generate` succeed, `just build` / `just build-once` work end-to-end, and their outputs land under `src/build/` or `src/build-debug/build/` as intended.

## In Progress
- Update tooling, scripts, and documentation (CI jobs, `justfile`, Nix shells, onboarding guides) to reference `src/build-debug/build/**` and reflect the new staging entry point.
- Capture the operational caveat that a generated script populates `src/build/`; developers must run `cd src/build && git clean -fx .` followed by `cd ../build-debug && git clean -fx .` before returning to live `tup` runs.

## Next
- Sweep remaining references to `src/build-debug/bin` (arm shell, docs, helper scripts) and switch them to `src/build-debug/build/**`.
- Document the post-`tup.sh` clean-up sequence across contributor docs and CI scripts, adding automation where possible to enforce a clean staging area.
- Verify CI and developer tooling run successfully with the updated paths and documented clean-up, then mark ADR 0006 as accepted.
