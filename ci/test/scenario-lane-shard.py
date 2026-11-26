#!/usr/bin/env python3
"""scenario-lane-shard.py <lane.yaml> <i>/<n> [--list]

One shard of a scenario lane: the lane file with only the `applicable:`
entries that `owners` gives shard i (shard 1 takes a light slice, one entry
in every 2n - 1, because it also carries a job's other steps; the rest go
round robin over shards 2..n).
Everything else in the file (pack, backend, modes, timeouts, `unsupported:`)
is kept as it is, and the lane is renamed `<name>-shard-<i>-of-<n>` so the
shards' run directories do not collide.

The shard file is written beside the lane file (its entries are relative
paths), as `.<name>.shard-<i>-of-<n>.lane.yaml`, and its path is printed.
With --list, the shard's entries are printed instead, one per line, and
nothing is written (ci/test/scenario-lane-shard-test.sh uses it to check that
the shards cover the lane exactly).

BY TIME, WHERE THE LANE HAS MEASURED TIMES. A lane with a `<name>.timings.tsv`
beside it (`<entry><TAB><seconds>`, `#` lines are prose) is split by time
instead: entries heaviest first, each to the shard with the least time so
far (ties to the lower shard, then file order), an entry the file does not
list weighing the median of those it does. Every shard is then equal, shard 1
included: such a lane runs in jobs of its own (the electron lane's matrix in
codetracer.yml). A timings line naming no entry of the lane is refused, so the
file cannot outlive the scenarios it measured.

The lane file stays the one list of what the lane runs. A CI job splits it at
run time (ci/test/scenarios.sh, SCENARIO_LANE_SHARD=i/n), so no scenario can
be left out of every shard by an edit to a hand-split copy.
"""
import os
import re
import sys


def parse(path):
    with open(path) as f:
        lines = f.read().split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("applicable:"))
    except StopIteration:
        sys.exit(f"scenario-lane-shard: {path} has no 'applicable:' list")
    end = start + 1
    while end < len(lines) and (lines[end].startswith(" ") or lines[end].strip() == ""):
        end += 1
    body = lines[start + 1:end]
    entries = [l for l in body if re.match(r"^\s+- ", l)]
    return lines, start, end, entries


def owners(count, n):
    """The shard (1..n) of each of `count` entries, in file order.

    Shard 1 carries a CI job's other steps (the GPUI window captures), so it
    takes a light slice: one entry in every 2n - 1. The rest go round robin
    over shards 2..n. With n == 1 every entry is shard 1's.
    """
    if n == 1:
        return [1] * count
    result, nxt = [], 0
    for k in range(count):
        if k % (2 * n - 1) == 0:
            result.append(1)
        else:
            result.append(2 + nxt % (n - 1))
            nxt += 1
    return result


def timings_of(path, entries):
    """The weight of each entry, from `<name>.timings.tsv` beside the lane
    file; None when there is no such file."""
    base = os.path.basename(path)
    if not base.endswith(".lane.yaml"):
        return None
    tpath = os.path.join(os.path.dirname(path), base[: -len(".lane.yaml")] + ".timings.tsv")
    if not os.path.exists(tpath):
        return None
    keys = [re.sub(r"^\s+- ", "", e).strip() for e in entries]
    measured = {}
    with open(tpath) as f:
        for number, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            entry, _, seconds = line.partition("\t")
            if not re.fullmatch(r"\d+(\.\d+)?", seconds.strip()):
                sys.exit(f"scenario-lane-shard: {tpath}:{number}: not '<entry><TAB><seconds>'")
            if entry not in keys:
                sys.exit(f"scenario-lane-shard: {tpath}:{number}: '{entry}' is no entry of {path}; remove it")
            measured[entry] = float(seconds)
    if not measured:
        return None
    values = sorted(measured.values())
    median = values[len(values) // 2]
    return [measured.get(k, median) for k in keys]


def weighted_owners(weights, n):
    """The shard (1..n) of each entry: heaviest first, each to the least-loaded
    shard (ties to the lower shard; equal weights in file order)."""
    load = [0.0] * n
    result = [0] * len(weights)
    for k in sorted(range(len(weights)), key=lambda k: (-weights[k], k)):
        target = min(range(n), key=lambda s: (load[s], s))
        load[target] += weights[k]
        result[k] = target + 1
    return result


def main(argv):
    if len(argv) < 3 or not re.fullmatch(r"\d+/\d+", argv[2]):
        sys.exit(__doc__)
    path = argv[1]
    i, n = (int(x) for x in argv[2].split("/"))
    if not (1 <= i <= n):
        sys.exit(f"scenario-lane-shard: shard {i}/{n} is out of range")
    lines, start, end, entries = parse(path)
    weights = timings_of(path, entries)
    shard_of = owners(len(entries), n) if weights is None else weighted_owners(weights, n)
    if "--weights" in argv[3:]:
        # The seconds each shard is expected to take, one line per shard.
        if weights is None:
            sys.exit(f"scenario-lane-shard: {path} has no timings")
        for s in range(1, n + 1):
            print(int(sum(w for w, o in zip(weights, shard_of) if o == s)))
        return
    mine = [e for e, owner in zip(entries, shard_of) if owner == i]
    if "--list" in argv[3:]:
        for e in mine:
            print(re.sub(r"^\s+- ", "", e))
        return
    if not mine:
        sys.exit(f"scenario-lane-shard: shard {i}/{n} of {path} is empty")
    head = lines[:start]
    name = None
    for k, l in enumerate(head):
        m = re.match(r"^name:\s*(\S+)\s*$", l)
        if m:
            name = m.group(1)
            head[k] = f"name: {name}-shard-{i}-of-{n}"
    if name is None:
        sys.exit(f"scenario-lane-shard: {path} has no 'name:'")
    out = os.path.join(os.path.dirname(path), f".{name}.shard-{i}-of-{n}.lane.yaml")
    with open(out, "w") as f:
        f.write("\n".join(head + ["applicable:"] + mine + lines[end:]))
    print(out)


if __name__ == "__main__":
    main(sys.argv)
