#!/usr/bin/env bash
# How the five GPUI lanes that select a shim by file substitution stage it at
# the live path, and whether cargo's output survives that.
#
#   bash ci/test/gpui-shim-staging-test.sh                       # all five
#   bash ci/test/gpui-shim-staging-test.sh --lane <path> [--lane <path>...]
#
# `--lane` runs exactly these assertions against another copy of a lane, so that
# review can run them against an unfixed one. The file's basename says which of
# the five it stands for, and only the named lanes run.
#
# On Linux cargo uplifts `target/debug/libgpui_nim_shim.<ext>` as a HARDLINK to
# its `deps/` output. A `cp` onto the live path writes through that inode, so
# cargo then re-uplifts the arm's bytes as if it had built them. A lane must
# therefore move the live shim aside, leave a later arm's inode alone, and move
# the shim back, so that the hardlink survives the run. All of them do that
# through `ci/lib/gpui-shim-stage.sh`, whose header gives the rules.
#
# macOS cargo copies the uplifted file instead (measured with cargo 1.96 on
# 2026-11-01; https://github.com/rust-lang/cargo/issues/10060), so no real macOS
# tree has this hardlink. The fixture builds it on both hosts all the same, so
# that a macOS run of this test can catch a write-through as a Linux run can.
#
# Each lane is held to these things:
#   (a) a stand-in saw the arm's bytes at the live path while the lane ran. This
#       is the positive control: a lane that exits before staging fails here,
#       because every other assertion would hold over a lane that did nothing.
#   (b) `deps/` held cargo's bytes while staged, and still does after exit.
#   (c) after exit the live path is the same inode as `deps/`, and no `*-backup`
#       file or no-original marker remains.
#   (d) a lane that swaps arms keeps (b) and (c) across the swaps, and each arm
#       it replaced still holds that arm's bytes: a swap unlinks the previous
#       arm and does not copy over the inode a running app has mapped.
#   (e) when the move aside fails, the lane stops, and cargo's file is untouched.
#       `cp -f` still succeeds in that state and writes through the hardlink: a
#       read-only directory does exactly this, and three lanes used to exit 0.
#   (f) when staging fails, the lane stops, and cargo's file is back in place.
#   Both also require the stand-in's refusal in the lane's output, so a lane that
#   stopped earlier for another reason does not count as having stopped here.
#   (g) a real SIGKILL while staged, then a re-run: the live path is cargo's inode
#       and bytes again, nothing is left over, and the re-run really staged. The
#       kill's own result is the positive control: exit 137, the arm at the live
#       path, and cargo's inode in a backup. No state is fabricated.
#   (h) the same with a DIFFERENT lane as the re-run, which is why the backup's
#       name belongs to no lane. One pair, plat38 then plat42: their `.so` paths
#       are the same file on every host. It runs when both are selected.
#   (i) with no live shim at the start, the arm was seen while staged, and neither
#       it nor the marker remains after exit.
#   (j) (i) with a real SIGKILL and a re-run, which has to tell a stale arm from
#       an original by the marker alone.
#   (k) a refused restore fails the lane, even one whose ordinary run exits 0
#       (plat38, plat42 and plat44, shown by an ordinary run first). It names the
#       backup, the backup keeps cargo's bytes, and a later run recovers. The same
#       for the no-original restore, when its `rm` is refused.
#   (l) a refused `rm` of a previous arm stops a lane that swaps arms, before the
#       next arm runs and without writing through the arm a running app mapped. A
#       refused `rm` of a stale arm on a re-run stops the lane before it runs the
#       app, with a backup or with a marker.
#   (m) SIGTERM and SIGINT while staged end the lane with 143 and 130, restored.
#       plat42 and plat44 used to restore on those and then run on.
#   (o) a pinned run (`CODETRACER_WINDOW_BIN_PINS_SHIM=1`, plat42 and plat44) stages
#       nothing, so it leaves a killed run's arm and backup alone for a later run
#       to recover. That the lane still ran its app is the positive control.
#
# And the library is held to these on its own, once, because no lane reaches them:
# a lane stops at a failed stage and has nothing to restore before one, and the
# stand-ins name one path where these cases need two moments.
#   (n) a run that never staged leaves an earlier run's backup alone, and a stage
#       tried again after a failed move does not take the original for an arm. A
#       refused removal of the marker fails the restore and can be retried. A
#       failed restore keeps a status that was already non-zero. A signal during
#       the restore does not stop it between its two removals.
#   (p) a backup left under a lane's own name by a run killed before the lanes
#       shared this library (`<live>.plat38-backup` and the like) is the original
#       too: it is taken over, and the restore puts it back. Two of them cannot
#       both be the original, so a stage refuses them, names both and touches
#       nothing. The stale arm at the live path is what makes the first case
#       fail without the takeover.
#   (q) every selected lane parses with the host's system Bash. On Darwin this
#       deliberately means `/bin/bash`, the 3.2 interpreter macOS supplies, and
#       not the newer Bash from the development shell that runs this test.
#
# REAL: bash, python3, the lane scripts themselves, run end to end from a copy
# in a sandbox workspace against `src/tests/visual/scenarios.json`, and a real
# hardlink between the fixture's live path and its `deps/` file. The lanes
# compute their root from their own path, so the copy resolves `isonim-gpui`,
# `build/` and its output to the sandbox and cannot reach the real sibling.
#
# STAND-INS, AND WHY: all of them are what cannot exist here, or what a lane
# only needs in order to walk past a step that has nothing to do with staging.
#   - The fixture's shims are one line of text, so a failure names the arm. Their
#     bytes are never loaded: the property under test is which bytes sit in which
#     inode, and a real cdylib takes a GPUI link that needs isonim-gpui's shell.
#   - `nm` and `ldd` on PATH, on both platforms, because a text shim has no
#     symbol table and because `nm -D` and `ldd` are ELF tools that do not behave
#     the same on Mach-O. `nm` answers with the two ABI symbols the lanes grep.
#   - `sway`, `grim`, `wayland-info`, `wtype` and `cargo` on PATH, as no-ops. The
#     lanes only ask whether they exist; macOS has no compositor to provide them.
#   - `xvfb-run` on PATH, as a no-op, because the real one holds the plat37 lane
#     for its 20-second window and proves nothing about staging.
#   - `mv`, `cp` and `rm` on PATH, which refuse the one step `STAGING_REFUSE`
#     names and are the real tools for everything else: `mv` the move aside (e),
#     `mv-to-live` the restore (k), `cp` the staging (f), and `rm` every unlink of
#     the live path (k, l). A read-only directory would make the same failure
#     with no stand-in, but root ignores it, and a CI container may run as root.
#   - A wrapper that records the lane's pid and `exec`s it, so that the observer
#     can signal the lane process itself and nothing else. The signals are real.
#   - The fixture's `scripts/wayland-run-test.sh`, the app at `build/bin`, and
#     `nim` are one observer. They are what a lane runs while a shim is staged,
#     so that is where the bytes are read. The compositor harness does not run
#     the inner `--inside` pass, because that pass only sleeps for a window that
#     cannot open here; it writes the empty records file the plat37 lane checks
#     for so that the lane goes on to its next arm. `nim` stands for the headless
#     probe, and the lane then stops on the probe's missing answer, after its
#     last swap. Reaching that failure is expected, so a lane's exit status is
#     reported and not asserted, except where a case says otherwise. At its first
#     observation of a run the observer sends `STAGING_SIGNAL` to the lane: that
#     is the one moment a shim is certainly staged, without a sleep or a race.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Names and not paths, so that `shell-gate-coverage.sh` does not credit these
# lanes as run: this test runs copies of them, against the stand-ins above.
lane_names=(plat35-gpui-capture plat37-window-frame plat38-keystroke
	plat42-frame-budget plat44-edit-window)

