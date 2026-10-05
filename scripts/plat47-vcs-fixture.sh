#!/usr/bin/env bash
# plat47-vcs-fixture.sh <dir> — PLAT-47 deliverable 4: a REAL git repository
# whose working tree has one file in each of the three states the VCS panes
# are compared on:
#
#   notes.txt     modified   (committed, then edited, not staged)   M
#   added.txt     added      (new, staged)                          A
#   scratch.txt   untracked  (new, never added)                     ?
#
# plus `unchanged.txt`, committed and untouched (it must NOT be listed), on the
# branch `plat47-vcs`. Deterministic by construction — fixed names, contents,
# identity and dates — so the desktop's capture
# (`plat47-vcs-capture.spec.ts`) and the terminal's and GPUI's suites build the
# same repository and read the same panel. <dir> must not exist or be empty.
set -euo pipefail
dir="${1:?usage: plat47-vcs-fixture.sh <dir>}"
mkdir -p "$dir"
cd "$dir"
if [ -n "$(ls -A . 2>/dev/null)" ]; then
	echo "plat47-vcs-fixture: $dir is not empty" >&2
	exit 1
fi
export GIT_AUTHOR_NAME="CodeTracer Fixture" GIT_AUTHOR_EMAIL="fixture@codetracer.invalid"
export GIT_COMMITTER_NAME="CodeTracer Fixture" GIT_COMMITTER_EMAIL="fixture@codetracer.invalid"
export GIT_AUTHOR_DATE="2026-09-28T12:00:00Z" GIT_COMMITTER_DATE="2026-09-28T12:00:00Z"
git -c init.defaultBranch=plat47-vcs init -q .
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"
git config commit.gpgsign false
printf 'first line\n' >notes.txt
printf 'stays as committed\n' >unchanged.txt
git add notes.txt unchanged.txt
git commit -q -m "Initial fixture commit"
printf 'first line\nan edit the index has not seen\n' >notes.txt
printf 'a new file, staged\n' >added.txt
git add added.txt
printf 'never added\n' >scratch.txt
