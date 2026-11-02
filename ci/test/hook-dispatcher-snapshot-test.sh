#!/usr/bin/env bash
#
# hook-dispatcher-snapshot-test.sh -- the dev shell keeps a Reprobuild hook
# dispatcher that another hook manager displaced, driven by the REAL python
# pre-commit and the REAL prek.
#
# THE DEFECT. `prek install` moves the dispatcher to `pre-commit.legacy` and
# takes the slot. On the next dev-shell entry git-hooks.nix's installer runs
# python `pre-commit uninstall`, which does not recognise prek's shim and leaves
# it, then `pre-commit install`, which moves that shim onto `.legacy`,
# OVERWRITING the dispatcher. ci/dev/reclaim-hook-dispatchers.sh then finds no
# dispatcher to put back, and the managed hooks stop running. See "A DISPATCHER
# THE INSTALLER DESTROYS" in that script.
#
# WHAT IS PINNED.
#   1. control: without the snapshot the real tools still destroy the
#      dispatcher, so the cases below test something;
#   2. with the snapshot the dispatcher is restored to the slot, pre-commit's
#      shim is chained as `.repro-local`, prek's shim stranded at `.legacy` is
#      removed, and a real `git commit` runs both the hook and the managed hook;
#   3. the next shell entry keeps that layout, and a commit still runs both;
#   4. the other order (python pre-commit displaced the dispatcher first)
#      keeps the dispatcher too.
#
# `shell_entry` below is git-hooks.nix's installationScript at the rev this
# flake pins (3bbec39: uninstall nine hook types, clear core.hooksPath,
# `install -c <config> -t <stage>`, write the relative core.hooksPath), minus the
# config symlink, between the snapshot and the reclaim exactly as
# nix/shells/main.nix runs them.
#
# Mocks: only the dispatcher, a stand-in carrying the real "# reprobuild hook
# dispatcher" marker and the real chain (`.repro-local`, then the managed hook),
# because the marker is all the scripts read and the real one needs a Reprobuild
# build. pre-commit, prek, git and the commits are real.
#
# Tools: `pre-commit` and `prek` from PATH (devShells.lint carries both), or
# CT_TEST_REAL_PRE_COMMIT / CT_TEST_REAL_PREK. Without them this REFUSES (exit 3)
# rather than skipping: a green tick for a case that ran nothing is the failure
# this suite exists to prevent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/ci/dev/reclaim-hook-dispatchers.sh"

PRE_COMMIT="${CT_TEST_REAL_PRE_COMMIT:-$(command -v pre-commit || true)}"
PREK="${CT_TEST_REAL_PREK:-$(command -v prek || true)}"
if [ -z "$PRE_COMMIT" ] || [ -z "$PREK" ]; then
	echo "FAIL: needs the real pre-commit and prek (pre-commit='$PRE_COMMIT' prek='$PREK');"
	echo "      run it from devShells.lint, or set CT_TEST_REAL_PRE_COMMIT / CT_TEST_REAL_PREK"
	exit 3
fi

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
	shift
	for line in "$@"; do printf '         %s\n' "$line"; done
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
export HOME="$tmp/home" PREK_HOME="$tmp/prek-home" PRE_COMMIT_HOME="$tmp/pre-commit-home"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$tmp"
mkdir -p "$HOME"
printf '[user]\n\tname = t\n\temail = t@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
# Hooks run with git's environment; scrub what a calling hook would export.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
# An ambient PYTHONPATH naming another pre-commit's site-packages outranks the
# one under test: a profile with pre-commit 4.5.1 made 4.3.0 report 4.5.1.
unset PYTHONPATH
ran="$tmp/ran"
export CT_TEST_RAN="$ran"

