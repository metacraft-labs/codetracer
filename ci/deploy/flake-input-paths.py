#!/usr/bin/env python3
"""flake-input-paths.py -- the store paths of flake.lock's locked inputs.

Every input flake.lock locks with a `narHash` is fetched into the store as a
fixed-output path named `source`, whose store path follows from that hash
alone. This prints those paths (one per line, those present in the local store
only with --existing), so ci/deploy/build-nix-and-push-to-attic.sh can push
them to the binary cache without asking Nix to evaluate or fetch anything --
`nix flake archive` refuses the whole flake as soon as one node is unlocked.

The computation is Nix's makeFixedOutputPath for a recursive sha256 hash,
which uses the NAR hash itself (no "fixed:out" inner hash):
  digest = sha256("source:sha256:<narHash hex>:/nix/store:source")
  path   = /nix/store/<nix32(xor-fold(digest, 20))>-source
"""

import base64
import hashlib
import json
import os
import sys

NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"


def nix32(data: bytes) -> str:
    n = (len(data) * 8 - 1) // 5 + 1
    out = []
    for i in range(n - 1, -1, -1):
        b = i * 5
        j, k = divmod(b, 8)
        c = data[j] >> k
        if j + 1 < len(data):
            c |= data[j + 1] << (8 - k)
        out.append(NIX32[c & 0x1F])
    return "".join(out)


def fold(digest: bytes, size: int) -> bytes:
    out = bytearray(size)
    for i, b in enumerate(digest):
        out[i % size] ^= b
    return bytes(out)


def source_path(nar_hash: str, store="/nix/store") -> str:
    algo, _, b64 = nar_hash.partition("-")
    if algo != "sha256":
        raise ValueError(f"unsupported narHash algorithm: {nar_hash}")
    hexd = base64.b64decode(b64).hex()
    digest = hashlib.sha256(f"source:sha256:{hexd}:{store}:source".encode()).digest()
    return f"{store}/{nix32(fold(digest, 20))}-source"


def main(argv):
    existing = "--existing" in argv
    args = [a for a in argv[1:] if a != "--existing"]
    lock = json.load(open(args[0] if args else "flake.lock"))
    seen = set()
    for node in lock.get("nodes", {}).values():
        h = (node.get("locked") or {}).get("narHash")
        if not h or h in seen:
            continue
        seen.add(h)
        p = source_path(h)
        if not existing or os.path.exists(p):
            print(p)


if __name__ == "__main__":
    main(sys.argv)
