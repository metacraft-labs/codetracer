{
  description = "CodeTracer";

  inputs = {
    # Multi-language toolchain management.
    # All CodeTracer repos share the same nixpkgs pin via this flake to ensure
    # ABI compatibility (same glibc, libstdc++, LLDB, etc.) across dev shells.
    # See: codetracer-specs/Working-with-the-CodeTracer-Repos.md
    codetracer-toolchains.url = "github:metacraft-labs/nix-codetracer-toolchains";

    # Use the toolchains flake's nixpkgs pin. This ensures binaries built in
    # this shell are link-compatible with binaries from sibling repos that also
    # follow the same pin (e.g. codetracer-native-backend).
    nixpkgs.follows = "codetracer-toolchains/nixpkgs";
    nixpkgs-unstable.follows = "nixpkgs";

    appimage-channel.url = "github:NixOS/nixpkgs/nixos-24.11";

    flake-utils.url = "github:numtide/flake-utils";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Fetch noir over git+https (cloning the repo) instead of GitHub's
    # tarball API.  cache.metacraft-labs.com had a stale .narinfo for
    # the GitHub-tarball form of metacraft-labs/noir@334c1ee9 with a
    # different NAR hash than what the current upstream tarball
    # actually produces; every job that re-evaluated the flake on a
    # runner that hit that cached entry failed with
    #
    #   NAR hash mismatch in input 'github:metacraft-labs/noir/334c1ee9...':
    #   expected 'sha256-gkp/0/sMp0...' but got 'sha256-sfBJqzD3...'.
    #
    # Switching the URL scheme bypasses the cached GitHub-tarball
    # narinfo entirely; ``git+https`` content-addresses the repository
    # snapshot from the actual ``git`` history rather than GitHub's
    # archive endpoint.
    #
    # A SOURCE INPUT, NOT A FLAKE — and that is the whole point of this
    # declaration.  ``nix/packages/default.nix`` builds ``nargo`` from this
    # source itself; see the ``noir`` attribute there for why.
    #
    # The short version: this input used to be ``flake = true``, and every
    # branch of ``metacraft-labs/noir`` that carries a ``flake.nix`` is legacy.
    # Measured: 50 of 63 refs have one, and all 50 are the 2023-24 lineage —
    # ``master`` (a dead 2023 mirror), ``plonky2``, three dozen traits and
    # closures branches, and ``codetracer-temp``, the newest of them, whose
    # last upstream sync is ``v1.0.0-beta.2`` (2025-02-18).  Being a flake and
    # being current were mutually exclusive, so the Nix packaging pinned the
    # product to an eighteen-month-old compiler.  That was STRUCTURAL, not an
    # oversight: the modern ``codetracer`` branch — the one whose tracer
    # emits the ``.ct`` CTFS container this product's db-backend accepts as its
    # only materialized-trace bundle — has no ``flake.nix`` and never had one.
    #
    # ``codetracer-temp``'s tracer writes the retired
    # ``trace.json`` + ``trace_metadata.json`` + ``trace_paths.json`` sidecar
    # triplet (``tooling/tracer/src/tracer_glue.rs::store_trace``), which
    # ``db_backend_record.nim`` and ``print_trace.nim`` no longer read at all.
    # Noir recording through ``ct record`` was therefore broken FOR AS LONG AS
    # THIS INPUT WAS A FLAKE.  Dropping ``flake = true`` is what let the pin
    # move to a branch that produces a trace this product can open.
    noir = {
      url = "git+https://github.com/metacraft-labs/noir.git?ref=codetracer&rev=a5e92b847ec95a7f20eadee36745b55d7c8f9659";
      flake = false;
    };

    # The wasm recorder (`wazero`), including the Stylus replay host
    # (`wazero run -stylus`). Its package links the CTFS trace writer, so the
    # binary in the dev shells records.
    wazero = {
      url = "github:metacraft-labs/codetracer-wasm-recorder/agents";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    nix-blockchain-development = {
      url = "github:metacraft-labs/nix-blockchain-development";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    # TODO: Remove this temporary Sui-only input after nix-blockchain-development
    # is updated and cached with the latest metacraft-labs/nixos-modules graph.
    # The intended composition is that all Metacraft repos share the same
    # nixos-modules input, and each repo gets nixpkgs / nixpkgs-unstable through
    # that nixos-modules flake rather than overriding nixpkgs independently.
    # Once nix-blockchain-development follows that pattern, Sui should come from
    # the regular nix-blockchain-development input.
    nix-blockchain-development-sui = {
      url = "github:metacraft-labs/nix-blockchain-development";
      inputs.nixos-modules.follows = "nix-blockchain-development/nixos-modules";
      flake = true;
    };

    codetracer-ruby-recorder = {
      url = "github:metacraft-labs/codetracer-ruby-recorder";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.codetracer-trace-format-nim.follows = "codetracer-trace-format-nim";
      inputs.codetracer-trace-format.follows = "codetracer-trace-format";
      flake = true;
    };

    codetracer-python-recorder = {
      # `/dev`, not the bare URL.  A bare `github:owner/repo` resolves the
      # repo's DEFAULT branch, and this repo's default is `stable` -- the last
      # released recorder snapshot, the same distinction spelled out for
      # `codetracer-native-recorder` below.  `nix/python.nix` reads
      # `inputs."codetracer-python-recorder".lib.python`, the single
      # declaration of the interpreter version that repo now owns
      # (`.python-version`); that output exists on `dev` and not on `stable`,
      # so the bare URL made `nix develop` fail outright with
      # `error: attribute 'python' missing`.  Every lane other than the Nix
      # lane took the recorder from a local checkout or a workspace override
      # and so never saw the disagreement.
      #
      # `/agents` while the 2026-10 trace format is integrated there: the
      # recorder that writes it (filter provenance before the first record) is
      # on `agents` and reaches `dev` with the next promotion, like `wazero`.
      url = "github:metacraft-labs/codetracer-python-recorder/agents";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    codetracer-js-recorder = {
      url = "github:metacraft-labs/codetracer-js-recorder";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.codetracer-trace-format-nim.follows = "codetracer-trace-format-nim";
      inputs.codetracer-trace-format.follows = "codetracer-trace-format";
      flake = true;
    };

    # The parity gate compiles this producer's FLIP C ABI. Pin its source
    # alongside the other sibling inputs; no additional dev shell is needed.
    codetracer-image-diff = {
      url = "github:metacraft-labs/codetracer-image-diff/agents";
      flake = false;
    };

    codetracer-shell-recorders = {
      url = "github:metacraft-labs/codetracer-shell-recorders";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.codetracer-trace-format-nim.follows = "codetracer-trace-format-nim";
      inputs.codetracer-trace-format.follows = "codetracer-trace-format";
      flake = true;
    };

    # runquota is DERIVED, not pinned: it is whatever the `reprobuild` input
    # below locks as its own `runquota-src`. No revision for it appears in
    # this file, and flake.lock grows no independent node for it — the
    # `follows` edge means the closure holds exactly ONE runquota, and it is
    # the one reprobuild was compiled against.
    #
    # ## Why derived rather than pinned
    #
    # reprobuild COMPILES AGAINST runquota's sources. This repo used to pin
    # runquota to an exact revision here and, separately, override
    # `inputs.runquota-src.follows = "runquota"` on the reprobuild input — so
    # reprobuild was compiled against whatever THIS file said, rather than
    # against what reprobuild itself had locked and been developed on. Drift
    # in either direction is a compile error inside reprobuild's own sources,
    # minutes into `nix develop`, naming an identifier nobody here has heard
    # of:
    #
    #   behind  -> repro_runquota.nim(932): undeclared identifier: 'ExtensionCellWire'
    #   ahead   -> repro_runquota.nim(501): undeclared identifier: 'LeaseFinishOutcome'
    #
    # Both were observed on this tree — commit c9cb186c bumped reprobuild
    # while runquota stayed put — which is why
    # `scripts/test-flake-pin-alignment.sh` exists. That check compares two
    # revisions, so it can only report divergence AFTER someone has written
    # it. The `follows` edge makes the divergence UNREPRESENTABLE instead:
    # there is no second revision left to disagree with. The check now asserts
    # that structure rather than comparing two numbers.
    #
    # ## Two overrides deliberately given up
    #
    # `follows` replaces the whole input node, so the four overrides this
    # block used to carry (`nixos-modules`, `nixpkgs`, `flake-parts`,
    # `git-hooks`) are gone with it. runquota is now evaluated as reprobuild's
    # own lock parameterises it — its nixpkgs resolves through
    # `runquota-src/nixos-modules/nixpkgs-unstable` rather than through this
    # repo's `nixpkgs`. That is the intended trade, not an oversight:
    # `inputs'.runquota.packages.runquota` (nix/shells/ci-base.nix) and
    # `RUNQUOTA_SRC` (ci-base.nix, nix/packages/default.nix) now resolve to
    # the runquota the shipped `repro` was actually built against, instead of
    # a separately-parameterised rebuild of it.
    runquota.follows = "reprobuild/runquota-src";

    reprobuild = {
      # NAMES A BRANCH, NOT A REVISION. The revision lives in flake.lock and
      # only there; this URL says WHICH LINE flake.lock is allowed to hold a
      # revision from. Moving the pin is a re-lock, never a transcribed SHA.
      #
      # ## Why `agents` and not `release/0.2.10`
      #
      # THIS REPO NOW TRACKS AN UNRELEASED REPROBUILD. That is the point, and
      # it is a deliberate trade rather than an oversight.
      #
      # Until 2026-10-15 this said `release/0.2.10`, mirroring the revision
      # metacraft-labs/nixos-modules pins for the whole org
      # (064daf5b154ea6a0758ddb2dcbcbc07685216e44). Tracking the release was
      # faithful and still failed the gate: `repro check --mode=pre-push`
      # compares every SUBSTITUTED input against the SIBLING CHECKOUT's HEAD
      # (`verifyFlakeLockAgainstSiblings`, repro_cli_support.nim:50897), and
      # the `../reprobuild` sibling every workspace here has is on `agents`,
      # 136 ahead / 7 behind that release. A faithful release pin was therefore
      # reported `flake_lock_stale` on every push, permanently.
      #
      # The repo was also already carrying both answers at once: `repro.lock`
      # records reprobuild at `f248842443e09cd` with `ref = "agents"` while
      # this file said `release/0.2.10` — two revisions of one dependency for
      # two purposes, with nothing keeping them equal. Tracking `agents` here
      # converges them.
      #
      # What is given up: the `repro` this repo's shells ship is no longer the
      # one `nixos-modules` pins for the rest of the org, so a reprobuild
      # regression reaches this repo before it reaches a release. The ONE
      # thing that must not happen as a result is a lock naming a revision
      # nobody else can obtain; `repro flake refresh-lock` already refuses to
      # record an unpublished sibling HEAD (`flakeClassifyPublication`), and
      # the revision below is on `origin/agents`.
      #
      # Why a ref and not the SHA: a URL carrying `rev=` sets `original.rev` in
      # flake.lock, and nothing may then move the node — `repro flake
      # refresh-lock` declines it by design ("the revision is the author's
      # statement and lives there"), while `repro check --mode=pre-push`
      # independently fails `flake_lock_stale` for the very same node. The two
      # halves are provably unsatisfiable together, so a commit-pinned URL
      # cannot satisfy both gates at once.
      # reprobuild's own flake takes this same shape for its `runquota-src`
      # (`url = "github:metacraft-labs/runquota/dev"`).
      #
      # This still does NOT `follows` nixos-modules' own reprobuild node,
      # because a bare `follows` replaces the whole input node and would drop
      # the overrides below: reprobuild would then be built against a different
      # nixpkgs and against its own native-recorder pins, producing a different
      # `repro` binary than the one this repo's shells are meant to ship.
      #
      # This pin is also a FLOOR, not only a mirror: `repro.nim` is compiled by
      # the `repro` this resolves to, so a recipe here cannot use a DSL
      # parameter the pinned revision has not grown yet. The previous pin
      # (`3a7ef0d7`) predated `extraEnv` on `sh.nim`'s `shell()`, which the ten
      # gate actions below declare `PYTHONHASHSEED` through, and the whole file
      # failed to compile:
      #
      #   repro.nim(1766, 40) Error: type mismatch
      #     [7] extraEnv = GateEnv: ...  unknown named parameter: extraEnv
      #
      # Nothing in CI compiles `repro.nim` on a pull request, so a pin that is
      # merely old is indistinguishable from a pin that is too old until
      # someone runs `repro build` — and in a WORKSPACE checkout that is not
      # enough either: `.envrc` sets `NIX_FLAKE_OVERRIDE_AUTO=1`, so a sibling
      # `../reprobuild` silently overrides this input and a local `repro build`
      # exercises the sibling's HEAD rather than the pin. To exercise the pin,
      # drop that one override:
      #
      #   nix develop '.?submodules=1' <other overrides> --command repro build
      #
      # (`readlink -f "$(command -v repro)"` names which one you actually got.)
      #
      # BUMPING THIS ALSO MOVES OUR NIM COMPILER. `nix/packages/default.nix`
      # takes `nim-fork` from this input's `packages.nim-fork`, and that is the
      # `nim` first on `$PATH` in every dev shell — so it compiles every Nim
      # test lane, `just build-storybook-components`, and the `repro.nim`
      # interface extraction that `just build-once` starts with. A reprobuild
      # bump therefore carries a compiler bump; re-run `just test-vm-native`,
      # `just test-vm-js` and `just build-once` after one. (Deliberately a
      # single pin: a second `nim-fork-src` pin here would be two pins for one
      # thing with nothing keeping them equal — the failure mode
      # `scripts/test-flake-pin-alignment.sh` exists to catch for `runquota`.)
      url = "github:metacraft-labs/reprobuild/agents";
      inputs.nixos-modules.follows = "nix-blockchain-development/nixos-modules";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.git-hooks.follows = "git-hooks-nix";
      # Reprobuild owns RunQuota's source and its input parameterisation.
      # Restating a nested URL overrides the producer's locked child when
      # this parent is updated, even if both happen to match today. Keep
      # the root `runquota` follows edge above and inherit the complete input.
      flake = true;
    };

    # Non-flake input: the trace-format Rust workspace.  At runtime in the
    # workspace dev shell, `.envrc` overrides this with `--override-input
    # codetracer-trace-format path:../codetracer-trace-format` so changes
    # in the sibling checkout are picked up immediately.  In CI / fresh
    # nix builds without a sibling, the input fetches from GitHub.
    #
    # See codetracer-specs/Working-with-the-CodeTracer-Repos.md for the
    # sibling-detection mechanism.
    #
    # `dev`, not `main`.  This was the last metacraft-labs sibling input still
    # tracking `main`, and it broke the Nix lane outright: `src/db-backend`'s
    # `ctfs_trace_reader` calls `NimTraceReaderHandle::{refresh, event_metadata}`,
    # `{Call,Step,Value}StreamReader::from_files` and a public
    # `decode_chunk_records`, none of which exist on `main`
    # (`29b2e047`, "ci: migrate ci-reprobuild.yml to the 5-class platform
    # matrix"), so `nix build '.?submodules=1#codetracer'` died with 13 compile
    # errors in `db-backend` -- E0603 `decode_chunk_records is private`, six
    # E0599 `no function ... named from_files`, E0599 `no method named refresh`
    # / `event_metadata`, and the E0277s that follow from them.
    #
    # `dev` is where product work lands for this repo class, and every other
    # lane already used it: the workflow's sibling-clone step asks for
    # `codetracer-trace-format=dev` (`.github/workflows/codetracer.yml`), its
    # matched FFI half `codetracer-trace-format-nim` is declared `/dev` five
    # declarations below, and so is `codetracer-native-recorder`. Only this one
    # input disagreed, so only the lane that consumes flake inputs rather than
    # sibling checkouts -- the Nix lane -- could see the disagreement.
    #
    # `/agents` while the 2026-10 trace format is integrated there: the
    # writer that produces it, and the readers in this repository that refuse
    # anything older, land on `agents` together and reach `dev` with the next
    # promotion. The recorders this flake builds (the Python recorder above,
    # and those that follow `codetracer-trace-format-nim`) take the writer
    # from these two inputs.
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/agents";
      flake = false;
    };

    # Non-flake inputs: needed by ``src/db-backend/build.rs`` and
    # ``codetracer_trace_writer_nim``'s build.rs to materialise
    # generated C / Nim FFI sources before the Rust crate links.  The
    # build script canonicalises ``../../../codetracer-native-recorder``
    # and ``../codetracer-trace-format-nim`` -- inside the Nix sandbox
    # we have to seed those paths from these flake inputs.  ``.envrc``
    # overrides each with a local checkout when present.
    codetracer-native-recorder = {
      # CodeTracer's dev build needs the recorder integration branch:
      # db-backend's emulator FFI contract moves with native-recorder
      # dev, while stable is only the last released recorder snapshot.
      url = "github:metacraft-labs/codetracer-native-recorder/dev";
      flake = false;
    };
    codetracer-trace-format-nim = {
      # `/agents` with `codetracer-trace-format` above, for the same reason.
      url = "github:metacraft-labs/codetracer-trace-format-nim/agents";
      flake = false;
    };
    # The native CLI used by backend-manager's recording tests imports the
    # production CTFS visual-stream reader, even for a non-graphics recording.
    codetracer-visual-replay = {
      url = "github:metacraft-labs/codetracer-visual-replay/agents";
      flake = false;
    };
    codetracer-native-backend = {
      url = "github:metacraft-labs/codetracer-native-backend/agents";
      flake = false;
    };
    # Match native-backend's Cargo.lock. Fetch this private source through
    # Nix's authenticated flake fetcher, rather than fetchgit in the sandbox.
    native-license-lldb-sys = {
      url = "github:metacraft-labs/lldb-sys.rs/7db095133fc4a03b39822de33907f5d25efcbd7c";
      flake = false;
    };

    # codetracer_trace_writer_nim imports both `results` and `stew/*` while
    # building the locked Python recorder. The main source input does not
    # include Git submodules, so pin the exact nim-stew revision recorded by
    # this repository's libs/nim-stew gitlink for sandboxed recorder builds.
    nim-stew = {
      url = "github:status-im/nim-stew/9c3596d9de809a5933fd777cec1183c2cdf521ec";
      flake = false;
    };

    # The sandboxed backend-manager test recorder (nix/packages/default.nix)
    # compiles codetracer-native-recorder's ct_cli, whose record parser needs
    # the metacraft-labs confutils fork at the exact commit its ct_cli.nimble
    # pins (the `valueName` / `implicitValue` / `alsoSets` pragmas). The main
    # source input carries no Git submodules, so these cannot come from
    # libs/; serialization and faststreams match this repository's gitlinks.
    nim-confutils = {
      url = "github:metacraft-labs/nim-confutils/331c5fa2f741a6657c16404bfc9401b18d295f92";
      flake = false;
    };
    nim-serialization = {
      url = "github:status-im/nim-serialization/9eb88077063bf7e16357e1ed6aaa7c1391b4d7c4";
      flake = false;
    };
    nim-faststreams = {
      url = "github:status-im/nim-faststreams/37a183153c071539ab870f427c09a1376ba311b9";
      flake = false;
    };

    # The standalone `results` package. codetracer-trace-format-nim declares
    # `requires "results"`. The `stew/results.nim` copy in the nim-stew pin
    # above is an older fork of it: its `unsafeError` constrains the value
    # type as well (`[T, E: not void]`), so `unsafeError` on a
    # `Result[void, E]` does not compile under upstream Nim 2.2, and the
    # writer uses exactly that. Every sandboxed build that compiles
    # trace-format-nim takes `results` from here. Tracks the same branch as
    # trace-format-nim's own flake.
    nim-results = {
      url = "github:arnetheduck/nim-results";
      flake = false;
    };

    # Non-flake inputs: ct_test's incremental runner imports the
    # io-mon capture model and stackable-hooks propagation helpers at
    # compile time.  Workspace dev shells resolve these as sibling repos;
    # standalone Nix package builds need deterministic source fallbacks.
    io-mon = {
      url = "github:metacraft-labs/io-mon/dev";
      flake = false;
    };
    nim-stackable-hooks = {
      url = "github:metacraft-labs/nim-stackable-hooks/dev";
      flake = false;
    };

    # Non-flake input: the reprobuild-packages catalog. Every `uses:` name in
    # `repro.nim` that reprobuild's stdlib no longer bundles — `sqlite3`,
    # `shellcheck`, `shfmt` and `prek` so far (reprobuild
    # `MovedToReprobuildPackages`); this recipe uses the first two — is looked
    # up here as `packages/interfaces/<name>/repro.nim`, and a recipe naming a
    # moved package that the catalog lacks does not compile. Every dev shell
    # that runs `repro` on this recipe exports it as REPROBUILD_PACKAGES_ROOT
    # (`nix/shells/ci-base.nix`), because in CI nothing clones the catalog
    # beside this checkout and the `repro` this flake pins is built from a
    # store path, beside which there is no catalog either.
    #
    # THIS PIN IS THE CATALOG, IN EVERY SHELL, AND A `../reprobuild-packages`
    # SIBLING DOES NOT REPLACE IT. With REPROBUILD_PACKAGES_ROOT set, reprobuild
    # consults no other location — that is the point: one catalog every lane
    # agrees on. This comment used to say `.envrc` substitutes the sibling;
    # it does not. `.envrc`'s blanket auto-override (NIX_FLAKE_OVERRIDE_AUTO=1)
    # skips any sibling without a `flake.nix` ("has no flake.nix; skipping",
    # direnv-nix-flake-overrides d643c23), and the catalog has none
    # (reprobuild-packages 4e2fd1dc). Believing otherwise is how this pin sat
    # at 9d9176bff5c5 — a revision without `shellcheck` — from 2026-09-30, the
    # day it was introduced, until 66f365d26 (2026-10-18) moved it: the dev
    # shell could not compile the recipe, and a workspace with a newer
    # sibling saw no sign of it (codetracer-pm issues/2026-10-13-the-
    # codetracer-dev-shell-pins-a-package-catalog-that-predates-shellcheck-
    # and-suppresses-the-sibling-that-has-it.md).
    #
    # So drift is prevented by a check, not by a fallback:
    # `scripts/test-reprobuild-catalog-coverage.sh` (`just
    # test-reprobuild-catalog-coverage`; run in `ci/lint/bash.sh` against
    # these real pins, and in `just test`) fails when any `uses:` name, on any
    # platform branch, resolves neither here nor in the stdlib nor in a
    # workspace producer, and when this revision and repro.lock's
    # `reprobuild-packages` revision differ. Move both together.
    #
    # PINNED BY REVISION, NOT BY BRANCH, and the revision is the one
    # reprobuild's own lock declares (`runquota-package-catalog`). Tracking
    # `dev` is what broke this shell: `shellcheck`, `shfmt` and `prek` left
    # reprobuild's stdlib, so a recipe that `uses:` them needs their
    # `packages/interfaces/<pkg>/repro.nim` from this catalog — and those
    # interfaces were added on the catalog's `agents` branch (5cb3f71026c5,
    # 2026-09-30) and have never been promoted to `dev`, whose tip has not
    # moved since 2026-09-29. So re-resolving `dev` cannot fix it: the content
    # is not on that branch to be resolved to. Re-pinning the PARENT
    # (reprobuild) forward while this child stayed on a branch that never
    # received the matching recipes is the same stale-child class as
    # `io-mon-src` (f79853ec2); the fix is the same single-node graft onto the
    # revision reprobuild itself declares.
    reprobuild-packages = {
      url = "github:metacraft-labs/reprobuild-packages/344e268e12de75c38bd1c6ad4620e60bf6548ab8";
      flake = false;
    };

    # Non-flake input: the metacraft-labs/langserver fork (a.k.a. nim-langserver),
    # branch `codetracer`.  Carries patches on top of upstream nim-lang/langserver
    # that the CodeTracer GUI depends on — currently `nim/traceExpandMacro`
    # (M11) and `nim/traceStaticBlock` (CTFS-M-StaticBlockTrace) LSP commands.
    # The overlay in `perSystem` substitutes nixpkgs' `nimlangserver` src with
    # this revision, so a stock `nix develop` ships our patched binary.
    #
    # `.envrc` can override with `--override-input nim-langserver path:../nim-langserver`
    # to consume a local sibling checkout during development.
    nim-langserver = {
      url = "github:metacraft-labs/langserver?ref=codetracer";
      flake = false;
    };

    # Non-flake inputs: the IsoNim view-layer used by the GUI, plus its
    # support libraries.  ``nim.cfg`` carries
    # ``path:"../isonim/src"`` / ``isonim-tui`` / ``isonim-gpui`` /
    # ``nim-everywhere`` / ``nim-termctl`` / ``nim-pty`` so local dev
    # shells pick up sibling checkouts; in CI / fresh ``nix build``
    # invocations we need deterministic sources for these to resolve
    # ``import isonim/web/web_renderer``, ``import nim_everywhere/platform``
    # etc. when building ``ui.js`` and the other Nim derivations.
    #
    # ``.envrc`` can override each with
    # ``--override-input isonim path:../isonim`` for local development.
    isonim = {
      url = "github:metacraft-labs/isonim/dev";
      flake = false;
    };
    # Facebook's Yoga, which ``isonim`` vendors as a GIT SUBMODULE at
    # ``src/isonim/layout/yoga`` and ``src/isonim/layout/yoga_bindings.nim``
    # compiles directly with ``{.compile.}`` -- 40-odd ``.cpp`` files, no
    # separate build step.
    #
    # WHY IT IS A SEPARATE INPUT.  The ``isonim`` input above is a ``github:``
    # url, which nix fetches as a TARBALL, and a tarball carries no submodule
    # content.  So ``$ISONIM_STAGE/isonim/src/isonim/layout/yoga`` is EMPTY in
    # the sandbox, and the first derivation to compile anything that touches
    # isonim's layout dies with
    #
    #   yoga_bindings.nim(20, 10) Error: cannot find:
    #     .../src/isonim/layout/yoga/yoga/YGConfig.cpp
    #
    # measured on 2026-09-06 while packaging ``codetracer-tui`` (CTUI-12).
    # Nothing hit it before because the JS-target derivations never reach the
    # C++ branch.  This is the same prerequisite CTUI-0 recorded for a
    # workspace checkout, where ``just tui-prereqs`` answers it with
    # ``git submodule update --init``.
    #
    # PINNED BY SHA, ON PURPOSE, and the sha is isonim's own gitlink:
    #   git -C isonim ls-tree <isonim-rev> src/isonim/layout/yoga
    # reports 3acb6cca at both the revision ``flake.lock`` pins for ``isonim``
    # (9936c544) and at the current ``dev`` tip (2a24d954).  A floating ref
    # would let this input and isonim's submodule disagree about which Yoga is
    # being compiled, with nothing to notice it: a tarball carries no gitlink,
    # so no build-time check can compare them.  When isonim bumps its
    # submodule, bump this line in the same change, and re-read the sha with
    # the command above rather than from memory.
    #
    # The alternative -- refetching ``isonim`` itself as
    # ``git+https://...?ref=dev&submodules=1`` -- was rejected here because it
    # would MOVE the isonim pin (9936c544 -> dev tip) for every derivation that
    # consumes it, which is a content change that has nothing to do with
    # packaging the TUI.
    isonim-yoga = {
      url = "github:facebook/yoga/3acb6cca429736a15e8634fbb3823003a9fe3a3d";
      flake = false;
    };
    isonim-tui = {
      url = "github:metacraft-labs/isonim-tui/dev";
      flake = false;
    };
    isonim-gpui = {
      url = "github:metacraft-labs/isonim-gpui/dev";
      flake = false;
    };
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/dev";
      flake = false;
    };
    nim-termctl = {
      url = "github:metacraft-labs/nim-termctl/dev";
      flake = false;
    };
    nim-pty = {
      url = "github:metacraft-labs/nim-pty/dev";
      flake = false;
    };
    nim-acp = {
      url = "github:metacraft-labs/nim-acp/dev";
      flake = false;
    };
    nim-agent-harbor = {
      url = "github:metacraft-labs/nim-agent-harbor/dev";
      flake = false;
    };
    nim-agents = {
      url = "github:metacraft-labs/nim-agents/dev";
      flake = false;
    };

    # Pre-commit hooks
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
  };

  # outputs = {
  #   nixpkgs,
  #   flake-utils,
  # }: let
  #   system = "x86_64-linux";
  #   pkgs = import nixpkgs {
  #     inherit system;
  #     overlays = [(import ./overlay.nix)];

  #     config = {
  #       permittedInsecurePackages = [
  #         "electron-13.6.9"
  #       ];
  #       # allowUnfree = true;
  #     };
  #   };
  #   # node2nixOutput = import ./src { inherit pkgs   system; };
  #   # nodeDeps = node2nixOutput.nodeDependencies;
  # in {
  #   # pkgs.overlays = [ (import ./overlay.nix) ];
  #   devShell."${system}" = import ./shell.nix {inherit pkgs;};
  # };

  outputs =
    inputs@{
      nixpkgs,
      nixpkgs-unstable,
      flake-parts,
      fenix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      imports = [
        ./nix/shells
        ./nix/packages
        inputs.git-hooks-nix.flakeModule
      ];

      # NixOS module for CodeTracer with BPF process monitoring.
      # Usage in configuration.nix:
      #   imports = [ codetracer.nixosModules.default ];
      #   programs.codetracer.enable = true;
      #   users.users.myuser.extraGroups = [ "codetracer-bpf" ];
      flake.nixosModules.default = ./nix/packages/codetracer-appimage/nixos-module.nix;

      # NixOS module for developer builds: passwordless setcap on the ct binary.
      # Usage in your NixOS configuration (e.g. ~/dotfiles):
      #   imports = [ codetracer.nixosModules.developer-bpf ];
      #   programs.codetracer.developer-bpf = {
      #     enable = true;
      #     user = "myuser";
      #     repoPath = "/home/myuser/metacraft/codetracer";
      #   };
      flake.nixosModules.developer-bpf = ./nix/modules/developer-bpf.nix;

      perSystem =
        { system, config, ... }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            config = {
              # tup is currently considered broken by Nix, but this is not true
              # TODO: this is already fixed in nixpkgs/unstable, so it may become
              #       unnecessary after a future `flake update`
              allowBroken = true;
              # NOTE: `permittedInsecurePackages = [ "electron-24.8.6" ]` used to
              # sit here (and in the `nixpkgs-unstable` import below). It was
              # dead: this flake's pinned nixpkgs
              # (687f05a9184cad4eaf905c48b63649e3a86f5433) exposes electron
              # attributes 37 through 41 and `electron` = 41.3.0 — there is no
              # `electron_24` for the permit to apply to, so nothing in any
              # evaluation was ever unblocked by it. Measured, not assumed:
              #
              #   nix eval --raw ... (attrNames matching ^electron)
              #   -> electron = 41.3.0, electron_37..electron_41, no electron_24.
              #
              # A standing permit for an insecure package is worse than useless
              # when the package is absent: it reads as "we knowingly ship a
              # 2023 Chromium" to anyone auditing the flake, and it would
              # silently start applying if a future nixpkgs bump reintroduced
              # the attribute.
            };
            overlays = [
              # crates.io's API host now answers 403 to every `curl/*`
              # User-Agent, which is exactly what `pkgs.fetchurl` sends, so
              # `importCargoLock` could not fetch a single Rust crate source
              # and `nix build .#backend-manager` / `.#codetracer` could not
              # start. This routes those fetches at `static.crates.io`, the
              # same substitution nixpkgs made upstream and which our pin
              # predates. Output paths are unchanged; see the file for the
              # measurement and for who owns the durable fix.
              (import ./nix/overlays/crates-io-download-url.nix)

              # Substitute nixpkgs' upstream `nimlangserver` source with our
              # metacraft-labs/langserver fork (branch `codetracer`), so the
              # binary in the dev shell carries the `nim/traceExpandMacro`
              # and `nim/traceStaticBlock` LSP commands the CodeTracer GUI
              # depends on.
              #
              # Nixpkgs' `nimlangserver` derivation computes
              # `meta = final.src.meta // { ... }` inside the
              # `buildNimPackage` fix-point — so a raw flake-input path
              # (which lacks a `.meta` attribute, unlike the
              # `fetchFromGitHub` output it replaces) breaks the inner
              # evaluation BEFORE `overrideAttrs` has a chance to fix up
              # the final meta.  We therefore decorate the source with an
              # empty `meta` via the `//` operator so the inner lookup
              # succeeds; the final meta is overridden a second time at the
              # outer derivation level (where `overrideAttrs` does run).
              (_final: prev: {
                nimlangserver = prev.nimlangserver.overrideAttrs (old: {
                  version = "${prev.nimlangserver.version}-metacraft-codetracer";
                  src = inputs.nim-langserver // {
                    meta = { };
                  };
                  meta = (old.meta or { }) // {
                    description = "Nim language server (metacraft-labs/langserver, branch codetracer)";
                    homepage = "https://github.com/metacraft-labs/langserver";
                  };
                });
              })
            ];
          };

          _module.args.unstablePkgs = import nixpkgs-unstable {
            inherit system;
            # No `config` opinion: the `permittedInsecurePackages` entry that
            # used to live here named `electron-24.8.6`, which this revision of
            # nixpkgs does not contain. See the note on the `nixpkgs` import
            # above.
            # `nixpkgs-unstable` `follows` `nixpkgs`, so this set is the same
            # revision and carries the same 403 on every crate download. It gets
            # the same overlay rather than being left as the one package set in
            # this flake that still cannot fetch a crate.
            overlays = [ (import ./nix/overlays/crates-io-download-url.nix) ];
          };

          # Pre-commit hooks configuration
          pre-commit.settings = import ./nix/pre-commit.nix {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ (import ./nix/overlays/crates-io-download-url.nix) ];
            };
            rustPkgs = config.packages;
          };

          # Disable pre-commit checks during nix flake check because the Rust
          # hooks need git submodules which aren't available in the Nix sandbox.
          # The hooks still work in the dev shell and during actual git commits.
          pre-commit.check.enable = false;
        };
    };
}