usage() {
	echo "usage: $0 [--lane <path>...]" >&2
	echo "  each <path>'s basename must be one of: ${lane_names[*]}" >&2
	exit 2
}

chosen_names=()
chosen_paths=()
while [ $# -gt 0 ]; do
	[ "$1" = --lane ] && [ $# -ge 2 ] && [ -f "$2" ] || usage
	name="$(basename "$2" .sh)"
	case " ${lane_names[*]} " in
	*" ${name} "*) ;;
	*) usage ;;
	esac
	chosen_names+=("${name}")
	chosen_paths+=("$(cd "$(dirname "$2")" && pwd)/$(basename "$2")")
	shift 2
done
if [ "${#chosen_names[@]}" -eq 0 ]; then
	for name in "${lane_names[@]}"; do
		chosen_names+=("${name}")
		chosen_paths+=("${root}/ci/test/${name}.sh")
	done
fi

command -v python3 >/dev/null || {
	echo "FAIL: python3 is required: the lanes parse scenarios.json with it." >&2
	exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export CODETRACER_HOME="${work}/home"
failures=0
output="${work}/output"
: >"${output}"

report() {
	failures=$((failures + 1))
	echo "FAIL: $*" >&2
}
# One verdict per case, printing the end of what the lane said when it failed.
verdict() {
	local name="$1" before="$2"
	if [ "${failures}" -eq "${before}" ]; then
		echo "PASS: ${name}"
	else
		tail -n 20 "${output}" | sed 's/^/    /' >&2
	fi
}

# The only lane that derives its extension is plat35's. The others spell `.so`,
# on every host, so that is the path their fixture has to hold.
lane_ext() {
	case "$1:$(uname -s)" in
	plat35-gpui-capture:Darwin) echo dylib ;;
	*) echo so ;;
	esac
}

read_bytes() { if [ -f "$1" ]; then cat "$1"; else echo '<absent>'; fi; }

# What a run may leave beside the live shim. `*-backup` catches each lane's old
# `.<lane>-backup` as well as the shared `.gpui-lane-backup`, so that this test
# can be pointed at an unfixed lane.
leftovers() {
	find "$(dirname "${live}")" -name '*-backup' -o -name '*.gpui-lane-no-original'
}

# The arms in the order the lane puts them at the live path, adjacent repeats
# collapsed. plat37 goes back to `windowed` for its compositor probes.
lane_arms() {
	case "$1" in
	plat35-gpui-capture) echo "arm:headless" ;;
	plat37-window-frame) echo "arm:windowed arm:featureless arm:windowed arm:headless" ;;
	*) echo "arm:windowed" ;;
	esac
}

first_arm() {
	local arms
	arms="$(lane_arms "$1")"
	echo "${arms%% *}"
}

# The arms this run of the lane put at the live path.
arms_seen() {
	cut -f2 "${ledger}" | uniq | paste -sd' ' -
}

cargo_bytes='cargo output of the shim'

# Parse the real lane before any stand-in can hide a failure. Every host runs
# this case: Darwin selects the platform Bash whose compatibility is the
# contract; other hosts select their real Bash and retain a syntax check.
check_system_bash_parse() {
	local name="$1" lane="$2" before parser rc=0 parse_output=""
	before="${failures}"
	case "$(uname -s)" in
	Darwin) parser=/bin/bash ;;
	*) parser="$(command -v bash)" ;;
	esac
	if [ ! -x "${parser}" ]; then
		report "${name}: (q) the system Bash is not executable at ${parser:-<empty>}"
	elif parse_output="$("${parser}" -n "${lane}" 2>&1)"; then
		:
	else
		rc=$?
		report "${name}: (q) ${parser} rejected the lane with status ${rc}: ${parse_output}"
	fi
	verdict "${name}: (q) parses with the host's system Bash (${parser:-unresolved})" "${before}"
}

