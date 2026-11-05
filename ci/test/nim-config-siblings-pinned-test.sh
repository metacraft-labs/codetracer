#!/usr/bin/env bash
# =============================================================================
# Contract: every workspace sibling that a Nim config file puts on the module
# search path is pinned by this repo's `repro.lock`.
#
# # Why this file exists
#
# `src/frontend/storybook_components.nim` imports
# `nim_agents_isonim_viewmodels/agent_harbor/[fixture_source, fleet_vm]`, and
# `config.nims` found it with
#
#     addPathIfDir(workspaceRoot / "nim-agents-isonim-viewmodels/src")
#
# That line was the only place the repo appeared. `repro.nim` and `repro.lock`
# did not name it, so `repro ws enable codetracer` did not check it out,
# `provision-repro-lock-siblings` could not clone it, and nothing recorded
# which revision StoryBook was built against. `addPathIfDir` is silent when
# the directory is missing, so the failure surfaced far away, in every lane
# and every fresh workspace:
#
#     src/frontend/storybook_components.nim(105, 49) Error: cannot open file:
#     nim_agents_isonim_viewmodels/agent_harbor/fixture_source
#
# (codetracer-pm issue
# 2026-11-05-codetracer-imports-nim-agents-isonim-viewmodels-without-declaring-it.md.)
#
# `provision-repro-lock-siblings` states the rule this file enforces: a sibling
# that becomes a real dependency is declared in `repro.nim`/`repro.lock` so
# the lock pins it, and is never cloned off a branch tip.
#
# # What is asserted
#
#   1. Every sibling named by a tracked Nim config file -- `*.nims`
#      (`workspaceRoot / "<sibling>..."` or a relative path that leaves this
#      repo), `nim.cfg` and `*.nim.cfg` (`--path:` / `--path=` / `-p:`
#      entries, bare or under `$config` / `$projectdir`, that leave this
#      repo) -- has a vcs entry in `repro.lock`'s `deps`. `libs/` (vendored
#      submodules) and test fixtures are not scanned: their configs are not
#      this repo's.
#   2. The scan found at least one sibling, so a change to how the configs
#      spell their paths cannot turn this into a vacuous pass.
#   3. Positive controls: the checker fails on a copy of this tree whose
#      lock lacks `nim-agents-isonim-viewmodels` (the issue's exact state)
#      and reports that sibling alone, on one whose `config.nims` names a
#      sibling the lock does not know, and on one whose `nim.cfg` does.
#
# Static, with no siblings and no network, so it runs on a stock runner.
#
# Usage: nim-config-siblings-pinned-test.sh [--check-only <repo-root>]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# check_tree <repo-root>: print each unpinned sibling and exit 1 if any.
check_tree() {
	python3 -I - "$1" <<'PY'
import os
import re
import subprocess
import sys

root = os.path.realpath(sys.argv[1])
workspace = os.path.dirname(root)

files = subprocess.run(
    ["git", "-C", root, "ls-files", "-z", "--", "*.nims", "*nim.cfg"],
    check=True, capture_output=True, text=True,
).stdout.split("\0")
files = [f for f in files
         if f and not f.startswith("libs/") and "/fixtures/" not in f]

# A sibling is the first path component below the workspace root, for a path
# that resolves outside this repo.
def sibling_of(base_dir, rel):
    resolved = os.path.normpath(os.path.join(base_dir, rel))
    if resolved == root or resolved.startswith(root + os.sep):
        return None
    if not resolved.startswith(workspace + os.sep):
        return None
    return resolved[len(workspace) + 1:].split(os.sep)[0]

ws_rel = re.compile(r'workspaceRoot\s*/\s*"([^"]+)"')
src_rel = re.compile(r'currentSourcePath\(\)\.parentDir\(\)\s*/\s*"([^"]+)"')
cfg_path = re.compile(r'^\s*-?-?(?:path|p)[:=]\s*"?([^"\s]+)"?', re.IGNORECASE)
# `$config` is the directory of the .cfg file; `$projectdir` is the project's,
# which for these per-directory configs is the same directory. Any other `$`
# variable (`$nim`, `$home`, ...) cannot name a workspace sibling.
cfg_dir_var = re.compile(r'^\$(?:config|projectdir|projectpath)(?=/|$)', re.IGNORECASE)

found = {}
for rel_file in files:
    path = os.path.join(root, rel_file)
    base = os.path.dirname(path)
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("#", 1)[0]
            names = []
            if rel_file.endswith(".nims"):
                names += [m.split("/")[0] for m in ws_rel.findall(code)]
                names += [sibling_of(base, m) for m in src_rel.findall(code)]
            else:
                m = cfg_path.match(code)
                if m:
                    value = cfg_dir_var.sub(".", m.group(1))
                    if not value.startswith("$"):
                        names.append(sibling_of(base, value))
            for name in filter(None, names):
                found.setdefault(name, []).append(f"{rel_file}:{lineno}")

with open(os.path.join(root, "repro.lock"), encoding="utf-8") as fh:
    pinned = set(re.findall(r'name = "([^"]+)", coord_kind = "vcs"', fh.read()))

if not found:
    print("FAIL: no Nim config file names a workspace sibling; the scan "
          "no longer matches how the configs spell their paths")
    sys.exit(1)

missing = sorted(n for n in found if n not in pinned)
for name in missing:
    print(f"FAIL: sibling '{name}' is on the Nim search path but repro.lock "
          f"does not pin it (declare it in repro.nim and relock): "
          f"{', '.join(found[name])}")
if missing:
    sys.exit(1)
print(f"ok: {len(found)} Nim-config siblings, all pinned by repro.lock: "
      f"{', '.join(sorted(found))}")
PY
}

