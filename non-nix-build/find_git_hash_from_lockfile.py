#!/usr/bin/env python3
# Prints the repository and the current lock has from flake.lock. This allows one to grep for github.com
# to get both the repo and the hash with a single call
import json
import sys
import os

if len(sys.argv) < 2:
    print("Error: need a dependency's name as an argument!")
    exit(1)

f = open(f"{os.environ['PWD']}/flake.lock", "r")
contents = f.read()
f.close()

obj = json.loads(contents)
a = obj["nodes"][sys.argv[1]]["locked"]

# Flake inputs can be locked under different node types: the
# ``github`` type stores ``owner``/``repo`` separately while the
# ``git`` type carries the full ``url`` and (optionally) a ``ref``.
# Both forms map to the same ``git clone <url> && git checkout
# <rev>`` recipe used by install_nargo.sh and install_wazero.sh, so
# normalise to a clone URL here.
node_type = a.get("type", "")
if node_type == "github":
    print(f"https://github.com/{a['owner']}/{a['repo']}.git")
elif node_type == "git":
    print(a["url"])
else:
    raise SystemExit(
        f"unsupported flake.lock node type {node_type!r} for input "
        f"{sys.argv[1]!r}; extend find_git_hash_from_lockfile.py"
    )
print(a["rev"])
