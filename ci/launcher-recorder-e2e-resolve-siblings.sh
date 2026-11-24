#!/usr/bin/env bash
# launcher-recorder-e2e-resolve-siblings.sh -- classify the launcher <-> recorder
# E2E gate's siblings by where codetracer pins each one, at the codetracer
# checkout the gate builds.
#
# Every repository a codetracer CI job clones is pinned by codetracer
# (codetracer-specs Testing/Cross-Repo-CI-Integration.md, "Where sibling pins
# live"; reprobuild-pm Unified-Locking-And-Hooks.md §14):
#
#   PRIVATE  a repository the public locks cannot name has ONE home for its
#            revision: flake.lock's locked.rev when it is a root flake input,
#            otherwise ci/toolchain.pin's PRIVATE_SIBLING_<NAME>. Emitted as
#            `<name>=<rev>` for clone-siblings.
#   BUILD    a solved member of repro.lock's develop set.
#            provision-repro-lock-siblings clones every one of them; nothing to
#            emit.
#   TEST     a member of the test lock, ci/test/siblings/repro.lock. Emitted by
#            name for provision-repro-lock-siblings' `test-siblings`.
#
# A planned name in none of them is an ERROR, by name: the gate would clone it
# at no recorded revision. ci/test/launcher-recorder-e2e-workflow-test.sh drives
# that negative control.
#
# Usage: launcher-recorder-e2e-resolve-siblings.sh --ct-dir DIR --self NAME
#          --planned "NEWLINE-SEPARATED NAMES" [--out GITHUB_OUTPUT_FILE]
# Without --out it prints `private=...` and `test-siblings=...` to stdout.
set -euo pipefail

ct_dir="" self="" planned="" out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--ct-dir) ct_dir="$2"; shift 2 ;;
	--self) self="$2"; shift 2 ;;
	--planned) planned="$2"; shift 2 ;;
	--out) out="$2"; shift 2 ;;
	*) echo "launcher-recorder-e2e-resolve-siblings: unknown argument '$1'" >&2; exit 2 ;;
	esac
done
[ -d "$ct_dir" ] || { echo "launcher-recorder-e2e-resolve-siblings: --ct-dir '$ct_dir' is not a directory" >&2; exit 2; }
[ -n "$self" ] || { echo "launcher-recorder-e2e-resolve-siblings: --self is required" >&2; exit 2; }

