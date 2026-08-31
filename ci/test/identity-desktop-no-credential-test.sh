#!/usr/bin/env bash
#
# identity-desktop-no-credential-test.sh — the mutation proof for
# ci/test/identity-desktop-no-credential.sh.
#
# That gate scans the working tree, so its arms must mutate the tree rather
# than a copy. Each one edits exactly one file (or adds exactly one), runs the
# gate, requires THE MESSAGE WRITTEN FOR THAT ARM, and restores.
#
# Restores come from a byte copy taken here, never from `git checkout --`: this
# repo installs a post-checkout hook that "repairs" worktree hooks as a side
# effect, and a test run must not mutate git state. The trap restores on
# interrupt, and the final check asserts the tree came back clean — an arm that
# left a planted credential behind would be worse than a failing gate.
#
# Usage:  bash ci/test/identity-desktop-no-credential-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

GATE="ci/test/identity-desktop-no-credential.sh"
SIGNIN="src/ct/online_sharing/authenticate.nim"
TOKEN="src/frontend/viewmodel/identity/token.nim"
PLANTED="src/ct/planted_unclassified_surface.nim"

work="$(mktemp -d)"
arms=0
misses=0

note() { printf '  %s\n' "$*"; }
pass() {
	arms=$((arms + 1))
	printf '  [KILL]   %s\n' "$*"
}
miss() {
	arms=$((arms + 1))
	misses=$((misses + 1))
	printf '  [MISS]   %s\n' "$*"
}

restore_all() {
	[ -f "${work}/signin.orig" ] && cp "${work}/signin.orig" "${SIGNIN}" 2>/dev/null
	[ -f "${work}/token.orig" ] && cp "${work}/token.orig" "${TOKEN}" 2>/dev/null
	rm -f "${PLANTED}"
	return 0
}
cleanup() {
	restore_all
	rm -rf "${work}"
}
trap cleanup EXIT INT TERM

[ -f "${GATE}" ] || {
	echo "${GATE} does not exist" >&2
	exit 2
}
cp "${SIGNIN}" "${work}/signin.orig"
cp "${TOKEN}" "${work}/token.orig"

run_gate() {
	bash "${GATE}" >"${work}/out" 2>&1
	printf '%s' "$?"
}

# expect_red LABEL NEEDLE
expect_red() {
	local label="$1" needle="$2" rc="$3"
	if [ "${rc}" = "0" ]; then
		miss "${label}: the gate still passed; the mutation SURVIVED"
	elif [ "${rc}" != "1" ]; then
		miss "${label}: the gate exited ${rc} rather than failing"
	elif grep -qF "${needle}" "${work}/out"; then
		pass "${label}"
	else
		miss "${label}: the gate failed, but not on its own assertion — wanted \"${needle}\""
		note "    a kill by a different check is a MISS. What went red:"
		grep '\[FAILED\]' "${work}/out" | sed 's/^/    /' | head -4
	fi
	restore_all
}

echo "=== mutation proof for ${GATE} ==="
echo

# ---------------------------------------------------------------------------
echo "Control arm: the unmutated tree"
# ---------------------------------------------------------------------------
rc="$(run_gate)"
arms=$((arms + 1))
if [ "${rc}" = "0" ] && grep -q "RESULT: OK" "${work}/out"; then
	n="$(grep -oE '^[0-9]+ check\(s\)' "${work}/out" | grep -oE '^[0-9]+')"
	printf '  [OK]     control: the gate passes, %s checks\n' "${n}"
	if [ "${n}" != "10" ]; then
		misses=$((misses + 1))
		printf '  [MISS]   control: expected 10 checks, saw %s — an assertion appeared or vanished\n' "${n}"
	fi
else
	misses=$((misses + 1))
	printf '  [MISS]   control: the gate does not pass over the unmutated tree (rc %s)\n' "${rc}"
	grep '\[FAILED\]' "${work}/out" | sed 's/^/    /'
fi
echo

# ---------------------------------------------------------------------------
echo "Mutation arms"
# ---------------------------------------------------------------------------

# D1: the sign-in path starts collecting a password. This is the defect the
# whole verification exists for — the embedded-credential flow §5 warns about.
{
	cat "${work}/signin.orig"
	printf '\nproc collectPassword*(): string =\n  readPasswordFromStdin("CodeTracer password: ")\n'
} >"${SIGNIN}"
expect_red "D1 the sign-in path collects a password" \
	"the sign-in path collects a credential" "$(run_gate)"

# D2: a credential surface nobody classified. The gate must refuse to guess.
cat >"${PLANTED}" <<'EOF'
const someSecret* = "a credential surface nobody classified"
EOF
expect_red "D2 an unclassified credential surface appears" \
	"unclassified credential surface" "$(run_gate)"

# D3: the gate is pointed at a file that is no longer the sign-in path. Without
# step 1, every zero in step 2 would still be reported as a pass.
#
# The rename must not CONTAIN the marker. Written first as
# `desktop-cli-token` -> `desktop-cli-tokenXX`, this arm survived, and it
# deserved to: the gate greps for a substring, and the substring was still
# there. The mutation had not expressed the defect.
sed 's/desktop-cli-token/desktop-web-handle/g' "${work}/signin.orig" >"${SIGNIN}"
expect_red "D3 the sign-in path loses a loopback marker" \
	"this gate is reading the wrong file" "$(run_gate)"

# D4: the identity layer grows a credential field. The token IS the credential;
# a module that also collects one has stopped verifying and started accepting.
#
# THIS ARM FOUND A REAL DEFECT IN THE GATE. `cachedPassword` is camelCase, and
# the gate's scanner was case-sensitive, so it walked past it — along with 9
# other files across the tree, 41 found of 50 that exist. The gate was made
# case-insensitive and its budget re-derived rather than this arm being
# softened to match what the scanner could already see.
{
	cat "${work}/token.orig"
	printf '\nvar cachedPassword*: string\n'
} >"${TOKEN}"
expect_red "D4 the identity layer defines a credential field" \
	"names a credential in code" "$(run_gate)"

# ---------------------------------------------------------------------------
echo
echo "Final: the tree came back clean"
# ---------------------------------------------------------------------------
arms=$((arms + 1))
dirty=0
cmp -s "${SIGNIN}" "${work}/signin.orig" || dirty=$((dirty + 1))
cmp -s "${TOKEN}" "${work}/token.orig" || dirty=$((dirty + 1))
[ -f "${PLANTED}" ] && dirty=$((dirty + 1))
if [ "${dirty}" -eq 0 ]; then
	printf '  [OK]     every mutated file was restored and nothing was left planted\n'
else
	misses=$((misses + 1))
	printf '  [MISS]   %s file(s) were left modified by this run\n' "${dirty}"
fi

echo
echo "${arms} arm(s), ${misses} miss(es)"
if [ "${misses}" -gt 0 ]; then
	echo "RESULT: FAILED — ${misses} arm(s) did not kill on their own assertion"
	exit 1
fi
echo "RESULT: OK — every assertion in ${GATE} has a mutation that reddens it"
