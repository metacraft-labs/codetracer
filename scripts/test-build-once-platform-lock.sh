#!/usr/bin/env bash
# Run the production driver with recording build tools: no full application
# compile is needed to verify its final repro argv. The real CLI's selected
# solve is checked separately against the committed locks. Helpers are stubbed
# only to isolate this driver's platform binding from unrelated provisioning.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/bin" "$work/locks"
cp "$root/scripts/build-once.sh" "$work/scripts/"
# The REAL pin check, not a stub: the driver calls it before binding the native
# lock, and running the real one here keeps this test honest about the whole
# step. The two fixture locks below carry no `deps` line, so it compares two
# empty dependency sets and agrees -- which is what "nothing to compare" should
# mean and is asserted directly by scripts/test-check-platform-lock-pins.sh.
cp "$root/scripts/check-platform-lock-pins.sh" "$work/scripts/"
printf 'linux lock\n' >"$work/repro.lock"
printf 'darwin lock\n' >"$work/locks/arm64-macosx.lock"
for helper in require-siblings build-tailwind; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$work/scripts/$helper.sh"
	chmod +x "$work/scripts/$helper.sh"
done
for tool in nim tup nix xcrun; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/$tool"
done
cat >"$work/bin/uname" <<'TOOL'
#!/usr/bin/env bash
case "$1" in
 -s) printf '%s\n' "$TEST_OS" ;;
 -m) printf '%s\n' "$TEST_ARCH" ;;
 *) exit 2 ;;
esac
TOOL
cat >"$work/bin/repro" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ARGS"
# Stop at the real build boundary; no successful output bundle is fabricated.
exit 71
TOOL
chmod +x "$work/bin/"*
run_driver() {
	local os="$1" arch="$2" command="${3:-build}" cwd="${4:-$work}" status=0
	rm -f "$work/args"
	(cd "$cwd" && env PATH="$work/bin:$PATH" TEST_OS="$os" TEST_ARCH="$arch" \
		TEST_ARGS="$work/args" REPROBUILD_BIN="$work/bin/repro" \
		CODETRACER_REPROBUILD_COMMAND="$command" \
		RUNQUOTA_SOCKET="$work/unused.sock" CODETRACER_REPROBUILD_LINUX=1 \
		bash "$work/scripts/build-once.sh") >"$work/log" 2>&1 || status=$?
	[ "$status" = 71 ] || {
		cat "$work/log" >&2
		echo "FAIL: driver status $status" >&2
		exit 1
	}
}
for platform in 'Darwin arm64' 'Darwin x86_64' 'Linux x86_64' 'MINGW64_NT x86_64'; do
	read -r os arch <<<"$platform"
	run_driver "$os" "$arch"
	if [ "$platform" = 'Darwin arm64' ]; then
		if ! grep -Fx -- '--lock' "$work/args" >/dev/null ||
			! grep -Fx -- "$work/locks/arm64-macosx.lock" "$work/args" >/dev/null; then
			cat "$work/args" >&2
			echo 'FAIL: Apple arm build did not bind its committed lock' >&2
			exit 1
		fi
	else
		if grep -q -- '--lock' "$work/args"; then
			echo "FAIL: $platform unexpectedly bound the Apple arm lock" >&2
			exit 1
		fi
	fi
	case "$os" in
	Darwin) want_target='.#macos-app' ;;
	*) want_target='.' ;;
	esac
	[ "$(sed -n 2p "$work/args")" = "$want_target" ] || {
		cat "$work/args" >&2
		echo "FAIL: $platform did not build $want_target" >&2
		exit 1
	}
	echo "PASS: $platform lock binding and target"
done
mkdir "$work/other"
run_driver Darwin arm64 build "$work/other"
grep -Fx -- "$work/locks/arm64-macosx.lock" "$work/args" >/dev/null
echo 'PASS: native binding is anchored to the repository from another cwd'
run_driver Darwin arm64 watch
if grep -q -- '--lock' "$work/args"; then
	echo 'FAIL: watch received an unsupported --lock flag' >&2
	exit 1
fi
grep -Fx watch "$work/args" >/dev/null
[ "$(sed -n 2p "$work/args")" = . ] || {
	echo 'FAIL: watch left its whole-project target' >&2
	exit 1
}
echo 'PASS: watch retains its supported invocation'
rm "$work/locks/arm64-macosx.lock"
status=0
rm -f "$work/args"
(cd "$work" && env PATH="$work/bin:$PATH" TEST_OS=Darwin TEST_ARCH=arm64 \
	TEST_ARGS="$work/args" REPROBUILD_BIN="$work/bin/repro" \
	RUNQUOTA_SOCKET="$work/unused.sock" bash scripts/build-once.sh) >"$work/log" 2>&1 || status=$?
