# Lint dev shell — the four `ci/lint/*.sh` stages, and nothing else.
#
# ## WHY THIS EXISTS
#
# The whole `lint-*` stage was dying inside `nix develop`, before a single lint
# ran, for an unknown period:
#
#     error: Failed to fetch git repository https://github.com/anza-xyz/crossbeam
#     fatal: could not read Username for 'https://github.com'
#
# `anza-xyz/crossbeam`, `MystenLabs/mysten-sim` and `mystenlabs/tidehunter` are
# transitive Cargo git dependencies of Sui and Solana, reached through
# `nix-blockchain-development` when `devShells.default`'s `nativeBuildInputs`
# are evaluated. To run **bash, shellcheck, python3, node and nimsuggest**, the
# lint jobs were fetching the Cargo git closure of two blockchains.
#
# ## WHY IT IS THE RIGHT FIX EVEN THOUGH THE CAUSE IS NOT SETTLED
#
# Five explanations were proposed for that failure and four are dead by
# measurement (checkout's global extraheader — written under a temporary HOME;
# nix `access-tokens` — not applied to plain https git fetches; a rev that no
# longer exists — different error; GitHub metering anonymous git universally —
# a git-shaped anonymous probe returns 200). What survives is a THRESHOLD: the
# failure is intermittent, and the repository it dies on MOVES between runs, so
# it is not attached to any repository.
#
# A shell that does not fetch dozens of third-party repositories is immune to a
# threshold if one exists, and is faster, more reproducible and not exposed to
# whatever the real cause is if one does not. THAT IS THE POINT: this fix does
# not depend on winning the argument about the cause.
#
# ## WHAT IS IN IT, AND HOW THE LIST WAS DERIVED
#
# By reading what the lint scripts INVOKE, not what they mention. A name in a
# comment is not a wire — `ci/lint/bash.sh` names `cargo`, `nim` and `node` in
# prose while invoking none of them at the top level. The set below is every
# command in command position across `ci/lint/bash.sh`, `ci/lint/nim.sh`,
# `ci/lib/lint-steps.sh` and every script those two run:
#
#     git (65)  awk (9)  node (7)  diff (6)  python3 (4)  nimsuggest (2)
#     timeout (1)  sha256sum (1)  plus shellcheck and bash themselves
#
# and NOT `nix`, `jq`, `yq` or `cargo`, which appear nowhere in command
# position in that set.
#
# ## WHAT THIS SHELL DELIBERATELY DOES NOT SERVE
#
# `ci/lint/rust.sh` needs the Rust toolchain, clippy, and a Nim compiler to
# generate the emulator's C sources; `ci/lint/nix.sh` runs `nix flake check`,
# which evaluates the flake's outputs by definition and would reach the same
# closure from inside no matter which shell launched it. Those two keep
# `devShells.default` and need their own answer. Claiming this shell serves all
# four would be the "capability that looks present" defect this campaign exists
# to remove.
#
# ## `pkgs` ONLY, AND THAT IS THE LOAD-BEARING PART
#
# This file takes `pkgs` and nothing else — no `self'`, no `inputs'`. Nix is
# lazy, so an attribute never referenced is never forced; taking the flake's
# own package set or a sibling flake's outputs here would drag exactly the
# evaluation this shell exists to avoid back in, silently, and the shell would
# still "work" while being slow and exposed again. If a future edit needs
# something from `self'`, that is a signal to put it in another shell rather
# than to widen this one.
{ pkgs }:
pkgs.mkShell {
  # `hardeningDisable` matches the other shells so a script cannot behave
  # differently here for reasons unrelated to its tools.
  hardeningDisable = [ "all" ];

  packages = with pkgs; [
    # The two the lint stages are *about*.
    bash
    shellcheck

    # Interpreters the contract suites run under.
    python3
    nodejs

    # `ci/test/nimsuggest-check.sh`. `nim` brings `nimsuggest` with it; this is
    # plain nixpkgs Nim rather than the pinned codetracer toolchain, because
    # the check is "does nimsuggest start", not "does it agree with the
    # product's compiler" — and the toolchain input is one of the heavy ones.
    nim

    # Everything else the scripts call, named individually rather than pulled
    # in as a blanket `coreutils`-plus-hope. `gnugrep`/`gnused`/`gawk` are
    # explicit because the scripts are written against GNU behaviour and a
    # BSD `sed` on a macOS runner is a different program.
    coreutils # sha256sum, timeout, comm, sort, cut, wc, base64, readlink
    diffutils # diff
    gawk
    gnugrep
    gnused
    findutils
    git
  ];

  shellHook = ''
    # NAMED, so a `nix develop .#lint` that is not this shell is obvious in a
    # log. The lint scripts also assert their tools themselves — see
    # ci/lint/require-tools.sh — because a shell being present is not the same
    # as a shell being complete.
    export CT_LINT_SHELL=1
  '';
}
