#!/usr/bin/env bash
# The GPUI shim gates of `ci/lib/build-freshness.sh`, and the macOS capture
# lane's refusals, over a stale shim and a dead app.
#
#   bash ci/test/plat37-shim-gate-test.sh                 # inside the dev shell
#   bash ci/test/plat37-shim-gate-test.sh --lane <path>   # another lane script
#
# `--lane` lets review run exactly these assertions against an unfixed lane.
#
# REAL: nim, cc, nm, git, the shipped ci/lib files, isonim-gpui's
# `tools/shim_input_digest.sh` and `tools/write_shim_stamp.sh`, and the lane
# script itself, run end to end in a sandbox workspace. The fixture app is a
# compiled Nim program that imports its shim through `{.dynlib.}`, as the
# front-end does, so the stale pair dies with the loader's own message. That
# death is the positive control for everything below it.
#
# STAND-INS, AND WHY: the sandbox's `plat37_macos_window_capture.nim` and
# `plat37_macos_window_grade.nim`. The real ones need a macOS GUI session, a
# kTCCServiceScreenCapture grant and a window to find, and no window can exist
# for an app that is meant to die. They reproduce only the lane-facing contract
# the lane's three controls and its refusal branch read: a host record, a
# refused record with exit 6, and a grader that passes only `--expect-blank`.
# The real driver's refusal text is asserted from its source below. `ffmpeg` is
# a stand-in on the lane's PATH too: the lane uses it only to synthesise the
# frame the stand-in grader never opens, and the macOS dev shell does not carry
# it, so the real one would turn this test into a test of the runner's PATH. `mv`
# is a stand-in that refuses a restore and is the real tool otherwise, because a
# read-only directory does not stop root and a CI container may run as root.
#
# The kill of the lane is real: the fixture app is the lane's direct child, so
# the app's `kills-lane` mode sends its parent a SIGKILL while the shim is staged.
# The SIGINT is real too: `timeout` is a stand-in that sends it to the lane, from
# the foreground child the lane is waiting for, and is the real tool otherwise.
# `ci/test/gpui-shim-staging-test.sh` holds the staging library to the rest of its
# rules; this lane is the one it cannot run, because it needs Darwin and a stamp.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lane="${root}/ci/test/plat37-macos-window-capture.sh"
if [ $# -gt 0 ]; then
	[ "$1" = --lane ] && [ $# -eq 2 ] || {
		echo "usage: $0 [--lane <path>]" >&2
		exit 2
	}
	lane="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
isonim_tools="${ISONIM_GPUI:-$(cd "${root}/.." && pwd)/isonim-gpui}/tools"
# shellcheck source=ci/lib/build-freshness.sh disable=SC1091
source "${root}/ci/lib/build-freshness.sh"

for tool in nim cc nm git python3; do
	command -v "${tool}" >/dev/null || {
		echo "FAIL: ${tool} is required. Run inside the dev shell." >&2
		exit 1
	}
done
for tool in shim_input_digest.sh write_shim_stamp.sh; do
	[ -f "${isonim_tools}/${tool}" ] || {
		echo "FAIL: ${isonim_tools}/${tool} is required: the digest and the stamp" >&2
		echo "  are isonim-gpui's, and a copy here could agree with itself." >&2
		exit 1
	}
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export CODETRACER_HOME="${work}/home"
failures=0
output="${work}/output"

report() {
	failures=$((failures + 1))
	echo "FAIL: $*" >&2
}
pass() { echo "PASS: $*"; }
# One verdict per case, printing what the case saw when it failed.
verdict() {
	local name="$1" before="$2"
	if [ "${failures}" -eq "${before}" ]; then
		pass "${name}"
	else
		sed 's/^/    /' "${output}" >&2
	fi
}
says() {
	grep -qF -- "$2" "${output}" || report "$1: output lacks: $2"
}
denies() {
	if grep -qF -- "$2" "${output}"; then report "$1: output carries: $2"; fi
}

case "$(uname -s)" in
Darwin) ext=dylib shared=(-dynamiclib) ;;
*) ext=so shared=(-shared -fPIC) ;;
esac

ws="${work}/ws"
sandbox="${ws}/codetracer"
isonim="${ws}/isonim-gpui"
live="${isonim}/rust/target/debug/libgpui_nim_shim.${ext}"
staged="${isonim}/rust/target/plat37/libgpui_nim_shim.windowed.${ext}"
stamp="${isonim}/rust/target/plat37/windowed.build-stamp"
remedy='  run the remedy'

