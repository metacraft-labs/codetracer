# Tup Build Staging Refactor – Status

## Completed
- Relocated the entire Tup graph to `src/build/`, with `Tupfile.ini` still rooted in `src/`; `tup` now runs directly from the staging tree and no `src/Tupfile` shim is needed.
- Standardized on per-file `SRC_DIR` handling for relocated Tupfiles, added `!cp_preserve` plus `src/build/.gitignore`, and refreshed `.agents/codebase-insights.txt`; no further Tupfile edits are planned.
- Validated the build: both `tup` and `tup generate` succeed, `just build` / `just build-once` work end-to-end, and their outputs land under `src/build/` or `src/build-debug/build/` as intended.
- Aligned developer tooling (Just recipes, CI helpers, Nix shells, non-Nix env scripts) and documentation—including contributor guides, mdBook outputs, and WebDriver specs—with the `src/build/` staging root and the new `build-debug/build` artifact paths, and documented the required clean-up after running generated scripts.
- Confirmed the updated workflows by exercising the key entry points (`tup build`, `tup build-debug`, `tup generate` + generated script, `just build`, `just build-once`) after the clean-up procedure; no regressions observed.

## Next
- Mark ADR 0006 as **Accepted**, close out this implementation plan, and communicate the finalized workflow (including the `tup generate` clean-up) to the wider team.
- Monitor for feedback over the next sprint and decide whether additional automation is needed to enforce the post-`tup.sh` cleaning steps.
