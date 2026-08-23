#!/usr/bin/env bash
# =============================================================================
# Contract: the Windows DIY install root degrades to somewhere writable, and
# the three scripts that resolve it agree on how.
#
# # Why this file exists
#
# Every ephemeral `eph-win-x64` job died at the first bootstrap step:
#
#     ensure-ttd.ps1:189  New-Item -ItemType Directory -Force -Path $ttdCacheDir
#                         Access to the path 'D:\metacraft-dev-deps\ttd' is denied.
#
# `Ensure-Ttd` was not at fault. `env.ps1`'s `Get-DefaultInstallRoot` chose the
# root, using `Test-Path -LiteralPath "D:\" -PathType Container` as its test
# for "there is a dev drive here". On an eph-win-x64 guest there is not:
# `D:` is the cloudbase-init config drive, a READ-ONLY CDFS volume. Confirmed
# on a CoW clone of `golden-win11-cloudbase.qcow2`, 2026-08-23:
#
#     DeviceID  DriveType  FileSystem  VolumeName  SizeGB
#     C:                3  NTFS        Windows      79.58
#     D:                5  CDFS        config-2         0
#
#     Test-Path D:\ -PathType Container  =>  True
#     New-Item  D:\metacraft-dev-deps\ttd  =>  Access to the path ... is denied.
#
# The guest's libvirt domain has exactly two block devices: the qcow2 system
# disk and a read-only SATA CD-ROM carrying the config drive. There is no
# third volume for `D:` to be, and there never was one to find.
#
# TTD is simply the FIRST `Ensure-*` step in `env.ps1`. Every one of them
# would have failed on the same root; TTD only took the bullet.
#
# # What is asserted
#
#   1. Neither resolver still uses bare existence as its dev-drive test.
#      `Test-Path -PathType Container` in PowerShell and `[[ -d ]]` in bash
#      both answer "yes" for a read-only mount, which is the whole defect.
#      `[[ -w ]]` is no better: Git-Bash synthesises POSIX permission bits
#      that do not carry Windows ACLs, so it reports a CDFS mount writable.
#   2. Both resolvers probe by CREATING a directory, which is the only test
#      that answers the question the caller is actually asking.
#   3. All THREE scripts that resolve this root agree. The third,
#      `setup-codetracer-runtime-env.sh`, used to default to a bare
#      `D:/metacraft-dev-deps` with no probe at all, so on a box without a
#      writable D: it disagreed with `env.sh` about where the toolchain lives
#      and silently built a PATH of directories that do not exist.
#   4. An explicitly-set `WINDOWS_DIY_INSTALL_ROOT` is still honoured
#      verbatim. Degrading gracefully must not mean overriding an operator.
#   5. There is a fallback below the dev drive, and it is a PERSISTENT one.
#      `RUNNER_TEMP` is the obvious CI scratch dir and is wiped between jobs;
#      making it the primary fallback would quietly turn a toolchain cache
#      into a re-download on every job on the two long-lived Windows runners.
#      `LOCALAPPDATA` persists, so it leads and `RUNNER_TEMP` is last resort.
#   6. `Ensure-Ttd` still takes its root as a parameter rather than
#      recomputing one, so fixing the resolver actually fixes the caller.
#
# # No mocks
#
# The four shipped scripts are the input, read as committed. Point the suite
# at another tree with `$1` to check a pristine copy (that is how the red run
# for this change was produced).
#
# Run: bash ci/test/windows-install-root-test.sh [<repo-root>]
# Lane: a step of the `ci-verdict` job (stock ubuntu-latest, bash only).
# =============================================================================
set -uo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
readonly REPO_ROOT

readonly ENV_PS1="$REPO_ROOT/env.ps1"
readonly ENV_SH="$REPO_ROOT/env.sh"
readonly RUNTIME_SH="$REPO_ROOT/non-nix-build/windows/setup-codetracer-runtime-env.sh"
readonly ENSURE_TTD="$REPO_ROOT/non-nix-build/windows/ensure-ttd.ps1"