# build_lib <output> <exported-name>...
build_lib() {
	local lib="$1" name
	shift
	# The lane's font-kit probe greps for this literal before it reaches the
	# gates under test.
	printf 'const char font_kit_build[] = "font_kit";\n' >"${work}/lib.c"
	for name in "$@"; do printf 'void %s(void) {}\n' "${name}" >>"${work}/lib.c"; done
	cc "${shared[@]}" -o "${lib}" "${work}/lib.c"
}
# build_literals <output> <literal>... — a real program holding these strings.
build_literals() {
	local exe="$1" text
	shift
	{
		printf '#include <stdio.h>\nint main(void) {\n'
		for text in "$@"; do printf '  puts("%s");\n' "${text}"; done
		printf '  return 0;\n}\n'
	} >"${work}/literals.c"
	cc -o "${exe}" "${work}/literals.c"
}

current="${work}/current.${ext}"
stale="${work}/stale.${ext}"
extra="${work}/extra.${ext}"
unrelated="${work}/unrelated.${ext}"
build_lib "${current}" gpui_launch gpui_set_window_activated_dispatcher
build_lib "${stale}" gpui_launch
build_lib "${extra}" gpui_launch gpui_set_window_activated_dispatcher gpui_render_to_pixels
build_lib "${unrelated}" something_else

# The sandbox workspace ------------------------------------------------------
mkdir -p "${sandbox}/src/frontend/gpui" "${sandbox}/src/tests/visual" \
	"${sandbox}/build/bin" "${sandbox}/ci/test" "${sandbox}/ci/lib" \
	"${isonim}/tools" "${isonim}/rust/gpui-nim-shim/src" \
	"$(dirname "${live}")" "$(dirname "${staged}")" "${work}/trace"
cp "${root}/ci/lib/build-freshness.sh" "${root}/ci/lib/gpui-shim-stage.sh" \
	"${root}/ci/lib/sha256.sh" "${sandbox}/ci/lib/"
# Named through a variable so that `shell-gate-coverage.sh` does not credit the
# real capture lane as run: this copy runs against the stand-ins described above.
sandbox_lane="${sandbox}/ci/test/$(basename "${lane}")"
cp "${lane}" "${sandbox_lane}"
cp "${root}/src/tests/visual/scenarios.json" "${sandbox}/src/tests/visual/"
cat >"${sandbox}/${BF_GPUI_ENTRY}" <<NIM
import std/[os, posix]
proc gpui_launch() {.importc: "gpui_launch", cdecl, dynlib: "${live}".}
proc gpui_set_window_activated_dispatcher()
  {.importc: "gpui_set_window_activated_dispatcher", cdecl, dynlib: "${live}".}
case getEnv("PLAT37_TEST_APP")
of "dies":
  stderr.writeLine("an incompatibility no gate has heard of")
  quit(3)
of "logs":
  stderr.writeLine("the app says the display went away")
of "silent":
  discard
of "kills-lane":
  discard kill(getppid(), SIGKILL)
else:
  gpui_launch()
  gpui_set_window_activated_dispatcher()
NIM
args=()
while IFS= read -r arg; do args+=("${arg}"); done < <(bf_gpui_nim_args)
(cd "${sandbox}" && nim c --hints:off --warnings:off "${args[@]}" \
	--nimcache:"${work}/app-cache" -o:"${sandbox}/${BF_GPUI_BIN}" "${BF_GPUI_ENTRY}")
unset BF_BUILDER
bf_gpui_write_stamp "${sandbox}" >/dev/null
bin="${sandbox}/${BF_GPUI_BIN}"

cp "${isonim_tools}/shim_input_digest.sh" "${isonim_tools}/write_shim_stamp.sh" "${isonim}/tools/"
printf 'rust/target\n' >"${isonim}/.gitignore"
for f in rust/Cargo.toml rust/Cargo.lock rust/gpui-nim-shim/Cargo.toml \
	rust/gpui-nim-shim/src/lib.rs flake.nix flake.lock Justfile; do
	printf 'fixture %s\n' "${f}" >"${isonim}/${f}"
