# Instructions for Codex

## Where a checkout — or a worktree — has to live

**A checkout of this repo must sit DIRECTLY under the workspace root, beside its
sibling repos.** A `git worktree` is a checkout and this rule is not relaxed for
it: put worktrees at `<workspace>/<name>`, never at `<workspace>/.agent-wt/<name>`
or in any other subdirectory, and never outside the workspace.

```
/path/to/workspace/          # the workspace root
  codetracer/                # the main checkout
  my-feature/                # CORRECT — a worktree, beside the siblings
  isonim/  runquota/  nim-agents/  codetracer-trace-format/  ...
  .agent-wt/
    my-feature/              # WRONG — its parent is `.agent-wt`, which has no siblings
```

The reason is that **the parent directory of the checkout IS the workspace root,
by definition**, for four independent resolvers that reach siblings by the
relative path `../<sibling>`:

| resolver | where | how it fails from the wrong place |
| --- | --- | --- |
| Nim | `config.nims` (`repoRoot.parentDir()`), `src/Tuprules.tup` (`$(ROOT)/../…`) | `--path` to a missing dir is silently ignored → `cannot open file: runquota_process`, minutes in |
| Cargo | `src/db-backend/Cargo.toml` (`path = "../../../codetracer-trace-format/…"`) | `failed to load manifest` |
| cc | `src/db-backend/build.rs` (`../../../codetracer-native-recorder/ct_emulator`) | 81 undefined `mcr*` symbols at link |
| Repro/Nix | `repro.nim` and native workspace input overrides (`../io-mon`, `../reprobuild`, …) | sibling overrides cannot be resolved |

None of the four can be pointed elsewhere per-worktree, so relocating the
checkout is the only fix. In particular **`runquota` has no override at all** by
design — see the tier notes in `scripts/require-siblings.sh` — so no environment
variable can paper over a badly-placed worktree.

Create one like this, from the main checkout:

```bash
git -C /path/to/workspace/codetracer worktree add /path/to/workspace/<name> <branch>
```

and move a misplaced one like this:

```bash
git worktree move /path/to/workspace/.agent-wt/<name> /path/to/workspace/<name>
```

`scripts/require-siblings.sh` runs before every build (`just build-once`,
`just build`, `just test-gui`, …) and refuses a badly-placed checkout by name.
**Do not answer it with `CODETRACER_SKIP_SIBLING_CHECK=1`**: that escape hatch is
for genuinely different layouts (vendored trees, Nix builds that pre-stage the
paths). Used here it only removes the message — the build still cannot see the
siblings and dies later naming a *module* instead of the real problem.

## Building the full frontend (Nim + Electron)

To rebuild the full CodeTracer frontend (Nim backend CLI, Nim renderer JS, webpack bundles):

```
just build-once
```

This runs tup (incremental build) and webpack. Use this after modifying any `.nim` files in
`src/ct/`, `src/frontend/`, or `src/common/`.

## Local dev-env services (`repro up`)

What this repo declares today, and what it does **not**:

```sh
repro up    --activity=frontend   # brings up `browser-replay` (the nginx harness)
repro down  --activity=frontend
repro tasks --activity=frontend
```

That is the whole service graph: **one** service, `browser-replay`, declared in
`repro.nim` under activities `frontend` and `tests`, and described in
[`browser-replay/README.md`](browser-replay/README.md). `repro up` with no
`--activity` starts nothing, because the `default` activity declares no
services — so silence there is the design, not a failure.

**There is no local identity provider in this repo.**
`src/frontend/viewmodel/identity/issuer.nim` opens with "The shared identity
issuer: Zitadel at `login.metacraft-labs.com`" — one issuer, shared across
products, rather than CodeTracer's own. Nothing here stands up a local
equivalent, so a local run has no issuer to talk to unless one is already
running on the machine.