readonly ROOT_ENV_VAR="WINDOWS_DIY_INSTALL_ROOT"
# The writability probe each resolver must go through.
readonly PS_PROBE_FN="Test-DirectoryWritable"
readonly SH_PROBE_FN="_ct_dir_writable"
readonly RUNTIME_PROBE_FN="_ct_runtime_dir_writable"
# The persistent fallback that must lead, and the volatile one that must not.
readonly PERSISTENT_FALLBACK="LOCALAPPDATA"
readonly VOLATILE_FALLBACK="RUNNER_TEMP"
# Floors, so an extractor that stops matching FAILS here rather than reporting
# "no violations" over empty input. Deliberately well below the real sizes.
# PowerShell's `$Root`, not the shell's: these `\$` are literal dollars in a
# PowerShell parameter declaration, and live here so the assertion sites read
# as plain strings.
# These two `$` are PowerShell's, not the shell's -- `$true` and `$Root` are
# literal text in a PowerShell parameter declaration. Single quotes are exactly
# right here (shfmt normalises to them), so SC2016's "did you mean to expand
# this?" is answered once, in writing, rather than worked around.
# shellcheck disable=SC2016
readonly ENSURE_TTD_ROOT_PARAM_RE='\[Parameter\(Mandatory = \$true\)\]\[string\]\$Root'
# shellcheck disable=SC2016
readonly ENSURE_TTD_ROOT_PARAM_LABEL='ensure-ttd.ps1 takes $Root as a mandatory parameter'
readonly MIN_ENV_PS1_LINES=800
readonly MIN_ENV_SH_LINES=400

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

# Strip comments so an assertion cannot be satisfied -- or defeated -- by
# prose. Every scan below runs over code only.
#
# The results are captured into variables and matched with HERE-STRINGS, never
# by piping a producer into `grep -q`. Under `set -o pipefail` that pairing is
# a trap: `grep -q` exits the instant it matches, the upstream `sed` takes
# SIGPIPE, and the pipeline's status becomes 141 -- so a SUCCESSFUL match can
# read as a failed test, nondeterministically, depending on how early in the
# file the match happens to sit. This suite lost an afternoon to exactly that:
# an assertion that passed on the real file and "failed" on a mutant whose only
# change was 30 lines further down.
ps_code() { sed 's/[[:space:]]*#.*$//' "$1"; }
sh_code() { sed 's/^[[:space:]]*#.*$//' "$1"; }

# ---------------------------------------------------------------------------
# 0. The inputs exist and are the size they should be.
# ---------------------------------------------------------------------------
echo "inputs"

for f in "$ENV_PS1" "$ENV_SH" "$RUNTIME_SH" "$ENSURE_TTD"; do
	if [ -f "$f" ]; then
		ok "exists: ${f#"$REPO_ROOT"/}"
	else
		fail "exists: ${f#"$REPO_ROOT"/}" \
			"every assertion about this file below would otherwise pass vacuously"
	fi
done

env_ps1_lines=$(wc -l <"$ENV_PS1" 2>/dev/null || echo 0)
if [ "$env_ps1_lines" -ge "$MIN_ENV_PS1_LINES" ]; then
	ok "env.ps1 is at least $MIN_ENV_PS1_LINES lines ($env_ps1_lines)"
else
	fail "env.ps1 is at least $MIN_ENV_PS1_LINES lines" \
		"got $env_ps1_lines; the file was truncated or this suite is reading the wrong tree"
fi
env_sh_lines=$(wc -l <"$ENV_SH" 2>/dev/null || echo 0)
if [ "$env_sh_lines" -ge "$MIN_ENV_SH_LINES" ]; then
	ok "env.sh is at least $MIN_ENV_SH_LINES lines ($env_sh_lines)"
else
	fail "env.sh is at least $MIN_ENV_SH_LINES lines" \
		"got $env_sh_lines; the file was truncated or this suite is reading the wrong tree"
fi

# ---------------------------------------------------------------------------
# 1. The dev-drive branch must not use existence as its test.
#
# Anchored on the D: lines specifically. `Test-Path` and `[[ -d ]]` are both
# perfectly legitimate elsewhere in these files; it is only as the DEV-DRIVE
# test that they are the bug.
# ---------------------------------------------------------------------------
echo
echo "the dev-drive probe"

ps_d_lines=$(ps_code "$ENV_PS1" | grep -n 'D:[\]' || true)
if [ -n "$ps_d_lines" ]; then
	ok 'env.ps1 still has a D:\ dev-drive branch to check'
else
	fail 'env.ps1 still has a D:\ dev-drive branch to check' \
		'no D:\ line found in code; if the dev-drive preference was removed on' \
		"purpose this suite must be RETARGETED, not left to pass on nothing"
fi

