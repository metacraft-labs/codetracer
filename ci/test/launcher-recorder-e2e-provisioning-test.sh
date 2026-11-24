#!/usr/bin/env bash
# launcher-recorder-e2e-provisioning-test.sh -- the launcher <-> recorder E2E
# gate's sibling provisioning, against fixtures built here.
#
# Invariants (codetracer-specs Testing/Cross-Repo-CI-Integration.md, "Where
# sibling pins live"; reprobuild-pm Unified-Locking-And-Hooks.md §14):
#   1. every gate sibling resolves from codetracer at the revision under test:
#      a repro.lock build input, a test-lock member, or a private repository's
#      one home (flake.lock root input, then ci/toolchain.pin PRIVATE_SIBLING_*);
#   2. a planned sibling none of those pins FAILS, by name (negative control);
#   3. the calling repo is never cloned, and is the only off-lock sibling the
#      build accepts, and only when it is a build input;
#   4. build-once's agreement check fails on any other off-lock build input,
#      on an override naming a non-build-input, and on a multi-name override;
#      with no override, a mismatch fails.
#
# Run: bash ci/test/launcher-recorder-e2e-provisioning-test.sh
# Lane: stock bash, git and jq or python3; no Nix, no network.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVE="$REPO_ROOT/ci/launcher-recorder-e2e-resolve-siblings.sh"
AGREE="$REPO_ROOT/ci/sibling-lock-agreement.sh"
SELECT="$REPO_ROOT/ci/repro-lock-build-input-siblings.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/launcher-recorder-e2e.yml"

