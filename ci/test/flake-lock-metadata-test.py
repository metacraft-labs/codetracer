#!/usr/bin/env python3
"""Helper for ci/test/flake-lock-metadata-test.sh.

Three subcommands, kept in a file of their own rather than inlined as
heredocs so that the shell suite stays readable and so each piece can be
exercised on its own:

  rows <flake.lock>   one TSV line per DIRECT `github` input that is pinned to
                      a revision: name, owner, repo, rev, lastModified.
  to-epoch <iso8601>  the UTC epoch seconds of an ISO-8601 timestamp, which is
                      the unit `flake.lock` records `lastModified` in.
  committer-date      read a GitHub commits API response on stdin and print
                      `.commit.committer.date` (the curl fallback path; the
                      `gh` path uses `--jq` and never reaches this).
"""

from __future__ import annotations

import datetime
import json
import sys


def rows(lock_path: str) -> int:
    with open(lock_path, encoding="utf-8") as fh:
        lock = json.load(fh)

    nodes = lock["nodes"]
    root = nodes[lock["root"]]["inputs"]

    for name, ref in sorted(root.items()):
        # A list value is a `follows` path into another node; it has no lock of
        # its own to be wrong.
        if not isinstance(ref, str):
            continue
        locked = nodes.get(ref, {}).get("locked", {})
        if locked.get("type") != "github":
            continue
        if not locked.get("rev") or not locked.get("lastModified"):
            continue
        print(
            "\t".join(
                [
                    name,
                    locked["owner"],
                    locked["repo"],
                    locked["rev"],
                    str(locked["lastModified"]),
                ]
            )
        )
    return 0


def to_epoch(iso: str) -> int:
    stamp = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    print(int(stamp.timestamp()))
    return 0


def committer_date() -> int:
    payload = json.load(sys.stdin)
    print(payload.get("commit", {}).get("committer", {}).get("date", ""))
    return 0


def main(argv: list[str]) -> int:
    # LF, never CRLF. The shell suite compares these values as strings, and on
    # a Windows checkout python3's default text mode appends a carriage return
    # that makes every comparison fail while printing two identical-looking
    # numbers. Fixed here rather than filtered downstream so there is one place
    # it can be wrong.
    sys.stdout.reconfigure(newline="\n")
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]
    if command == "rows":
        return rows(argv[2])
    if command == "to-epoch":
        return to_epoch(argv[2])
    if command == "committer-date":
        return committer_date()
    print(f"unknown subcommand: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