# The stand-ins --------------------------------------------------------------
stand_ins="${work}/stand-ins"
mkdir -p "${stand_ins}"
for tool in sway grim wayland-info wtype cargo xvfb-run; do
	printf '#!/bin/sh\nexit 0\n' >"${stand_ins}/${tool}"
done
cat >"${stand_ins}/nm" <<'SH'
#!/bin/sh
# Stand-in: see the test's header. One write, because the lanes pipe this into
# `grep -q` under pipefail.
printf '0 T gpui_dispatch_key_to_focus\n0 T gpui_frame_count\n'
SH
printf '#!/bin/sh\necho "stand-in => none"\n' >"${stand_ins}/ldd"
# The steps are spelled `mv -f <from> <to>`, `cp -f <from> <to>` and `rm -f
# <path>`, so the position says which step this is: the move aside takes the live
# path as its source, the restore and staging take it as their destination.
#
# refusing_tool <tool> (<STAGING_REFUSE value> <position of the live path>)...
refusing_tool() {
	local tool="$1" real
	real="$(command -v "${tool}")"
	shift
	{
		printf '#!/bin/sh\n# Stand-in: see the test'"'"'s header.\n'
		while [ $# -gt 0 ]; do
			cat <<SH
if [ "\${STAGING_REFUSE:-}" = "$1" ] && [ "\$$2" = "\${STAGING_LIVE:-}" ]; then
	echo "stand-in ${tool}: refused" >&2
	exit 1
fi
SH
			shift 2
		done
		printf 'exec "%s" "$@"\n' "${real}"
	} >"${stand_ins}/${tool}"
}
refusing_tool mv mv 2 mv-to-live 3
refusing_tool cp cp 3
refusing_tool rm rm 2

# Stand-in: see the test's header. `exec` keeps the pid, so the file names the
# lane's own bash and not a parent of it.
lane_wrapper="${work}/lane-wrapper"
cat >"${lane_wrapper}" <<'SH'
#!/usr/bin/env bash
echo "$$" >"${STAGING_PID_FILE}"
exec bash "$@"
SH

# The observer, installed under each name a lane runs while a shim is staged.
#
# Holding a hardlink to the live file is what (d) reads: it keeps the inode
# alive, as a running app's mapping does, so a lane that copied the next arm over
# this one changes the held file's bytes. Comparing inode numbers could not say
# so: a filesystem may reuse a freed one at once.
observer="${work}/observer"
cat >"${observer}" <<'SH'
#!/usr/bin/env bash
# Stand-in: see the test's header.
read_bytes() { if [ -f "$1" ]; then cat "$1"; else echo '<absent>'; fi; }
seen="$(wc -l <"${STAGING_LEDGER}" | tr -d ' ')"
ln "${STAGING_LIVE}" "${STAGING_HELD}/${seen}" 2>/dev/null || true
printf '%s\t%s\t%s\n' "${0##*/}" "$(read_bytes "${STAGING_LIVE}")" \
	"$(read_bytes "${STAGING_DEPS}")" >>"${STAGING_LEDGER}"
if [ -n "${STAGING_SIGNAL:-}" ] && [ "${seen}" = 0 ]; then
	kill "-${STAGING_SIGNAL}" "$(cat "${STAGING_PID_FILE}")"
fi
# `--inside <config>`: the file the plat37 lane requires of a capture pass.
previous=""
for arg in "$@"; do
	if [ "${previous}" = --inside ]; then : >"${STAGING_PLAT37_OUT}/${arg}.records.jsonl"; fi
	previous="${arg}"
done
SH
cp "${observer}" "${stand_ins}/nim"
chmod +x "${observer}" "${stand_ins}"/*

# One case's sandbox ----------------------------------------------------------
# Sets `sandbox`, `sandbox_lane`, `isonim`, `target`, `live`, `deps`, `trace`,
# `ledger` and `held` for the caller, which declares them local.
build_fixture() {
	local name="$1" lane="$2" ws="$3" ext arm
	ext="$(lane_ext "${name}")"
	sandbox="${ws}/codetracer"
	isonim="${ws}/isonim-gpui"
	target="${isonim}/rust/target"
	live="${target}/debug/libgpui_nim_shim.${ext}"
	deps="${target}/debug/deps/libgpui_nim_shim.${ext}"
	trace="${ws}/trace"
	ledger="${ws}/ledger"
	held="${ws}/held"

	mkdir -p "${sandbox}/ci/test" "${sandbox}/src/tests/visual" "${sandbox}/build/bin" \
		"${sandbox}/build/plat37" "${isonim}/scripts" "${target}/plat37" \
		"$(dirname "${deps}")" "${ws}/GuiAssert" "${trace}" "${held}"
	# Named through a variable for the reason given at `lane_names`.
	sandbox_lane="${sandbox}/ci/test/${name}.sh"
	cp "${lane}" "${sandbox_lane}"
	# Always, so that `--lane` can run a lane from before this library existed.
	mkdir -p "${sandbox}/ci/lib"
	cp "${root}/ci/lib/gpui-shim-stage.sh" "${sandbox}/ci/lib/"
	cp "${root}/src/tests/visual/scenarios.json" "${sandbox}/src/tests/visual/"
	cp "${observer}" "${sandbox}/build/bin/codetracer-gpui"
	cp "${observer}" "${isonim}/scripts/wayland-run-test.sh"
	printf '#!/bin/sh\nexit 0\n' >"${isonim}/scripts/wayland-capture-frame.sh"

	# As cargo leaves it on Linux: the uplifted file is a hardlink to `deps/`.
	printf '%s\n' "${cargo_bytes}" >"${deps}"
	ln "${deps}" "${live}"
	[ "${live}" -ef "${deps}" ] || {
		report "${name}: the fixture is not a hardlink, so nothing below would mean anything"
		return 1
	}
	for arm in featureless windowed headless; do
		printf 'arm:%s\n' "${arm}" >"${target}/plat37/libgpui_nim_shim.${arm}.${ext}"
	done
	: >"${ledger}"
}

# Runs the fixture's lane, and sets `rc`. `$1` is the step to refuse, if any, `$2`
# the signal the observer sends the lane at its first observation, if any, and
# `$3` is 1 for a run whose binary pins its own shim.
#
# The variables below select another binary, shim or trace, or a pinned binary
# that leaves the shared shim alone, and any of them would bypass staging. So the
# ambient pin is overridden here, and only a case that asks for one has it.
run_lane() {
	rc=0
	# The group's redirection is for bash's own `Killed: 9` notice about the lane.
	{
		env -u CODETRACER_PLAT42_BIN \
			-u CODETRACER_PLAT42_WINDOWED_SHIM -u CODETRACER_PLAT44_BIN \
			CODETRACER_WINDOW_BIN_PINS_SHIM="${3:-0}" \
			PATH="${stand_ins}:${PATH}" ISONIM_GPUI="${isonim}" ISONIM_GPUI_DIR="${isonim}" \
			CODETRACER_PLAT35_TRACE="${trace}" CODETRACER_PLAT37_TRACE="${trace}" \
			CODETRACER_PLAT38_TRACE="${trace}" \
			STAGING_LEDGER="${ledger}" STAGING_HELD="${held}" STAGING_LIVE="${live}" \
			STAGING_DEPS="${deps}" STAGING_PLAT37_OUT="${sandbox}/build/plat37" \
			STAGING_REFUSE="${1:-}" STAGING_SIGNAL="${2:-}" STAGING_PID_FILE="${ledger}.pid" \
			bash "${lane_wrapper}" "${sandbox_lane}" >"${output}" 2>&1 || rc=$?
	} 2>/dev/null
}

# The ordinary run: (a) to (d) -------------------------------------------------
check_lane() {
	local name="$1" lane="$2" before rc
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}" || return 0
	run_lane
	echo "NOTE: ${name} exited ${rc} after $(wc -l <"${ledger}" | tr -d ' ') observation(s)"

	before="${failures}"
	local want saw
	want="$(lane_arms "${name}")"
	saw="$(arms_seen)"
	[ "${saw}" = "${want}" ] ||
		report "${name}: (a) the live path held [${saw}] while the lane ran, expected [${want}]"
	verdict "${name}: (a) the arm was at the live path while the lane ran" "${before}"

	before="${failures}"
	local staged_deps
	staged_deps="$(cut -f3 "${ledger}" | sort -u | paste -sd' ' -)"
	[ "${staged_deps}" = "${cargo_bytes}" ] ||
		report "${name}: (b) while staged, deps/ held [${staged_deps}]"
	[ "$(cat "${deps}")" = "${cargo_bytes}" ] ||
		report "${name}: (b) after exit, deps/ holds [$(cat "${deps}")]"
	verdict "${name}: (b) deps/ kept cargo's bytes while staged and after exit" "${before}"

	before="${failures}"
	[ "${live}" -ef "${deps}" ] ||
		report "${name}: (c) after exit the live path is not the same inode as deps/"
	local leftover
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (c) a backup remains: ${leftover}"
	verdict "${name}: (c) the live path is cargo's inode again and no backup remains" "${before}"

	case "${want}" in *" "*) ;; *) return ;; esac
	before="${failures}"
	local line=0 who bytes rest
	while IFS=$'\t' read -r who bytes rest; do
		[ "$(cat "${held}/${line}")" = "${bytes}" ] ||
			report "${name}: (d) the inode ${who} saw as [${bytes}] now holds [$(cat "${held}/${line}")]"
		line=$((line + 1))
	done <"${ledger}"
	verdict "${name}: (d) each swap left the previous arm's inode alone" "${before}"
}

# A staging step that fails: (e) and (f) ---------------------------------------
check_refusal() {
	local name="$1" lane="$2" tool="$3" label="$4" step="$5" before rc leftover
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.${tool}" || return 0
	run_lane "${tool}"
	echo "NOTE: ${name} with ${step} refused exited ${rc}"

	before="${failures}"
	grep -q "stand-in ${tool}: refused" "${output}" ||
		report "${name}: (${label}) the lane never reached ${step}"
	[ "${rc}" -ne 0 ] || report "${name}: (${label}) the lane exited 0 after ${step} failed"
	[ ! -s "${ledger}" ] ||
		report "${name}: (${label}) the lane ran the app after ${step} failed"
	[ "$(cat "${deps}")" = "${cargo_bytes}" ] ||
		report "${name}: (${label}) deps/ holds [$(cat "${deps}")]"
	[ "${live}" -ef "${deps}" ] ||
		report "${name}: (${label}) the live path is not the same inode as deps/"
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (${label}) a backup remains: ${leftover}"
	verdict "${name}: (${label}) the lane stops when ${step} fails, and cargo's file survives" \
		"${before}"
}

# A kill while staged: (g), (h) and (j) ----------------------------------------
# Kills the lane at its first observation, and holds the kill's own result to
# what the cases after it rely on. A lane that was not killed while staged would
# otherwise pass them over nothing. The caller reads the backup's existence.
kill_while_staged() {
	local name="$1" label="$2" arm
	arm="$(first_arm "${name}")"
	run_lane "" KILL
	echo "NOTE: ${name} (${label}) was killed: rc ${rc}, live holds [$(read_bytes "${live}")]"
	[ "${rc}" -eq 137 ] || report "${name}: (${label}) the lane exited ${rc}, not by the SIGKILL"
	[ "$(read_bytes "${live}")" = "${arm}" ] ||
		report "${name}: (${label}) the kill left [$(read_bytes "${live}")] at the live path"
	[ "$(arms_seen)" = "${arm}" ] ||
		report "${name}: (${label}) the lane saw [$(arms_seen)] before the kill"
}

# The control of a kill that had an original to keep.
assert_original_in_backup() {
	local name="$1" label="$2" backup
	backup="$(leftovers)"
	[ -n "${backup}" ] && [ "${backup}" -ef "${deps}" ] ||
		report "${name}: (${label}) the kill left [${backup}], not cargo's inode in a backup"
}

# That a re-run put `$3` at the live path, and left the original in place.
assert_recovered() {
	local name="$1" label="$2" want="$3" leftover
	echo "NOTE: ${name} (${label}) re-run exited ${rc}"
	[ "$(arms_seen)" = "${want}" ] ||
		report "${name}: (${label}) the re-run saw [$(arms_seen)], expected [${want}]"
	[ "$(read_bytes "${live}")" = "${cargo_bytes}" ] ||
		report "${name}: (${label}) after the re-run the live path holds [$(read_bytes "${live}")]"
	[ "${live}" -ef "${deps}" ] ||
		report "${name}: (${label}) after the re-run the live path is not the same inode as deps/"
	[ "$(cat "${deps}")" = "${cargo_bytes}" ] ||
		report "${name}: (${label}) deps/ holds [$(cat "${deps}")]"
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (${label}) left over: ${leftover}"
}

check_kill_rerun() {
	local name="$1" lane="$2" before rc
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.kill" || return 0
	before="${failures}"
	kill_while_staged "${name}" g
	assert_original_in_backup "${name}" g
	: >"${ledger}"
	run_lane
	assert_recovered "${name}" g "$(lane_arms "${name}")"
	verdict "${name}: (g) a re-run after a SIGKILL puts cargo's inode back" "${before}"
}

check_kill_other_lane() {
	local killed="$1" killed_lane="$2" next="$3" next_lane="$4" before rc
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${killed}" "${killed_lane}" "${work}/other-lane.kill" || return 0
	before="${failures}"
	kill_while_staged "${killed}" h
	assert_original_in_backup "${killed}" h
	sandbox_lane="${sandbox}/ci/test/${next}.sh"
	cp "${next_lane}" "${sandbox_lane}"
	: >"${ledger}"
	run_lane
	assert_recovered "${next}" h "$(lane_arms "${next}")"
	verdict "${next}: (h) a re-run after ${killed} was killed puts cargo's inode back" "${before}"
}

# Gap 2: no live shim at the start: (i) and (j) --------------------------------
assert_nothing_at_live() {
	local name="$1" label="$2" want="$3" leftover
	echo "NOTE: ${name} (${label}) exited ${rc}"
	[ "$(arms_seen)" = "${want}" ] ||
		report "${name}: (${label}) the live path held [$(arms_seen)] while the lane ran, expected [${want}]"
	[ ! -e "${live}" ] ||
		report "${name}: (${label}) after exit the live path holds [$(read_bytes "${live}")]"
	[ "$(cat "${deps}")" = "${cargo_bytes}" ] ||
		report "${name}: (${label}) deps/ holds [$(cat "${deps}")]"
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (${label}) left over: ${leftover}"
}

check_no_original() {
	local name="$1" lane="$2" before rc
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.no-original" || return 0
	before="${failures}"
	rm -f "${live}"
	run_lane
	assert_nothing_at_live "${name}" i "$(lane_arms "${name}")"
	verdict "${name}: (i) a lane that found no live shim leaves none" "${before}"
}

check_no_original_kill() {
	local name="$1" lane="$2" before rc leftover
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.no-original-kill" || return 0
	before="${failures}"
	rm -f "${live}"
	kill_while_staged "${name}" j
	: >"${ledger}"
	run_lane
	assert_nothing_at_live "${name}" j "$(lane_arms "${name}")"
	verdict "${name}: (j) a re-run after a SIGKILL still leaves no live shim" "${before}"
}

# A restore that fails: (k) ----------------------------------------------------
check_refused_restore() {
	local name="$1" lane="$2" before rc backup
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.restore" || return 0
	before="${failures}"
	# What makes the exit status below this lane's restore and not its run.
	run_lane
	case "${name}" in
	plat35-gpui-capture | plat37-window-frame) ;;
	*)
		[ "${rc}" -eq 0 ] || report "${name}: (k) the ordinary run exited ${rc}, not 0"
		;;
	esac
	: >"${ledger}"
	run_lane mv-to-live
	echo "NOTE: ${name} with the restore refused exited ${rc}"
	[ -s "${ledger}" ] || report "${name}: (k) the lane never staged"
	grep -q 'stand-in mv: refused' "${output}" || report "${name}: (k) the restore was never tried"
	[ "${rc}" -ne 0 ] || report "${name}: (k) the lane exited 0 after its restore failed"
	backup="$(leftovers)"
	[ -n "${backup}" ] || report "${name}: (k) no backup remains"
	grep -qF "failed to restore ${live}; backup remains at ${backup}" "${output}" ||
		report "${name}: (k) the output does not name the backup [${backup}]"
	[ "$(read_bytes "${backup}")" = "${cargo_bytes}" ] ||
		report "${name}: (k) the backup holds [$(read_bytes "${backup}")]"
	verdict "${name}: (k) a refused restore fails the lane and names the backup" "${before}"

	# The failure has to leave something a later run can use.
	before="${failures}"
	: >"${ledger}"
	run_lane
	assert_recovered "${name}" k "$(lane_arms "${name}")"
	verdict "${name}: (k) a run after a refused restore recovers" "${before}"
}

check_refused_removal() {
	local name="$1" lane="$2" before rc arm
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.removal" || return 0
	before="${failures}"
	arm="$(first_arm "${name}")"
	rm -f "${live}"
	run_lane rm
	echo "NOTE: ${name} with the no-original restore refused exited ${rc}"
	[ -s "${ledger}" ] || report "${name}: (k) the lane never staged"
	grep -q 'stand-in rm: refused' "${output}" || report "${name}: (k) the removal was never tried"
	[ "${rc}" -ne 0 ] || report "${name}: (k) the lane exited 0 after its removal failed"
	grep -qF "failed to remove the staged shim at ${live}" "${output}" ||
		report "${name}: (k) the output does not name the live path"
	[ "$(read_bytes "${live}")" = "${arm}" ] ||
		report "${name}: (k) the live path holds [$(read_bytes "${live}")], not the arm that stayed"
	[ -n "$(leftovers)" ] || report "${name}: (k) the marker a later run needs is gone"
	verdict "${name}: (k) a refused removal fails the lane and names the path" "${before}"

	before="${failures}"
	: >"${ledger}"
	run_lane
	assert_nothing_at_live "${name}" k "$(lane_arms "${name}")"
	verdict "${name}: (k) a run after a refused removal recovers" "${before}"
}

# A swap that fails: (l) -------------------------------------------------------
check_refused_swap() {
	local name="$1" lane="$2" before rc arm leftover
	local sandbox sandbox_lane isonim target live deps trace ledger held
	case "$(lane_arms "${name}")" in *" "*) ;; *) return 0 ;; esac
	build_fixture "${name}" "${lane}" "${work}/${name}.swap" || return 0
	before="${failures}"
	arm="$(first_arm "${name}")"
	run_lane rm
	echo "NOTE: ${name} with the swap refused exited ${rc}"
	grep -q 'stand-in rm: refused' "${output}" || report "${name}: (l) the swap was never tried"
	[ "${rc}" -ne 0 ] || report "${name}: (l) the lane exited 0 after its swap failed"
	grep -qF "the previous arm at ${live} could not be removed" "${output}" ||
		report "${name}: (l) the output does not name the path"
	[ "$(arms_seen)" = "${arm}" ] ||
		report "${name}: (l) the live path held [$(arms_seen)] while the lane ran, expected [${arm}]"
	[ "$(read_bytes "${held}/0")" = "${arm}" ] ||
		report "${name}: (l) the inode the first arm ran from now holds [$(read_bytes "${held}/0")]"
	[ "${live}" -ef "${deps}" ] ||
		report "${name}: (l) the live path is not the same inode as deps/"
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (l) left over: ${leftover}"
	verdict "${name}: (l) a refused swap stops the lane before the next arm" "${before}"
}

check_refused_stale_removal() {
	local name="$1" lane="$2" before rc leftover
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.stale" || return 0
	before="${failures}"
	kill_while_staged "${name}" l
	assert_original_in_backup "${name}" l
	: >"${ledger}"
	run_lane rm
	echo "NOTE: ${name} with the stale arm's removal refused exited ${rc}"
	grep -q 'stand-in rm: refused' "${output}" || report "${name}: (l) the removal was never tried"
	[ "${rc}" -ne 0 ] || report "${name}: (l) the lane exited 0 after the removal failed"
	grep -qF "the stale shim at ${live} could not be removed" "${output}" ||
		report "${name}: (l) the output does not name the path"
	[ ! -s "${ledger}" ] || report "${name}: (l) the lane ran the app over a stale arm"
	[ "${live}" -ef "${deps}" ] ||
		report "${name}: (l) the live path is not the same inode as deps/"
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (l) left over: ${leftover}"
	verdict "${name}: (l) a stale arm that cannot be removed stops the re-run" "${before}"
}

# The marker's half of the case above. The refused `rm` also stops the exit's
# removal, so what stays is the arm and its marker, for a later run to finish.
check_refused_stale_marker_removal() {
	local name="$1" lane="$2" before rc
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.stale-marker" || return 0
	before="${failures}"
	rm -f "${live}"
	kill_while_staged "${name}" l
	: >"${ledger}"
	run_lane rm
	echo "NOTE: ${name} with the marked arm's removal refused exited ${rc}"
	grep -q 'stand-in rm: refused' "${output}" || report "${name}: (l) the removal was never tried"
	[ "${rc}" -ne 0 ] || report "${name}: (l) the lane exited 0 after the removal failed"
	grep -qF "the stale shim at ${live} could not be removed" "${output}" ||
		report "${name}: (l) the output does not name the path"
	[ ! -s "${ledger}" ] || report "${name}: (l) the lane ran the app over a stale arm"
	[ -n "$(leftovers)" ] || report "${name}: (l) the marker a later run needs is gone"
	verdict "${name}: (l) a marked arm that cannot be removed stops the re-run" "${before}"

	before="${failures}"
	: >"${ledger}"
	run_lane
	assert_nothing_at_live "${name}" l "$(lane_arms "${name}")"
	verdict "${name}: (l) a run after a refused marked removal recovers" "${before}"
}

# A signal while staged: (m) ---------------------------------------------------
check_signal() {
	local name="$1" lane="$2" signal="$3" want_rc="$4" before rc arm leftover
	local sandbox sandbox_lane isonim target live deps trace ledger held
	build_fixture "${name}" "${lane}" "${work}/${name}.${signal}" || return 0
	before="${failures}"
	arm="$(first_arm "${name}")"
	run_lane "" "${signal}"
	echo "NOTE: ${name} after SIG${signal} exited ${rc}"
	[ "$(arms_seen)" = "${arm}" ] ||
		report "${name}: (m) the live path held [$(arms_seen)] while the lane ran, expected [${arm}]"
	[ "${rc}" -eq "${want_rc}" ] || report "${name}: (m) exited ${rc}, expected ${want_rc}"
	[ "${live}" -ef "${deps}" ] ||
		report "${name}: (m) after SIG${signal} the live path is not the same inode as deps/"
	leftover="$(leftovers)"
	[ -z "${leftover}" ] || report "${name}: (m) left over: ${leftover}"
	verdict "${name}: (m) SIG${signal} ends the lane, restored" "${before}"
}

# A pinned run after a kill: (o) -----------------------------------------------
check_pinned() {
	local name="$1" lane="$2" before rc arm backup
	local sandbox sandbox_lane isonim target live deps trace ledger held
	case "${name}" in
	plat42-frame-budget | plat44-edit-window) ;;
	*) return 0 ;;
	esac
	build_fixture "${name}" "${lane}" "${work}/${name}.pinned" || return 0
	before="${failures}"
	arm="$(first_arm "${name}")"
	kill_while_staged "${name}" o
	assert_original_in_backup "${name}" o
	backup="$(leftovers)"
	: >"${ledger}"
	run_lane "" "" 1
	echo "NOTE: ${name} (o) pinned run exited ${rc}"
	[ -s "${ledger}" ] || report "${name}: (o) the pinned run never ran its app"
	[ "$(read_bytes "${live}")" = "${arm}" ] ||
		report "${name}: (o) the pinned run left [$(read_bytes "${live}")] at the live path"
	[ "${backup}" -ef "${deps}" ] ||
		report "${name}: (o) the pinned run took the backup"
	verdict "${name}: (o) a pinned run leaves a killed run's state alone" "${before}"

	before="${failures}"
	: >"${ledger}"
	run_lane
	assert_recovered "${name}" o "$(lane_arms "${name}")"
	verdict "${name}: (o) a run after the pinned run recovers" "${before}"
}

# The library on its own: (n) --------------------------------------------------
# In subshells, because its state and its traps belong to one run. What a subshell
# exports is meant to stay in it.
# shellcheck disable=SC2030,SC2031
check_library() {
	local dir="${work}/library" shim before leftover
	shim="${dir}/live"
	mkdir -p "${dir}"
	printf 'stale arm\n' >"${shim}"
	printf 'original\n' >"${shim}.gpui-lane-backup"

	before="${failures}"
	(
		# shellcheck source=ci/lib/gpui-shim-stage.sh disable=SC1091
		source "${root}/ci/lib/gpui-shim-stage.sh"
		gpui_shim_restore
	) >"${output}" 2>&1 || report "(n) a restore that had nothing to do failed"
	[ "$(read_bytes "${shim}")" = 'stale arm' ] ||
		report "(n) a run that never staged left [$(read_bytes "${shim}")] at the live path"
	[ "$(read_bytes "${shim}.gpui-lane-backup")" = original ] ||
		report "(n) a run that never staged took the backup"
	verdict "library: (n) a run that never staged leaves a backup alone" "${before}"

	before="${failures}"
	rm -f "${shim}.gpui-lane-backup"
	printf 'original\n' >"${shim}"
	printf 'arm\n' >"${dir}/arm"
	(
		# shellcheck source=ci/lib/gpui-shim-stage.sh disable=SC1091
		source "${root}/ci/lib/gpui-shim-stage.sh"
		export PATH="${stand_ins}:${PATH}" STAGING_LIVE="${shim}" STAGING_REFUSE=mv
		if gpui_shim_stage "${shim}" "${dir}/arm"; then exit 3; fi
		[ "$(read_bytes "${shim}")" = original ] || exit 4
		STAGING_REFUSE=""
		gpui_shim_stage "${shim}" "${dir}/arm" || exit 5
		[ "$(read_bytes "${shim}")" = arm ] || exit 6
		gpui_shim_restore
	) >"${output}" 2>&1 || report "(n) the retried stage failed with status $?"
	[ "$(read_bytes "${shim}")" = original ] ||
		report "(n) after a retried stage the live path holds [$(read_bytes "${shim}")]"
	verdict "library: (n) a retried stage keeps the original" "${before}"

	# `rm` is refused for the marker only, so the arm's removal goes through first.
	before="${failures}"
	rm -f "${shim}"
	(
		# shellcheck source=ci/lib/gpui-shim-stage.sh disable=SC1091
		source "${root}/ci/lib/gpui-shim-stage.sh"
		export PATH="${stand_ins}:${PATH}" STAGING_LIVE="${shim}.gpui-lane-no-original" STAGING_REFUSE=rm
		gpui_shim_stage "${shim}" "${dir}/arm" || exit 3
		if gpui_shim_restore; then exit 4; fi
		[ -e "${shim}.gpui-lane-no-original" ] || exit 5
		STAGING_REFUSE=""
		gpui_shim_restore || exit 6
	) >"${output}" 2>&1 || report "(n) the marker's restore failed with status $?"
	grep -qF "failed to remove ${shim}.gpui-lane-no-original" "${output}" ||
		report "(n) the refused marker removal was not reported"
	[ ! -e "${shim}" ] && [ ! -e "${shim}.gpui-lane-no-original" ] ||
		report "(n) the retried restore left the arm or the marker"
	verdict "library: (n) a refused marker removal fails and can be retried" "${before}"

	# The real EXIT handler, so a real bash and not a subshell of this one.
	local status=0
	before="${failures}"
	printf 'original\n' >"${shim}"
	PATH="${stand_ins}:${PATH}" STAGING_LIVE="${shim}" STAGING_REFUSE=mv-to-live \
		bash -c 'source "$1"; gpui_shim_install_traps; gpui_shim_stage "$2" "$3" || exit 3; exit 23' \
		_ "${root}/ci/lib/gpui-shim-stage.sh" "${shim}" "${dir}/arm" >"${output}" 2>&1 || status=$?
	[ "${status}" -eq 23 ] || report "(n) a failed restore turned status 23 into ${status}"
	[ "$(read_bytes "${shim}.gpui-lane-backup")" = original ] ||
		report "(n) the refused restore lost the backup"
	verdict "library: (n) a failed restore keeps the lane's own status" "${before}"

	# The stand-in `rm` signals between the two removals, as a second Ctrl-C would.
	status=0
	before="${failures}"
	rm -f "${shim}" "${shim}.gpui-lane-backup"
	bash -c 'source "$1"; gpui_shim_install_traps; gpui_shim_stage "$2" "$3" || exit 3
		rm() { command rm "$@"; kill -TERM $$; sleep .01; }
		exit 0' \
		_ "${root}/ci/lib/gpui-shim-stage.sh" "${shim}" "${dir}/arm" >"${output}" 2>&1 || status=$?
	[ "${status}" -eq 0 ] || report "(n) a signal during the restore exited ${status}"
	[ ! -e "${shim}" ] && [ ! -e "${shim}.gpui-lane-no-original" ] ||
		report "(n) a signal stopped the restore between its removals"
	verdict "library: (n) a signal during the restore does not stop it" "${before}"

	# (p) What a run of a lane from before this library left when it was killed.
	before="${failures}"
	rm -f "${shim}" "${shim}".*
	printf 'stale arm\n' >"${shim}"
	printf 'original\n' >"${shim}.plat38-backup"
	(
		# shellcheck source=ci/lib/gpui-shim-stage.sh disable=SC1091
		source "${root}/ci/lib/gpui-shim-stage.sh"
		gpui_shim_stage "${shim}" "${dir}/arm" || exit 3
		[ "$(read_bytes "${shim}")" = arm ] || exit 4
		gpui_shim_restore || exit 5
	) >"${output}" 2>&1 || report "(p) staging over an old lane's backup failed with status $?"
	[ "$(read_bytes "${shim}")" = original ] ||
		report "(p) after the run the live path holds [$(read_bytes "${shim}")], not the old lane's backup"
	leftover="$(find "${dir}" -name 'live.*')"
	[ -z "${leftover}" ] || report "(p) left over: ${leftover}"
	verdict "library: (p) an old lane's backup is taken over as the original" "${before}"

	before="${failures}"
	rm -f "${shim}" "${shim}".*
	printf 'stale arm\n' >"${shim}"
	printf 'original\n' >"${shim}.plat38-backup"
	printf 'older arm\n' >"${shim}.plat42-backup"
	(
		# shellcheck source=ci/lib/gpui-shim-stage.sh disable=SC1091
		source "${root}/ci/lib/gpui-shim-stage.sh"
		if gpui_shim_stage "${shim}" "${dir}/arm"; then exit 3; fi
		gpui_shim_restore || exit 4
	) >"${output}" 2>&1 || report "(p) two old backups: the stage or the restore exited $?"
	local named
	for named in plat38 plat42; do
		grep -qF "${shim}.${named}-backup" "${output}" ||
			report "(p) the refusal does not name ${shim}.${named}-backup"
	done
	[ "$(read_bytes "${shim}")" = 'stale arm' ] &&
		[ "$(read_bytes "${shim}.plat38-backup")" = original ] &&
		[ "$(read_bytes "${shim}.plat42-backup")" = 'older arm' ] &&
		[ ! -e "${shim}.gpui-lane-backup" ] && [ ! -e "${shim}.gpui-lane-no-original" ] ||
		report "(p) a refused stage changed what it found"
	verdict "library: (p) two old backups are refused and left as they are" "${before}"
}

check_library

i=0
while [ "${i}" -lt "${#chosen_names[@]}" ]; do
	check_system_bash_parse "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_lane "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refusal "${chosen_names[${i}]}" "${chosen_paths[${i}]}" mv e "the move aside"
	check_refusal "${chosen_names[${i}]}" "${chosen_paths[${i}]}" cp f "staging"
	check_kill_rerun "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_no_original "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_no_original_kill "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refused_restore "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refused_removal "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refused_swap "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refused_stale_removal "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refused_stale_marker_removal "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_signal "${chosen_names[${i}]}" "${chosen_paths[${i}]}" TERM 143
	check_signal "${chosen_names[${i}]}" "${chosen_paths[${i}]}" INT 130
	check_pinned "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	i=$((i + 1))
done

# (h) needs both lanes of its pair.
killed_path=""
next_path=""
i=0
while [ "${i}" -lt "${#chosen_names[@]}" ]; do
	case "${chosen_names[${i}]}" in
	plat38-keystroke) killed_path="${chosen_paths[${i}]}" ;;
	plat42-frame-budget) next_path="${chosen_paths[${i}]}" ;;
	esac
	i=$((i + 1))
done
if [ -n "${killed_path}" ] && [ -n "${next_path}" ]; then
	check_kill_other_lane plat38-keystroke "${killed_path}" plat42-frame-budget "${next_path}"
else
	echo "NOTE: (h) needs plat38-keystroke and plat42-frame-budget together, so it did not run"
fi

[ "${failures}" -eq 0 ] || {
	echo "FAIL: ${failures} assertion(s) failed" >&2
	exit 1
}
