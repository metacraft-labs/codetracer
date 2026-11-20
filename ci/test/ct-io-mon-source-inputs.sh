#!/usr/bin/env bash
#
# ct-io-mon-source-inputs.sh — fail, BY NAME, on any source directory io-mon's
# build reads that the `ct-io-mon` derivation does not hand it.
#
# `ct-io-mon` (nix/packages/default.nix) builds the `io-mon` binary and shim
# from the `io-mon` flake input with io-mon's own recipe. io-mon's
# `config.nims` finds each library it compiles against through a variable with
# a sibling-checkout default:
#
#     getEnv("SHM_GSET_SRC", "../nim-shm-gset/src")
#
# In the Nix sandbox there is no sibling, so a variable the derivation leaves
# unset is a path that does not exist and the build stops on
# `cannot open file: <module>`. That is how io-mon efe6dc5, which began
# declaring the binary's command line with clispec (`CLI_SPEC_SRC`,
# nim-cli-spec), would have broken the package at the next io-mon bump
# (reprobuild-pm issue
# 2026-11-19-codetracer-io-mon-builds-need-nim-cli-spec-from-io-mon-efe6dc5).
#
# THE RULE: for every `getEnv("<VAR>", "../<repo>/src")` in the io-mon
# checkout's `config.nims`, `ct-io-mon` sets `<VAR> = "${inputs.<repo>}/src";`
# and flake.nix declares the input `<repo>`. A `getEnv("<X>_SRC", …)` whose
# default has another shape fails the check rather than being passed over.
#
# NOT checked: that the revision an input is locked at is one io-mon builds
# against, and that the io-mon checkout read is at the revision `flake.lock`
# locks. This check answers "is every variable handed over", against the io-mon
# it is pointed at.
#
# Reads the REAL tree: nix/packages/default.nix and flake.nix at the repository
# root (or the files named by `PACKAGES_NIX` / `FLAKE_NIX`), and `config.nims`
# of the io-mon checkout named by the first argument, `IO_MON_REPO`, or the
# `../io-mon` sibling. A missing checkout is a failure, not a skip: nothing is
# known about the inputs then. python3 and nothing else; under a second.
#
# Run: bash ci/test/ct-io-mon-source-inputs.sh [io-mon checkout]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGES_NIX="${PACKAGES_NIX:-$REPO_ROOT/nix/packages/default.nix}"
FLAKE_NIX="${FLAKE_NIX:-$REPO_ROOT/flake.nix}"
IO_MON_CHECKOUT="${1:-${IO_MON_REPO:-$REPO_ROOT/../io-mon}}"

command -v python3 >/dev/null 2>&1 || {
	echo "FAIL: python3 is not on PATH; the inputs were not compared (nothing is" >&2
	echo "      known about them)" >&2
	exit 2
}

python3 - "$PACKAGES_NIX" "$FLAKE_NIX" "$IO_MON_CHECKOUT/config.nims" <<'PY'
import re
import sys

packages_path, flake_path, config_path = sys.argv[1:4]


def read(path, what):
    try:
        return open(path).read()
    except OSError as e:
        print(f"FAIL: {what} could not be read: {e}")
        sys.exit(2)


packages = read(packages_path, "the package set")
flake = read(flake_path, "flake.nix")
config = read(config_path, "io-mon's config.nims (name an io-mon checkout as "
              "the first argument or in IO_MON_REPO)")

wanted = re.findall(r'getEnv\(\s*"([A-Z][A-Z0-9_]*)"\s*,\s*"\.\./([^"/]+)/src"\s*\)', config)
all_src_vars = set(re.findall(r'getEnv\(\s*"([A-Z][A-Z0-9_]*_SRC)"', config))
unread = sorted(all_src_vars - {var for var, _ in wanted})
if unread:
    print(f"FAIL: {config_path} reads {', '.join(unread)} with a default that is "
          'not "../<repo>/src"; this check cannot tell which input supplies it')
    sys.exit(2)
if not wanted:
    print(f"FAIL: {config_path} resolves no library through a "
          'getEnv("<VAR>", "../<repo>/src") default; its shape changed and '
          "nothing was compared")
    sys.exit(2)

block = re.search(r'^( *)ct-io-mon = pkgs\.stdenv\.mkDerivation \{\n(.*?)^\1\};',
                  packages, re.S | re.M)
if not block:
    print(f"FAIL: {packages_path} has no `ct-io-mon = pkgs.stdenv.mkDerivation` block")
    sys.exit(2)
# Uncommented attribute lines only: a commented-out assignment sets nothing.
attrs = dict(re.findall(r'^\s*([A-Z][A-Z0-9_]*) = "\$\{inputs\.([A-Za-z0-9_-]+)\}/src";',
                        block.group(2), re.M))
uncommented_flake = "\n".join(l for l in flake.splitlines() if not l.lstrip().startswith("#"))

failures = []
for var, repo in wanted:
    have = attrs.get(var)
    if have is None:
        failures.append(f"{var}: io-mon's config.nims reads it (default ../{repo}/src) "
                        f"and ct-io-mon does not set it; add "
                        f'`{var} = "${{inputs.{repo}}}/src";` and the `{repo}` flake input')
        continue
    if have != repo:
        failures.append(f"{var}: ct-io-mon takes it from inputs.{have}, io-mon's "
                        f"config.nims from the {repo} repository")
        continue
    if not re.search(rf'^\s*{re.escape(repo)} = \{{', uncommented_flake, re.M):
        failures.append(f"{var}: ct-io-mon reads inputs.{repo}, which flake.nix does not declare")

if failures:
    for line in failures:
        print(f"FAIL: {line}")
    print(f"FAIL: {len(failures)} of {len(wanted)} source directories io-mon's build "
          "reads are not supplied by ct-io-mon")
    sys.exit(1)
print(f"ok: ct-io-mon supplies all {len(wanted)} source directories io-mon's "
      f"config.nims reads ({', '.join(v for v, _ in wanted)})")
PY