done
git -C "${isonim}" init -q
git -C "${isonim}" add -A
commit_fixture() {
	git -C "${isonim}" -c user.name=test -c user.email=test@example.invalid \
		-c commit.gpgsign=false commit -qm "$1"
}
commit_fixture fixture

# stage <shim>: what `just plat37-shims` leaves behind, through its own tools.
stage() {
	cp "$1" "${staged}"
	SHIM_BUILT_BY="$(cc --version | head -1)" \
		bash "${isonim}/tools/write_shim_stamp.sh" "${stamp}" "${staged}" \
		"$(bash "${isonim}/tools/shim_input_digest.sh" "${isonim}")" windowed
}

# The positive control: the issue's own failure, from the real loader ---------
before="${failures}"
cp "${stale}" "${live}"
rc=0
"${bin}" >"${output}" 2>&1 || rc=$?
[ "${rc}" -ne 0 ] || report 'the stale pair loaded'
says 'stale pair' 'could not import: gpui_set_window_activated_dispatcher'
# Unlinked first: overwriting a library that was mapped can kill the next loader
# with SIGKILL (Code Signature Invalid). The lane's staging explains it.
rm -f "${live}"
cp "${current}" "${live}"
rc=0
"${bin}" >"${output}" 2>&1 || rc=$?
[ "${rc}" -eq 0 ] || report "the current pair did not load (rc ${rc})"
verdict 'the stale pair dies in the loader and the current pair loads' "${before}"

# The pair gate --------------------------------------------------------------
pair() { bf_gpui_shim_assert_compatible "$1" "$2" "${remedy}" >"${output}" 2>&1; }

before="${failures}"
if pair "${bin}" "${stale}"; then report 'a binary was accepted with a shim that lacks its import'; fi
says 'stale pair' '    gpui_set_window_activated_dispatcher'
says 'stale pair' "binary: ${bin}"
says 'stale pair' "shim:   ${stale}"
says 'stale pair' "${remedy}"
verdict 'a missing import is refused by name, with both artefacts and the remedy' "${before}"

before="${failures}"
pair "${bin}" "${current}" || report 'the current pair was refused'
says 'current pair' 'exports all 2 gpui_ names'
pair "${bin}" "${extra}" || report 'a shim exporting more than is imported was refused'
says 'wider shim' 'exports all 2 gpui_ names'
says 'wider shim' '(3 exported)'
verdict 'a shim exporting everything imported passes, extras included' "${before}"

build_literals "${work}/no-names" 'nothing to see'
build_literals "${work}/prose-only" 'gpui_launch failed to start'
build_literals "${work}/no-launch" 'gpui_other'
build_literals "${work}/with-prose" 'gpui_launch' 'gpui_phantom failed'
printf 'not an object file\n' >"${work}/garbage.${ext}"

before="${failures}"
for empty in no-names prose-only no-launch; do
	if pair "${work}/${empty}" "${current}"; then report "${empty}: a vacuous scan passed"; fi
	says "${empty}" 'nothing was compared'
done
if pair "${bin}" "${unrelated}"; then report 'a shim with no gpui_ exports passed'; fi
says 'no exports' 'nothing was compared'
verdict 'a scan that matched nothing is refused, not read as nothing missing' "${before}"

before="${failures}"
pair "${work}/with-prose" "${stale}" || report 'a message spelled like a symbol was read as an import'
says 'prose' 'exports all 1 gpui_ names'
verdict 'a message that starts with a symbol name is not an import' "${before}"

before="${failures}"
if pair "${bin}" "${work}/garbage.${ext}"; then report 'an unreadable shim passed'; fi
says 'garbage' 'could not be read'
if pair "${bin}" "${work}/absent.${ext}"; then report 'an absent shim passed'; fi
says 'absent shim' 'could not be read'
if pair "${work}/absent" "${current}"; then report 'an absent binary passed'; fi
says 'absent binary' 'could not be read'
verdict 'an artefact that cannot be read is refused' "${before}"

# The shim's stamp -----------------------------------------------------------
fresh() { bf_gpui_shim_assert_fresh "${isonim}" "${stamp}" "${staged}" "${remedy}" >"${output}" 2>&1; }

before="${failures}"
stage "${current}"
fresh || report 'a freshly stamped shim was refused'
says 'fresh' 'WINDOWED SHIM'
verdict 'a shim stamped from this tree passes' "${before}"