pass=0 failn=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
fail() { failn=$((failn + 1)); echo "  FAIL $1"; shift; for l in "$@"; do echo "       $l"; done; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- fixture: a codetracer checkout with its locks and homes, and siblings ---
root="$tmp/ws"
ct="$root/codetracer"
mkdir -p "$ct/ci/test/siblings"
cp "$RESOLVE" "$AGREE" "$SELECT" "$ct/ci/"

mkrepo() { # $1 = name -> prints its HEAD
	local d="$root/$1"
	git init -q "$d"
	git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1 one"
	git -C "$d" rev-parse HEAD
}
advance() { # $1 = name -> prints the new HEAD
	git -C "$root/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1 two"
	git -C "$root/$1" rev-parse HEAD
}
dep() { printf '{ name = "%s", coord_kind = "vcs", url = "https://github.com/metacraft-labs/%s", revision = "%s", integrity = "git-sha1:%s", version = "", visibility = "public", participation = "", depends = "", tags = "" }' "$1" "$1" "$2" "$2"; }
pkg() { printf '{ name = "%s", version = "1.0.0", source = "%s", selection = "selected" }' "$1" "$1"; }

r_tfn="$(mkrepo codetracer-trace-format-nim)"
r_py="$(mkrepo codetracer-python-recorder)"
r_iso="$(mkrepo isonim)"
r_dvs="$(mkrepo DemoVideoScript)"
cat >"$ct/repro.lock" <<LOCK
schema = "reprobuild.solved-graph-lock.v3"

[lock]
packages = [$(pkg codetracer-trace-format-nim), $(pkg codetracer-python-recorder), $(pkg isonim)]
deps = [{ name = "codetracer", self = "true", coord_kind = "vcs", url = "https://github.com/metacraft-labs/codetracer", revision = "0000000000000000000000000000000000000000", integrity = "", version = "", visibility = "public", participation = "", depends = "", tags = "" }, $(dep codetracer-trace-format-nim "$r_tfn"), $(dep codetracer-python-recorder "$r_py"), $(dep isonim "$r_iso")]
LOCK
cat >"$ct/ci/test/siblings/repro.lock" <<LOCK
schema = "reprobuild.solved-graph-lock.v3"

[lock]
deps = [$(dep DemoVideoScript "$r_dvs")]
LOCK
nb_rev=1111111111111111111111111111111111111111
nr_rev=2222222222222222222222222222222222222222
la_rev=3333333333333333333333333333333333333333
cat >"$ct/flake.lock" <<JSON
{"root":"root","version":7,"nodes":{
 "root":{"inputs":{"codetracer-native-backend":"nb","codetracer-native-recorder":"nr","codetracer-trace-format-nim":"tfn"}},
 "nb":{"locked":{"rev":"$nb_rev"}},
 "nr":{"locked":{"rev":"$nr_rev"}},
 "tfn":{"locked":{"rev":"$r_tfn"}}}}
JSON
printf 'PRIVATE_SIBLING_CODETRACER_LAUNCHER=%s\n' "$la_rev" >"$ct/ci/toolchain.pin"

resolve() { # $1 = self, $2.. = planned names
	local self="$1"; shift
	bash "$ct/ci/launcher-recorder-e2e-resolve-siblings.sh" --ct-dir "$ct" --self "$self" --planned "$(printf '%s\n' "$@")" 2>"$tmp/err"
}

# --- 1. classification -------------------------------------------------------
out="$(resolve codetracer-native-recorder codetracer codetracer-launcher codetracer-native-recorder codetracer-trace-format-nim codetracer-native-backend)"; rc=$?
want_private="codetracer-launcher=$la_rev
codetracer-native-backend=$nb_rev"
got_private="$(sed -n '/^private<<LRC_PRIVATE_EOF$/,/^LRC_PRIVATE_EOF$/p' <<<"$out" | sed '1d;$d')"
if [ "$rc" -eq 0 ] && [ "$got_private" = "$want_private" ] && grep -qx 'off-lock=' <<<"$out"; then
	ok "native edge: launcher from ci/toolchain.pin, native-backend from flake.lock, trace-format-nim from repro.lock, the caller never cloned"
else
	fail "native edge resolves from the locks and homes" "rc=$rc" "got private: $got_private" "$(cat "$tmp/err")"
fi

out="$(resolve codetracer-python-recorder codetracer codetracer-launcher codetracer-python-recorder codetracer-trace-format-nim)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'off-lock=codetracer-python-recorder' <<<"$out" && ! grep -q 'codetracer-trace-format-nim=' <<<"$out"; then
	ok "a public flake input that repro.lock pins (trace-format-nim) comes from the lock, and a build-input caller is the off-lock override"
else
	fail "python edge: lock before flake home, caller is the off-lock override" "rc=$rc" "$out"
fi

out="$(resolve codetracer codetracer-launcher codetracer-python-recorder DemoVideoScript)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'test-siblings=DemoVideoScript' <<<"$out" && grep -qx 'off-lock=' <<<"$out"; then
	ok "a test-lock member is named for test-siblings; codetracer calling itself has no off-lock sibling"
else
	fail "desktop edge: test-lock member and no override" "rc=$rc" "$out"
fi

# --- 2. negative control: a gate sibling no lock pins -----------------------
out="$(resolve codetracer-native-recorder codetracer-launcher not-a-pinned-repo)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'gate sibling not-a-pinned-repo: no lock and no home pins it' "$tmp/err"; then
	ok "NEGATIVE CONTROL: a gate sibling no lock and no home pins fails, by name"
else
	fail "a gate sibling no lock pins must fail" "rc=$rc" "$(cat "$tmp/err")"
fi
printf 'PRIVATE_SIBLING_CODETRACER_LAUNCHER=dev\n' >"$ct/ci/toolchain.pin"
out="$(resolve codetracer-native-recorder codetracer-launcher)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a private home that records a branch, not a 40-hex revision, fails"; else fail "a branch in a private home must fail" "$out"; fi
printf 'PRIVATE_SIBLING_CODETRACER_LAUNCHER=%s\n' "$la_rev" >"$ct/ci/toolchain.pin"

# --- 3. the workflow wires it the way the script assumes --------------------
grep -q 'exclude: ${{ steps.plan.outputs.self }}' "$WORKFLOW" &&
	ok "the workflow excludes the calling repo from provisioning" ||
	fail "the workflow excludes the calling repo from provisioning" "no 'exclude: \${{ steps.plan.outputs.self }}' in $WORKFLOW"
grep -q 'CODETRACER_OFF_LOCK_SIBLING: ${{ steps.resolve.outputs.off-lock }}' "$WORKFLOW" &&
	ok "the core build's only off-lock sibling is the resolver's, i.e. the caller" ||
	fail "the core build's off-lock sibling comes from the resolver" "not found in $WORKFLOW"
grep -q 'CODETRACER_REQUIRE_LOCKED_SIBLINGS: "1"' "$WORKFLOW" &&
	ok "the core build requires every other build input at its locked revision" ||
	fail "the core build requires locked siblings" "not found in $WORKFLOW"
if grep -nE '^\s+[A-Za-z0-9_.-]+=[0-9a-f]{40}' "$WORKFLOW" >"$tmp/literal"; then
	fail "the workflow writes no sibling revision of its own" "$(cat "$tmp/literal")"
else
	ok "the workflow writes no sibling revision of its own (every one comes from codetracer's locks or homes)"
fi

# --- 4. build-once's agreement check ----------------------------------------
agree() { (cd "$ct" && CODETRACER_OFF_LOCK_SIBLING="$1" GITHUB_STEP_SUMMARY="$tmp/summary" bash ci/sibling-lock-agreement.sh "$ct") >"$tmp/agree" 2>&1; }
agree "" && ok "every build input at its locked revision: accepted" || fail "all-locked must pass" "$(cat "$tmp/agree")"

new_py="$(advance codetracer-python-recorder)"
if ! agree ""; then ok "a build input off its lock with NO override fails"; else fail "an unacknowledged mismatch must fail" "$(cat "$tmp/agree")"; fi
: >"$tmp/summary"
if agree codetracer-python-recorder && grep -q "acknowledged off-lock sibling: codetracer-python-recorder at $new_py (repro.lock pins $r_py)" "$tmp/agree" && grep -q 'codetracer-python-recorder' "$tmp/summary"; then
	ok "the caller off its lock is accepted when it is THE override, and printed with both revisions in the log and the summary"
else
	fail "the acknowledged override is accepted and printed" "$(cat "$tmp/agree")"
fi
advance isonim >/dev/null
if ! agree codetracer-python-recorder; then ok "with the override set, any OTHER off-lock build input still fails"; else fail "a second off-lock sibling must fail" "$(cat "$tmp/agree")"; fi
git -C "$root/isonim" -c advice.detachedHead=false checkout -q "$r_iso"
if ! agree isonim-tui; then ok "an override naming a sibling that is not a build input fails"; else fail "an override outside the build inputs must fail" "$(cat "$tmp/agree")"; fi
if ! agree "codetracer-python-recorder,isonim"; then ok "an override naming more than one sibling fails"; else fail "a multi-name override must fail" "$(cat "$tmp/agree")"; fi
if ! agree isonim; then ok "an override naming a sibling OTHER than the off-lock one leaves the real mismatch failing"; else fail "the override must not cover a different sibling" "$(cat "$tmp/agree")"; fi

echo
if [ "$failn" -eq 0 ]; then
	echo "launcher-recorder-e2e-provisioning-test: $pass assertions passed"
else
	echo "launcher-recorder-e2e-provisioning-test: $failn of $((pass + failn)) assertions FAILED"
	exit 1
fi
