#!/usr/bin/env bash
# =============================================================================
# Contract: `ci/test/scenarios.sh` builds the scenario runner only from the
# sibling revisions the test lock pins, and does not run a program built from
# any other.
#
#   bash ci/test/scenarios-sibling-pin-test.sh
#
# WHY THIS FILE EXISTS
#   A sibling checkout three commits behind its pin built a `dvs` without
#   DemoVideoScript 028ea4f ("leave a traced orphan to its tracer"). That
#   `dvs`'s orphan reaper SIGKILLed rr's replay processes after every seek,
#   so rr scenarios lost their replay at random ("Tracee was killed") for
#   days, and the runs were written off as host noise. `build` had said so,
#   once, as a warning in its log.
#
# WHAT IT DOES
#   Copies the real `scenarios.sh` into a scratch workspace with a test lock
#   that pins a scratch DemoVideoScript git checkout at its first commit, and
#   a `nim` on PATH that writes a stand-in program wherever `-o:` says (the
#   stand-in records that it ran). It then requires:
#     1. at the pin, `build dvs` builds, and records the revision it used;
#     2. one commit off the pin, `build dvs` exits 3 naming the sibling and
#        its pin, and compiles nothing;
#     3. CONTROL: with CT_SCENARIOS_ALLOW_OFF_PIN=1 the same build goes ahead
#        (so 2 is the check refusing, not the build failing), with a warning;
#     4. `run` with that off-pin `dvs` and the opt-out unset rebuilds it,
#        which refuses, and the off-pin program does not run;
#     5. back at the pin, `run` rebuilds `dvs` from the pin and runs it.
#   SCENARIOS_SH=<path> runs the same checks against another copy of the
#   script: against the `scenarios.sh` before this check, the off-pin build
#   of 2 compiles, and nothing records what a build used.
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SCENARIOS_SH:-${here}/scenarios.sh}"
scratch="$(mktemp -d)"
trap '[ -n "${KEEP_SCRATCH:-}" ] || rm -rf "${scratch}"' EXIT

ws="${scratch}/ws"
root="${ws}/ct"
mkdir -p "${root}/ci/test/siblings" "${root}/node_modules/playwright-core" \
	"${root}/src/tests/scenarios/pack" "${scratch}/tools"
cp "${script}" "${root}/ci/test/scenarios.sh"

git_in() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}"; }

# The sibling: two commits; the lock pins the first.
dvs_repo="${ws}/DemoVideoScript"
mkdir -p "${dvs_repo}/src"
git init -q "${dvs_repo}"
echo 'echo "dvs"' >"${dvs_repo}/src/dvs.nim"
git_in "${dvs_repo}" add -A
git_in "${dvs_repo}" commit -q -m pinned
pinned="$(git -C "${dvs_repo}" rev-parse HEAD)"
echo '# later work' >>"${dvs_repo}/src/dvs.nim"
git_in "${dvs_repo}" commit -q -am later
later="$(git -C "${dvs_repo}" rev-parse HEAD)"
git_in "${dvs_repo}" checkout -q --detach "${pinned}"

# The desktop arm, at its pin throughout.
arm_repo="${ws}/DemoVideoScript-Playwright"
mkdir -p "${arm_repo}/src"
git init -q "${arm_repo}"
echo '// arm' >"${arm_repo}/src/main.ts"
git_in "${arm_repo}" add -A
git_in "${arm_repo}" commit -q -m arm
arm_pinned="$(git -C "${arm_repo}" rev-parse HEAD)"

cat >"${root}/ci/test/siblings/repro.lock" <<EOF
deps = [{ name = "DemoVideoScript", coord_kind = "vcs", url = "https://example.invalid/DemoVideoScript", revision = "${pinned}", integrity = "git-sha1:${pinned}" }, { name = "DemoVideoScript-Playwright", coord_kind = "vcs", url = "https://example.invalid/DemoVideoScript-Playwright", revision = "${arm_pinned}", integrity = "git-sha1:${arm_pinned}" }]
EOF

