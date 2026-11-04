#!/usr/bin/env bash
#
# lane-user-state-guard-test.sh — contract suite for the user-state guard
# (ci/lib/codetracer-home.sh) and its two users: a Nim test lane
# (ci/lib/run-nim-test-lane.sh) gives every file its own per-user roots, and
# FAILS, naming the file, when a file it ran (or a binary that file spawned)
# touched the user's own CodeTracer state anyway; and every other entry point
# that exports a scratch `CODETRACER_HOME` fails the same way, from its EXIT
# trap.
#
# WHY THIS EXISTS
# ---------------
# The lane runner gives each file a scratch `CODETRACER_HOME`, layout
# directory and XDG roots, and compares the user's `~/.local/state/codetracer`,
# `~/.config/codetracer`, trace index (`~/.local/share/codetracer`) and cache
# (`~/.cache/codetracer`, by name) before and after. A guard that is never seen failing is a guard nobody knows
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
#
# THE CACHE AND THE OTHER ENTRY POINTS (2026-11-04). On 2026-11-02 two entry
# points wrote `~/.cache/codetracer` under a scratch `CODETRACER_HOME`:
# `just test-rust` (through `ct-mcr record`) and `ci/lint/nim.sh` (through
# `ci/test/cua-keymap-extractor.sh`). The guard did not look at the cache and
# wrapped only the Nim lanes, so neither was reported. Cases 6-12 pin both: the
# cache is guarded (by name), the helper's own check and exit-trap form behave,
# and every entry point that exports a scratch home also checks the guard.

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
	"${repo_root}/ci/lib/codetracer-home.sh" \
	"${repo_root}/ci/lib/test-lane-report.sh" \
	"${repo_root}/ci/lib/known_failures.py" "${fake}/ci/lib/"
# An empty ledger: no registration may excuse anything here.
: >"${fake}/ci/lib/known-test-failures.tsv"

cat >"${fake}/ci/lib/test-lane-files.sh" <<'LANES'
test_lane_ids() { printf '%s\n' guard-clean guard-state guard-index guard-removal guard-mixed guard-cache guard-cache-rewrite; }
test_lane_recipe() { echo ""; }
test_lane_file_skip_reason() { :; }
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
	guard-cache) echo tests/test_writes_cache.nim ;;
	guard-cache-rewrite) echo tests/test_rewrites_cache.nim ;;
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
# The 2026-11-02 shape: a recorder that ignores CODETRACER_HOME files a
# library-family list in the user's cache.
cat >"${fake}/tests/test_writes_cache.nim" <<'FIX'
#!/usr/bin/env bash
mkdir -p "$HOME/.cache/codetracer/sync-families"
echo leak >"$HOME/.cache/codetracer/sync-families/0123-4567.rec"
echo "[OK] passes, as a leaking suite does"
FIX
# The cache is compared by NAME: an existing entry rewritten in place is not a
# new or a lost entry, and is not reported.
cat >"${fake}/tests/test_rewrites_cache.nim" <<'FIX'
#!/usr/bin/env bash
echo rewritten >"$HOME/.cache/codetracer/vscode-484fdf69/package.json"
echo "[OK] its own roots"
FIX