repo() {
	rm -rf "$tmp/r"
	git init -q "$tmp/r"
	cd "$tmp/r"
	hooks="$tmp/r/.git/hooks"
	rm -f "$hooks"/*.sample
	cat >.pre-commit-config.yaml <<'EOF'
repos:
  - repo: local
    hooks:
      - id: record
        name: record
        entry: sh -c 'echo hook >> "$CT_TEST_RAN"'
        language: system
        pass_filenames: false
        always_run: true
EOF
	git add .pre-commit-config.yaml
	git commit -q --no-verify -m init
	cat >"$hooks/pre-commit" <<'EOF'
#!/bin/sh
# reprobuild hook dispatcher protocol=2
# (fixture: ci/test/hook-dispatcher-snapshot-test.sh)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
if [ -x "$d/pre-commit.repro-local" ]; then
	(unset PRE_COMMIT_RUNNING_LEGACY PREK_RUNNING_LEGACY; exec "$d/pre-commit.repro-local" "$@")
fi
exec "$d/pre-commit.repro-managed" "$@"
EOF
	# shellcheck disable=SC2016 # the managed hook expands it, not this script
	printf '#!/bin/sh\necho managed >>"$CT_TEST_RAN"\n' >"$hooks/pre-commit.repro-managed"
	chmod +x "$hooks/pre-commit" "$hooks/pre-commit.repro-managed"
}

# git-hooks.nix's installationScript (3bbec39), between the snapshot and the
# reclaim as nix/shells/main.nix runs them. NO_SNAPSHOT=1 is the pre-fix shell.
shell_entry() {
	local snap="" h
	if [ "${NO_SNAPSHOT:-}" != 1 ]; then
		snap="$(bash "$TOOL" snapshot || true)"
	fi
	for h in commit-msg post-checkout post-commit post-merge post-rewrite pre-commit pre-merge-commit pre-push prepare-commit-msg; do
		"$PRE_COMMIT" uninstall -t "$h" >/dev/null 2>&1 || true
	done
	git config --local --unset-all core.hooksPath || true
	"$PRE_COMMIT" install -c .pre-commit-config.yaml -t pre-commit >/dev/null
	git config --local core.hooksPath .git/hooks
	if [ "${NO_SNAPSHOT:-}" = 1 ]; then
		bash "$TOOL"
	else
		bash "$TOOL" --snapshot "$snap"
	fi
}

is_dispatcher() { grep -q 'reprobuild hook dispatcher' "$1" 2>/dev/null; }
is_pre_commit() { grep -q '^# File generated by pre-commit:' "$1" 2>/dev/null; }
is_prek() { grep -q '^# File generated by prek:' "$1" 2>/dev/null; }
layout() { for f in "$hooks"/*; do printf '%s ' "$(basename "$f")"; done; }

commit_runs() { # MESSAGE -> what the commit ran, sorted
	: >"$ran"
	echo "$1" >f.txt
	git add f.txt
	if ! git commit -q -m "$1" >"$tmp/commit.out" 2>&1; then
		echo "commit failed: $(tr '\n' ' ' <"$tmp/commit.out")"
		return 0
	fi
	sort "$ran" | tr '\n' ' '
}

# What `prek install` leaves over a dispatcher.
prek_displaced() {
	repo
	"$PREK" install -c .pre-commit-config.yaml -t pre-commit >/dev/null 2>&1
	if ! is_prek "$hooks/pre-commit" || ! is_dispatcher "$hooks/pre-commit.legacy"; then
		echo "FAIL: fixture: prek did not displace the dispatcher ($(layout))"
		exit 1
	fi
}

echo "hook-dispatcher-snapshot ($("$PRE_COMMIT" --version), $("$PREK" --version))"

# 1: control -- without the snapshot the dispatcher is destroyed.
prek_displaced
NO_SNAPSHOT=1 shell_entry 2>/dev/null
if ! is_dispatcher "$hooks/pre-commit" && ! is_dispatcher "$hooks/pre-commit.legacy" &&
	is_prek "$hooks/pre-commit.legacy"; then
	ok "control: without the snapshot, pre-commit's install overwrites the displaced dispatcher"
else
	fail "control: without the snapshot, pre-commit's install overwrites the displaced dispatcher" \
		"the clobber no longer happens, so the cases below test nothing: $(layout)"
fi

# 2: with the snapshot it is restored, and a commit runs both.
prek_displaced
shell_entry 2>"$tmp/err2"
if is_dispatcher "$hooks/pre-commit" && is_pre_commit "$hooks/pre-commit.repro-local" &&
	[ ! -e "$hooks/pre-commit.legacy" ] && grep -q 'restored the Reprobuild dispatcher' "$tmp/err2"; then
	ok "the dispatcher is restored, pre-commit is chained, and prek's stranded shim is removed"
else
	fail "the dispatcher is restored, pre-commit is chained, and prek's stranded shim is removed" \
		"layout: $(layout)" "stderr: $(tr '\n' ' ' <"$tmp/err2")"
fi
got="$(commit_runs one)"
if [ "$got" = "hook managed " ]; then
	ok "a commit runs the pre-commit hook and the managed hook"
else
	fail "a commit runs the pre-commit hook and the managed hook" "ran: $got"
fi

# 3: the next shell entry keeps it.
shell_entry 2>/dev/null
got="$(commit_runs two)"
if is_dispatcher "$hooks/pre-commit" && [ ! -e "$hooks/pre-commit.legacy" ] && [ "$got" = "hook managed " ]; then
	ok "the next shell entry keeps the dispatcher, and a commit still runs both"
else
	fail "the next shell entry keeps the dispatcher, and a commit still runs both" \
		"layout: $(layout)" "ran: $got"
fi

# 4: the other order -- python pre-commit displaced it first.
repo
"$PRE_COMMIT" install -c .pre-commit-config.yaml -t pre-commit >/dev/null
shell_entry 2>/dev/null
got="$(commit_runs three)"
if is_dispatcher "$hooks/pre-commit" && [ ! -e "$hooks/pre-commit.legacy" ] && [ "$got" = "hook managed " ]; then
	ok "a dispatcher python pre-commit displaced is kept too"
else
	fail "a dispatcher python pre-commit displaced is kept too" "layout: $(layout)" "ran: $got"
fi

echo
if [ "$assertions" -ne 5 ]; then
	echo "FAIL: ran $assertions assertions, expected 5"
	failures=$((failures + 1))
fi
if [ "$failures" -ne 0 ]; then
	echo "$failures of $assertions assertions failed"
	exit 1
fi
echo "all $assertions assertions passed"