# `nim c ... -o:<out> <src>`: a stand-in program at <out>, built from the
# source revision; it records each run.
compiles="${scratch}/compiles.log"
runs="${scratch}/runs.log"
cat >"${scratch}/tools/nim" <<EOF
#!/usr/bin/env bash
out=""
for a in "\$@"; do case "\$a" in -o:*) out="\${a#-o:}" ;; esac; done
echo "\$out" >>"${compiles}"
mkdir -p "\$(dirname "\$out")"
printf '#!/usr/bin/env bash\necho "\$0 \$*" >>%q\n' "${runs}" >"\$out"
chmod +x "\$out"
EOF
chmod +x "${scratch}/tools/nim"
export PATH="${scratch}/tools:${PATH}"
unset CT_SCENARIOS_ALLOW_OFF_PIN DVS_SRC DVS_PLAYWRIGHT_ROOT CT_SCENARIO_BUILD

failures=0
fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}
count() { [ -f "$1" ] && wc -l <"$1" || echo 0; }
sh_() { (cd "${root}" && bash ci/test/scenarios.sh "$@"); }

# 1. At the pin.
if sh_ build dvs >"${scratch}/1.log" 2>&1; then
	grep -q "DemoVideoScript ${pinned}" "${root}/build/bin/.siblings-dvs" 2>/dev/null ||
		fail "1: the build did not record DemoVideoScript ${pinned:0:11}"
else
	fail "1: building at the pin failed: $(cat "${scratch}/1.log")"
fi

# 2. Off the pin.
git_in "${dvs_repo}" checkout -q --detach "${later}"
before="$(count "${compiles}")"
set +e
sh_ build dvs >"${scratch}/2.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 3 ] || fail "2: an off-pin build exited ${rc}, not 3"
grep -q "pins DemoVideoScript at ${pinned:0:11}" "${scratch}/2.log" ||
	fail "2: the refusal does not name the sibling and its pin: $(cat "${scratch}/2.log")"
[ "$(count "${compiles}")" = "${before}" ] || fail "2: the off-pin build compiled something"

# 3. CONTROL: the opt-out builds against the same checkout.
if CT_SCENARIOS_ALLOW_OFF_PIN=1 sh_ build dvs >"${scratch}/3.log" 2>&1; then
	grep -q "warning: building against" "${scratch}/3.log" ||
		fail "3: the opt-out build did not warn"
	grep -q "DemoVideoScript ${later}" "${root}/build/bin/.siblings-dvs" ||
		fail "3: the opt-out build did not record ${later:0:11}"
else
	fail "3: the opt-out build failed: $(cat "${scratch}/3.log")"
fi

# 4. `run` with the off-pin dvs and no opt-out.
before="$(count "${runs}")"
set +e
sh_ run electron some.yaml >"${scratch}/4.log" 2>&1
rc=$?
set -e
[ "${rc}" -ne 0 ] || fail "4: run used a dvs built off the pin: $(cat "${scratch}/4.log")"
[ "$(count "${runs}")" = "${before}" ] || fail "4: the off-pin dvs ran"

# 5. Back at the pin, `run` rebuilds and runs.
git_in "${dvs_repo}" checkout -q --detach "${pinned}"
if sh_ run electron some.yaml >"${scratch}/5.log" 2>&1; then
	grep -q "DemoVideoScript ${pinned}" "${root}/build/bin/.siblings-dvs" ||
		fail "5: run did not rebuild dvs from the pin"
	grep -q "/dvs run some.yaml" "${runs}" || fail "5: dvs did not run"
else
	fail "5: run at the pin failed: $(cat "${scratch}/5.log")"
fi

if [ "${failures}" -ne 0 ]; then
	echo "scenarios-sibling-pin-test: ${failures} check(s) failed" >&2
	exit 1
fi
echo "scenarios-sibling-pin-test: ok"
