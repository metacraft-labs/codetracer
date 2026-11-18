#!/usr/bin/env bash
# build-once.sh uses a sibling reprobuild checkout's own `build/bin/repro` only
# while that build is fit to serve this repository, and always says which
# `repro` it ran.
#
# The workspace checks reprobuild out beside codetracer by design, so the
# sibling's `build/bin/repro` used to win whenever one existed, with no check
# and no statement. A `repro 0.2.6` built 13 days earlier then refused the
# committed lock with "unsupported lock schema … v3 (expected … v2)" while the
# pinned `repro 0.2.19` on PATH read it without complaint, and nothing in the
# output named the binary that refused (codetracer-pm issue
# 2026-10-31-build-once-prefers-the-sibling-reprobuild-checkouts-build-over-
# the-pinned-repro-with-no-version-check.md).
#
# The real build-once.sh runs against a scratch reprobuild checkout: a git
# repository carrying reprobuild's own `scripts/bootstrap_guard.sh` (copied
# from the sibling checkout, not reimplemented) and a native-format
# `build/bin/repro` + `build/bin/reprobuild` pair compiled here. The guard
# classifies binaries by their machine-format magic, so a shell-script stub
# would never pass as a build at all; `cc` is required, and its absence fails
# the test rather than skipping it. Both `repro` binaries are recording stubs
# that stop at the build boundary with distinct exit codes (sibling 72, PATH
# 71), which is how each case proves which one actually ran. Helpers unrelated
# to the tool's selection are stubbed, as in test-build-once-platform-lock.sh.
#
# Cases: a fresh sibling at or past the pin is used (the pin read through a
# `follows` edge too), and never the other platform's `repro.exe` beside it;
# a sibling whose sources
# are newer than its build, whose HEAD does not contain the pinned revision,
# or whose checkout lacks the pinned commit, falls through to the pinned repro
# on PATH with the reason printed; with no repro on PATH such a sibling is
# refused before any build runs; REPROBUILD_BIN still wins unconditionally.
#
#   bash scripts/test-build-once-repro-selection.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
guard_src="${CODETRACER_REPROBUILD_REPO_PATH:-$root/../reprobuild}/scripts/bootstrap_guard.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
[ -f "$guard_src" ] || fail "reprobuild's bootstrap_guard.sh not found at $guard_src (check reprobuild out beside codetracer or set CODETRACER_REPROBUILD_REPO_PATH)"
command -v cc >/dev/null || fail "cc is required to build native-format repro stubs"

ct="$work/codetracer"
rb="$work/reprobuild"
mkdir -p "$ct/scripts" "$ct/locks" "$work/bin" "$rb/scripts" "$rb/apps" "$rb/libs/repro_cli_support" "$rb/build/bin"
cp "$root/scripts/build-once.sh" "$ct/scripts/"
printf 'linux lock\n' >"$ct/repro.lock"
printf 'darwin lock\n' >"$ct/locks/arm64-macosx.lock"
for helper in require-siblings build-tailwind; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$ct/scripts/$helper.sh"
done
for tool in nim tup nix xcrun; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/$tool"
done
cat >"$work/bin/repro" <<'TOOL'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'repro pinned-stub'; exit 0; fi
printf 'pinned\n' >"$TEST_RAN"
exit 71
TOOL
chmod +x "$ct/scripts/"*.sh "$work/bin/"*

# The scratch reprobuild checkout.
cp "$guard_src" "$rb/scripts/bootstrap_guard.sh"
printf 'build/\n' >"$rb/.gitignore"
printf 'echo 1\n' >"$rb/apps/repro.nim"
printf 'readme\n' >"$rb/README.md"
git -C "$rb" init -q
git -C "$rb" -c user.name=t -c user.email=t@t add -A
git -C "$rb" -c user.name=t -c user.email=t@t commit -qm base
base_rev="$(git -C "$rb" rev-parse HEAD)"
# A commit HEAD does not contain: a pin past the sibling. Only README.md
# differs, which is outside the guard's source roots, so returning to the base
# commit leaves the sibling's build fresh by mtime.
git -C "$rb" checkout -q -b ahead
printf 'readme 2\n' >"$rb/README.md"
git -C "$rb" -c user.name=t -c user.email=t@t commit -qam ahead
ahead_rev="$(git -C "$rb" rev-parse HEAD)"
git -C "$rb" checkout -q -
cat >"$work/stub.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
	if (argc > 1 && strcmp(argv[1], "--version") == 0) {
		puts("repro sibling-stub");
		return 0;
	}
	const char *ran = getenv("TEST_RAN");
	FILE *f = ran ? fopen(ran, "w") : NULL;
	if (f) {
		fputs("sibling\n", f);
		fclose(f);
	}
	return 72;
}
C
build_sibling() {
	cc -o "$rb/build/bin/repro" "$work/stub.c"
	cp "$rb/build/bin/repro" "$rb/build/bin/reprobuild"
}