A sibling checkout in the same workspace does run one as part of its own local
stack; if you have that checkout, its `local-dev/README.md` is the authority on
bringing it up and on a known defect where the command exits non-zero on a
session that came up correctly.

**Do not add a second copy of the issuer here to work around that.** Two
definitions of one shared service is the outcome worth avoiding, and the reason
it is not simply factored into something both repos reference is a reprobuild
limitation rather than an oversight: a dev-env service is declared as a name, an
activity list and an opaque metadata string, with no composition and no way to
reference a service declared elsewhere. That gap — and the build-caching
consequence that follows from it — is recorded in the reprobuild specs repo's
`issues/` folder, dated 2026-10-07.

## Launching the TUI / GPUI for the user

The user-facing reference is README.md, "Running the terminal (TUI) and native
(GPUI) front-ends". The agent recipe, from a clean shell at this checkout's root:

1. **Environment.** Run build/record commands as `repro exec . -- <cmd>` (no
   interactive shell, no direnv). The first run in a checkout takes minutes.
2. **Siblings at the pin.** `../isonim-tui` and `../isonim-gpui` must contain the
   revisions `flake.lock` pins (`jq -r '.nodes["isonim-tui"].locked.rev' flake.lock`),
   or the TUI fails to compile with undeclared identifiers from isonim-tui. Do not
   move the user's sibling checkouts; use the `../<repo>-pin` worktree loop from
   README.md and `export ISONIM_TUI_SRC=$PWD/../isonim-tui-pin/src
   ISONIM_GPUI_SRC=$PWD/../isonim-gpui-pin/src` before building.
3. **Build:** `repro exec . -- just build-once` (only if `src/build-debug/bin/ct` or
   `replay-server` is missing), then `repro exec . -- just build-tui`.