before="${failures}"
printf 'edit\n' >>"${isonim}/rust/gpui-nim-shim/src/lib.rs"
if fresh; then report 'a changed input passed'; fi
says 'changed input' 'built from different sources'
git -C "${isonim}" checkout -q rust/gpui-nim-shim/src/lib.rs
fresh || report 'restoring the input did not clear the refusal'
verdict 'a changed shim input is refused' "${before}"

# A shim is routinely built before its source is committed, and landing that
# same source must not call it stale: index state is not an input.
before="${failures}"
printf 'uncommitted\n' >>"${isonim}/rust/gpui-nim-shim/src/lib.rs"
stage "${current}"
fresh || report 'a shim stamped from a modified tree was refused'
git -C "${isonim}" add -A
fresh || report 'staging the source it was built from refused the shim'
commit_fixture 'the source the shim was built from'
fresh || report 'committing the source it was built from refused the shim'
git -C "${isonim}" reset -q --hard HEAD~1
if fresh; then report 'a shim of a source this tree no longer has passed'; fi
says 'reverted' 'built from different sources'
stage "${current}"
verdict 'staging and committing what the shim was built from leaves it fresh' "${before}"

before="${failures}"
cp "${stamp}" "${work}/stamp"
rm "${stamp}"
if fresh; then report 'an unstamped shim passed'; fi
says 'no stamp' 'carries no freshness stamp'
cp "${work}/stamp" "${stamp}"
cp "${extra}" "${staged}"
if fresh; then report 'a replaced shim passed'; fi
says 'replaced' 'stamp does not describe the artefact'
stage "${current}"
mv "${isonim}/tools/shim_input_digest.sh" "${work}/digest.sh"
if fresh; then report 'a tree with no digest script passed'; fi
says 'no script' 'shim_input_digest.sh does not exist'
mv "${work}/digest.sh" "${isonim}/tools/shim_input_digest.sh"
verdict 'a missing stamp, a replaced shim and a missing digest script are refused' "${before}"

# The real driver's refusal text. Its window lookup cannot be reached without
# the grant, so this reads the source of the one message that matters.
before="${failures}"
cp "${root}/ci/test/plat37_macos_window_capture.nim" "${output}"
denies 'driver' 'The front-end did not open'
says 'driver' 'That is the observation and not a cause'
verdict 'the capture driver names what it observed and no cause' "${before}"

# The lane, end to end -------------------------------------------------------
if [ "$(uname -s)" != Darwin ]; then
	echo "NOTE: the lane cases need Darwin, as the lane does; the library cases above ran."
	[ "${failures}" -eq 0 ] || exit 1
	exit 0
fi
command -v timeout >/dev/null || {
	echo "FAIL: timeout is required by the lane. Run inside the dev shell." >&2
	exit 1
}

cat >"${sandbox}/ci/test/plat37_macos_window_capture.nim" <<'NIM'
# Stand-in: see the test's header. Answers the lane's control 1 and refuses
# every capture exactly as the real driver does when no window appears.
import std/[json, os, strutils]
var record = ""
for arg in commandLineParams():
  if arg.startsWith("--record="): record = arg["--record=".len .. ^1]
if paramStr(1) == "host":
  writeFile(record, "{}")
  quit(0)
writeFile(record, $ %*{"outcome": "refused", "attestation": {"matched": 0},
                       "refusal": "stand-in: no window"})
quit(6)
NIM
cat >"${sandbox}/ci/test/plat37_macos_window_grade.nim" <<'NIM'
# Stand-in: see the test's header. Control 3 needs its two arms to differ.
import std/os
quit(if "--expect-blank" in commandLineParams(): 0 else: 1)
NIM

mkdir "${work}/stand-ins"
cat >"${work}/stand-ins/ffmpeg" <<'SH'
#!/bin/sh
# Stand-in: see the test's header. Writes the file named last.
for output; do :; done
: >"${output}"
SH
cat >"${work}/stand-ins/mv" <<SH
#!/bin/sh
# Stand-in: see the test's header.
if [ "\$3" = "\${PLAT37_REFUSE_MV_TO:-}" ]; then
	echo 'stand-in mv: refused' >&2
	exit 1
fi
exec "$(command -v mv)" "\$@"
SH
cat >"${work}/stand-ins/timeout" <<SH
#!/bin/sh
# Stand-in: see the test's header. Only once the backup shows the shim is staged.
if [ -n "\${PLAT37_INTERRUPT_LANE:-}" ] && [ -e "${live}.gpui-lane-backup" ]; then
	kill -INT "\${PPID}"