pin() {
	cat >"$ct/flake.lock" <<JSON
{
  "nodes": {
    "reprobuild_2": {
      "locked": { "owner": "metacraft-labs", "repo": "reprobuild", "rev": "$1", "type": "github" }
    },
    "root": { "inputs": { "reprobuild": "reprobuild_2" } }
  },
  "root": "root",
  "version": 7
}
JSON
}

# The guard and the driver must agree on the host format, so uname reports
# the real host; only -s/-m are consulted.
real_os="$(uname -s)"
real_arch="$(uname -m)"
cat >"$work/bin/uname" <<TOOL
#!/usr/bin/env bash
case "\$1" in
 -s) printf '%s\n' "$real_os" ;;
 -m) printf '%s\n' "$real_arch" ;;
 *) exit 2 ;;
esac
TOOL
chmod +x "$work/bin/uname"

# run_driver <path> [extra env...]: runs the driver, leaves its status in
# $status, its output in $work/log and the stub that ran in $work/ran.
run_driver() {
	local path="$1"
	shift
	status=0
	rm -f "$work/ran"
	(cd "$ct" && env PATH="$path" TEST_RAN="$work/ran" \
		CODETRACER_REPROBUILD_REPO_PATH="$rb" \
		RUNQUOTA_SOCKET="$work/unused.sock" CODETRACER_REPROBUILD_LINUX=1 \
		"$@" bash "$ct/scripts/build-once.sh") >"$work/log" 2>&1 || status=$?
}
expect_ran() {
	local want="$1" want_status="$2" what="$3"
	if [ "$status" != "$want_status" ] || [ "$(cat "$work/ran" 2>/dev/null)" != "$want" ]; then
		cat "$work/log" >&2
		fail "$what: expected the $want repro (exit $want_status), got exit $status, ran '$(cat "$work/ran" 2>/dev/null)'"
	fi
}
expect_log() {
	grep -F -- "$1" "$work/log" >/dev/null || {
		cat "$work/log" >&2
		fail "$2: output lacks '$1'"
	}
}

# A `build/` tree shared with a Windows checkout also carries that platform's
# `repro.exe`. The guard judges only this host's artefact, so the driver must
# never run the other one (it used to try `repro.exe` first everywhere).
cat >"$rb/build/bin/repro.exe" <<'TOOL'
#!/usr/bin/env bash
printf 'other-platform\n' >"$TEST_RAN"
exit 73
TOOL
chmod +x "$rb/build/bin/repro.exe"

# 1. Fresh sibling whose HEAD is the pinned revision: the sibling is used, and
#    said to be.
pin "$base_rev"
build_sibling
run_driver "$work/bin:$PATH"
expect_ran sibling 72 'fresh sibling at the pin'
expect_log "build-once: repro: $rb/build/bin/repro" 'fresh sibling at the pin'
expect_log 'repro sibling-stub' 'fresh sibling at the pin'
# The failure names the binary, not only what it refused.
expect_log "repro build exited 72; the tool was $rb/build/bin/repro" 'failed sibling build'
echo 'PASS: a fresh sibling build at the pin is used and named'

# 2. Sources newer than the sibling's build: stale, so the pinned repro runs.
sleep 1
printf 'echo 2\n' >"$rb/apps/repro.nim"
run_driver "$work/bin:$PATH"
expect_ran pinned 71 'stale sibling'
expect_log "not using $rb/build/bin/repro" 'stale sibling'
expect_log 'apps/repro.nim newer than build/bin/repro' 'stale sibling'
expect_log "build-once: repro: $work/bin/repro" 'stale sibling'
expect_log "repro build exited 71; the tool was $work/bin/repro" 'stale sibling'
echo 'PASS: a sibling build older than its sources falls through to the pinned repro'
git -C "$rb" checkout -q -- apps/repro.nim

