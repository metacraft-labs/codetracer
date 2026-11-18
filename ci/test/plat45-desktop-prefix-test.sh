#!/usr/bin/env bash
# plat45-desktop-prefix-test.sh — the contract suite for
# `scripts/plat45-desktop-prefix.sh`'s choice of the built `ct`.
#
# Every desktop capture lane (`scripts/plat4[5-9]-capture-electron.sh`,
# `plat5[0-2]-…`) assembles its prefix with that script, and the prefix copies
# the `ct` of an existing build. The script used to read it from
# `src/build-debug/bin/ct` alone. On a host whose dev shell builds elsewhere
# (`CODETRACER_BUILD_DIR`, e.g. `src/build-debug-repro` on macOS) the lane
# died there, and it died SILENTLY: the lookup was a `readlink -f` inside a
# command substitution under `set -euo pipefail`, so the shell exited before
# the script's own "no built ct" message could run. The capture recipe then
# exited 1 straight after recording its fixture, with nothing on stderr.
#
# Three arms, each over a scratch checkout that carries the REAL script:
#   (a) the only `ct` is under `$CODETRACER_BUILD_DIR/bin`: the prefix is
#       assembled and its `bin/ct` is a copy of that one;
#   (b) no `ct` anywhere: the script fails, and says so on stderr, naming the
#       path it looked at;
#   (c) `CODETRACER_BUILD_DIR` unset and a `ct` in `src/build-debug/bin`: the
#       default is unchanged.
#
# Why a fake `nim` (the one stand-in here): the script compiles this checkout's
# desktop JavaScript after it has chosen the `ct`, and that takes minutes and a
# dev shell. Nothing under test depends on what the compiler produces, only on
# the script reaching it and then assembling the prefix, so `nim` is replaced by
# a stub that writes the `--out:` file it was asked for. Everything else — the
# script, the Tuprules flag extraction, the mirroring and copying — is the real
# code on the real filesystem. Pure bash + python3 over mktemp; no nix, no
# network, no build.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/scripts/plat45-desktop-prefix.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}

# The stub compiler: write the file named by `--out:` and succeed.
mkdir -p "$work/stub-bin"
cat >"$work/stub-bin/nim" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
	case "$arg" in
	--out:*) out="${arg#--out:}" ;;
	esac
done
[ -n "${out:-}" ] || { echo "stub nim: no --out: given" >&2; exit 2; }
echo "// stub output" >"$out"
SH
chmod +x "$work/stub-bin/nim"

# A scratch checkout with what the script reads, and nothing it does not.
make_checkout() {
	local root="$1"
	mkdir -p "$root/scripts" "$root/src/config" "$root/src/frontend" \
		"$root/libs/nim-chronicles"
	cp "$script" "$root/scripts/plat45-desktop-prefix.sh"
	: >"$root/libs/nim-chronicles/chronicles.nim"
	echo "theme: default_dark" >"$root/src/config/default_config.yaml"
	echo '{}' >"$root/src/config/default_layout.json"
	cat >"$root/src/Tuprules.tup" <<'TUP'
NIM_COMMON_FLAGS = --hints:off
NIM_REPO_PATH_FLAGS = --path:$(ROOT)/libs/nim-chronicles
NIM_DEBUG_FLAGS = -d:debug
TUP
}

# A built variant: a `ct` that names itself, plus the directories the script
# mirrors.
make_build() {
	local base="$1" tag="$2"
	mkdir -p "$base/bin" "$base/src" "$base/public"
	printf '#!/bin/sh\necho %s\n' "$tag" >"$base/bin/ct"
	chmod +x "$base/bin/ct"
}

# run_script <checkout> <stderr-file> [VAR=value ...]: run the copied script
# with the stub `nim` first on PATH and CODETRACER_BUILD_DIR cleared unless
# given. Prints the exit status.
run_script() {
	local root="$1" err="$2"
	shift 2
	local rc=0
	env -u CODETRACER_BUILD_DIR PATH="$work/stub-bin:$PATH" "$@" \
		bash "$root/scripts/plat45-desktop-prefix.sh" "$root/prefix" \
		>"$err.out" 2>"$err" || rc=$?
	echo "$rc"
}

# (a) Only $CODETRACER_BUILD_DIR/bin/ct exists.
a="$work/a"
make_checkout "$a"
make_build "$a/src/build-debug-repro" "the-build-dir-ct"
rc="$(run_script "$a" "$work/a.err" CODETRACER_BUILD_DIR="$a/src/build-debug-repro")"
if [ "$rc" != 0 ]; then
	fail "(a) with ct only under \$CODETRACER_BUILD_DIR the script exited $rc; stderr: '$(cat "$work/a.err")'"
elif ! cmp -s "$a/prefix/bin/ct" "$a/src/build-debug-repro/bin/ct"; then
	fail "(a) the prefix's bin/ct is not a copy of \$CODETRACER_BUILD_DIR/bin/ct"
elif [ -L "$a/prefix/bin/ct" ]; then
	fail "(a) the prefix's bin/ct is a symlink; the script must copy it"
else
	echo "ok   (a) ct is taken from the CODETRACER_BUILD_DIR build"
fi

# (b) No ct at all: a non-zero exit, and a message naming where it looked.
b="$work/b"
make_checkout "$b"
rc="$(run_script "$b" "$work/b.err" CODETRACER_BUILD_DIR="$b/src/build-debug-repro")"
if [ "$rc" = 0 ]; then
	fail "(b) with no ct the script exited 0"
elif ! grep -q "no built ct" "$work/b.err"; then
	fail "(b) with no ct the script exited $rc SILENTLY (stderr: '$(cat "$work/b.err")'); it must say there is no built ct"
elif ! grep -qF "$b/src/build-debug-repro/bin/ct" "$work/b.err"; then
	fail "(b) the message does not name the path it looked at: '$(cat "$work/b.err")'"
else
	echo "ok   (b) a missing ct fails with a message naming $b/src/build-debug-repro/bin/ct"
fi

# (c) Unset CODETRACER_BUILD_DIR: the default src/build-debug is still used.
c="$work/c"
make_checkout "$c"
make_build "$c/src/build-debug" "the-default-ct"
rc="$(run_script "$c" "$work/c.err")"
if [ "$rc" != 0 ]; then
	fail "(c) with ct in src/build-debug and no CODETRACER_BUILD_DIR the script exited $rc; stderr: '$(cat "$work/c.err")'"
elif ! cmp -s "$c/prefix/bin/ct" "$c/src/build-debug/bin/ct"; then
	fail "(c) the prefix's bin/ct is not a copy of src/build-debug/bin/ct"
else
	echo "ok   (c) the default src/build-debug is unchanged"
fi

if [ "$failures" -gt 0 ]; then
	echo "plat45-desktop-prefix-test: $failures failure(s)" >&2
	exit 1
fi
echo "plat45-desktop-prefix-test: all 3 arms passed"