flake_rev() { # $1 = root input name -> locked.rev, or '' when not a root input
	local lock="$ct_dir/flake.lock"
	[ -f "$lock" ] || return 0
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg name "$1" '
			. as $l
			| def node_of($r):
				if ($r | type) == "string" then $r
				else reduce $r[] as $i ($l.root; node_of($l.nodes[.].inputs[$i])) end;
			($l.nodes[$l.root].inputs[$name] // empty) as $r
			| $l.nodes[node_of($r)].locked.rev // empty' "$lock"
	elif command -v python3 >/dev/null 2>&1; then
		python3 -I - "$lock" "$1" <<'PY'
import json, sys
l = json.load(open(sys.argv[1]))
def node_of(r):
    if isinstance(r, str):
        return r
    n = l["root"]
    for i in r:
        n = node_of(l["nodes"][n]["inputs"][i])
    return n
r = l["nodes"][l["root"]].get("inputs", {}).get(sys.argv[2])
if r is not None:
    print(l["nodes"][node_of(r)].get("locked", {}).get("rev", ""))
PY
	else
		echo "launcher-recorder-e2e-resolve-siblings: neither jq nor python3 is available to read flake.lock" >&2
		return 1
	fi
}

pin_rev() { # $1 = name -> ci/toolchain.pin PRIVATE_SIBLING_<NAME>, or ''
	local key="${1//-/_}" line
	key="PRIVATE_SIBLING_${key^^}"
	[ -f "$ct_dir/ci/toolchain.pin" ] || return 0
	while IFS= read -r line; do
		if [[ "$line" =~ ^${key}=([0-9a-f]{40})$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
	done <"$ct_dir/ci/toolchain.pin"
	return 0
}

lock_names() { # $1 = a repro.lock -> its vcs deps names, one per line
	[ -f "$1" ] || return 0
	grep -o '{ name = "[^"]*", \(self = "true", \|path = "[^"]*", \)\?coord_kind = "vcs"' "$1" |
		sed 's/{ name = "//; s/".*//'
}

build_inputs=",$(bash "$ct_dir/ci/repro-lock-build-input-siblings.sh" "$ct_dir/repro.lock"),"
test_lock=",$(lock_names "$ct_dir/ci/test/siblings/repro.lock" | paste -sd, -),"

# The planner names the gate's corners; `just build-once` additionally reads
# every REQUIRED row of scripts/require-siblings.sh by relative path. Build
# inputs among them are cloned by provisioning anyway; the rest (a private
# sibling such as codetracer-native-recorder, which db-backend links) must be
# resolved here too, or the core build dies on a missing checkout.
required=""
if [ -f "$ct_dir/scripts/require-siblings.sh" ]; then
	required="$(sed -n '/^required_siblings=(/,/^)/p' "$ct_dir/scripts/require-siblings.sh" |
		grep -oE "^[[:space:]]*['\"][A-Za-z0-9._-]+\|" | tr -d "'\"| \t")"
fi
planned="$(printf '%s\n%s\n' "$planned" "$required" | awk 'NF && !seen[$0]++')"

private=() tests=() errors=()
while IFS= read -r name; do
	name="${name//[[:space:]]/}"
	[ -n "$name" ] || continue
	[ "$name" != codetracer ] || continue
	[ "$name" != "$self" ] || continue
	# Public first: a repository the locks pin is cloned from the lock even
	# when it is ALSO a flake input (codetracer-trace-format-nim, the public
	# recorders); the one-home rule is for the repositories the public locks
	# cannot name.
	if [[ "$build_inputs" == *",$name,"* ]]; then
		echo "  build    $name (repro.lock)" >&2
		continue
	fi
	if [[ "$test_lock" == *",$name,"* ]]; then
		tests+=("$name")
		echo "  test     $name (ci/test/siblings/repro.lock)" >&2
		continue
	fi
	rev="$(flake_rev "$name")"
	[ -n "$rev" ] || rev="$(pin_rev "$name")"
	if [ -z "$rev" ]; then
		errors+=("$name: no lock and no home pins it (not a repro.lock build input, not in ci/test/siblings/repro.lock, no flake.lock root input, no ci/toolchain.pin PRIVATE_SIBLING_*)")
	elif ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
		errors+=("$name: its home records '$rev', not a 40-hex revision")
	else
		private+=("$name=$rev")
		echo "  private  $name=$rev" >&2
	fi
done <<<"$planned"

if [ "${#errors[@]}" -gt 0 ]; then
	for e in "${errors[@]}"; do echo "::error::launcher-recorder-e2e: gate sibling $e. Declare it in codetracer's repro.nim, or in ci/test/siblings/repro.nim (with a minimal recipe if it has none), or give a private repository its one home; do not pin it in the workflow." >&2; done
	exit 1
fi

# The calling repo is checked out at the commit under test, not at the
# revision codetracer's lock pins for it. When it is one of codetracer's build
# inputs, build-once must be told that this one sibling is off-lock on purpose.
off_lock=""
if [[ "$build_inputs" == *",$self,"* ]]; then
	off_lock="$self"
fi

emit() {
	printf 'off-lock=%s\n' "$off_lock"
	printf 'private<<LRC_PRIVATE_EOF\n'
	[ "${#private[@]}" -eq 0 ] || printf '%s\n' "${private[@]}"
	printf 'LRC_PRIVATE_EOF\n'
	(IFS=','; printf 'test-siblings=%s\n' "${tests[*]}")
}
if [ -n "$out" ]; then emit >>"$out"; else emit; fi
