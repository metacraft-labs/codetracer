# Instructions for Codex

## Building the full frontend (Nim + Electron)

To rebuild the full CodeTracer frontend (Nim backend CLI, Nim renderer JS, webpack bundles):

```
just build-once
```

This runs tup (incremental build) and webpack. Use this after modifying any `.nim` files in
`src/ct/`, `src/frontend/`, or `src/common/`.

## Building the db-backend

```
# inside src/db-backend
cargo build
```

## Running tests

```
# inside src/db-backend
cargo test
```

## Running the linter

```
# inside src/db-backend
cargo clippy
```

Don't disable the lint: try to fix the code instead first!

## Running Playwright e2e tests

```
# From the repo root (needs Xvfb or a display)
just test-e2e
```

The Playwright tests live in `tsc-ui-tests/`. They launch the real Electron app via the `ct`
binary at `src/build-debug/bin/ct`. If you modify frontend Nim code, run `just build-once`
first to rebuild the frontend before running the tests.

## Running the cross-language ct_test provider tests

```
# From inside the dev shell (provides nim + the gtest/catch2/cmake/ninja
# toolchain and the CMAKE_PREFIX_PATH / CT_TEST_C{C,XX} the C/C++ providers need)
just test-ct-providers
```

This runs the cross-language `ct_test` provider suites (C/C++ GoogleTest/Catch2/CTest, M11
native, M12 fallback, JavaScript, Ruby) plus the framework gate tests. It first builds the
native (`ct-mcr`), JavaScript and Ruby recorder siblings in their own pinned dev shells
(`direnv exec <repo> just build`, via `scripts/build-siblings.sh`) so the recording tests run
against real recorders; a missing or failed required sibling fails loudly rather than skipping
(per `codetracer-specs/Working-with-the-CodeTracer-Repos.md` Part 2). Useful overrides:

- `CT_PROVIDERS_SKIP_SIBLINGS=1` — reuse already-built recorders, skip the sibling build step.
- `CT_PROVIDERS_ALLOW_MISSING=1` — run the suites even if a required recorder sibling is
  missing/unbuildable (the recording tests then fail honestly instead of aborting up front).

The recorder binaries are discovered via PATH / the documented env vars
(`CODETRACER_CT_MCR_CMD`, `CODETRACER_JS_RECORDER_PATH`, `CODETRACER_RUBY_RECORDER_PATH`) by
`scripts/detect-siblings.sh`. See `ci/test/ct-providers.sh`.

## Windows local setup (non-Nix)

For Windows development (both x64 and ARM64), use the DIY bootstrap:

### Activate environment (auto-installs tools on first run)
```bash
# Git Bash / MSYS2
source env.sh

# PowerShell
. .\env.ps1
```

### Optional skip flags
Components can be skipped via environment variables (e.g. for satellite repos
that only need a subset):
- `WINDOWS_DIY_SKIP_NARGO=1` — skip Noir compiler
- `WINDOWS_DIY_SKIP_CT_REMOTE=1` — skip ct-remote desktop client
- `WINDOWS_DIY_ENSURE_TTD=0` — skip TTD/WinDbg validation

### Build commands (Windows)
```bash
# Rust components
cd src/db-backend && cargo build && cargo test && cargo clippy
cd src/tui && cargo build && cargo test
cd src/backend-manager && cargo build

# Full frontend (Nim + Tup)
cd src/build-debug && source ../../env.sh && tup upd
```

### Version pins
Pinned tool versions are tracked in:
```
non-nix-build/windows/toolchain-versions.env
```

For detailed Windows porting progress, see `windows-porting-initiative-status.md`.

## Nix dev shell and local flake overrides

The `.envrc` auto-detects sibling repos and passes `--override-input` flags
to `nix develop`. The sibling map is in `.envrc` (the `_ct_sibling_map` array).

### Blockchain recorder tools (circom, forc)

The codetracer nix dev shell includes `circom` and `forc` from the
`nix-blockchain-development` flake input. These are needed by the Circom
and Fuel/Sway recorders at runtime.

For the packages to resolve, the local `nix-blockchain-development` checkout
must be used (the `main` branch has all packages; the pinned `stylus-tools`
branch in `flake.lock` does not). The `.envrc` sibling map includes
`nix-blockchain-development` for automatic local override.

### Invalidating the nix-direnv cache

When you modify a local override input (e.g. change a package in
`../nix-blockchain-development`), `nix-direnv` may serve a stale cached
environment. To force re-evaluation:

```bash
# Option 1: Delete the cached profile
rm -rf .direnv/flake-profile-* .direnv/flake-inputs
direnv allow

# Option 2: Use nix develop directly (bypasses nix-direnv cache)
nix develop '.?submodules=1' --override-input nix-blockchain-development path:../nix-blockchain-development -c bash
```

The `nix develop` approach always evaluates fresh and is useful for testing
changes to override inputs before waiting for nix-direnv to catch up.

### Cadence Go helper

The `detect-siblings.sh` script auto-builds `cadence-trace-helper` from
`codetracer-flow-recorder/go-helper/` when the flow recorder sibling is
present and `go` is available. The built binary is exported via
`CADENCE_HELPER_BIN` and added to PATH.

# Keeping notes

In the `.agents/codebase-insights.txt` file, we try to maintain useful tips that may help
you in your development tasks. When you discover something important or surprising about
the codebase, add a remark in a comment near the relevant code or in the codebase-insights
file. ALWAYS remove older remarks if they are no longer true.

You can consult this file before starting your coding tasks.

# Code quality guidelines

- ALWAYS strive to achieve high code quality.
- ALWAYS write secure code.
- ALWAYS make sure the code is well tested and edge cases are covered. Design the code for testability and be extremely thorough.
- ALWAYS write defensive code and make sure all potential errors are handled.
- ALWAYS strive to write highly reusable code with routines that have high fan in and low fan out.
- ALWAYS keep the code DRY.
- Aim for low coupling and high cohesion. Encapsulate and hide implementation details.
- When creating executable, ALWAYS make sure the functionality can also be used as a library.
  To achieve this, avoid global variables, raise/return errors instead of terminating the program, and think whether the use case of the library requires more control over logging
  and metrics from the application that integrates the library.

# Code commenting guidelines

- Document public APIs and complex modules using standard code documentation conventions.
- Comment the intention behind your code extensively. Omit comments only for very obvious
  facts that almost any developer would know.
- Maintain the comments together with the code to keep them meaningful and current.
- When the code is based on specific formats, standards or well-specified behavior of
  other software, always make sure to include relevant links (URLs) that provide the
  necessary technical details.

# Writing git commit messages

- You MUST use multiline git commit messages.
- Use the conventional commits style for the first line of the commit message.
- Use the summary section of your final response as the remaining lines in the commit message.
