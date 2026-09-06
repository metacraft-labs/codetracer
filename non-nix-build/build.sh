#!/usr/bin/env bash
# shellcheck source=/dev/null
# shellcheck disable=SC2154  # platform and os are defined in env.sh

set -e

NON_NIX_BUILD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$NON_NIX_BUILD_DIR"

# NAMED BY PATH, NOT BY BASENAME. `source env.sh` — no slash — does not mean
# "the env.sh next to me". Bash searches `$PATH` for a slash-less source
# argument and only falls back to the current directory if PATH has no match,
# so any directory on PATH holding an `env.sh` wins over this one. There are
# also two files by this name in this repository (`./env.sh` is the Windows DIY
# toolchain bootstrap; this one is the POSIX platform env) and both assign
# `ROOT_DIR`, so the wrong answer is a real file that sets real variables and
# the shell reports nothing.
source "$NON_NIX_BUILD_DIR/env.sh"

echo "platform: ${platform}; os: ${os}"

# passing platform and os as args, not env var, to make it easier
# to pass in nix-shell without modifying env
case $platform in
'linux')
	# TODO install main deps: electron/etc
	./install_rust.sh
	./build_in_simple_env.sh "$platform" "$os"
	;;
'mac')
	export MACOSX_DEPLOYMENT_TARGET=12.0
	./build_in_simple_env.sh "$platform" "$os"
	./build_mac_app.sh
	echo Successfully built non-nix-build/CodeTracer.app
	./build_dmg.sh
	echo Successfully built non-nix-build/CodeTracer.dmg
	;;
*)
	echo "unsupported platform"
	exit 1
	;;
esac