# 3. Fresh build, but the sibling HEAD predates the pinned revision.
pin "$ahead_rev"
build_sibling
run_driver "$work/bin:$PATH"
expect_ran pinned 71 'sibling behind the pin'
expect_log "does not contain the pinned reprobuild $ahead_rev" 'sibling behind the pin'
echo 'PASS: a sibling checkout behind the flake pin falls through to the pinned repro'

# 4. The pinned commit is not in the sibling's object store at all.
pin 0123456789abcdef0123456789abcdef01234567
run_driver "$work/bin:$PATH"
expect_ran pinned 71 'pin unknown to the sibling'
expect_log 'does not contain the pinned reprobuild 0123456789abcdef0123456789abcdef01234567' 'pin unknown to the sibling'
echo 'PASS: a pin the sibling checkout cannot resolve falls through to the pinned repro'

# 5. A pin the sibling is past (its HEAD descends from it) is fine.
git -C "$rb" checkout -q ahead
pin "$base_rev"
build_sibling
run_driver "$work/bin:$PATH"
expect_ran sibling 72 'sibling past the pin'
echo 'PASS: a fresh sibling past the pin is used'

# 5b. The pin reached through a `follows` edge is resolved, not ignored: the
#     same lock says yes when the followed node is the sibling's base and no
#     when it names a commit the sibling lacks.
pin_follows() {
	cat >"$ct/flake.lock" <<JSON
{
  "nodes": {
    "modules": {
      "inputs": { "reprobuild": "reprobuild_3" },
      "locked": { "owner": "metacraft-labs", "repo": "devops-modules", "rev": "ffffffffffffffffffffffffffffffffffffffff", "type": "github" }
    },
    "reprobuild_3": {
      "locked": { "owner": "metacraft-labs", "repo": "reprobuild", "rev": "$1", "type": "github" }
    },
    "root": { "inputs": { "modules": "modules", "reprobuild": ["modules", "reprobuild"] } }
  },
  "root": "root",
  "version": 7
}
JSON
}
pin_follows "$base_rev"
run_driver "$work/bin:$PATH"
expect_ran sibling 72 'pin through a follows edge'
pin_follows 0123456789abcdef0123456789abcdef01234567
run_driver "$work/bin:$PATH"
expect_ran pinned 71 'unknown pin through a follows edge'
expect_log 'does not contain the pinned reprobuild 0123456789abcdef0123456789abcdef01234567' 'unknown pin through a follows edge'
echo 'PASS: a pin reached through a follows edge is resolved and checked'

# 6. An unfit sibling with no repro on PATH is refused before any build. The
#    PATH is the caller's minus every directory that carries a `repro`, with
#    this test's stubs except its pinned repro.
mkdir "$work/norepro"
for tool in nim tup nix xcrun uname; do
	ln -s "$work/bin/$tool" "$work/norepro/$tool"
done
norepro_path="$work/norepro"
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
	[ -n "$dir" ] && [ ! -x "$dir/repro" ] && norepro_path="$norepro_path:$dir"
done
for dir in "${path_dirs[@]}"; do
	[ -n "$dir" ] && [ -x "$dir/repro" ] || continue
	for exe in "$dir"/*; do
		name="${exe##*/}"
		[ "$name" = repro ] || [ -e "$work/norepro/$name" ] || ln -s "$exe" "$work/norepro/$name"
	done
done
pin "$ahead_rev"
git -C "$rb" checkout -q -
build_sibling
run_driver "$norepro_path"
if [ "$status" = 0 ] || [ -e "$work/ran" ]; then
	cat "$work/log" >&2
	fail "an unfit sibling with no pinned repro was not refused (exit $status, ran '$(cat "$work/ran" 2>/dev/null)')"
fi
expect_log "not using $rb/build/bin/repro" 'refusal'
expect_log 'REPROBUILD_BIN' 'refusal'
echo 'PASS: an unfit sibling with no pinned repro is refused before the build'

# 7. REPROBUILD_BIN is an explicit choice and is honoured as-is.
run_driver "$work/bin:$PATH" REPROBUILD_BIN="$rb/build/bin/repro"
expect_ran sibling 72 'REPROBUILD_BIN'
expect_log "build-once: repro: $rb/build/bin/repro (REPROBUILD_BIN)" 'REPROBUILD_BIN'
echo 'PASS: REPROBUILD_BIN is used as given and named'
