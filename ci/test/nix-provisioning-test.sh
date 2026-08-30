#!/usr/bin/env bash
# =============================================================================
# Contract: a job that runs `nix` installs Nix first.
#
# # The defect
#
# `push-gpg-public-key` and `push-install-script` go straight from
# `actions/checkout` to
#
#     nix develop .#devShells.x86_64-linux.default --command aws ... s3 cp ...
#
# with no Nix-provisioning step in between. Every other nix job in this
# repository has one -- `./.github/actions/setup-nix`, or a `setup-dev-env`
# with `env-flavor: nix`, or one of the composites that wraps it. Those two do
# not, so they use whatever `nix` the runner image happens to have, configured
# however the image happens to configure it. On `eph-linux-x64` that
# configuration does not enable the experimental features `nix develop` needs:
#
#     error: experimental Nix feature 'nix-command' is disabled;
#     add '--extra-experimental-features nix-command' to enable it
#     ##[error]Process completed with exit code 1.
#
# Both jobs have failed this way in every one of the last twelve completed
# `dev` runs. It reads as a runner defect and is not one: `setup-nix` writes
# the experimental-features line (along with the Attic substituter and its
# public key), and these two jobs never call it.
#
# The fix is one step each. This contract is what stops the next
# nix-using job from being written without it -- the omission is invisible in
# review precisely because `nix develop` looks self-contained.
#
# # What is asserted
#
#   1. Every workflow job that invokes `nix` in a `run:` step has a
#      Nix-provisioning step earlier in the SAME job.
#   2. The scanner still finds the jobs it scans for (an exact count), so a
#      rewording that stops it matching is a failure rather than a vacuous pass.
#
# # Scope
#
# `run:` steps only, and only `nix` as the first word of a command. A composite
# action that runs nix is provisioned by its caller, which assertion 1 covers
# from the caller's side.
#
# # No mocks
#
# `.github/workflows/*.yml` as committed is the input.
#
# Run: bash ci/test/nix-provisioning-test.sh
# Lane: a step of `lint-bash` (pure bash, no nix, no network).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
WORKFLOW_DIR="${1:-$REPO_ROOT/.github/workflows}"
readonly WORKFLOW_DIR

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

echo "every job that runs nix installs Nix first"

# The step spellings that leave a configured Nix behind. `setup-nix` is the
# direct one; `setup-dev-env` installs Nix when its `env-flavor` is `nix`, and
# the two local composites are thin wrappers over it. `nix-installer-action` is
# what all of them ultimately call, named here so a job that calls it directly
# is not reported.
is_provisioning_step() { # $1 = a stripped YAML line
	case "$1" in
	*'.github/actions/setup-nix'*) return 0 ;;
	# What `.github/actions/setup-nix` wraps, and the OTHER upstream action
	# beside it: `push-tag` and `create-release` call `install-nix@main`
	# directly. Leaving this spelling out made the scanner report
	# `create-release` as unprovisioned when it was not -- a false positive
	# that nearly had a redundant second Install Nix step committed to it.
	*'nixos-modules/.github/setup-nix'*) return 0 ;;
	*'nixos-modules/.github/install-nix'*) return 0 ;;
	*'metacraft-github-actions/setup-dev-env'*) return 0 ;;
	*'.github/actions/setup-db-backend-siblings'*) return 0 ;;
	*'.github/actions/setup-isonim-siblings'*) return 0 ;;
	*'DeterminateSystems/nix-installer-action'*) return 0 ;;
	esac
	return 1
}

nix_jobs=()
unprovisioned=()

for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
	[ -f "$wf" ] || continue
	wf_name="${wf##*/}"
	job=""
	provisioned=0
	job_reported=""
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		# YAML comments quote both `nix develop ...` and the action names
		# below all over this repository. Prose provisions nothing and
		# invokes nothing.
		case "$stripped" in '#'*) continue ;; esac

		# Job boundaries are two-space-indented keys under `jobs:`; anything
		# deeper belongs to the job above.
		case "$line" in
		'  '[a-zA-Z0-9_-]*':'*)
			case "$line" in
			'   '*) ;;
			*)
				job="${line#  }"
				job="${job%%:*}"
				provisioned=0
				job_reported=""
				;;
			esac
			;;
		esac

		if is_provisioning_step "$stripped"; then
			provisioned=1
			continue
		fi

		# A `nix` invocation: `nix` as the first word, either as the whole of
		# a `run:` value or as a line of a `run: |` block.
		case "$stripped" in
		'run: nix '* | 'nix '*)
			# Only the subcommands that need the experimental features.
			case "$stripped" in
			*'nix develop'* | *'nix build'* | *'nix eval'* | *'nix run'* | *'nix shell'* | *'nix flake'* | *'nix profile'*) ;;
			*) continue ;;
			esac
			case " ${nix_jobs[*]-} " in
			*" $wf_name:$job "*) ;;
			*) nix_jobs+=("$wf_name:$job") ;;
			esac
			if [ "$provisioned" -eq 0 ] && [ "$job_reported" != "$job" ]; then
				job_reported="$job"
				unprovisioned+=("$wf_name:$line_no: job '$job' runs nix with no Nix-provisioning step before it")
			fi
			;;
		esac
	done <"$wf"
done

# The number of jobs this scanner is expected to classify as nix-using. Exact,
# in the same spirit as EXPECTED_BUILD_SITES in
# ci/test/sibling-provisioning-test.sh: "no unprovisioned job was found" is
# also true of a scanner that has stopped finding jobs at all.
# 30 -> 31: dev-build gained a multi-line `nix develop ... -c direnv allow`
# step (its native-recorder setup). Its pre-existing build step spelled nix as
# a single-line quoted `- run: "nix develop ..."`, which this scanner does not
# match, so dev-build only now classifies as nix-using. It provisions Nix
# (Install Nix + setup-db-backend-siblings), so the "provisions first" rule holds.
readonly EXPECTED_NIX_JOBS=31

if [ "${#nix_jobs[@]}" -eq "$EXPECTED_NIX_JOBS" ]; then
	ok "the scanner still classifies the nix-using jobs (${#nix_jobs[@]})"
else
	fail "the scanner still classifies the nix-using jobs" \
		"expected $EXPECTED_NIX_JOBS nix-using job(s), found ${#nix_jobs[@]}." \
		"If a job was added or removed, confirm the new one provisions Nix and update" \
		"EXPECTED_NIX_JOBS. If neither, this scanner has stopped matching what it scans." \
		"found: ${nix_jobs[*]-<none>}"
fi

if [ "${#unprovisioned[@]}" -eq 0 ]; then
	ok "every nix-using job provisions Nix first"
else
	fail "every nix-using job provisions Nix first" \
		"Without it the job uses whatever nix the runner image ships, configured" \
		"however that image configures it -- on eph-linux-x64 that means" \
		"\"error: experimental Nix feature 'nix-command' is disabled\"." \
		"${unprovisioned[@]}"
fi

echo
readonly EXPECTED_ASSERTIONS=2
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
