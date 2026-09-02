#!/usr/bin/env bash
# =============================================================================
# sibling-pins.sh — resolve the cross-repo build siblings to the EXACT commit
# SHAs this commit specifies, and verify that a checkout is actually at them.
#
# ## The defect this exists to close
#
# CodeTracer consumes three sibling repositories as build inputs of the
# browser-replay bundle — `codetracer-native-recorder` (ct_emulator's WASM C
# generator), `codetracer-trace-format-nim` (the Nim half of the FFI pair) and
# `codetracer-trace-format` (its matched Rust half). Every lane that CLONES
# them named a BRANCH:
#
#     siblings: |
#       codetracer-native-recorder=dev
#       codetracer-trace-format=dev
#       codetracer-trace-format-nim=dev
#
# A branch is not a pin. The same codetracer commit built on Monday and on
# Wednesday takes whatever `dev` pointed at each day, so the commit does not
# determine the artifact. `clone-siblings` already says so out loud —
#
#     ::warning:: sibling '<name>' is pinned by the explicit entry
#     '<name>=<ref>', not by the workspace lock, and '<ref>' is not a 40-hex
#     commit SHA. This build is therefore not reproducible for '<name>'
#
# — and its own remediation text names the two sanctioned fixes, in order:
# declare the sibling in the project manifest so the workspace lock pins it, or
# "name a revision explicitly with a '<name>=<40-hex sha>' entry in 'siblings'
# — a commit SHA, never a branch."
#
# The first fix is not available from inside this repository. It requires a
# workspace lock published to metacraft-labs/metacraft-manifests for the commit
# under test, and that pipeline is not currently delivering: `repro workspace
# lock` refuses on any dirty sibling (correctly — "a lock recorded over
# uncommitted changes would not reproduce the tree it claims"), and where
# `.repro/manifests` is not a git checkout the lock is generated and then
# silently dropped. `ci/verdict/workspace-lock-freshness.sh` is the alarm for
# that condition and `.github/workflows/publish-workspace-lock.yml` is the
# repair; neither is this script's business.
#
# ## Where the SHAs come from: flake.lock, which is already correct
#
# The second fix needs a per-commit, in-repo, SHA-level statement of what these
# three siblings are. That statement already exists and is already committed:
# `flake.lock`. The Nix lane consumes these three as flake inputs, so every one
# of them carries a `locked.rev`:
#
#     inputs.codetracer-trace-format.original = {ref = "dev"}       <- a branch
#     inputs.codetracer-trace-format.locked   = {rev = "392c5559…"} <- a commit
#
# `flake.nix` names a branch; `flake.lock` records the commit that branch
# resolved to, and `flake.lock` is tracked in git. So the commit ALREADY
# determines these three inputs for the Nix lane. It is only the lanes that
# clone the siblings that threw that away by re-reading the branch.
#
# This script is the bridge: it reads the revisions out of `flake.lock` and
# hands them to the clone step, so both lanes build the same three commits and
# both are determined by the codetracer commit alone.
#
# ## What this does NOT buy
#
# Input determinism, not bit-identical output. `ci/deploy/noir-wasm.pin`
# records the measured reason: building one revision twice from two different
# checkout DIRECTORIES gave 15862494 vs 15862541 bytes, because rustc embeds
# source paths and the length of the build directory reaches the artifact.
# Pinning inputs does not touch that and does not claim to. What it buys is
# that the QUESTION "what should this commit produce?" now has an answer.
#
# AND IT DOES NOT COVER THE TOOLCHAIN. `SIBLINGS` below is a list of three
# REPOSITORIES. The compilers that read them are not in it, and a PASS here is
# therefore not a statement that two builds will agree. There is a live,
# unclosed hypothesis that the Nim compiler is a fourth unpinned input: two
# builds that both claimed all three sources at their pins differed by 60,920
# bytes, and the two environments were observed running different Nim versions
# (`Nim 2.2.4` from `~/.nix-profile/bin/nim` against `nim-unwrapped-2.2.10`).
# If that is the cause, every check in this file passes over it, because the
# thing that differed is not a thing this file looks at.
#
# This is called out here, and again on the PASSED line, for one reason: the
# failure mode of a scoped guard is that its scope is forgotten and its green
# tick is read as "the build is reproducible". It does not mean that. It means
# the three named repositories are at the commits `flake.lock` specifies.
# Pinning the toolchain is separate work and is NOT done here.
#
# ## Modes
#
#   sibling-pins.sh                      -> `name=rev` lines, one per sibling
#   sibling-pins.sh --github-output      -> the same, as a `pins` step output
#   sibling-pins.sh --verify <dir>       -> assert <dir>/<name> is AT its pin
#
# `--verify` is the half that is not circular. Resolving a pin out of
# `flake.lock` and then comparing it to `flake.lock` proves nothing; comparing
# it to the tree the compiler actually read proves the build used what the
# commit specifies. It is counted, and the count is asserted: a run that
# checked nothing is a FAILURE, never a pass.
#
# Run: bash scripts/sibling-pins.sh
# Contract suite: ci/test/sibling-pins-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/flake.lock"

