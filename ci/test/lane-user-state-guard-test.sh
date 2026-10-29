#!/usr/bin/env bash
#
# lane-user-state-guard-test.sh — contract suite for the user-state guard in
# ci/lib/run-nim-test-lane.sh: a Nim test lane gives every file its own
# per-user roots, and FAILS, naming the file, when a file it ran (or a binary
# that file spawned) touched the user's own CodeTracer state anyway.
#
# WHY THIS EXISTS
# ---------------
# The lane runner gives each file a scratch `CODETRACER_HOME`, layout
# directory and XDG roots, and compares the user's `~/.local/state/codetracer`,
# `~/.config/codetracer` and trace index (`~/.local/share/codetracer`) before
# and after. A guard that is never seen failing is a guard nobody knows
# works: reports that a lane "wrote the user's terminal-profiles.json and
# trace_index.db" could not be told apart from another process on the host
# writing them, because the comparison only said "this lane". So the runner
# now compares around EACH file as well, and this suite RUNS it, against
# fixture test programs that misbehave the way a child that ignores the
# overrides would.
#
# HERMETIC, NO TOOLCHAIN
# ----------------------
# The runner is copied into a scratch repository whose
# `ci/lib/test-lane-files.sh` declares this suite's own lanes, and `nim` on
# PATH is a stub that "compiles" a fixture by copying it (each fixture is a
# shell script printing unittest-shaped lines). `HOME` is a scratch home, so a
# fixture that writes "the user's" state writes into a throwaway directory —
# the arm that must fail can fail without harming anyone.
#
# THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: the `nim` stub. What is under
# test is the runner's handling of the environment and of the user's
# directories around a RUN; the compiler is not exercised by any contract, and
# a real one would make this suite need the dev shell and take minutes. The
# runner, its report library and the known-failure ledger are the real files.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lane-user-state-guard.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
}

# --- the scratch repository -------------------------------------------------
fake="${scratch}/repo"
mkdir -p "${fake}/ci/lib" "${fake}/tests" "${scratch}/bin" "${scratch}/tmp"
cp "${repo_root}/ci/lib/run-nim-test-lane.sh" \
	"${repo_root}/ci/lib/test-lane-report.sh" \
	"${repo_root}/ci/lib/known_failures.py" "${fake}/ci/lib/"
# An empty ledger: no registration may excuse anything here.
: >"${fake}/ci/lib/known-test-failures.tsv"

cat >"${fake}/ci/lib/test-lane-files.sh" <<'LANES'
test_lane_ids() { printf '%s\n' guard-clean guard-state guard-index guard-removal guard-mixed; }
test_lane_recipe() { echo ""; }
test_lane_backend() { echo "c"; }
test_lane_extra_flags() { echo ""; }
test_lane_run_library_path() { echo ""; }
test_lane_is_compile_only() { echo "0"; }
test_lane_description() { echo "lane-user-state-guard-test fixture lane $1"; }
test_lane_files() {
	case "$1" in
	guard-clean) echo tests/test_clean_a.nim; echo tests/test_clean_b.nim ;;
	guard-state) echo tests/test_writes_state.nim ;;
	guard-index) echo tests/test_writes_index.nim ;;
	guard-removal) echo tests/test_removes_layout.nim ;;
	guard-mixed)
		echo tests/test_clean_a.nim
		echo tests/test_writes_state.nim
		echo tests/test_clean_b.nim
		;;
	esac
}
LANES

# `nim c ... -o:<artifact> <file>`: the artifact is the fixture itself.
cat >"${scratch}/bin/nim" <<'NIM'
#!/usr/bin/env bash
out=""
src=""
for a in "$@"; do
	case "$a" in
	-o:*) out="${a#-o:}" ;;
	-*) ;;
	c) ;;
	*) src="$a" ;;
	esac
done
mkdir -p "$(dirname "$out")"
cp "$src" "$out" && chmod +x "$out"
NIM
chmod +x "${scratch}/bin/nim"