if [[ ${1:-} == "--check-only" ]]; then
	if [[ $# -ne 2 ]]; then
		echo "usage: $0 [--check-only <repo-root>]" >&2
		exit 2
	fi
	check_tree "$2"
	exit
fi

fail=0
check_tree "$REPO_ROOT" || fail=1

# Positive controls run against throwaway copies of the tracked config files
# and the lock, laid out as <tmp>/ws/codetracer so siblings resolve the same
# way they do in a real workspace.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_copy() {
	local dest="$tmp/$1/codetracer"
	mkdir -p "$dest"
	git -C "$REPO_ROOT" ls-files -z -- '*.nims' '*nim.cfg' repro.lock |
		(cd "$REPO_ROOT" && xargs -0 cp --parents -t "$dest")
	git -C "$dest" init -q
	git -C "$dest" add -A
	printf '%s\n' "$dest"
}

# expect_failure <label> <tree> <sibling>: the checker must fail on <tree>
# and report <sibling> as the ONLY unpinned one, so a control cannot pass on
# collateral damage (for example a mutation that broke the whole lock).
expect_failure() {
	local label="$1" dest="$2" sibling="$3" out reported
	if out="$(check_tree "$dest")"; then
		echo "FAIL: positive control '$label' passed; the checker cannot see the defect"
		fail=1
		return
	fi
	reported="$(sed -n "s/^FAIL: sibling '\([^']*\)' is on the Nim search path.*/\1/p" <<<"$out")"
	if [[ $reported != "$sibling" ]]; then
		echo "FAIL: positive control '$label' did not report exactly '$sibling':"
		echo "$out"
		fail=1
	else
		echo "ok: positive control '$label' is caught"
	fi
}

# repro.lock keeps all of `deps` as one inline array on a single line, so
# remove just this entry's inline table and prove the mutation took.
dest="$(make_copy unpinned-viewmodels)"
sed -i 's/{ name = "nim-agents-isonim-viewmodels", coord_kind = "vcs"[^}]*}, //' "$dest/repro.lock"
if grep -qF 'name = "nim-agents-isonim-viewmodels", coord_kind' "$dest/repro.lock"; then
	echo "FAIL: positive control could not remove nim-agents-isonim-viewmodels from the lock copy"
	fail=1
fi
expect_failure "lock without nim-agents-isonim-viewmodels" "$dest" \
	nim-agents-isonim-viewmodels

dest="$(make_copy undeclared-sibling)"
echo 'addPathIfDir(workspaceRoot / "nim-undeclared-sibling/src")' >>"$dest/config.nims"
expect_failure "config.nims names an undeclared sibling" "$dest" \
	nim-undeclared-sibling

dest="$(make_copy undeclared-cfg-sibling)"
# shellcheck disable=SC2016 # a literal Nim $config, not a shell expansion
echo '--path:"$config/../../../nim-undeclared-cfg-sibling/src"' >>"$dest/src/ct_test/nim.cfg"
expect_failure "nim.cfg names an undeclared sibling" "$dest" \
	nim-undeclared-cfg-sibling

exit "$fail"
