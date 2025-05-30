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

print(f"https://github.com/{a['owner']}/{a['repo']}.git")
print(a["rev"])
