# ADR 0006: Consolidate Codetracer Build Definitions

- **Status:** Proposed
- **Date:** 2025-02-14
- **Deciders:** Codetracer Build & Release Leads
- **Consulted:** Runtime (Nim) Maintainers, Desktop Packaging, Dev Productivity, Release Engineering
- **Informed:** Developer Experience, Support, Product, Security

## Context

The Codetracer binaries (`ct`, `db-backend-record`, `backend-manager`, etc.) are compiled from Nim or Rust sources across several environments. Today each build surface hand-crafts the same Nim invocations with slightly different flag sets:

- **Tup (`src/Tuprules.tup`, generated `tup.sh`)** uses the `!codetracer` rule to compile `codetracer.nim` and `db_backend_record.nim`.
- **Just (`justfile`), non-Nix packaging (`non-nix-build/build_with_nim.sh`)**, and **AppImage scripts (`appimage-scripts/build_with_nim.sh`)** restate the Nim command lines with their own flag matrices, rpaths, and copy steps.
- **Nix derivations (`nix/packages/default.nix`)** inline the same compilation again inside `buildPhase`.

Every time we tweak compiler flags, add defines, or change output layout we must touch all of these places. They drift easily (different optimization/debug flags, mismatched defines like `-d:withTup`, inconsistent `linksPathConst`, etc.) and routinely break when an environment falls out of sync. The situation violates the DRY principle and undermines confidence in release reproducibility.

## Decision

Codetracer will expose a **single, parameterised build driver** for Nim-based binaries and require every build surface (Tup, Just, Nix, packaging scripts, CI) to delegate to it instead of inlining raw `nim` invocations.

1. **Introduce `tools/build/build_codetracer.sh`:** The script becomes the canonical entry point for building Nim binaries. It accepts parameters for build profile (`debug`/`release`/`relwithdebinfo`), target output directory, additional defines, and platform-specific linker hints. The script owns the shared defaults (compiler flags, defines such as `-d:ctEntrypoint`, `-d:useOpenssl3`, nimcache layout) and provides hooks for environment-specific extensions through environment variables or optional arguments.
2. **Add per-environment thin adapters:** Rather than duplicating command lines, each consumer (Tup rules, Nix derivation, AppImage, non-Nix build, CI) delegates to the shared script with the relevant profile/overrides. For example, Tup uses a new `!build_codetracer` rule that shells out to the script; the Nix derivation calls it inside `buildPhase` with `PROFILE=release` and custom `RPATH_FLAGS`.
3. **Centralise configuration in `tools/build/codetracer_flags.env`:** Shared flag bundles (e.g., debug vs release defines, library RPATH templates) live in a versioned config file consumed by the build script, ensuring consistent behaviour across environments.
4. **Document the build contract:** The build script guarantees stable outputs (binary names, relative paths, artifacts) so downstream packaging can rely on it. Any new flags or defines must be added in one place.

Once this ADR is accepted the inline Nim command lines elsewhere are considered deprecated; new build surfaces must call the shared driver.

## Alternatives Considered

- **Leave the duplication in place:** Rejected; it continues to cause drift and recurring packaging failures.
- **Rewrite the entire build in a single tool (e.g., solely Tup or solely Nix):** Unfeasible in the near term because we must support non-Nix packaging, AppImage, and local developer workflows. A shared script keeps the flexibility while restoring DRY.
- **Invoke Nim from a custom Rust/Nim helper binary instead of a shell script:** Possible but heavier to maintain; the shell driver with explicit config is sufficient and easier to audit.

## Consequences

- **Positive:** One source of truth for compiler flags and outputs; flag updates ship everywhere; easier onboarding and debugging; fewer mismatches between development, CI, and release packaging.
- **Negative:** Consumers must adopt the new script, adding an initial integration cost. The shared driver must remain portable (POSIX shell) and kept backward compatible for automation.
- **Risks:** A regression in the shared script affects all build surfaces; we mitigate with unit/integration tests for the driver and CI coverage across profiles/platforms.

## Key Locations

- `tools/build/build_codetracer.sh` (new canonical driver)
- `tools/build/codetracer_flags.env` (shared flag sets/profile config)
- `src/Tuprules.tup`, `src/bin/Tupfile` (updated to call the driver)
- `justfile`, `non-nix-build/**`, `appimage-scripts/**`, `nix/packages/default.nix` (delegate to the shared script)
- `ci/**` (ensure smoke tests invoke the driver)

## Implementation Notes

1. Create the shared driver and config, supporting at minimum `ct`, `db-backend-record`, and the JS-transpiled binaries (`index.js`, `ui.js`, etc.) through subcommands or flags.
2. Update Tup rules to use the driver (e.g., `!build_codetracer`), ensuring ninja-generated scripts produce consistent `mkdir` behaviour.
3. Migrate each packaging path (Just, AppImage, non-Nix, Nix) to call the driver. Keep transitional wrappers if necessary, but remove duplicated Nim command lines.
4. Add regression tests (shell scripts or `just` recipes) that invoke the driver with different profiles and diff the output flags to guarantee parity.
5. Document the usage in `docs/building_and_packaging/build_systems.md` and communicate the change to contributors.

## Status & Next Steps

- Draft ADR (this document) for review.
- Build prototype driver and migrate Tup in a feature branch.
- Roll out to other build surfaces once Tup integration is stable.

