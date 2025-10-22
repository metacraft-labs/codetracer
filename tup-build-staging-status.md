# Tup Build Staging Refactor – Status

## Completed
- Relocated the entire Tup graph to `src/build/`, with `Tupfile.ini` still rooted in `src/`; `tup` now runs directly from the staging tree and no `src/Tupfile` shim is needed.
- Standardized on per-file `SRC_DIR` handling for relocated Tupfiles, added `!cp_preserve` plus `src/build/.gitignore`, and refreshed `.agents/codebase-insights.txt`; no further Tupfile edits are planned.
- Validated the build: both `tup` and `tup generate` succeed, `just build` / `just build-once` work end-to-end, and their outputs land under `src/build/` or `src/build-debug/build/` as intended.
- Aligned developer tooling (Just recipes, CI helpers, Nix shells, non-Nix env scripts) and documentation—including contributor guides, mdBook outputs, and WebDriver specs—with the `src/build/` staging root and the new `build-debug/build` artifact paths, and documented the required clean-up after running generated scripts.

## In Progress
- Monitor developer tooling and CI jobs for regressions now that their scripts target `src/build/` and `src/build-debug/build/**`; collect feedback from early adopters before marking ADR 0006 as accepted.

## Next
- Verify CI and developer tooling run successfully with the updated paths and documented clean-up, then mark ADR 0006 as accepted.
- Capture any follow-up automation needed to enforce the post-`tup.sh` cleaning workflow (e.g., pre-commit hooks or CI guardrails) based on user feedback.
