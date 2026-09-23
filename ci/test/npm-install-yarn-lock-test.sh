#!/usr/bin/env bash
#
# npm-install-yarn-lock-test.sh — the GUI harness's `npm install` must leave
# `src/tests/gui/yarn.lock` byte-identical.
#
# WHAT THIS IS ABOUT
#
# `src/tests/gui` is installed by two package managers: npm (every `just test-*`
# recipe that drives Playwright) and yarn (`env.sh`'s Windows/DIY bootstrap,
# which runs `yarn install --frozen-lockfile` when a `yarn.lock` is present).
# The tracked lockfile is `yarn.lock`.  npm >= 7 maintains an existing
# `yarn.lock` as a secondary lockfile and writes it from the tree it ACTUALLY
# installed — which on Linux omits `playwright`'s darwin-only optional
# dependency `fsevents@2.3.2`.  So every GUI run deleted that block and left
# the worktree dirty; several agents restored it by hand before anyone traced
# it to the install.  `ci/lib/npm-install.sh` absorbs the rewrite; its header
# records the flags that were measured and rejected (`--no-save` does not help;
# `--no-package-lock` helps by making the install non-reproducible).
#
# WHY THE `npm` HERE IS A STUB — the one piece of mocking in this file
#
# The behaviour under test is the WRAPPER's, not npm's: "whatever npm did to
# yarn.lock, put it back, and say so when npm wanted to add rather than drop".
# Driving that with the real npm would need the network, would take the
# registry's current opinion of `^5.0.0` as an input, and — decisively — could
# only ever exercise the ONE rewrite this platform happens to produce.  A stub
# lets each rewrite shape be stated exactly: a pure deletion (the fsevents
# case), an addition (a stale lockfile), and a failing install (npm rewrites
# the lockfile BEFORE it reports the failure, so the restore must survive a
# non-zero exit).  The seam is npm's command-line contract, which is stable and
# not ours to change.  `src/tests/gui/yarn.lock` itself is used as the fixture
# input, so the shapes are asserted against the real file rather than an
# invented one.
#
# Run: bash ci/test/npm-install-yarn-lock-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${REPO_ROOT}/ci/lib/npm-install.sh"
REAL_LOCK="${REPO_ROOT}/src/tests/gui/yarn.lock"

failures=0
checks=0

fail() {
	echo "  FAIL: $*" >&2
	failures=$((failures + 1))
}

ok() {
	echo "  ok: $*"
}

expect() {
	# expect <description> <condition-rc>
	checks=$((checks + 1))
	if [ "$2" -eq 0 ]; then ok "$1"; else fail "$1"; fi
}

# expect_ok / expect_fail <description> <command...>
#
# The command is RUN BY THESE, rather than run by the caller and its `$?`
# passed in.  `$?` is overwritten by whatever the next expansion evaluates —
# including the `[ ... ]` inside a `$(...)` written to convert it — so the
# indirect spelling silently graded the wrong thing, and shellcheck says so
# (SC2181/SC2319).  Running the command here means the status being judged
# cannot have been clobbered between producing it and reading it.
expect_ok() {
	local desc="$1"
	shift
	local rc=0
	"$@" || rc=$?
	expect "${desc}" "${rc}"
}

expect_fail() {
	local desc="$1"
	shift
	local rc=0
	"$@" || rc=$?
	if [ "${rc}" -ne 0 ]; then expect "${desc}" 0; else expect "${desc}" 1; fi
}

# contains <needle> <haystack> — a grep with the argument order the helpers
# above need (command first, then its arguments).
#
# shellcheck disable=SC2329  # invoked indirectly, as `expect_ok … contains …`
contains() {
	grep -q -- "$1" <<<"$2"
}

if [ ! -x "${HELPER}" ] && [ ! -f "${HELPER}" ]; then
	echo "ERROR: ${HELPER} is missing — the GUI recipes call it by path." >&2
	exit 1
fi

if [ ! -f "${REAL_LOCK}" ]; then
	echo "ERROR: ${REAL_LOCK} is missing; this guard uses it as its fixture." >&2
	exit 1
fi

# The block npm strips on Linux.  Asserted here so that if the harness ever
# stops depending on a darwin-only optional, this guard says so by name instead
# of passing vacuously on a lockfile that has nothing left to strip.
checks=$((checks + 1))
if grep -q '^fsevents@' "${REAL_LOCK}"; then
	ok "the tracked yarn.lock still carries the darwin-only fsevents entry"
else
	fail "src/tests/gui/yarn.lock no longer has an 'fsevents@' block — the rewrite this guard is about may no longer be reachable; re-measure before deleting anything"
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# A stub `npm` whose only job is to mangle yarn.lock in a stated way.
#
# $CT_FAKE_NPM_MODE selects the shape; $CT_FAKE_NPM_RC its exit status.
# ---------------------------------------------------------------------------
mkdir -p "${work}/bin"
cat >"${work}/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -u
case "${CT_FAKE_NPM_MODE}" in
strip)
	# What the real npm does on Linux: drop the darwin-only optional's block.
	# The block runs from the `fsevents@…:` header to the blank line after it.
	awk '/^fsevents@/ {skip=1} skip && /^$/ {skip=0; next} !skip' yarn.lock >yarn.lock.tmp
	mv yarn.lock.tmp yarn.lock
	;;