4. **A trace.** Reuse `test-logs/tui-fixtures/calc-*/` if `just test-tui` has run
   here, or record one: `repro exec . -- ct record -o /tmp/ct-calc
   test-programs/calc/main.py`. Package-style Python needs
   `repro exec . -- env PYTHONPATH=<pkg-parent> ct record ...` (a `PYTHONPATH`
   exported before `repro exec` is replaced by the environment's).
5. **Check it headless first:** `build/bin/codetracer-tui --headless <trace>`
   prints one screen and exits; the built binaries run without the environment.
6. **Open it in a tmux split for the user** (from inside their tmux session; it
   creates a NEW pane and leaves the others alone, `-d` keeps focus where it is):

   ```bash
   tmux split-window -v -c "$PWD" "build/bin/codetracer-tui <trace> || read"
   ```

   Equivalent through the launcher: `src/build-debug/bin/ct replay --ui=tui <trace>`.
   A dev build finds `src/build-debug/bin/replay-server` of its own checkout; set
   `REPLAY_SERVER_BIN=<path>` when the engine lives elsewhere (for example a
   `src/build-debug-repro/bin/` build, or another worktree's).
7. **State.** When launching for the user, do NOT set `CODETRACER_TUI_LAYOUT_DIR`:
   they expect their own remembered layout in `$XDG_STATE_HOME/codetracer/`
   (`~/.local/state/codetracer/tui-layout.json`). When YOU drive the TUI for
   testing, always set `CODETRACER_TUI_LAYOUT_DIR=<scratch dir>` so a test never
   rewrites the user's layout or `icons` choice — and a scratch
   `CODETRACER_HOME` (see "Tests never touch your real CodeTracer state"), which
   keeps the trace index, recordings and config out of their profile as well.
8. **Stopping.** The user quits with `q`; closing the pane also ends it. Each
   running TUI owns one `replay-server` child, which exits with it. The
   orphan-sensitive pty suites (`test_real_no_orphans`, `test_real_pty_lifecycle`)
   count every `replay-server` on the host, so they FAIL while the user's TUI pane
   is open. Check `pgrep -a replay-server` before running them or before calling
   such a failure a regression, and never kill a replay-server you did not start.

GPUI: build the windowed shim in the same isonim-gpui checkout the build compiles
against (`repro exec . -- bash -c 'cd rust && cargo build --features gpui-backend'`
inside it), `repro exec . -- just build-gpui`, and launch with
`repro exec . -- bash -c 'LD_LIBRARY_PATH=$CODETRACER_GPUI_RUNTIME_LIB_PATH
src/build-debug/bin/ct replay --ui=gpui <trace>'` from a graphical session. With
no display, use `--report-plan` (same command) to check the build; `--headless`
is TUI-only and `ct` refuses it with `--ui=gpui`.

## Building the db-backend

```
# inside src/db-backend
cargo build
```

## Running tests

```
# inside src/db-backend
CODETRACER_HOME="$(mktemp -d)" cargo test
```

### Tests never touch your real CodeTracer state: `CODETRACER_HOME`

`CODETRACER_HOME` relocates EVERY per-user location CodeTracer has — the trace
index, recordings, config and layouts, native TUI/GPUI state, caches, the
per-run tmp dir, Electron's profile, `ct-native-replay`'s licensing counter —
on every OS, and every child process inherits it. Layout:
`$CODETRACER_HOME/{data,config,state,cache,tmp,launcher}`. Resolvers:
`src/common/ct_home.nim` (Nim) and `libs/ct-home` (Rust); unset, nothing moves.
Full table: codetracer-specs `Architecture/Per-User-State-Locations.md`.

- The harnesses set a scratch one for you: every Nim test program (force-imported
  `test_support/state_isolation.nim`), `ci/lib/run-nim-test-lane.sh` (one per
  file), `just test-rust` / `just test-frontend-js` / the Windows Rust lanes /
  `scripts/run-cross-repo-tests.sh` (`ci/lib/codetracer-home.sh`), the
  db-backend integration harness (`ct_home::isolate_for_tests`), and the
  Playwright fixtures. A bare `cargo test` or `cargo nextest` does NOT — export
  one as above.
- When a suite gives a spawned helper a scratch directory, set
  `CODETRACER_HOME` for it. Never redirect `HOME`/`USERPROFILE`/`XDG_*_HOME`
  instead: `CODETRACER_HOME` outranks them, and missing `USERPROFILE` is how a
  Windows run wrote into a real `trace_index.db` (2026-09-23).
- When YOU drive `ct`, the TUI or the GUI to verify something, export a scratch
  `CODETRACER_HOME` too. When launching for the user, do not.
- `src/common/ct_home_isolation_test.nim` fails a harness that stops setting it,
  a suite that redirects a home variable without it, and a resolver that
  ignores it.

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
(`repro exec <repo> -- just build`, via `scripts/build-siblings.sh`) so the recording tests run
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
cd src/tui && cargo build && cargo test   # the legacy Rust TUI crate, NOT the terminal front-end (`just build-tui`)
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

The Repro shell hook activates the flake through `repro.nim`. Run `repro allow`
once for this checkout, then enter it with the hook installed. For an explicit
command, use `repro exec /path/to/codetracer -- <command>`.

Repro resolves declared workspace siblings as native flake input overrides.
Keep direnv denied; `.envrc` and the old override plugin are not required for
this activation path. Changes to the recipe require renewed Repro authorization.

### Blockchain recorder tools (circom, forc)

The Nix dev shell supplies the toolchains declared by the CodeTracer flake.
Build recorder siblings through `scripts/build-siblings.sh`; each recorder's
`repro.nim` activates its own pinned environment. See the helper's per-repository
logs when a required tool or sibling build fails.

### Inspecting a Nix environment directly

To diagnose an individual flake input independently of shell activation, use an
explicit Nix invocation without changing direnv trust:

```bash
nix develop '.?submodules=1' --override-input nix-blockchain-development path:../nix-blockchain-development -c bash
```

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
