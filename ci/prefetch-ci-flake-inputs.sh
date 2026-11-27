#!/usr/bin/env bash
# prefetch-ci-flake-inputs.sh -- fetch, while the job's GitHub token is still
# valid, every flake input the later steps of a long cross-repo job evaluate.
#
# WHY. A CI job's GitHub installation token expires one hour after it is
# minted, a job may mint only one (metacraft-dev-guidelines
# policies/ci-workflow-standards.md, "Two token-mint steps in one job"), and
# nix keeps presenting the dead token on every github.com fetch it has not
# cached, answered with `401 Bad credentials` for public repositories too. So
# every flake evaluation a later step makes is done HERE, near the top of the
# job, and lands in the store and nix's fetcher cache, from which the later
# evaluation of the same locked revisions is answered. The full history of
# the failures this prevents is in the header of the "Fetch every flake input
# later steps evaluate, while the token is valid" step of
# .github/workflows/launcher-recorder-e2e.yml, which this script follows.
# That workflow keeps its inline copy for now: it is taken from codetracer@dev
# but runs scripts from the codetracer checkout its callers PIN, and those pins
# predate this file, so calling it from there would break every launcher lane
# until each pin moves. Fold it into this script once they all carry it.
#
# What it fetches:
#   1. the nixpkgs revision repro provisions catalog tools from
#      (`CanonicalNixpkgsRev` / `CanonicalNixpkgsNarHash` in reprobuild's
#      libs/repro_dsl_stdlib/src/repro_dsl_stdlib/nixpkgs_pin.nim), read out of
#      codetracer's locked `reprobuild` flake input -- no dev shell evaluation
#      reaches it, and `repro exec` fetches it itself;
#   2. each named dev shell's derivation (evaluation only: nothing is built),
#      spelled `.?submodules=1#devShells.<system>.<shell>` with
#      `--no-write-lock-file`, as `nix develop` and repro's
#      `useFlakeDevShell()` spell it. A directory with no flake.nix is skipped.
#
# No credential is handled here: nix reads the token from the user-level
# nix.conf `setup-nix` wrote.
#
# Usage: prefetch-ci-flake-inputs.sh --ct-dir DIR [DIR:SHELL ...]
set -euo pipefail

ct_dir=""
targets=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--ct-dir)
		[ "$#" -ge 2 ] || { echo "prefetch-ci-flake-inputs: --ct-dir needs a directory" >&2; exit 2; }
		ct_dir="$2"
		shift 2
		;;
	*:*) targets+=("$1"); shift ;;
	*) echo "prefetch-ci-flake-inputs: unknown argument '$1' (want --ct-dir DIR and DIR:SHELL pairs)" >&2; exit 2 ;;
	esac
done
[ -d "$ct_dir" ] || { echo "prefetch-ci-flake-inputs: --ct-dir '$ct_dir' is not a directory" >&2; exit 2; }

PIN_FILE="libs/repro_dsl_stdlib/src/repro_dsl_stdlib/nixpkgs_pin.nim"
rb_node=""
if [ -f "${ct_dir}/flake.lock" ]; then
	rb_node="$(jq -r '.nodes.root.inputs.reprobuild // "" | if type == "string" then . else "" end' "${ct_dir}/flake.lock")"
fi
if [ -z "${rb_node}" ]; then
	echo "no direct reprobuild input in ${ct_dir}/flake.lock (repro's tool-provisioning nixpkgs is not this flake's to name)"
else
	rb_ref="$(jq -r --arg n "${rb_node}" '.nodes[$n].locked | if .type == "github" then "github:\(.owner)/\(.repo)/\(.rev)?narHash=\(.narHash | @uri)" else "" end' "${ct_dir}/flake.lock")"
	if [ -z "${rb_ref}" ]; then
		echo "::error::codetracer's reprobuild flake input is not a locked github input, so this step cannot read the nixpkgs revision repro provisions tools from. Teach ci/prefetch-ci-flake-inputs.sh the input's type; skipping it would leave that fetch to after the token expires."
		exit 1
	fi
	if ! rb_json="$(nix flake prefetch --json "${rb_ref}")"; then
		echo "::error::could not fetch ${rb_ref} (codetracer's reprobuild input, which names the nixpkgs repro provisions tools from) while this job's GitHub token is still valid; nix's own diagnostic is above this line."
		exit 1
	fi
	rb_src="$(jq -r '.storePath // ""' <<<"${rb_json}" 2>/dev/null || true)"
	pin="${rb_src}/${PIN_FILE}"
	np_rev=""
	np_nar=""
	if [ -n "${rb_src}" ] && [ -f "${pin}" ]; then
		np_rev="$(sed -n -E 's|^[[:space:]]*CanonicalNixpkgsRev\*?[[:space:]]*=[[:space:]]*"([0-9a-f]{40})".*|\1|p' "${pin}")"
		np_nar="$(sed -n -E 's|^[[:space:]]*CanonicalNixpkgsNarHash\*?[[:space:]]*=[[:space:]]*"(sha256-[A-Za-z0-9+/=]+)".*|\1|p' "${pin}")"
	fi
	if [ -z "${np_rev}" ] || [ -z "${np_nar}" ]; then
		echo "::error::could not read CanonicalNixpkgsRev / CanonicalNixpkgsNarHash from ${PIN_FILE} in ${rb_ref}. That pair names the nixpkgs repro realizes every catalog tool from; it must be fetched while the token is valid. If reprobuild moved or renamed it, update ci/prefetch-ci-flake-inputs.sh."
		exit 1
	fi
	np_nar_q="${np_nar//+/%2B}"
	np_nar_q="${np_nar_q//\//%2F}"
	np_nar_q="${np_nar_q//=/%3D}"
	np_ref="github:NixOS/nixpkgs/${np_rev}?narHash=${np_nar_q}"
	started="${SECONDS}"
	if ! nix flake prefetch "${np_ref}" >/dev/null; then
		echo "::error::could not fetch ${np_ref} (the nixpkgs repro provisions tools from) while this job's GitHub token is still valid; nix's own diagnostic is above this line."
		exit 1
	fi
	echo "fetched: ${np_ref} (repro tool provisioning; ${rb_ref}) ($((SECONDS - started))s)"
fi

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
for t in ${targets[@]+"${targets[@]}"}; do
	dir="${t%:*}"
	shell="${t##*:}"
	attr="devShells.${SYSTEM}.${shell}"
	if [ ! -f "${dir}/flake.nix" ]; then
		echo "no flake.nix in ${dir} (nothing a later step evaluates there)"
		continue
	fi
	started="${SECONDS}"
	if ! (cd "${dir}" && nix eval --raw --no-write-lock-file ".?submodules=1#${attr}.drvPath" >/dev/null); then
		echo "::error::could not evaluate ${attr} of ${dir} while this job's GitHub token is still valid; nix's own diagnostic is above this line and names the input. A later step evaluates exactly this, after the token has expired. An 'HTTP error 401' or '404' here means the CI Token Provider installation cannot read that input's repository."
		exit 1
	fi
	echo "fetched: ${dir} #${attr} ($((SECONDS - started))s)"
done