fi
exec "$(command -v timeout)" "\$@"
SH
chmod +x "${work}/stand-ins/ffmpeg" "${work}/stand-ins/mv" "${work}/stand-ins/timeout"

out="${work}/lane-out"
driver="${sandbox}/build/plat37_macos_window_capture"
rm -f "${live}"
printf 'the build the operator had in place\n' >"${live}"
# As cargo leaves it: the uplifted file is a hardlink to its `deps/` output.
cargo_output="$(dirname "${live}")/deps-copy-of-the-shim"
ln "${live}" "${cargo_output}"

run_lane() {
	local app="$1"
	lane_rc=0
	rm -rf "${out}" "${driver}" "${sandbox}/build/plat37_macos_window_grade"
	# The group's redirection is for bash's own `Killed: 9` notice about the lane.
	{
		PATH="${work}/stand-ins:${PATH}" PLAT37_TEST_APP="${app}" ISONIM_GPUI="${isonim}" \
			CODETRACER_PLAT37_TRACE="${work}/trace" REPLAY_SERVER_BIN=/usr/bin/true \
			CODETRACER_PLAT37_SETTLE_S=0 CODETRACER_PLAT37_WAIT_MS=0 \
			bash "${sandbox_lane}" --only shell --out "${out}" >"${output}" 2>&1 || lane_rc=$?
	} 2>/dev/null
}
# The operator's shim is back, and a scenario log shows the lane really ran one.
assert_restored() {
	grep -q 'the build the operator had in place' "${live}" ||
		report "$1: the operator's shim was not restored"
	[ "${live}" -ef "${cargo_output}" ] || report "$1: the shim's hardlink to cargo's output was broken"
	grep -q 'the build the operator had in place' "${cargo_output}" ||
		report "$1: staging wrote through the hardlink into cargo's output"
	[ -f "${out}/shell.gpui.log" ] || report "$1: no scenario ran"
}

before="${failures}"
stage "${stale}"
run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'a: the lane accepted a stale shim'
says 'a' 'gpui_set_window_activated_dispatcher'
says 'a' "${bin}"
says 'a' "${staged}"
says 'a' 'just plat37-shims'
grep -q 'the build the operator had in place' "${live}" || report 'a: the stale shim was staged'
backup="${live}.gpui-lane-backup"
[ ! -e "${backup}" ] || report 'a: a backup was taken for a staging that must not happen'
[ ! -e "${live}.gpui-lane-no-original" ] || report 'a: a marker was left for a staging that must not happen'
[ ! -e "${out}/shell.gpui.log" ] || report 'a: a scenario ran'
[ ! -e "${driver}" ] || report 'a: the capture driver was built before the refusal'
verdict 'lane: a shim that lacks an import refuses before anything is staged' "${before}"

# A really stale shim is stale in both senses, and a shim built before stamps
# existed has none, so the symbol must not depend on the stamp gate passing.
before="${failures}"
stage "${stale}"
printf 'edit\n' >>"${isonim}/rust/gpui-nim-shim/src/lib.rs"
run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'a2: the lane accepted a stale shim of an older tree'
says 'a2' 'gpui_set_window_activated_dispatcher'
git -C "${isonim}" checkout -q rust/gpui-nim-shim/src/lib.rs
rm "${stamp}"
run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'a2: the lane accepted an unstamped stale shim'
says 'a2' 'gpui_set_window_activated_dispatcher'
verdict 'lane: the missing symbol is named whatever the stamp says' "${before}"

before="${failures}"
stage "${current}"
printf 'edit\n' >>"${isonim}/rust/gpui-nim-shim/src/lib.rs"
run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'b: the lane accepted a shim older than its tree'
says 'b' 'STALE WINDOWED SHIM: built from different sources'
[ ! -e "${out}/shell.gpui.log" ] || report 'b: a scenario ran'
git -C "${isonim}" checkout -q rust/gpui-nim-shim/src/lib.rs
verdict 'lane: a loadable shim older than its tree refuses' "${before}"

