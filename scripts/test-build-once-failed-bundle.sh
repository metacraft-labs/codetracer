#!/usr/bin/env bash
# Execute the real driver in an isolated tree. Fake build tools inject failures
# at each boundary without filling the shared host's quota or compiling the
# whole application; real files model stale and partially written bundles.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/bin" "$work/src/.tup" "$work/node_modules/.bin"
cp "$repo/scripts/build-once.sh" "$work/scripts/"
for helper in require-siblings build-tailwind require-fuse-mount-helper require-tup-globs post-build-setcap require-runtime-assets; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$work/scripts/$helper.sh"
	chmod +x "$work/scripts/$helper.sh"
done
cat >"$work/scripts/build-tailwind.sh" <<'TOOL'
#!/usr/bin/env bash
[ "$FAIL_AT" != tailwind ] || exit 75
TOOL
touch "$work/src/.tup/db"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/nim"
cat >"$work/bin/tup" <<'TOOL'
#!/usr/bin/env bash
count=0
[ ! -f "$TEST_WORK/count" ] || read -r count < "$TEST_WORK/count"
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_WORK/count"
if [ "$FAIL_AT" = "tup$count" ] || [ "$FAIL_AT" = cleanup-failure ]; then
 [ "$FAIL_AT" != cleanup-failure ] || touch "$TEST_WORK/fail-rm"
 echo 'Nim compile: Disk quota exceeded' >&2
 exit 73
fi
mkdir -p "$TEST_WORK/src/build-$CODETRACER_CONFIG/public/dist"
if [ -f "$TEST_WORK/src/public/dist/frontend_bundle.js" ]; then
 cp "$TEST_WORK/src/public/dist/frontend_bundle.js" "$TEST_WORK/src/build-$CODETRACER_CONFIG/public/dist/"
fi
TOOL
cat >"$work/node_modules/.bin/webpack" <<'TOOL'
#!/usr/bin/env bash
printf 'new bundle\n' > "$TEST_WORK/src/public/dist/frontend_bundle.js"
printf 'new source map\n' > "$TEST_WORK/src/public/dist/frontend_bundle.js.map"
[ "$FAIL_AT" != webpack ] || exit 74
TOOL
chmod +x "$work/bin/"* "$work/node_modules/.bin/webpack"
real_rm="$(command -v rm)"
cat >"$work/bin/rm" <<'TOOL'
#!/usr/bin/env bash
[ ! -f "$TEST_WORK/fail-rm" ] || exit 77
exec "$REAL_RM" "$@"
TOOL
chmod +x "$work/bin/rm"
for config in debug release; do
	for stage in tailwind tup1 webpack tup2 success; do
		mkdir -p "$work/src/public/dist" "$work/src/build-$config/public/dist"
		for dir in "$work/src/public/dist" "$work/src/build-$config/public/dist"; do
			printf 'old bundle\n' >"$dir/frontend_bundle.js"
			printf 'old map\n' >"$dir/frontend_bundle.js.map"
		done
		rm -f "$work/count"
		rc=0
		(cd "$work" && env -u CODETRACER_REPROBUILD_LINUX CODETRACER_CONFIG="$config" PATH="$work/bin:$PATH" REAL_RM="$real_rm" TEST_WORK="$work" FAIL_AT="$stage" bash scripts/build-once.sh) >"$work/log" 2>&1 || rc=$?
		if [ "$stage" = success ]; then
			if [ "$rc" != 0 ] || ! grep -qx 'new bundle' "$work/src/build-$config/public/dist/frontend_bundle.js"; then
				cat "$work/log"
				echo 'successful build did not publish current bundle' >&2
				exit 1
			fi
		else
			expected=73
			[ "$stage" != webpack ] || expected=74
			[ "$stage" != tailwind ] || expected=75
			[ "$rc" = "$expected" ] || {
				cat "$work/log"
				echo "wrong failure status: $rc" >&2
				exit 1
			}
			for dir in "$work/src/public/dist" "$work/src/build-$config/public/dist"; do
				if [ -e "$dir/frontend_bundle.js" ] || [ -e "$dir/frontend_bundle.js.map" ]; then
					echo "FAIL: $stage left a stale or partial renderer in $dir" >&2
					exit 1
				fi
			done
		fi
		echo "PASS: $config $stage"
	done
done
# Cleanup diagnostics must not replace the compiler's original exit status.
rc=0
(cd "$work" && env -u CODETRACER_REPROBUILD_LINUX CODETRACER_CONFIG=debug PATH="$work/bin:$PATH" REAL_RM="$real_rm" TEST_WORK="$work" FAIL_AT=cleanup-failure bash scripts/build-once.sh) >"$work/log" 2>&1 || rc=$?
if [ "$rc" != 73 ] || ! grep -q 'failed to invalidate renderer' "$work/log"; then
	cat "$work/log"
	echo "FAIL: cleanup masked compiler failure ($rc)" >&2
	exit 1
fi
echo 'PASS: cleanup failure preserves compiler status'

# A cached shell profile can fail before any build tool starts. Exercise that
# boundary with a minimal PATH so installed host Nim/Tup cannot skip sourcing.
mkdir -p "$work/profile-bin" "$work/.direnv"
for tool in bash dirname cat uname rm; do
	ln -s "$(command -v "$tool")" "$work/profile-bin/$tool"
done
printf 'exit 76\n' >"$work/.direnv/flake-profile-test.rc"
for dir in "$work/src/public/dist" "$work/src/build-debug/public/dist"; do
	printf 'stale renderer\n' >"$dir/frontend_bundle.js"
	printf 'stale map\n' >"$dir/frontend_bundle.js.map"
done
rc=0
(cd "$work" && env -u CODETRACER_REPROBUILD_LINUX CODETRACER_CONFIG=debug PATH="$work/profile-bin" bash scripts/build-once.sh) >"$work/log" 2>&1 || rc=$?
[ "$rc" = 76 ] || {
	cat "$work/log"
	echo "FAIL: profile failure returned $rc" >&2
	exit 1
}
for dir in "$work/src/public/dist" "$work/src/build-debug/public/dist"; do
	if [ -e "$dir/frontend_bundle.js" ] || [ -e "$dir/frontend_bundle.js.map" ]; then
		echo "FAIL: profile failure left stale renderer in $dir" >&2
		exit 1
	fi
done
echo 'PASS: cached profile failure invalidates renderer'
# Tup's sanitized child environment must carry the operator's scratch override.
grep -qx 'export TMPDIR' "$repo/src/Tuprules.tup" || {
	echo 'FAIL: Tup strips TMPDIR' >&2
	exit 1
}
