# Tup Build Staging Refactor – Status

## Completed
- Step 1: Created the `src/build/` staging layout, moved the root Tupfile/Tuprules plus crate-specific Tupfiles, added the `src/Tupfile` shim, and kept `Tupfile.ini` rooted in `src/`.

## In Progress
- Step 2: Updating relocated Tupfiles to pull inputs from the original source tree and emit outputs inside `src/build/`. Added `include_rules` to every staged Tupfile, introduced a `!cp_preserve` helper, and rewrote asset copies to use explicit relative paths instead of `!tup_preserve`. Need to validate with `tup` runs (current environment blocks user namespaces) and adjust paths based on the results.

## Next
- Step 2: Validate the updated rules by running `tup` (default + `build-debug`) once user-namespace restrictions are lifted, and fix any remaining path issues that show up.
- Step 3: Refresh tooling, documentation, and CI scripts to rely on the staging tree and ensure `tup generate` produces artifacts only under `src/build/` and the existing variant directories.