# A well-behaved file: asserts the runner gave it its own roots, none of them
# inside HOME, and writes only under them. It prints its roots so the
# contracts can check that two files did not share one.
clean_fixture() {
	cat <<'FIX'
#!/usr/bin/env bash
ok=1
for v in CODETRACER_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME CODETRACER_TUI_LAYOUT_DIR; do
	val="${!v:-}"
	case "$val" in
	"") echo "unset: $v"; ok=0 ;;
	"$HOME"/*) echo "inside HOME: $v=$val"; ok=0 ;;
	esac
	echo "$v=$val" >>"$TMPDIR/roots.txt"
done
mkdir -p "$CODETRACER_HOME/state" "$XDG_DATA_HOME/codetracer" "$XDG_CONFIG_HOME/codetracer"
echo x >"$CODETRACER_HOME/state/terminal-profiles.json"
echo x >"$XDG_DATA_HOME/codetracer/trace_index.db"
if [ "$ok" = 1 ]; then echo "[OK] its own roots"; else echo "[FAILED] its own roots"; exit 1; fi
FIX
}
clean_fixture >"${fake}/tests/test_clean_a.nim"
clean_fixture >"${fake}/tests/test_clean_b.nim"
cat >"${fake}/tests/test_writes_state.nim" <<'FIX'
#!/usr/bin/env bash
# A child that ignores every override and writes the user's state.
mkdir -p "$HOME/.local/state/codetracer"
echo leak >"$HOME/.local/state/codetracer/terminal-profiles.json"
echo "[OK] passes, as a leaking suite does"
FIX
cat >"${fake}/tests/test_writes_index.nim" <<'FIX'
#!/usr/bin/env bash
echo rewritten >>"$HOME/.local/share/codetracer/trace_index.db"
echo "[OK] passes, as a leaking suite does"
FIX
cat >"${fake}/tests/test_removes_layout.nim" <<'FIX'
#!/usr/bin/env bash
rm -f "$HOME/.local/state/codetracer/tui-layout.json"
echo "[OK] passes, as a cleaning-up suite does"
FIX

# --- the scratch home, with the user's state in it --------------------------
reset_home() {
	rm -rf "${scratch:?}/home"
	mkdir -p "${scratch}/home/.local/state/codetracer" \
		"${scratch}/home/.local/share/codetracer" "${scratch}/home/.config/codetracer"
	echo '{"user":"layout"}' >"${scratch}/home/.local/state/codetracer/tui-layout.json"
	echo 'index' >"${scratch}/home/.local/share/codetracer/trace_index.db"
	echo 'cfg: 1' >"${scratch}/home/.config/codetracer/.config.yaml"
}

run_lane() {
	# A clean environment as the lane would get it from a shell: no override
	# of the caller's is inherited, so the runner's own are what is tested.
	reset_home
	rm -f "${scratch}/tmp/roots.txt"
	(
		cd "${fake}" || exit 2
		env -u CODETRACER_HOME -u CODETRACER_TUI_LAYOUT_DIR -u XDG_STATE_HOME \
			-u XDG_DATA_HOME -u XDG_CONFIG_HOME \
			HOME="${scratch}/home" TMPDIR="${scratch}/tmp" \
			PATH="${scratch}/bin:${PATH}" CT_NIM_CACHE_ROOT="${scratch}/cache" \
			bash ci/lib/run-nim-test-lane.sh "$1"
	) >"${scratch}/out" 2>&1
	echo $?
}

echo "lane-user-state-guard-test:"

# 1. A clean lane passes, every file got its own roots outside HOME, and no
#    two files shared one.
rc="$(run_lane guard-clean)"
if [ "${rc}" = 0 ] && grep -q 'guard-clean: 2 file(s) passed, 0 failed' "${scratch}/out"; then
	t_pass "a lane whose files stay in their own roots passes"
else
	t_fail "a lane whose files stay in their own roots passes (rc=${rc})"
	sed 's/^/       /' "${scratch}/out" >&2
fi
roots="${scratch}/tmp/roots.txt"
shared="$(sort "${roots}" 2>/dev/null | uniq -d)"
if [ "$(wc -l <"${roots}" 2>/dev/null || echo 0)" -eq 10 ] && [ -z "${shared}" ]; then
	t_pass "each file was given roots of its own (5 roots x 2 files, none shared)"
else
	t_fail "each file was given roots of its own: $(cat "${roots}" 2>/dev/null)"
fi

# 2-4. Each kind of damage fails the lane and names the file that did it.
for spec in "guard-state:test_writes_state.nim:terminal-profiles.json" \
	"guard-index:test_writes_index.nim:trace_index.db" \
	"guard-removal:test_removes_layout.nim:tui-layout.json"; do
	lane="${spec%%:*}"
	rest="${spec#*:}"
	file="${rest%%:*}"
	path="${rest#*:}"
	rc="$(run_lane "${lane}")"
	if [ "${rc}" != 0 ] &&
		grep -q "tests/${file} changed the user's own CodeTracer state" "${scratch}/out" &&
		grep -q "${path}" "${scratch}/out" &&
		grep -q "TOUCHED THE USER'S STATE" "${scratch}/out"; then
		t_pass "${lane}: the lane fails and names ${file} and ${path}"
	else
		t_fail "${lane}: the lane fails and names ${file} and ${path} (rc=${rc})"
		sed 's/^/       /' "${scratch}/out" >&2
	fi
done

# 5. Attribution: in a lane of three files only the one that wrote is named,
#    and the two clean files still pass.
rc="$(run_lane guard-mixed)"
named="$(grep -c "changed the user's own CodeTracer state" "${scratch}/out" || true)"
if [ "${rc}" != 0 ] && [ "${named}" = 1 ] &&
	grep -q "tests/test_writes_state.nim changed" "${scratch}/out" &&
	grep -q 'guard-mixed: 2 file(s) passed, 1 failed' "${scratch}/out"; then
	t_pass "a writer between two clean files is the one file named"
else
	t_fail "a writer between two clean files is the one file named (rc=${rc}, named=${named})"
	sed 's/^/       /' "${scratch}/out" >&2
fi

echo "lane-user-state-guard-test: ${passes} passed, ${failures} failed"
[ "${failures}" -eq 0 ] && [ "${passes}" -eq 6 ]
