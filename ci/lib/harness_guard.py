"""harness_guard.py — the argument rule every mutation harness applies first.

The harnesses under `src/**/run-plat*-mutations.py` edit the product's sources
in place. `ci/test/harness-argument-refusal.sh` already makes each one refuse a
FLAG it does not know. This module covers the other half of the command line:
the ARM IDS a run is narrowed to.

An arm filter that names no declared arm used to be accepted and silently
narrowed the run to nothing, or — for an empty `--only=` in the harnesses that
read "no filter" from an empty value — widened it to EVERY arm: a full,
file-mutating grade nobody asked for. So, before a harness touches anything:

  * every arm id on the command line (`--only=A,B`, `--only A,B`, a bare
    positional id, `--explain ID`) must be one the harness declares, and
  * `--only` must name at least one arm.

Either failure exits 2 with "no such arm(s)", the usage-error code the flag
refusal uses.

The declared ids are read from the harness's own module globals — every
upper-case list whose items carry an `id` or a `name`, or are tuples whose first
field is the id — so there is no second registry of arm ids to drift from the
arms. A harness in which nothing is found is refused too: a check over nothing
is not a check.
"""

from __future__ import annotations


def declared_arm_ids(namespace: dict) -> set:
    """Every arm id the harness module declares."""
    ids = set()
    for name, value in list(namespace.items()):
        if not (name.isupper() and isinstance(value, (list, tuple))):
            continue
        for item in value:
            ident = getattr(item, "id", None)
            if not isinstance(ident, str):
                ident = getattr(item, "name", None)
            if not isinstance(ident, str) and isinstance(item, (tuple, list)) \
                    and len(item) >= 3 and isinstance(item[0], str):
                ident = item[0]
            if isinstance(ident, str):
                ids.add(ident)
    return ids


def _split(value: str) -> list:
    return [s.strip() for s in value.split(",") if s.strip()]


def requested_arm_ids(argv: list) -> tuple:
    """(whether `--only` was given, the arm ids the command line names)."""
    only_given = False
    ids = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--only":
            only_given = True
            if i + 1 < len(argv):
                ids += _split(argv[i + 1])
                i += 1
        elif arg.startswith("--only="):
            only_given = True
            ids += _split(arg[len("--only="):])
        elif arg == "--explain":
            if i + 1 < len(argv):
                ids.append(argv[i + 1])
                i += 1
        elif not arg.startswith("-"):
            ids.append(arg)
        i += 1
    return only_given, ids


def refuse_undeclared_arms(argv: list, namespace: dict) -> int:
    """0 when the command line's arm ids are all declared; otherwise prints
    why and answers 2, before the harness has touched anything."""
    declared = declared_arm_ids(namespace)
    if not declared:
        print("no such arm(s): the harness declares no arm ids this guard can "
              "read — refusing rather than checking nothing")
        return 2
    only_given, wanted = requested_arm_ids(argv)
    if only_given and not wanted:
        print("no such arm(s): --only names no arm (an empty filter is not "
              "'every arm')")
        return 2
    unknown = [w for w in wanted if w not in declared]
    if unknown:
        print(f"no such arm(s): {unknown}; this harness declares "
              f"{len(declared)}: {', '.join(sorted(declared))}")
        return 2
    return 0


def _self_test() -> int:
    """The guard's own contract, run by `ci/test/harness-argument-refusal.sh`
    before it probes the harnesses: it accepts declared ids and the flags
    that name none, and refuses each refusable shape — so a guard that let
    everything through cannot make that probe pass vacuously."""
    import contextlib
    import io

    class _Arm:
        def __init__(self, ident):
            self.id = ident

    namespace = {"ARMS": [_Arm("A1"), _Arm("B2")],
                 "SURVIVORS": [("S1", "path", "find", "replace")]}
    cases = [
        ([], 0), (["--needle-scan"], 0), (["--only=A1,B2"], 0),
        (["--only", "S1"], 0), (["A1"], 0), (["--explain", "B2"], 0),
        (["--only="], 2), (["--only=,"], 2), (["--only=ZZ"], 2),
        (["ZZ"], 2), (["--explain", "ZZ"], 2), (["--only=A1,ZZ"], 2),
    ]
    failed = 0
    for argv, want in cases:
        with contextlib.redirect_stdout(io.StringIO()):
            got = refuse_undeclared_arms(argv, namespace)
        if got != want:
            print(f"harness_guard self-test: {argv} -> {got}, want {want}")
            failed += 1
    with contextlib.redirect_stdout(io.StringIO()):
        if refuse_undeclared_arms([], {"ARMS": []}) != 2:
            print("harness_guard self-test: a harness with no arms was not refused")
            failed += 1
    if failed == 0:
        print(f"harness_guard self-test: {len(cases) + 1} cases as required")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(_self_test())
