#!/usr/bin/env bash
# Execute the real driver in an isolated tree. Fake build tools inject failures
# at each boundary without filling the shared host's quota or compiling the
# whole application; real files model stale and partially written bundles.
#
# What is asserted: a `build` that exits non-zero leaves no renderer bundle
# (`frontend_bundle.js` and its map) in either place it is kept, and exits with
# the status the failing tool returned; a successful build leaves the bundle
# the build published; a `watch` that is interrupted removes nothing.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/bin" "$work/ci/lib" "$work/node_modules/.bin"
cp "$repo/scripts/build-once.sh" "$work/scripts/"
for helper in require-siblings post-build-setcap require-runtime-assets; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$work/scripts/$helper.sh"
	chmod +x "$work/scripts/$helper.sh"
done
cat >"$work/scripts/build-tailwind.sh" <<'TOOL'
#!/usr/bin/env bash
[ "$FAIL_AT" != tailwind ] || exit 75
TOOL
chmod +x "$work/scripts/build-tailwind.sh"
# build-once sources this for the freshness stamp, which needs a real build.
printf 'bf_electron_write_stamp() { return 0; }\n' >"$work/ci/lib/build-freshness.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/nim"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/node"
# `nix` is stubbed so the script's native-library probes do not reach the store.
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/nix"
# The host branch is selected from `uname -s`; report Linux on every host.
cat >"$work/bin/uname" <<'TOOL'
#!/usr/bin/env bash
case "$1" in
 -s) printf 'Linux\n' ;;
 -m) printf 'x86_64\n' ;;
 *) exit 2 ;;
esac
TOOL
# The build driver: publishes a bundle into both places, or fails as asked.
cat >"$work/bin/repro" <<'TOOL'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo 'repro test-stub'; exit 0; }
if [ "$FAIL_AT" = repro ]; then
 echo 'Nim compile: Disk quota exceeded' >&2
 exit 73
fi
mkdir -p "$TEST_WORK/src/public/dist" "$TEST_WORK/src/build-$CODETRACER_CONFIG-repro/public/dist"
for dir in "$TEST_WORK/src/public/dist" "$TEST_WORK/src/build-$CODETRACER_CONFIG-repro/public/dist"; do
 printf 'new bundle\n' >"$dir/frontend_bundle.js"
 printf 'new source map\n' >"$dir/frontend_bundle.js.map"
done
TOOL
chmod +x "$work/bin/"*
real_rm="$(command -v rm)"
cat >"$work/bin/rm" <<'TOOL'
#!/usr/bin/env bash
[ ! -f "$TEST_WORK/fail-rm" ] || exit 77
exec "$REAL_RM" "$@"
TOOL
chmod +x "$work/bin/rm"

# run_build <config> <stage> [K=V...]: the real build-once.sh in the sandbox.
# RUNQUOTA_SOCKET names an endpoint so the script starts no daemon of its own.
# build-once requires trace-format-nim's tool-path manifest (474095248b9),
# which the dev shell names; this test runs outside it, against a stub repro.
printf '{}\n' >"$work/tool-paths.json"

run_build() {
	local config="$1" stage="$2"
	shift 2
	rc=0
	(cd "$work" && env -u CODETRACER_REPROBUILD_COMMAND CODETRACER_CONFIG="$config" \
		RUNQUOTA_SOCKET="$work/unused.sock" PATH="$work/bin:$PATH" REAL_RM="$real_rm" \
		TEST_WORK="$work" FAIL_AT="$stage" CODETRACER_TRACE_FORMAT_NIM_TOOL_PATHS="$work/tool-paths.json" \
		"$@" bash scripts/build-once.sh) >"$work/log" 2>&1 || rc=$?
}

seed_stale() {
	local config="$1" dir
	for dir in "$work/src/public/dist" "$work/src/build-$config-repro/public/dist"; do
		mkdir -p "$dir"
		printf 'old bundle\n' >"$dir/frontend_bundle.js"
		printf 'old map\n' >"$dir/frontend_bundle.js.map"
	done
}

for config in debug release; do
	for stage in tailwind repro success; do
		seed_stale "$config"
		run_build "$config" "$stage"
		if [ "$stage" = success ]; then
			if [ "$rc" != 0 ] || ! grep -qx 'new bundle' "$work/src/build-$config-repro/public/dist/frontend_bundle.js"; then
				cat "$work/log"
				echo 'successful build did not publish current bundle' >&2
				exit 1
			fi
		else
			expected=73
			[ "$stage" != tailwind ] || expected=75
			[ "$rc" = "$expected" ] || {
				cat "$work/log"
				echo "wrong failure status: $rc" >&2
				exit 1
			}
			for dir in "$work/src/public/dist" "$work/src/build-$config-repro/public/dist"; do
				if [ -e "$dir/frontend_bundle.js" ] || [ -e "$dir/frontend_bundle.js.map" ]; then
					echo "FAIL: $stage left a stale or partial renderer in $dir" >&2
					exit 1
				fi
			done
		fi
		echo "PASS: $config $stage"
	done
done

# Cleanup diagnostics must not replace the build tool's original exit status.
seed_stale debug
touch "$work/fail-rm"
run_build debug repro
"$real_rm" -f "$work/fail-rm"
if [ "$rc" != 73 ] || ! grep -q 'failed to invalidate renderer' "$work/log"; then
	cat "$work/log"
	echo "FAIL: cleanup masked the build tool's failure ($rc)" >&2
	exit 1
fi
echo 'PASS: cleanup failure preserves the build tool status'

# A failing `watch` is not a failed build: the bundle stays.
seed_stale debug
run_build debug repro CODETRACER_REPROBUILD_COMMAND=watch
if [ "$rc" != 73 ]; then
	cat "$work/log"
	echo "FAIL: watch returned $rc, expected the tool's 73" >&2
	exit 1
fi
for dir in "$work/src/public/dist" "$work/src/build-debug-repro/public/dist"; do
	if [ ! -e "$dir/frontend_bundle.js" ]; then
		echo "FAIL: an interrupted watch removed the renderer in $dir" >&2
		exit 1
	fi
done
echo 'PASS: a failing watch leaves the renderer alone'

# A cached shell profile can fail before any build tool starts. Exercise that
# boundary with a minimal PATH so installed host Nim/Node cannot skip sourcing.
mkdir -p "$work/profile-bin" "$work/.direnv"
for tool in bash dirname cat; do
	ln -s "$(command -v "$tool")" "$work/profile-bin/$tool"
done
ln -s "$work/bin/uname" "$work/profile-bin/uname"
ln -s "$work/bin/rm" "$work/profile-bin/rm"
printf 'exit 76\n' >"$work/.direnv/flake-profile-test.rc"
seed_stale debug
rc=0
(cd "$work" && env -u CODETRACER_REPROBUILD_COMMAND CODETRACER_CONFIG=debug TEST_WORK="$work" \
	REAL_RM="$real_rm" PATH="$work/profile-bin" bash scripts/build-once.sh) >"$work/log" 2>&1 || rc=$?
[ "$rc" = 76 ] || {
	cat "$work/log"
	echo "FAIL: profile failure returned $rc" >&2
	exit 1
}
for dir in "$work/src/public/dist" "$work/src/build-debug-repro/public/dist"; do
	if [ -e "$dir/frontend_bundle.js" ] || [ -e "$dir/frontend_bundle.js.map" ]; then
		echo "FAIL: profile failure left stale renderer in $dir" >&2
		exit 1
	fi
done
echo 'PASS: cached profile failure invalidates renderer'
