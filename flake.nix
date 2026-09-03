{
  description = "Code Tracer";

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
      url = "git+https://github.com/metacraft-labs/noir.git?ref=codetracer&rev=ca080a58b05106e37a7b5178a11a8f4503951a2b";
      flake = false;
    };

    wazero = {
      url = "github:metacraft-labs/codetracer-wasm-recorder?ref=wasm-tracing";
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
      url = "github:metacraft-labs/codetracer-python-recorder/dev";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    codetracer-js-recorder = {
      url = "github:metacraft-labs/codetracer-js-recorder";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.codetracer-trace-format-nim.follows = "codetracer-trace-format-nim";
      flake = true;
    };

    codetracer-shell-recorders = {
      url = "github:metacraft-labs/codetracer-shell-recorders";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.codetracer-trace-format-nim.follows = "codetracer-trace-format-nim";
      flake = true;
    };

    runquota = {
      # runquota/main is stale and lacks the bounded grant-stream API
      # (pollNextGrantBounded / GrantPollResult) that current reprobuild uses.
      #
      # PINNED to the exact revision that the `reprobuild` input below locks as
      # its own `runquota-src`, and it must be kept equal to it. This is NOT a
      # "keep it recent" pin, and a branch is the wrong thing here: the
      # `inputs.runquota-src.follows = "runquota"` line below means REPROBUILD
      # IS COMPILED AGAINST WHATEVER THIS RESOLVES TO, so any drift in either
      # direction is a compile error inside reprobuild's own sources, minutes
      # into `nix develop`, naming an identifier nobody here has heard of:
      #
      #   behind  -> repro_runquota.nim(932): undeclared identifier: 'ExtensionCellWire'
      #   ahead   -> repro_runquota.nim(501): undeclared identifier: 'LeaseFinishOutcome'
      #
      # Both were observed on this tree: `dev` had moved past the pinned
      # reprobuild and REMOVED LeaseFinishOutcome, so tracking the branch tip
      # was no more correct than lagging behind it.
      #
      # Bump this in lockstep with `reprobuild` below — read the new
      # reprobuild revision's own flake.lock and mirror its `runquota-src`.
      # `scripts/test-flake-pin-alignment.sh` (in `just test`) enforces the
      # equality so the two pins cannot silently diverge again.
      url = "github:metacraft-labs/runquota/f1ca742d19c7b981eeea0fba8b4e029207f43778";
      inputs.nixos-modules.follows = "nix-blockchain-development/nixos-modules";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.git-hooks.follows = "git-hooks-nix";
      flake = true;
    };

    reprobuild = {
      # PINNED to the exact revision that metacraft-labs/nixos-modules pins,
      # so every repo in the org builds the same `repro`. nixos-modules is the
      # single source of truth for this SHA — bump it there first, then mirror
      # the new SHA here.
      #
      # This mirrors the SHA rather than `follows`-ing nixos-modules' own
      # reprobuild node, because a bare `follows` replaces the whole input node
      # and would drop the six overrides below: reprobuild would then be built
      # against a different nixpkgs and against its own runquota /
      # native-recorder pins, producing a different `repro` binary than the one
      # this repo's shells are meant to ship.
      url = "github:metacraft-labs/reprobuild/2f124aebbc8a9e61e87de1aa13e15298a83f88c6";
      inputs.nixos-modules.follows = "nix-blockchain-development/nixos-modules";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.git-hooks.follows = "git-hooks-nix";
      inputs.runquota-src.follows = "runquota";
      # reprobuild's repro package needs ct_interpose (from the
      # native-recorder repo) to build; share CodeTracer's own
      # native-recorder input so a local sibling checkout is reused.
      inputs.codetracer-native-recorder.follows = "codetracer-native-recorder";
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
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/dev";
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
      url = "github:metacraft-labs/codetracer-trace-format-nim/dev";
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
