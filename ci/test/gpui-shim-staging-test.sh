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
# the shim back, so that the hardlink survives the run.
#
# macOS cargo copies the uplifted file instead (measured with cargo 1.96 on
# 2026-11-01; https://github.com/rust-lang/cargo/issues/10060), so no real macOS
# tree has this hardlink. The fixture builds it on both hosts all the same, so
# that a macOS run of this test can catch a write-through as a Linux run can.
#
# Each lane is held to six things:
#   (a) a stand-in saw the arm's bytes at the live path while the lane ran. This
#       is the positive control: a lane that exits before staging fails here,
#       because every other assertion would hold over a lane that did nothing.
#   (b) `deps/` held cargo's bytes while staged, and still does after exit.
#   (c) after exit the live path is the same inode as `deps/`, and no `*-backup`
#       file remains.
#   (d) a lane that swaps arms keeps (b) and (c) across the swaps, and each arm
#       it replaced still holds that arm's bytes: a swap unlinks the previous
#       arm and does not copy over the inode a running app has mapped.
#   (e) when the move aside fails, the lane stops, and cargo's file is untouched.
#       `cp -f` still succeeds in that state and writes through the hardlink: a
#       read-only directory does exactly this, and three lanes used to exit 0.
#   (f) when staging fails, the lane stops, and cargo's file is back in place.
#   Both also require the stand-in's refusal in the lane's output, so a lane that
#   stopped earlier for another reason does not count as having stopped here.
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
#   - `mv` and `cp` on PATH, which refuse the one staging step that (e) or (f)
#     names and are the real tools for everything else. A read-only directory
#     would make the same failure with no stand-in, but root ignores it, and a CI
#     container may run as root.
#   - The fixture's `scripts/wayland-run-test.sh`, the app at `build/bin`, and
#     `nim` are one observer. They are what a lane runs while a shim is staged,
#     so that is where the bytes are read. The compositor harness does not run
#     the inner `--inside` pass, because that pass only sleeps for a window that
#     cannot open here; it writes the empty records file the plat37 lane checks
#     for so that the lane goes on to its next arm. `nim` stands for the headless
#     probe, and the lane then stops on the probe's missing answer, after its
#     last swap. Reaching that failure is expected, so a lane's exit status is
#     reported and not asserted.
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

# The arms in the order the lane puts them at the live path, adjacent repeats
# collapsed. plat37 goes back to `windowed` for its compositor probes.
lane_arms() {
	case "$1" in
	plat35-gpui-capture) echo "arm:headless" ;;
	plat37-window-frame) echo "arm:windowed arm:featureless arm:windowed arm:headless" ;;
	*) echo "arm:windowed" ;;
	esac
}

cargo_bytes='cargo output of the shim'

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
# The lanes spell these `mv -f <from> <to>` and `cp -f <from> <to>`, so the
# position says which step this is: the move aside takes the live path as its
# source, and staging takes it as its destination.
refusing_tool() {
	local tool="$1" live_arg="$2" real
	real="$(command -v "${tool}")"
	cat >"${stand_ins}/${tool}" <<SH
#!/bin/sh
# Stand-in: see the test's header.
if [ "\${STAGING_REFUSE:-}" = "${tool}" ] && [ "\$${live_arg}" = "\${STAGING_LIVE:-}" ]; then
	echo "stand-in ${tool}: refused" >&2
	exit 1
fi
exec "${real}" "\$@"
SH
}
refusing_tool mv 2
refusing_tool cp 3

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

# Runs the fixture's lane, and sets `rc`. `$1` names the tool that refuses its
# staging step, if any.
#
# The variables below select another binary, shim or trace, or a pinned binary
# that leaves the shared shim alone, and any of them would bypass staging.
run_lane() {
	rc=0
	env -u CODETRACER_WINDOW_BIN_PINS_SHIM -u CODETRACER_PLAT42_BIN \
		-u CODETRACER_PLAT42_WINDOWED_SHIM -u CODETRACER_PLAT44_BIN \
		PATH="${stand_ins}:${PATH}" ISONIM_GPUI="${isonim}" ISONIM_GPUI_DIR="${isonim}" \
		CODETRACER_PLAT35_TRACE="${trace}" CODETRACER_PLAT37_TRACE="${trace}" \
		CODETRACER_PLAT38_TRACE="${trace}" \
		STAGING_LEDGER="${ledger}" STAGING_HELD="${held}" STAGING_LIVE="${live}" \
		STAGING_DEPS="${deps}" STAGING_PLAT37_OUT="${sandbox}/build/plat37" \
		STAGING_REFUSE="${1:-}" \
		bash "${sandbox_lane}" >"${output}" 2>&1 || rc=$?
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
	saw="$(cut -f2 "${ledger}" | uniq | paste -sd' ' -)"
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
	leftover="$(find "$(dirname "${live}")" -name '*-backup')"
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
	leftover="$(find "$(dirname "${live}")" -name '*-backup')"
	[ -z "${leftover}" ] || report "${name}: (${label}) a backup remains: ${leftover}"
	verdict "${name}: (${label}) the lane stops when ${step} fails, and cargo's file survives" \
		"${before}"
}

i=0
while [ "${i}" -lt "${#chosen_names[@]}" ]; do
	check_lane "${chosen_names[${i}]}" "${chosen_paths[${i}]}"
	check_refusal "${chosen_names[${i}]}" "${chosen_paths[${i}]}" mv e "the move aside"
	check_refusal "${chosen_names[${i}]}" "${chosen_paths[${i}]}" cp f "staging"
	i=$((i + 1))
done

[ "${failures}" -eq 0 ] || {
	echo "FAIL: ${failures} assertion(s) failed" >&2
	exit 1
}