if grep -q 'Test-Path' <<<"$ps_d_lines"; then
	fail "env.ps1's D:\\ branch does not use Test-Path" \
		'Test-Path cannot see a read-only mount: D:\ on eph-win-x64 is a CDFS' \
		"config drive that exists and refuses every write. Offending line(s):" \
		"$(printf '%s' "$ps_d_lines" | tr '\n' '|')"
else
	ok "env.ps1's D:\\ branch does not use Test-Path"
fi

if grep -q "$PS_PROBE_FN" <<<"$ps_d_lines"; then
	ok "env.ps1's D:\\ branch goes through $PS_PROBE_FN"
else
	fail "env.ps1's D:\\ branch goes through $PS_PROBE_FN" \
		"the dev drive must be probed by trying to create in it"
fi

sh_d_lines=$(sh_code "$ENV_SH" | grep -n '/d/' || true)
if [ -n "$sh_d_lines" ]; then
	ok "env.sh still has a /d/ dev-drive branch to check"
else
	fail "env.sh still has a /d/ dev-drive branch to check" \
		"no /d/ line found in code; retarget this suite rather than let it pass on nothing"
fi

if grep -qE '\[\[ *-[dw] +/d/' <<<"$sh_d_lines"; then
	fail "env.sh's /d/ branch does not use [[ -d ]] or [[ -w ]]" \
		"both answer yes for the read-only CDFS mount that D: actually is:" \
		"-d because it exists, -w because Git-Bash's synthesised POSIX bits" \
		"do not carry Windows ACLs. Offending line(s):" \
		"$(printf '%s' "$sh_d_lines" | tr '\n' '|')"
else
	ok "env.sh's /d/ branch does not use [[ -d ]] or [[ -w ]]"
fi

if grep -q "$SH_PROBE_FN" <<<"$sh_d_lines"; then
	ok "env.sh's /d/ branch goes through $SH_PROBE_FN"
else
	fail "env.sh's /d/ branch goes through $SH_PROBE_FN" \
		"the dev drive must be probed by trying to create in it"
fi

# ---------------------------------------------------------------------------
# 2. The probes must actually create something.
#
# A probe named `Test-DirectoryWritable` that only calls `Test-Path` would
# satisfy section 1 and reintroduce the exact defect, so the body is checked.
# ---------------------------------------------------------------------------
echo
echo "the probes create, they do not merely look"

ps_probe_body=$(ps_code "$ENV_PS1" | awk "/^function $PS_PROBE_FN/,/^}/")
if [ -n "$ps_probe_body" ]; then
	ok "env.ps1 defines $PS_PROBE_FN"
else
	fail "env.ps1 defines $PS_PROBE_FN" "the two body assertions below would pass on empty input"
fi
if grep -q 'New-Item -ItemType Directory' <<<"$ps_probe_body"; then
	ok "$PS_PROBE_FN creates a directory to decide"
else
	fail "$PS_PROBE_FN creates a directory to decide" \
		"a probe that only calls Test-Path is the shipped bug wearing a better name"
fi
if grep -q 'Remove-Item' <<<"$ps_probe_body"; then
	ok "$PS_PROBE_FN removes its probe directory"
else
	fail "$PS_PROBE_FN removes its probe directory" \
		"a probe that litters the dev-deps root is a probe that gets deleted later"
fi

sh_probe_body=$(sh_code "$ENV_SH" | awk "/^$SH_PROBE_FN\(\)/,/^}/")
if [ -n "$sh_probe_body" ]; then
	ok "env.sh defines $SH_PROBE_FN"
else
	fail "env.sh defines $SH_PROBE_FN" "the two body assertions below would pass on empty input"
fi
if grep -q 'mkdir' <<<"$sh_probe_body"; then
	ok "$SH_PROBE_FN creates a directory to decide"
else
	fail "$SH_PROBE_FN creates a directory to decide" \
		"only an actual create answers the question; -d and -w both lie here"
fi
if grep -q 'rmdir' <<<"$sh_probe_body"; then
	ok "$SH_PROBE_FN removes its probe directory"
else
	fail "$SH_PROBE_FN removes its probe directory"
fi

# ---------------------------------------------------------------------------
# 2b. The bash probe, actually executed.
#
# Everything above is structural. This section EXTRACTS `_ct_dir_writable`
# from env.sh and runs it, against a directory that exists and refuses
# creation -- the same shape as the read-only CDFS mount that D: turned out to
# be, reproduced portably with a chmod. A probe that returns "writable" here
# would ship the outage again, and no amount of grepping would say so.
#
# `_ct_dir_writable` is pure bash with no Windows dependency, so this runs on
# the Linux verdict runner where the rest of this suite already runs.
# ---------------------------------------------------------------------------
echo
echo "the bash probe, executed"

