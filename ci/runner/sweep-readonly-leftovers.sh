#!/usr/bin/env bash
# =============================================================================
# sweep-readonly-leftovers.sh — restore owner-write over a persistent runner's
# work directory so the next `actions/checkout` can clean it.
#
# THIS FILE IS THE CANONICAL COPY OF A STEP THAT CANNOT `uses:` IT.
#
# The sweep has to run BEFORE `actions/checkout`, and before checkout the
# repository — and therefore this script — is not on the runner's disk. So
# everything from the `BEGIN INLINE BODY` marker down is pasted verbatim into
# the `run:` block of every job that needs it in
# .github/workflows/codetracer.yml, and ci/test/readonly-leftovers-sweep-test.sh
# asserts the pasted copies are byte-identical to the body here. That test is
# also the only place the sweep is EXECUTED against a fixture, which is the
# point: an inline `run:` block has no other way to be tested.
#
# The body is indented with SPACES, unlike the rest of ci/, because it is
# embedded in a YAML block scalar.
#
# ## The defect
#
# Run 33734457928, job 100581650873, runner m3-mcl-003, step 4 (`Checkout`):
#
#   warning: failed to remove non-nix-build/CodeTracer.app/Contents/MacOS/
#     node_modules/<31,307 paths>: Permission denied
#   ##[warning]Unable to clean or reset the repository. The repository will be
#     recreated instead.
#   Deleting the contents of '/private/var/lib/github-runner-work/mcl-003/...'
#   ##[error]File was unable to be removed Error: EACCES: permission denied,
#     unlink '.../CodeTracer.app/Contents/MacOS/node_modules/abbrev/LICENSE'
#
# All 31,307 warnings name paths under one tree: the staged `node_modules`
# inside `non-nix-build/CodeTracer.app`, which `dmg-build` copies out of the
# Nix store. Store directories are mode 0555, `shutil.copytree` preserved that,
# and the `.app` is gitignored (non-nix-build/.gitignore) so it SURVIVES in the
# persistent work directory. The next job's `git clean -ffdx` then cannot
# unlink anything inside those directories, checkout falls back to deleting the
# whole checkout, and node's unlink hits the same EACCES.
#
# The source is fixed in scripts/stage-desktop-node-modules.py, which now
# restores owner-write over what it stages. This sweep is the BACKSTOP: a
# source fix does not clean the poison already sitting on m3-mcl-003's disk.
#
# ## Why it measures DIRECTORIES
#
# A read-only FILE is not the problem and is completely normal — git's own
# `.git/objects/pack/*.pack` and `*.idx` are 0444 by design, and counting them
# would drown the signal (4,853 such files in a routine checkout of this repo).
# POSIX unlink needs write permission on the PARENT DIRECTORY, not on the file.
# So the actionable count is "directories that are not owner-writable", and
# that is what this prints before and after.
#
# ## Why it is written in pure bash
#
# `grep`, `sed`, `awk` and `find` are NOT on PATH in a raw `run:` step on the
# nix-darwin m3 runners: the runner service's PATH is the nix profile built
# from `extraPackages` in metacraft-labs/infra services/github-runners/
# common.nix (coreutils-full, git, curl, jq, gh, gnupg, openssh, direnv) and
# does NOT include /usr/bin. This campaign has already been bitten by that
# once, on this very runner class: a verification step used `grep -ciE`, grep
# exited 127, `|| true` swallowed it, and an EMPTY count printed as a pass.
#
# `chmod` comes from coreutils-full and IS present — but the body proves that
# rather than assuming it, because a missing `chmod` would otherwise be exactly
# the same silent no-op.
#
# The existing "Sweep stale git lock files from the persistent work directory"
# step does contain a `chmod -R u+w`, and it did NOT cover this for two
# independent reasons: it exists in exactly one job
# (`visual-replay-regression-gate`, `runs-on: [self-hosted, gpu]`), and it is
# built on `find`, which the m3 macOS runners do not have.
# =============================================================================

# --- BEGIN INLINE BODY (kept byte-identical in .github/workflows/codetracer.yml)
set -uo pipefail
shopt -s dotglob nullglob
root="${RUNNER_WORKSPACE:-}"
echo "ro-sweep: runner=${RUNNER_NAME:-?} root=${root:-<unset>}"
if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "ro-sweep: found 0 unwritable directory(ies) (work dir absent - fresh runner)"
  echo "ro-sweep: NOTHING FOUND - this host was already clean, mode 3 did not apply here"
  exit 0
fi
ro_count=0
ro_shown=0
ro_blind=0
# Directory-only recursion via a trailing-slash glob, so bash never has to test
# the tens of thousands of regular files one at a time. `"$d"/*/` also matches
# symlinks TO directories; those are skipped, because following them leaves the
# work directory (these checkouts link into /nix/store) and a store path is not
# ours to chmod.
scan() {
  local d="$1" e p
  for e in "$d"/*/; do
    p="${e%/}"
    # `[ -L "$p" ] && continue` would be shorter and WRONG: GitHub runs `run:`
    # blocks under `bash -e`, where a bare `A && B` list that evaluates false is
    # a fatal command. Every branch here is a condition, never a bare list.
    if [ -L "$p" ]; then
      continue
    fi
    if [ ! -r "$p" ] || [ ! -x "$p" ]; then
      ro_blind=$((ro_blind + 1))
      continue
    fi
    if [ ! -w "$p" ]; then
      ro_count=$((ro_count + 1))
      if [ "$ro_shown" -lt 10 ]; then
        ro_shown=$((ro_shown + 1))
        echo "ro-sweep:   unwritable $p"
      fi
    fi
    scan "$p"
  done
  return 0
}
scan "$root"
before="$ro_count"
echo "ro-sweep: found $before unwritable directory(ies) under $root ($ro_blind unreadable)"
if [ "$before" -eq 0 ]; then
  echo "ro-sweep: NOTHING FOUND - this host was already clean, mode 3 did not apply here"
  exit 0
fi
# Prove the tool exists before claiming it worked: a `chmod` that is not on
# PATH exits 127, and a `|| true` would turn that into a silent pass.
chmod_bin="$(command -v chmod 2>/dev/null || true)"
if [ -z "$chmod_bin" ]; then
  for candidate in /bin/chmod /usr/bin/chmod /run/current-system/sw/bin/chmod; do
    if [ -x "$candidate" ]; then
      chmod_bin="$candidate"
      break
    fi
  done
fi
if [ -z "$chmod_bin" ]; then
  echo "ro-sweep: FATAL no chmod on PATH and none at /bin/chmod;" \
    "$before directory(ies) CANNOT be fixed" >&2
  exit 1
fi
echo "ro-sweep: using $chmod_bin"
"$chmod_bin" -R u+w "$root" 2>/dev/null || true
ro_count=0
ro_shown=0
ro_blind=0
scan "$root"
after="$ro_count"
echo "ro-sweep: after chmod -R u+w: $after unwritable directory(ies) remain"
echo "ro-sweep: RESTORED owner-write on $((before - after)) directory(ies)"
if [ "$after" -ne 0 ]; then
  echo "ro-sweep: WARNING $after directory(ies) are not owned by the runner user;" \
    "checkout will still fail to clean them"
fi
# --- END INLINE BODY