if [ "$status" = 0 ] || [ -e "$work/args" ] || ! grep -q 'arm64-macosx.lock' "$work/log"; then
	cat "$work/log" >&2
	echo 'FAIL: missing native lock was not refused before the build' >&2
	exit 1
fi
echo 'PASS: missing native lock refuses without fallback'

# Lock content is part of the real Electron freshness digest. Exercise the
# production digest over a tiny Git index rather than mocking its hash tools.
# shellcheck source=ci/lib/build-freshness.sh
source "$root/ci/lib/build-freshness.sh"
git -C "$work" init -q
printf 'darwin lock\n' >"$work/locks/arm64-macosx.lock"
git -C "$work" add repro.lock locks/arm64-macosx.lock
before="$(bf_electron_input_digest "$work")"
printf 'changed native solve\n' >>"$work/locks/arm64-macosx.lock"
after="$(bf_electron_input_digest "$work")"
[ "$before" != "$after" ] || {
	echo 'FAIL: native solve changed without invalidating freshness' >&2
	exit 1
}
git -C "$work" checkout -- locks/arm64-macosx.lock
restored="$(bf_electron_input_digest "$work")"
[ "$before" = "$restored" ] || {
	echo 'FAIL: restored native lock did not restore the digest' >&2
	exit 1
}
printf 'changed Linux solve\n' >>"$work/repro.lock"
[ "$before" != "$(bf_electron_input_digest "$work")" ] || {
	echo 'FAIL: canonical solve changed without invalidating freshness' >&2
	exit 1
}
echo 'PASS: both committed solves participate in Electron freshness'

# The two committed solves must name the same source (codetracer-pm
# spec/Architecture/Build-Outputs-And-Path-Resolution.md section 4.6): a
# dependency revision is a source fact, not a platform fact. Unlike relating a
# lock to flake.lock, this question has the same answer on every host, so it
# runs unconditionally -- it is what makes Linux CI's `just test` refuse a
# commit that moves a pin in repro.lock and leaves the native file behind
# (codetracer-pm
# issues/2026-11-03-six-native-lock-sibling-pins-diverged-unchecked-and-the-seventh-is-caught-only-on-a-mac.md).
# The escape hatch is for a deliberate local build, never for this test, so it
# is cleared here.
if ! env -u CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT "${BASH:-bash}" \
	"$root/scripts/check-platform-lock-pins.sh" \
	"$root/locks/arm64-macosx.lock" "$root/repro.lock"; then
	echo 'FAIL: the committed solves pin different source revisions' >&2
	exit 1
fi
echo 'PASS: both committed solves pin the same source revisions'

# Verify the committed solves too. This complements the driver boundary test:
# recording correct argv cannot establish that its native file is a native
# solve, or that the build and dev shell pin the same package catalog.
python3 - "$root" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
flake = json.loads((root / "flake.lock").read_text())
edge = flake["nodes"][flake["root"]]["inputs"]["reprobuild-packages"]
catalog = flake["nodes"][edge]["locked"]["rev"]
engine_edge = flake["nodes"][flake["root"]]["inputs"]["reprobuild"]
engine_revision = flake["nodes"][engine_edge]["locked"]["rev"]
for path, platform in (("repro.lock", "amd64-linux"),
                       ("locks/arm64-macosx.lock", "arm64-macosx")):
    text = (root / path).read_text()
    assert re.search(r'^platform = "' + platform + r'"$', text, re.M), path + " has the wrong platform"
    deps_line = re.search(r'^deps\s*=\s*\[(.*)\]\s*$', text, re.M)
    assert deps_line, path + " has no dependency pins"
    deps = {}
    for entry in re.findall(r'\{([^{}]*)\}', deps_line.group(1)):
        fields = dict(re.findall(r'(\w+)\s*=\s*"([^"\\]*)"', entry))
        deps[fields["name"]] = fields.get("revision", "")
    assert deps.get("reprobuild-packages") == catalog, path + " catalog disagrees with flake.lock"
    # Checked on every host. Only an Apple arm host can refresh the native
    # file, but the native file's pins must equal repro.lock's (checked above),
    # so a native pin that disagrees with flake.lock is a failure everywhere,
    # not only where somebody happens to build on a Mac.
    # Never --platform=amd64-linux for repro.lock: on a Mac that writes this
    # host's solve under the Linux label, and every check here would pass it.
    remedy = ("repro lock update reprobuild" if path == "repro.lock" else
              "repro lock refresh . --lock " + path + " --platform=" + platform +
              " (on an " + platform + " host)")
    assert deps.get("reprobuild") == engine_revision, (path + " Reprobuild pin disagrees with flake.lock; run: " + remedy)
    print("PASS: " + path + " platform and catalog pin")
PY