# --- the scratch home, with the user's state in it --------------------------
reset_home() {
	rm -rf "${scratch:?}/home"
	mkdir -p "${scratch}/home/.local/state/codetracer" \
		"${scratch}/home/.local/share/codetracer" "${scratch}/home/.config/codetracer"
	echo '{"user":"layout"}' >"${scratch}/home/.local/state/codetracer/tui-layout.json"
	echo 'index' >"${scratch}/home/.local/share/codetracer/trace_index.db"
	echo 'cfg: 1' >"${scratch}/home/.config/codetracer/.config.yaml"
	mkdir -p "${scratch}/home/.cache/codetracer/vscode-484fdf69"
	echo '{}' >"${scratch}/home/.cache/codetracer/vscode-484fdf69/package.json"
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

# 6. The cache: a file that appears under ~/.cache/codetracer fails the lane
#    and names the file and the entry.
rc="$(run_lane guard-cache)"
if [ "${rc}" != 0 ] &&
	grep -q "tests/test_writes_cache.nim changed the user's own CodeTracer state" "${scratch}/out" &&
	grep -q "sync-families/0123-4567.rec" "${scratch}/out" &&
	grep -q "\.cache/codetracer" "${scratch}/out"; then
	t_pass "guard-cache: a new ~/.cache/codetracer entry fails the lane and is named"
else
	t_fail "guard-cache: a new ~/.cache/codetracer entry fails the lane and is named (rc=${rc})"
	sed 's/^/       /' "${scratch}/out" >&2
fi

# 7. ... by name only: an entry rewritten in place is not reported.
rc="$(run_lane guard-cache-rewrite)"
if [ "${rc}" = 0 ] && grep -q 'guard-cache-rewrite: 1 file(s) passed, 0 failed' "${scratch}/out"; then
	t_pass "guard-cache-rewrite: a cache entry rewritten in place is not a finding (by name)"
else
	t_fail "guard-cache-rewrite: a cache entry rewritten in place is not a finding (rc=${rc})"
	sed 's/^/       /' "${scratch}/out" >&2
fi

# --- the helper itself, as every other entry point uses it -------------------
# A script shaped like `just test-rust`: export a scratch home (which starts
# the guard), run something, end through the prescribed EXIT trap. `$1` is
# what the "lane" does, `$2` the status it exits with.
entry_point() {
	reset_home
	cat >"${scratch}/entry.sh" <<ENTRY
set -euo pipefail
source "${repo_root}/ci/lib/codetracer-home.sh"
ct_export_scratch_codetracer_home probe
trap '_ct_rc=\$?; rm -rf \${ct_scratch_home_created:+"\$ct_scratch_home_created"}; ct_user_state_guard_exit probe "\$_ct_rc"' EXIT
$1
exit $2
ENTRY
	env -u CODETRACER_HOME HOME="${scratch}/home" TMPDIR="${scratch}/tmp" \
		bash "${scratch}/entry.sh" >"${scratch}/out" 2>&1
	echo $?
}

# 8. A clean run keeps its own status, both ways.
# shellcheck disable=SC2016 # expanded by the entry point, not here
rc0="$(entry_point 'mkdir -p "$CODETRACER_HOME/cache/x" && echo ok >"$CODETRACER_HOME/cache/x/y"' 0)"
rc3="$(entry_point ':' 3)"
if [ "${rc0}" = 0 ] && [ "${rc3}" = 3 ]; then
	t_pass "an entry point that writes only its scratch home keeps its own exit status (0 and 3)"
else
	t_fail "an entry point that writes only its scratch home keeps its own exit status (got ${rc0} and ${rc3})"
	sed 's/^/       /' "${scratch}/out" >&2
fi

# 9. A run that passed but wrote the user's cache fails, naming the entry.
# shellcheck disable=SC2016 # expanded by the entry point, not here
rc="$(entry_point 'mkdir -p "$HOME/.cache/codetracer/sync-families" && echo x >"$HOME/.cache/codetracer/sync-families/leak.rec"' 0)"
if [ "${rc}" = 1 ] && grep -q "probe WROTE the user's own CodeTracer state" "${scratch}/out" &&
	grep -q "sync-families/leak.rec" "${scratch}/out"; then
	t_pass "an entry point that passed but wrote ~/.cache/codetracer exits 1, naming the entry"
else
	t_fail "an entry point that passed but wrote ~/.cache/codetracer exits 1 (rc=${rc})"
	sed 's/^/       /' "${scratch}/out" >&2
fi

# 10. A deletion is damage too, from the helper as from the lane.
# shellcheck disable=SC2016 # expanded by the entry point, not here
rc="$(entry_point 'rm -f "$HOME/.config/codetracer/.config.yaml"' 0)"
if [ "${rc}" = 1 ] && grep -q "probe: these files LEFT the user's own CodeTracer" "${scratch}/out" &&
	grep -q "\.config/codetracer/\.config\.yaml" "${scratch}/out"; then
	t_pass "an entry point that removed a user config file exits 1, naming it"
else
	t_fail "an entry point that removed a user config file exits 1 (rc=${rc})"
	sed 's/^/       /' "${scratch}/out" >&2
fi

# 11. A check with nothing to compare against refuses rather than passing.
out="$(env HOME="${scratch}/home" bash -c "source '${repo_root}/ci/lib/codetracer-home.sh'; ct_user_state_guard_check never-started" 2>&1)"
rc=$?
if [ "${rc}" = 2 ] && grep -q "never started" <<<"${out}"; then
	t_pass "a guard checked without being started refuses (exit 2), it does not pass"
else
	t_fail "a guard checked without being started refuses (rc=${rc}): ${out}"
fi

# 12. EVERY entry point that exports a scratch CODETRACER_HOME checks the guard.
#     The unit is the file, or for the justfile the recipe. A positive control
#     first: the scanner must flag a recipe that exports and never checks.
entry_points_unchecked() {
	# Prints "<file>[:<recipe>]" for every unit that exports a scratch home in
	# code and never calls ct_user_state_guard_exit / _check in code.
	awk -v file="$1" '
	function flush() {
		if (exports && !checks) print file (recipe != "" ? ":" recipe : "")
		exports = 0; checks = 0
	}
	BEGIN { recipe = ""; exports = 0; checks = 0; isjust = (file ~ /justfile$/) }
	{
		line = $0
		if (isjust && line ~ /^[A-Za-z0-9_@-][A-Za-z0-9_-]*([ \t][^:=]*)?:([^=]|$)/) {
			flush(); recipe = line; sub(/[ \t:].*/, "", recipe); sub(/^@/, "", recipe)
		}
		code = line; sub(/^[ \t]+/, "", code)
		if (code ~ /^#/) next
		if (code ~ /(^|[^_[:alnum:]])ct_export_scratch_codetracer_home[ \t]+[a-z]/) exports = 1
		if (code ~ /ct_user_state_guard_(exit|check)[ \t]/) checks = 1
	}
	END { flush() }' "$1"
}
mkdir -p "${scratch}/control"
printf 'ok-recipe:\n  source ci/lib/codetracer-home.sh\n  ct_export_scratch_codetracer_home a\n  trap '"'"'ct_user_state_guard_exit a "$?"'"'"' EXIT\n\nbad-recipe:\n  source ci/lib/codetracer-home.sh\n  ct_export_scratch_codetracer_home b\n  trap '"'"'rm -rf x'"'"' EXIT\n' >"${scratch}/control/justfile"
control="$(entry_points_unchecked "${scratch}/control/justfile")"
entry_files=()
while IFS= read -r f; do entry_files+=("$f"); done < <(
	cd "${repo_root}" && grep -rlE 'ct_export_scratch_codetracer_home[[:space:]]+[a-z]' \
		--include='*.sh' --include=justfile ci scripts justfile 2>/dev/null |
		grep -v '^ci/lib/codetracer-home\.sh$' | grep -v '^ci/test/lane-user-state-guard-test\.sh$' | sort -u
)
units=0
unchecked=""
for f in "${entry_files[@]+"${entry_files[@]}"}"; do
	# `grep -c` prints 0 and exits 1 when nothing matches; the braces keep that
	# `|| true` from also covering a failed `cd` (SC2015).
	u="$(cd "${repo_root}" && { awk '/^[^#]*ct_export_scratch_codetracer_home[ \t]+[a-z]/' "$f" | grep -c . || true; })"
	units=$((units + u))
	unchecked="${unchecked}$(cd "${repo_root}" && entry_points_unchecked "$f")"
done
if [ "${control}" = "${scratch}/control/justfile:bad-recipe" ] && [ -z "${unchecked}" ] && [ "${units}" -ge 8 ]; then
	t_pass "all ${units} entry points that export a scratch CODETRACER_HOME check the guard (control flagged)"
else
	t_fail "every entry point that exports a scratch CODETRACER_HOME checks the guard: unchecked='${unchecked}' units=${units} control='${control}'"
fi

echo "lane-user-state-guard-test: ${passes} passed, ${failures} failed"
[ "${failures}" -eq 0 ] && [ "${passes}" -eq 13 ]