probe_tmp=$(mktemp -d)
# shellcheck disable=SC1090
if eval "$(sh_code "$ENV_SH" | awk "/^$SH_PROBE_FN\(\)/,/^}/")" 2>/dev/null; then
	ok "$SH_PROBE_FN can be extracted from env.sh and defined"
else
	fail "$SH_PROBE_FN can be extracted from env.sh and defined" \
		"the three behavioural assertions below cannot run"
fi

if declare -F "$SH_PROBE_FN" >/dev/null; then
	mkdir -p "$probe_tmp/writable"
	if "$SH_PROBE_FN" "$probe_tmp/writable"; then
		ok "$SH_PROBE_FN says yes for a writable directory"
	else
		fail "$SH_PROBE_FN says yes for a writable directory" \
			"a probe that refuses everything would push every host to the last-resort fallback"
	fi

	if "$SH_PROBE_FN" "$probe_tmp/does-not-exist"; then
		fail "$SH_PROBE_FN says no for a missing directory"
	else
		ok "$SH_PROBE_FN says no for a missing directory"
	fi

	# The load-bearing case: EXISTS, and still refuses to be written to.
	mkdir -p "$probe_tmp/readonly"
	chmod a-w "$probe_tmp/readonly"
	if [ -d "$probe_tmp/readonly" ] && ! "$SH_PROBE_FN" "$probe_tmp/readonly"; then
		ok "$SH_PROBE_FN says no for a directory that exists but refuses creation"
	else
		fail "$SH_PROBE_FN says no for a directory that exists but refuses creation" \
			"this is the eph-win-x64 D: case: Test-Path/[[ -d ]] say yes and every" \
			"mkdir underneath fails. If this assertion passes vacuously because the" \
			"suite runs as root, run it unprivileged."
	fi
	chmod u+w "$probe_tmp/readonly"
else
	for _ in 1 2 3; do
		fail "$SH_PROBE_FN behavioural check" "the function could not be defined"
	done
fi
rm -rf "$probe_tmp"

# ---------------------------------------------------------------------------
# 3. All three resolvers agree.
# ---------------------------------------------------------------------------
echo
echo "the three resolvers agree"

runtime_sh_code=$(sh_code "$RUNTIME_SH")

if grep -qE 'INSTALL_ROOT="\$\{'"$ROOT_ENV_VAR"':-D:/metacraft-dev-deps\}"' <<<"$runtime_sh_code"; then
	fail "setup-codetracer-runtime-env.sh has no unprobed D: default" \
		"it defaulted to D:/metacraft-dev-deps with no probe at all, so on any" \
		"box without a writable D: it disagreed with env.sh about where the" \
		"toolchain lives and built a PATH of directories that do not exist"
else
	ok "setup-codetracer-runtime-env.sh has no unprobed D: default"
fi

if grep -q "$RUNTIME_PROBE_FN" <<<"$runtime_sh_code"; then
	ok "setup-codetracer-runtime-env.sh probes writability like env.sh does"
else
	fail "setup-codetracer-runtime-env.sh probes writability like env.sh does" \
		"its fallback must reach the same answer env.sh reached"
fi

if grep -q "$PERSISTENT_FALLBACK" <<<"$runtime_sh_code"; then
	ok "setup-codetracer-runtime-env.sh falls back to $PERSISTENT_FALLBACK like env.sh"
else
	fail "setup-codetracer-runtime-env.sh falls back to $PERSISTENT_FALLBACK like env.sh"
fi

# ---------------------------------------------------------------------------
# 4. An explicit root still wins.
# ---------------------------------------------------------------------------
echo
echo "an explicit root is still honoured"

for f in "$ENV_PS1" "$ENV_SH" "$RUNTIME_SH"; do
	rel="${f#"$REPO_ROOT"/}"
	if grep -q "$ROOT_ENV_VAR" "$f"; then
		ok "$rel honours \$$ROOT_ENV_VAR"
	else
		fail "$rel honours \$$ROOT_ENV_VAR" \
			"degrading gracefully must not mean overriding an operator's pinned root"
	fi
done

# ---------------------------------------------------------------------------
# 5. The fallback order: persistent first, volatile last.
# ---------------------------------------------------------------------------
echo
echo "fallback order"

