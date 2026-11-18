#!/usr/bin/env bash
# wtype-keys-guard-test.sh — every capture lane types through
# ci/test/wtype-keys.sh, never `wtype` directly.
#
# A direct `wtype` call can lose its first key without a trace (the helper's
# header has the measurements), and a lane that forgets the priming fails as
# "the window never saw the key", which reads as a product defect. This guard
# reads the lanes' code lines (comments left out) for a `wtype` command and
# names each one.
#
# Its control runs first: a scratch lane that calls `wtype` directly must be
# refused, and one that calls the helper must not, so a guard that matches
# nothing cannot pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The code lines of <file> that run `wtype` itself: in a shell line `wtype`
# followed by an argument, or handed to `xargs`; in Python, `"wtype"` as a
# command list's first element. Prerequisite checks (`command -v wtype`, a
# `for tool in ... wtype ...` list, `("grim", "wtype")`) do not run it.
direct_calls() {
	local file="$1"
	case "${file}" in
	*.py)
		grep -n -E '^[^#]*\[[[:space:]]*["'"'"']wtype["'"'"'][[:space:]]*,' "${file}" || true
		;;
	*)
		grep -n -E '^[^#]*(^|[[:space:];&|(`"'"'"'=])wtype[[:space:]]+[^[:space:]]' "${file}" |
			grep -v -E 'command -v|for tool in|wtype-keys\.sh' || true
		;;
	esac
}

scan() {
	local found=0 file hits
	for file in "$@"; do
		[ "$(basename "${file}")" = "wtype-keys.sh" ] && continue
		[ "$(basename "${file}")" = "wtype-keys-guard-test.sh" ] && continue
		hits="$(direct_calls "${file}")"
		if [ -n "${hits}" ]; then
			found=1
			while IFS= read -r line; do
				echo "  ${file#"${root}/"}:${line}"
			done <<<"${hits}"
		fi
	done
	return "${found}"
}

# The control.
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
printf 'bash -c "sleep 1; wtype -k F12"\n' >"${scratch}/direct.sh"
printf 'subprocess.run(["wtype", "-k", "F12"])\n' >"${scratch}/direct.py"
printf '# wtype x in a comment\nfor tool in sway wtype grim; do command -v wtype; done\n' >"${scratch}/checks.sh"
printf 'bash -c "sleep 1; bash ci/test/wtype-keys.sh -k F12"\n' >"${scratch}/helper.sh"
for f in direct.sh direct.py; do
	if scan "${scratch}/${f}" >/dev/null; then
		echo "FAIL: the guard did not refuse a direct wtype call (${f})"
		exit 1
	fi
done
for f in checks.sh helper.sh; do
	if ! scan "${scratch}/${f}" >/dev/null; then
		echo "FAIL: the guard refused a line that does not run wtype (${f})"
		exit 1
	fi
done

shopt -s nullglob
lanes=("${root}"/ci/test/*.sh "${root}"/ci/test/*.py)
if ! report="$(scan "${lanes[@]}")"; then
	echo "FAIL: these lanes call wtype directly; type through ci/test/wtype-keys.sh:"
	echo "${report}"
	exit 1
fi
echo "wtype-keys-guard: every lane types through ci/test/wtype-keys.sh (${#lanes[@]} files read)"
