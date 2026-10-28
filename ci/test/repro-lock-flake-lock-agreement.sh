#!/usr/bin/env bash
#
# repro-lock-flake-lock-agreement.sh — fail, BY NAME, on any sibling that this
# repository pins at one revision in `flake.lock` and at another in
# `repro.lock`.
#
# The two locks are read by different builds (Nix, and reprobuild's provisioning
# of the from-source siblings), and both describe the SAME source a product build
# compiles against. A sibling moved in one and not the other builds a different
# product depending on which tool provisioned it — measured on 2026-10-26: the
# code needed `isonim-tui` 70124210 (its compositor's grapheme fencing), which
# `flake.lock` pinned while `repro.lock` still pinned 029cc0cf, so a reprobuild
# workspace at the lock's pins could not build what Nix built (codetracer-pm
# issue `2026-10-27-repro-lock-pinned-an-isonim-tui-older-than-flake-lock`).
#
# THE RULE: for every root input of `flake.lock` that names a GitHub repository
# `repro.lock` also declares (same owner/repo), the two revisions are equal. An
# input that names a DIFFERENT repository under the same name is not the same
# pin and is reported as such, never compared (`nim-stew`: the flake builds the
# recorders against status-im's, the workspace takes metacraft-labs' fork).
#
# Reads the REAL tree (this is a gate, not a contract suite): `flake.lock` and
# `repro.lock` at the repository root, or the files named by
# `FLAKE_LOCK` / `REPRO_LOCK`. python3 and nothing else; under a second.
#
# Run: bash ci/test/repro-lock-flake-lock-agreement.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLAKE_LOCK="${FLAKE_LOCK:-$REPO_ROOT/flake.lock}"
REPRO_LOCK="${REPRO_LOCK:-$REPO_ROOT/repro.lock}"

command -v python3 >/dev/null 2>&1 || {
	echo "FAIL: python3 is not on PATH; the locks were not compared (nothing is" >&2
	echo "      known about them)" >&2
	exit 2
}

python3 - "$FLAKE_LOCK" "$REPRO_LOCK" <<'PY'
import json
import re
import sys

flake_path, repro_path = sys.argv[1], sys.argv[2]
try:
    nodes = json.load(open(flake_path))["nodes"]
except (OSError, ValueError, KeyError) as e:
    print(f"FAIL: {flake_path} could not be read as a flake lock: {e}")
    sys.exit(2)
try:
    repro = open(repro_path).read()
except OSError as e:
    print(f"FAIL: {repro_path} could not be read: {e}")
    sys.exit(2)

deps = {}
for m in re.finditer(r'\{ name = "([^"]+)", (?:self = "true", )?coord_kind = "vcs", '
                     r'url = "https://github.com/([^"/]+)/([^"/]+?)(?:\.git)?", '
                     r'ref = "[^"]*", revision = "([0-9a-f]{40})"', repro):
    name, owner, repo, rev = m.groups()
    deps[name] = (owner.lower(), repo.lower(), rev)
if not deps:
    print(f"FAIL: {repro_path} declares no vcs dependency this check can read")
    sys.exit(2)

compared, mismatched, other_repo = 0, [], []
for name, ref in nodes["root"]["inputs"].items():
    if not isinstance(ref, str) or name not in deps:
        continue
    locked = nodes[ref].get("locked", {})
    if locked.get("type") != "github":
        continue
    owner, repo = locked.get("owner", "").lower(), locked.get("repo", "").lower()
    d_owner, d_repo, d_rev = deps[name]
    if (owner, repo) != (d_owner, d_repo):
        other_repo.append(f"{name}: flake {owner}/{repo}, repro.lock {d_owner}/{d_repo}")
        continue
    compared += 1
    if locked.get("rev") != d_rev:
        mismatched.append(f"{name}: flake.lock {locked.get('rev')}, repro.lock {d_rev}")

for line in other_repo:
    print(f"  not the same pin (different repositories): {line}")
if mismatched:
    for line in mismatched:
        print(f"FAIL: {line}")
    print(f"FAIL: {len(mismatched)} of {compared} shared sibling pins disagree; "
          "move both locks together")
    sys.exit(1)
print(f"ok: {compared} sibling pins agree between flake.lock and repro.lock")
PY