# Anchored on the line that actually ITERATES the fallback, not on any line
# that merely names it. Both resolvers mention RUNNER_TEMP a second time in
# their "could not resolve any writable root" diagnostic, and an earlier draft
# of this suite accepted that -- so deleting the whole fallback loop left the
# gate green. Requiring the loop construct is what closes it.
ps_persist_at=$(ps_code "$ENV_PS1" | grep -n 'LocalApplicationData' | head -1 | cut -d: -f1)
ps_volatile_at=$(ps_code "$ENV_PS1" | grep -nE "foreach .*$VOLATILE_FALLBACK" | head -1 | cut -d: -f1)
if [ -n "$ps_persist_at" ] && [ -n "$ps_volatile_at" ]; then
	ok "env.ps1 offers both a persistent and a last-resort fallback"
	if [ "$ps_persist_at" -lt "$ps_volatile_at" ]; then
		ok "env.ps1 tries the persistent fallback before $VOLATILE_FALLBACK"
	else
		fail "env.ps1 tries the persistent fallback before $VOLATILE_FALLBACK" \
			"$VOLATILE_FALLBACK is wiped between jobs; leading with it turns the" \
			"toolchain cache into a re-download on every job on the persistent runners"
	fi
else
	fail "env.ps1 offers both a persistent and a last-resort fallback" \
		"LocalApplicationData at '${ps_persist_at:-none}', $VOLATILE_FALLBACK at '${ps_volatile_at:-none}'"
	fail "env.ps1 tries the persistent fallback before $VOLATILE_FALLBACK" \
		"not checkable: one of the two fallbacks is missing"
fi

sh_persist_at=$(sh_code "$ENV_SH" | grep -n "$PERSISTENT_FALLBACK" | head -1 | cut -d: -f1)
sh_volatile_at=$(sh_code "$ENV_SH" | grep -nE "for .*$VOLATILE_FALLBACK.*; do" | head -1 | cut -d: -f1)
if [ -n "$sh_persist_at" ] && [ -n "$sh_volatile_at" ]; then
	ok "env.sh offers both a persistent and a last-resort fallback"
	if [ "$sh_persist_at" -lt "$sh_volatile_at" ]; then
		ok "env.sh tries the persistent fallback before $VOLATILE_FALLBACK"
	else
		fail "env.sh tries the persistent fallback before $VOLATILE_FALLBACK" \
			"$VOLATILE_FALLBACK is wiped between jobs"
	fi
else
	fail "env.sh offers both a persistent and a last-resort fallback" \
		"$PERSISTENT_FALLBACK at '${sh_persist_at:-none}', $VOLATILE_FALLBACK at '${sh_volatile_at:-none}'"
	fail "env.sh tries the persistent fallback before $VOLATILE_FALLBACK" \
		"not checkable: one of the two fallbacks is missing"
fi

# ---------------------------------------------------------------------------
# 6. Ensure-Ttd takes the root it is given.
#
# If it ever recomputed a root of its own, fixing the resolver would leave the
# reported failure exactly where it was.
# ---------------------------------------------------------------------------
echo
echo "Ensure-Ttd uses the root it is handed"

ensure_ttd_code=$(ps_code "$ENSURE_TTD")

if grep -qE "$ENSURE_TTD_ROOT_PARAM_RE" <<<"$ensure_ttd_code"; then
	ok "$ENSURE_TTD_ROOT_PARAM_LABEL"
else
	fail "$ENSURE_TTD_ROOT_PARAM_LABEL" \
		"if it resolved its own root, fixing env.ps1 would not fix the reported failure"
fi

if grep -q 'D:' <<<"$ensure_ttd_code"; then
	fail "ensure-ttd.ps1 hard-codes no D: path" \
		"it must use the root env.ps1 resolved, not one of its own"
else
	ok "ensure-ttd.ps1 hard-codes no D: path"
fi

# ---------------------------------------------------------------------------
# Assertion budget: 4 file-existence + 2 size floors + 6 dev-drive probe
# + 6 probe-body + 4 executed-bash-probe + 3 three-resolver + 3 explicit-root
# + 4 fallback-order + 2 Ensure-Ttd.
# ---------------------------------------------------------------------------
echo
expected_assertions=$((4 + 2 + 6 + 6 + 4 + 3 + 3 + 4 + 2))
if [ "$assertions" -ne "$expected_assertions" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$expected_assertions"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