add)
	# A lockfile that is stale against package.json: npm knows a package the
	# lock does not describe.
	printf '\nbrand-new-package@1.2.3:\n  version "1.2.3"\n' >>yarn.lock
	;;
none) ;;
*)
	echo "fake npm: unknown mode ${CT_FAKE_NPM_MODE}" >&2
	exit 64
	;;
esac
exit "${CT_FAKE_NPM_RC:-0}"
STUB
chmod +x "${work}/bin/npm"

# Each case gets its own copy of the real lockfile plus a package.json, so the
# helper is pointed at a throwaway directory and the repo is never written to.
new_case() {
	local name="$1"
	local dir="${work}/${name}"
	mkdir -p "${dir}"
	cp "${REAL_LOCK}" "${dir}/yarn.lock"
	printf '{"name":"fixture","private":true}\n' >"${dir}/package.json"
	printf '%s' "${dir}"
}

run_helper() {
	# run_helper <dir> <mode> <rc> -> prints combined output, returns helper rc
	local dir="$1" mode="$2" rc="$3"
	CT_FAKE_NPM_MODE="${mode}" CT_FAKE_NPM_RC="${rc}" \
		PATH="${work}/bin:${PATH}" \
		bash "${HELPER}" "${dir}" 2>&1
}

echo "=== ci/test/npm-install-yarn-lock-test.sh ==="

# --- 1. A pure deletion (the fsevents strip) is reverted, silently. ---------
dir="$(new_case strip)"
rc=0
out="$(run_helper "${dir}" strip 0)" || rc=$?
expect_ok "a stripping install exits 0" test "${rc}" -eq 0
expect_ok "the fsevents strip is reverted — yarn.lock is byte-identical" \
	cmp -s "${REAL_LOCK}" "${dir}/yarn.lock"
expect_fail "a pure deletion is reverted without a warning" \
	contains "WARNING" "${out}"

# Prove the stub actually strips, so case 1 cannot pass because nothing happened.
dir="$(new_case strip-control)"
(cd "${dir}" && CT_FAKE_NPM_MODE=strip CT_FAKE_NPM_RC=0 "${work}/bin/npm" install >/dev/null 2>&1)
expect_fail "control: the stub npm does mangle an unwrapped yarn.lock" \
	cmp -s "${REAL_LOCK}" "${dir}/yarn.lock"

# --- 2. An addition is reverted AND reported. -------------------------------
dir="$(new_case add)"
rc=0
out="$(run_helper "${dir}" add 0)" || rc=$?
expect_ok "an added entry is reverted — npm does not own this file" \
	cmp -s "${REAL_LOCK}" "${dir}/yarn.lock"
expect_ok "an added entry is reported, because it means package.json moved" \
	contains "WARNING: npm wanted to ADD entries" "${out}"
expect_ok "the warning names the tool that DOES own the lockfile" \
	contains "yarn install" "${out}"

# --- 3. A failing install still restores, and still fails. ------------------
dir="$(new_case fails)"
rc=0
out="$(run_helper "${dir}" strip 7)" || rc=$?
expect_ok "a failing npm install propagates its exit status" test "${rc}" -eq 7
expect_ok "a failing npm install still leaves yarn.lock intact" \
	cmp -s "${REAL_LOCK}" "${dir}/yarn.lock"

# --- 4. No yarn.lock at all: the helper must not invent one or crash. -------
dir="$(new_case nolock)"
rm -f "${dir}/yarn.lock"
rc=0
out="$(run_helper "${dir}" none 0)" || rc=$?
expect_ok "a directory with no yarn.lock installs cleanly" test "${rc}" -eq 0
expect_ok "a directory with no yarn.lock does not acquire one" \
	test ! -e "${dir}/yarn.lock"

# --- 5. A missing directory is refused by name, not ignored. ----------------
rc=0
out="$(CT_FAKE_NPM_MODE=none CT_FAKE_NPM_RC=0 PATH="${work}/bin:${PATH}" \
	bash "${HELPER}" "${work}/does-not-exist" 2>&1)" || rc=$?
expect_ok "a missing target directory is a failure" test "${rc}" -ne 0
expect_ok "a missing target directory is named in the message" \
	contains "no such directory" "${out}"

echo ""
if [ "${failures}" -eq 0 ]; then
	echo "npm-install-yarn-lock-test: ${checks} checks, all passed"
	exit 0
fi
echo "npm-install-yarn-lock-test: ${failures} of ${checks} checks FAILED" >&2
exit 1