# The cross-repo build inputs of the browser-replay bundle. These are exactly
# the three siblings `.github/workflows/deploy-web-codetracer.yml` and
# `.github/actions/setup-db-backend-siblings/action.yml` clone, and exactly the
# three declared as non-flake inputs in `flake.nix` for the same reason:
# `src/db-backend/build.rs` and `codetracer_trace_writer_nim`'s build.rs
# resolve them by relative path. Adding a fourth here without adding it to the
# workflow (or the reverse) is caught by ci/test/sibling-pins-test.sh.
SIBLINGS=(
	codetracer-native-recorder
	codetracer-trace-format
	codetracer-trace-format-nim
)

die() {
	printf 'sibling-pins: %s\n' "$1" >&2
	exit 1
}

# Resolve every declared sibling to its `locked.rev` in one python3 call.
#
# The lookup goes through the ROOT INPUT NAME, not the node key. Those differ:
# `codetracer-trace-format` lives at node key `codetracer-trace-format_4`
# because several inputs pull in their own copy and nix disambiguates with a
# numeric suffix. Reading `nodes["codetracer-trace-format"]` finds a DIFFERENT
# repo's node or none at all, and the resulting wrong-or-empty rev would be
# indistinguishable from a correct one. Always go root.inputs[name] -> node.
#
# Failure to parse is reported as a parse failure and never as a statement
# about a pin. A guard that answers "flake.lock has no rev for X" when python3
# is simply absent sends the reader to edit the very pin it was protecting.
resolve_pins() {
	local out rc
	out="$(python3 -c '
import json, re, sys

path = sys.argv[1]
wanted = sys.argv[2:]
try:
    with open(path) as handle:
        data = json.load(handle)
    nodes = data["nodes"]
    root = nodes[data["root"]]["inputs"]
except Exception as exc:  # noqa: BLE001 - reported verbatim below
    print("PARSE-ERROR %s" % exc)
    raise SystemExit(0)

for name in wanted:
    key = root.get(name)
    if key is None:
        print("MISSING %s not-a-root-input" % name)
        continue
    if isinstance(key, list):
        key = key[0]
    locked = nodes.get(key, {}).get("locked", {})
    rev = locked.get("rev", "")
    if not re.fullmatch(r"[0-9a-f]{40}", rev or ""):
        print("MISSING %s no-40-hex-rev(%r)" % (name, rev))
        continue
    print("PIN %s %s" % (name, rev))
' "$LOCK" "${SIBLINGS[@]}" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || die "could not run python3 over '$LOCK' (exit $rc). This is a
  parse/tooling failure, NOT a statement about any pin — do not read it as
  'the sibling is unpinned'. Parser output:
$out"
	printf '%s\n' "$out"
}

