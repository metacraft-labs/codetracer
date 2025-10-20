# Build System Consolidation – Implementation Plan

Implementation tracks ADR 0006 (“Consolidate Codetracer Build Definitions”).

---

## Part 1 – Establish the Canonical Build Driver

1. **Design CLI & configuration**
   - Define the interface for `tools/build/build_codetracer.sh` (subcommands, required arguments, supported profiles).
   - Capture shared flag bundles in `tools/build/codetracer_flags.env` (debug vs release, common defines, linker hints).
   - Document expected environment variables (e.g., `OUTPUT_DIR`, `PROFILE`, `EXTRA_DEFINES`).

2. **Implement the driver**
   - Build the script to compile Nim binaries (`ct`, `db-backend-record`) and JS artefacts, reusing the shared flag sets.
   - Ensure the script accepts extensibility hooks (additional linker flags, rpaths) without copying the base command.
   - Add smoke tests (`tools/build/tests`) that run the driver in `debug` and `release` modes, verifying command lines via dry-run or hash comparisons.

3. **Developer documentation**
   - Update `docs/building_and_packaging/build_systems.md` with usage instructions.
   - Add inline help (`-h/--help`) to the driver for quick reference.

Deliverable: a reusable driver plus tests and docs; no downstream integration yet.

---

## Part 2 – Migrate Build Surfaces to the Driver

1. **Tup integration**
   - Replace `!codetracer` and related Nim commands in `src/Tuprules.tup` with a new `!build_codetracer` rule invoking the driver.
   - Update `src/bin/Tupfile` and generated artefact wiring to consume the driver outputs.
   - Regenerate `tup.sh` to confirm the extraneous `mkdir` issue is resolved.

2. **Developer workflows (Just & local scripts)**
   - Update `justfile`, `tup` recipes, and developer helper scripts to call the driver rather than embedding Nim commands.
   - Provide migration notes for contributors (e.g., `just build` now shells out to `tools/build/build_codetracer.sh`).

3. **Release packaging paths**
   - Update `non-nix-build/build_with_nim.sh`, AppImage scripts, and `nix/packages/default.nix` to delegate to the driver with the appropriate profiles and rpath overrides.
   - Ensure platform-specific steps (codesign, patchelf, rpaths) remain after the driver call but no longer recompile Nim manually.

4. **Continuous integration**
   - Adjust CI workflows to invoke the driver directly or via the updated scripts.
   - Add regression checks that the driver is used (e.g., lint for lingering `nim ... codetracer.nim` command lines outside the driver).

Deliverable: all supported build surfaces call the shared driver; duplicated Nim invocations are removed.

---

## Part 3 – Clean-up & Validation

1. **Remove dead code**
   - Delete obsolete helper functions or scripts that existed solely to build the binaries with duplicated commands.
   - Prune documentation referencing the old commands.

2. **Retrofit tooling**
   - Ensure new tooling (e.g., future packaging scripts) references the driver; add a checklist in CONTRIBUTING.

3. **Post-migration audit**
   - Run cross-platform smoke tests (Linux, macOS, CI) to confirm outputs match previous builds.
   - Capture lessons learned and, if necessary, iterate on the driver interface.

Deliverable: consolidated build system with verified parity and updated contributor guidance.

---

**Milestones**
1. Ship the driver and tests (Part 1).
2. Land Tup + local workflow migration (Part 2, steps 1–2).
3. Finish release packaging/CI migration and clean-up (Part 2 step 3 onward, Part 3).