before="${failures}"
stage "${current}"
run_lane dies
[ "${lane_rc}" -ne 0 ] || report 'c: the lane passed a dead app'
says 'c' 'SHIM PAIR: the shim exports all 2 gpui_ names'
says 'c' '| an incompatibility no gate has heard of'
says 'c' 'lines of '
says 'c' 'did not shut down cleanly'
assert_restored 'c'
verdict 'lane: an app that dies for a new reason is quoted, not diagnosed' "${before}"

before="${failures}"
run_lane logs
[ "${lane_rc}" -ne 0 ] || report 'd: the lane passed a refused scenario'
says 'd' 'refused (rc 6)'
says 'd' '| the app says the display went away'
says 'd' '1 of 1 scenarios did not produce a graded frame'
assert_restored 'd'
python3 - "${out}" "${stamp}" <<'PY' || report 'd: the census does not hold the cause'
import json, sys
out, stamp = sys.argv[1:]
record = json.loads(open(f"{out}/records.jsonl").read().splitlines()[0])
assert record["appLog"] == ["the app says the display went away"], record
shim = json.load(open(f"{out}/manifest.json"))["subject"]["shim"]
fields = dict(ln.strip().split("=", 1) for ln in open(stamp) if "=" in ln)
assert shim["stampInputDigest"] == fields["input_digest"], shim
assert shim["stampBuiltAt"] == fields["built_at"], shim
assert (shim["importedSymbols"], shim["exportedSymbols"]) == (2, 2), shim
PY
verdict 'lane: a refused scenario quotes the app and the census keeps it' "${before}"

before="${failures}"
run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'e: the lane passed a refused scenario'
says 'e' 'refused (rc 6)'
says 'e' 'the app wrote nothing to'
says 'e' 'no cause is established'
denies 'e' 'what the app wrote'
assert_restored 'e'
python3 - "${out}" <<'PY' || report 'e: the census invented a log'
import json, sys
record = json.loads(open(f"{sys.argv[1]}/records.jsonl").read().splitlines()[0])
assert record["appLog"] == [], record
PY
verdict 'lane: a silent app is reported as silent, with no cause offered' "${before}"

# The kill's own result is the control: the re-run below has something to keep.
before="${failures}"
run_lane kills-lane
[ "${lane_rc}" -eq 137 ] || report "f: the lane exited ${lane_rc}, not by the SIGKILL"
cmp -s "${staged}" "${live}" || report 'f: the kill did not leave the arm at the live path'
[ "${backup}" -ef "${cargo_output}" ] || report "f: the kill did not leave cargo's inode in the backup"
run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'f: the lane passed a refused scenario'
says 'f' "kept the original shim at ${backup}"
assert_restored 'f'
[ ! -e "${backup}" ] || report 'f: the backup remains'
verdict 'lane: a run after a SIGKILL keeps the backup and restores it' "${before}"

# The scenario is refused here whatever the restore does, so the status cannot
# show that the restore alone fails the lane: `says` is what ties this to it.
before="${failures}"
PLAT37_REFUSE_MV_TO="${live}" run_lane silent
[ "${lane_rc}" -ne 0 ] || report 'g: the lane exited 0 after its restore failed'
says 'g' 'stand-in mv: refused'
says 'g' "failed to restore ${live}; backup remains at ${backup}"
says 'g' 'restoring the capture shim failed'
grep -q 'the build the operator had in place' "${backup}" || report 'g: the backup lost the original'
cmp -s "${staged}" "${live}" || report 'g: the arm did not stay at the live path'
run_lane silent
assert_restored 'g'
[ ! -e "${backup}" ] || report 'g: the backup remains after a later run'
verdict 'lane: a refused restore names the backup, and a later run recovers' "${before}"

# A SIGINT from the foreground child, and not a SIGTERM from the app, because the
# status is then the control. Without the lane's signal traps a SIGTERM still exits
# 143 through its EXIT trap, and bash ignores a SIGINT sent to it alone once the
# child it waits for has exited normally, so the lane would run on and refuse.
before="${failures}"
PLAT37_INTERRUPT_LANE=1 run_lane silent
[ "${lane_rc}" -eq 130 ] || report "h: a SIGINT while staged exited ${lane_rc}, not 130"
assert_restored 'h'
[ ! -e "${backup}" ] || report 'h: the backup remains'
verdict 'lane: a SIGINT while staged ends the lane, restored' "${before}"

[ "${failures}" -eq 0 ] || {
	echo "FAIL: ${failures} assertion(s) failed" >&2
	exit 1
}