collect() {
	[ -f "$LOCK" ] || die "flake.lock is missing at $LOCK; there is nothing to pin from."

	local raw line name rev
	raw="$(resolve_pins)"

	case "$raw" in
	PARSE-ERROR*) die "flake.lock at $LOCK did not parse as JSON: ${raw#PARSE-ERROR }" ;;
	esac

	PIN_NAMES=()
	PIN_REVS=()
	local problems=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
		"PIN "*)
			name="$(printf '%s' "$line" | cut -d' ' -f2)"
			rev="$(printf '%s' "$line" | cut -d' ' -f3)"
			PIN_NAMES+=("$name")
			PIN_REVS+=("$rev")
			;;
		"MISSING "*)
			problems="$problems
  - ${line#MISSING }"
			;;
		*)
			problems="$problems
  - unrecognised resolver output: $line"
			;;
		esac
	done <<<"$raw"

	if [ -n "$problems" ]; then
		die "flake.lock does not pin every declared build sibling to a commit:$problems

  Each of these must be a root input of flake.nix carrying a 40-hex locked.rev.
  If a sibling was renamed or dropped from flake.nix, update SIBLINGS in this
  script to match — do not leave the two disagreeing, because the clone step
  would then silently fall back to a branch tip for the one that vanished."
	fi

	# The vacuity guard. Every loop below is a universal quantification, and a
	# universal quantification over an empty set is TRUE. If SIBLINGS were ever
	# emptied — or the resolver's output shape drifted so nothing matched
	# `PIN ` — every check downstream would pass while pinning nothing at all.
	if [ "${#PIN_NAMES[@]}" -eq 0 ]; then
		die "resolved 0 sibling pins. Refusing to report success over an empty set:
  a build with no pins is not a pinned build, it is an unchecked one."
	fi
	if [ "${#PIN_NAMES[@]}" -ne "${#SIBLINGS[@]}" ]; then
		die "resolved ${#PIN_NAMES[@]} pin(s) but ${#SIBLINGS[@]} sibling(s) are declared."
	fi
}

