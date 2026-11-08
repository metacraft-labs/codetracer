#!/usr/bin/env bash
#
# input-routing-gate-test.sh — the contract suite over
# ci/test/input-routing-gate.sh. Each case copies the real modules the gate reads
# into a synthetic tree, plants one violation, and requires the gate to redden
# on it by check name; the clean copy must pass. No mocks: the gate is run as
# shipped, over copies of the shipped modules.
#
# Usage: ci/test/input-routing-gate-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${repo_root}/ci/test/input-routing-gate.sh"
pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

make_tree() {
	local t="${work}/$1" top
	mkdir -p "${t}/ci/test"
	cp "${repo_root}/ci/test/input-routing-gate-ledger.txt" "${t}/ci/test/"
	for top in ui tui gpui viewmodel/views; do
		mkdir -p "${t}/src/frontend/${top}"
		cp -r "${repo_root}/src/frontend/${top}/." "${t}/src/frontend/${top}/"
	done
	echo "${t}"
}

expect_red() {
	local name="$1" check="$2" out rc
	out="$(bash "${gate}" "${work}/${name}" 2>&1)"
	rc=$?
	if [ "${rc}" -ne 0 ] && grep -qF "FAIL  [${check}]" <<<"${out}"; then
		pass=$((pass + 1))
		echo "  ok   ${name}: reddens on ${check}"
	else
		fail=$((fail + 1))
		echo "  FAIL ${name}: expected red on ${check}, rc=${rc}"
		echo "${out}" | tail -3
	fi
}

clean="$(make_tree clean)"
if bash "${gate}" "${clean}" >/dev/null 2>&1; then
	pass=$((pass + 1))
	echo "  ok   the clean copy passes"
else
	fail=$((fail + 1))
	echo "  FAIL the clean copy is red"
	bash "${gate}" "${clean}" | tail -5
fi

t="$(make_tree case)"
cat >>"${t}/src/frontend/tui/app/views/planted.nim" <<'NIM'
proc planted(key: string) =
  case key
  of "Enter": discard
  else: discard
NIM
expect_red case case

t="$(make_tree compare)"
cat >>"${t}/src/frontend/gpui/planted.nim" <<'NIM'
proc planted(key: string): bool = key == "Esc"
NIM
expect_red compare compare

t="$(make_tree listen)"
cat >>"${t}/src/frontend/viewmodel/views/planted.nim" <<'NIM'
proc planted(el: Node) =
  el.addEventListener("keydown", proc(ev: Event) = discard)
NIM
expect_red listen listen

t="$(make_tree stale)"
echo "src/frontend/ui/key_chords_gone.nim case 3" >>"${t}/ci/test/input-routing-gate-ledger.txt"
expect_red stale ledger

echo "input-routing-gate-test: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