# --- verify -----------------------------------------------------------------
#
# Assert that a directory holding sibling checkouts is at the pinned commits.
# This is the arm that compares the declaration against what was ACTUALLY
# built, so its failure modes are all hard failures:
#
#   * sibling directory absent      -> FAIL (never "nothing to check")
#   * not a git repository          -> FAIL
#   * HEAD != pin                   -> FAIL
#   * working tree dirty            -> FAIL (the tree is not any commit)
#
# The absent case matters most. An absent sibling reading as a skip is exactly
# how an unpinned build passes a pin check: the check reports on nothing and
# prints a green tick.
verify() {
	local dir="$1"
	[ -n "$dir" ] || die "--verify needs a directory holding the sibling checkouts."
	[ -d "$dir" ] || die "--verify was given '$dir', which is not a directory."
	dir="$(cd "$dir" && pwd)"

	collect

	local checked=0 failed=0 i name pin head dirty
	for i in "${!PIN_NAMES[@]}"; do
		name="${PIN_NAMES[$i]}"
		pin="${PIN_REVS[$i]}"
		checked=$((checked + 1))

		if [ ! -d "$dir/$name" ]; then
			failed=$((failed + 1))
			printf '  FAIL  %s: no checkout at %s\n' "$name" "$dir/$name" >&2
			printf '        The commit pins it at %s. A sibling that is not there was not\n' "$pin" >&2
			printf '        built from the pin; it was built from somewhere else or not at all.\n' >&2
			continue
		fi

		head="$(git -C "$dir/$name" rev-parse HEAD 2>/dev/null)"
		if [ -z "$head" ]; then
			failed=$((failed + 1))
			printf '  FAIL  %s: %s is not a git checkout, so its revision cannot be established\n' "$name" "$dir/$name" >&2
			continue
		fi

		if [ "$head" != "$pin" ]; then
			failed=$((failed + 1))
			printf '  FAIL  %s: built from %s, but this commit pins %s\n' "$name" "$head" "$pin" >&2
			printf '        The artifact does not correspond to this codetracer commit.\n' >&2
			continue
		fi

		dirty="$(git -C "$dir/$name" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
		if [ "$dirty" != "0" ]; then
			failed=$((failed + 1))
			printf '  FAIL  %s: at the pinned commit %s but with %s uncommitted change(s)\n' "$name" "$pin" "$dirty" >&2
			printf '        A dirty tree is not any commit, so the pin describes it no longer.\n' >&2
			continue
		fi

		printf '  ok    %s at %s\n' "$name" "$pin"
	done

	# Counted, and the count itself asserted. `failed -eq 0` alone is satisfied
	# by a run that checked nothing.
	if [ "$checked" -eq 0 ]; then
		printf 'RESULT: FAILED — verified 0 siblings; the check asserted nothing at all.\n' >&2
		exit 1
	fi
	if [ "$checked" -ne "${#SIBLINGS[@]}" ]; then
		printf 'RESULT: FAILED — verified %d sibling(s), but %d are declared.\n' \
			"$checked" "${#SIBLINGS[@]}" >&2
		exit 1
	fi
	if [ "$failed" -ne 0 ]; then
		printf 'RESULT: FAILED — %d of %d sibling(s) are not at the revision this commit pins.\n' \
			"$failed" "$checked" >&2
		exit 1
	fi
	printf 'RESULT: PASSED — all %d declared sibling(s) are at the revision this commit pins.\n' "$checked"
	# The scope, printed on every pass. See "What this does NOT buy" in the
	# header. A scoped guard whose scope is forgotten gets read as a
	# reproducibility claim, and this one is not one: it covers repositories,
	# not the compilers that read them.
	printf '        SCOPE: %d repositories, not the toolchain. This is NOT a claim that the\n' "$checked"
	printf '        build is reproducible — the Nim compiler is not pinned by this check and\n'
	printf '        is a live suspect in a 60,920-byte gap between two builds that both had\n'
	printf '        all three siblings at their pins.\n'
}

# --- entry point ------------------------------------------------------------

MODE=lines
VERIFY_DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
	--github-output)
		MODE=github
		shift
		;;
	--verify)
		MODE=verify
		VERIFY_DIR="${2:-}"
		shift 2 2>/dev/null || shift
		;;
	--list)
		MODE=list
		shift
		;;
	-h | --help)
		sed -n '2,90p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		die "unknown argument '$1'. Usage: sibling-pins.sh [--github-output | --verify <dir> | --list]"
		;;
	esac
done

case "$MODE" in
list)
	printf '%s\n' "${SIBLINGS[@]}"
	;;
verify)
	verify "$VERIFY_DIR"
	;;
lines)
	collect
	for i in "${!PIN_NAMES[@]}"; do
		printf '%s=%s\n' "${PIN_NAMES[$i]}" "${PIN_REVS[$i]}"
	done
	;;
github)
	collect
	[ -n "${GITHUB_OUTPUT:-}" ] || die "--github-output writes a step output, so it needs the
  GITHUB_OUTPUT environment variable set. It is unset here, which means this is
  not a GitHub Actions step — run without the flag to print the pins instead."
	{
		printf 'pins<<SIBLING_PINS_EOF\n'
		for i in "${!PIN_NAMES[@]}"; do
			printf '%s=%s\n' "${PIN_NAMES[$i]}" "${PIN_REVS[$i]}"
		done
		printf 'SIBLING_PINS_EOF\n'
	} >>"$GITHUB_OUTPUT"
	for i in "${!PIN_NAMES[@]}"; do
		printf 'pinned %s at %s\n' "${PIN_NAMES[$i]}" "${PIN_REVS[$i]}"
	done
	;;
esac
