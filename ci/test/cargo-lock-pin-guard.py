#!/usr/bin/env python3
"""Classify what changed when a sibling-coupled Cargo.lock is re-resolved.

Why this exists
---------------
``codetracer-native-backend/Cargo.lock`` is *not* a pure function of that
repository's own content.  Its manifest routes one dependency through a
sibling working tree::

    [patch.crates-io]
    ct-dap-client = { path = "../codetracer/libs/ct-dap-client" }

A path dependency records no source, no checksum and no revision, so Cargo
writes the sibling's *dependency edges* into the lock verbatim.  The hunk is
therefore a function of whatever happens to sit at ``../codetracer`` when the
lock is written -- and in this gate that is the CodeTracer pull request under
test, which is by design newer than any revision native-backend was locked
against.

That coupling is deliberate and correct: native-backend's flow tests drive the
sibling's ``db-backend`` binary through the sibling's own ``test_support``
client, so the client must come from the tree being tested, not from a pinned
revision.  What is *not* correct is asserting the whole lock with ``--locked``:
that turns an expected cross-repo lag into "cannot update the lock file because
--locked was passed", a message that names a flag instead of a cause.

So the gate re-resolves the lock and asks this script a sharper question than
``--locked`` can: did anything that is actually pinned move?

Verdicts
--------
FAIL  a package that carries a ``source`` changed version, source or checksum.
      That is version drift, and it is exactly what ``--locked`` protected.
FAIL  a package that carries a ``source`` is present only after re-resolution.
      A sibling pulled in a crate the committed lock does not pin, so Cargo
      just picked whatever the registry offers today.
FAIL  a source-less package that is NOT reached through a sibling directory --
      a workspace member, or an in-repo path dependency -- changed its edges.
      Nothing outside the repository can explain that, so it is an unrefreshed
      lock and the repository that owns it has to say so.
PASS  differences confined to the dependency edges of packages reached through
      a sibling directory (a path that leaves the repository), and to pinned
      packages the re-resolved graph stopped using. This is cross-repo lag:
      reported in full, with the sibling revision that caused it, so the next
      reader sees the cause rather than the flag.
"""

from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path


def load_packages(path: Path) -> list[dict]:
    with path.open("rb") as handle:
        return tomllib.load(handle).get("package", [])


def pinned_identities(packages: list[dict]) -> dict[str, set[tuple]]:
    """name -> {(version, source, checksum)} for packages that carry a source."""
    out: dict[str, set[tuple]] = {}
    for pkg in packages:
        if "source" not in pkg:
            continue
        out.setdefault(pkg["name"], set()).add(
            (pkg.get("version", ""), pkg["source"], pkg.get("checksum", ""))
        )
    return out


def path_edges(packages: list[dict]) -> dict[str, list[str]]:
    """name -> sorted dependency edges, for packages with no source (path deps)."""
    return {
        pkg["name"]: sorted(pkg.get("dependencies", []))
        for pkg in packages
        if "source" not in pkg
    }


def sibling_paths(manifest: Path) -> dict[str, str]:
    """Map crate name -> declared relative path, for every path-routed entry."""
    if not manifest.is_file():
        return {}
    with manifest.open("rb") as handle:
        data = tomllib.load(handle)
    found: dict[str, str] = {}
    tables: list[dict] = []
    for key in ("dependencies", "dev-dependencies", "build-dependencies"):
        tables.append(data.get(key, {}))
    tables.extend(data.get("patch", {}).values())
    for target in data.get("target", {}).values():
        for key in ("dependencies", "dev-dependencies", "build-dependencies"):
            tables.append(target.get(key, {}))
    for table in tables:
        for name, spec in table.items():
            if isinstance(spec, dict) and "path" in spec:
                found.setdefault(name, spec["path"])
    return found


def describe_origin(repo: Path, relative: str | None) -> str:
    """Human-readable '<path> @ <revision>' for a sibling crate directory."""
    if relative is None:
        return "unknown origin"
    crate_dir = (repo / relative).resolve()
    revision = "revision unavailable"
    git_dir = crate_dir
    for candidate in [git_dir, *git_dir.parents]:
        if (candidate / ".git").exists():
            head = candidate / ".git" / "HEAD"
            try:
                raw = head.read_text(encoding="utf-8").strip()
            except OSError:
                break
            if raw.startswith("ref: "):
                ref = (candidate / ".git" / raw[5:]).resolve()
                try:
                    revision = ref.read_text(encoding="utf-8").strip()[:12]
                except OSError:
                    revision = raw[5:]
            else:
                revision = raw[:12]
            break
    return f"{relative} @ {revision}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--committed", required=True, type=Path)
    parser.add_argument("--resolved", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument(
        "--label",
        default="codetracer-native-backend",
        help="repository name used in the report",
    )
    args = parser.parse_args()

    repo = args.manifest.parent
    before = load_packages(args.committed)
    after = load_packages(args.resolved)

    before_pins = pinned_identities(before)
    after_pins = pinned_identities(after)
    paths = sibling_paths(args.manifest)

    moved: list[str] = []
    for name in sorted(set(before_pins) & set(after_pins)):
        if before_pins[name] == after_pins[name]:
            continue
        for version, source, _ in sorted(before_pins[name] - after_pins[name]):
            moved.append(f"    - {name} {version}  ({source})")
        for version, source, _ in sorted(after_pins[name] - before_pins[name]):
            moved.append(f"    + {name} {version}  ({source})")

    entered = sorted(set(after_pins) - set(before_pins))
    dropped = sorted(set(before_pins) - set(after_pins))

    before_edges = path_edges(before)
    after_edges = path_edges(after)
    repo_root = repo.resolve()
    lagging: list[str] = []
    local: list[str] = []
    for name in sorted(set(before_edges) | set(after_edges)):
        old = before_edges.get(name)
        new = after_edges.get(name)
        if old == new:
            continue
        relative = paths.get(name)
        origin = describe_origin(repo, relative)
        added = sorted(set(new or []) - set(old or []))
        removed = sorted(set(old or []) - set(new or []))
        detail = ", ".join(
            [f"+{edge}" for edge in added] + [f"-{edge}" for edge in removed]
        )
        line = f"    {name} ({origin}): {detail or 'entry added/removed'}"
        # A workspace member, or a path dependency that stays inside the
        # repository, is content the repository controls: nothing outside it can
        # explain the drift, so it is simply an unrefreshed lock. `path = "."`
        # is the repository itself and must land on that side of the line.
        outside = False
        if relative is not None:
            crate_dir = (repo / relative).resolve()
            outside = crate_dir != repo_root and repo_root not in crate_dir.parents
        if outside:
            lagging.append(line)
        else:
            local.append(line)

    if moved:
        print(
            f"{args.label}'s Cargo.lock does not pin the graph it resolves to.\n"
            "  A package that carries a source changed version, source or checksum:\n"
            + "\n".join(moved)
            + "\n"
            "  This is dependency version drift, not sibling lag. The visual replay\n"
            "  gate builds ct-native-replay against pinned versions and refuses to\n"
            f"  continue against a graph {args.label}'s Cargo.lock does not describe.\n"
            f"  Fix in {args.label}: refresh Cargo.lock and commit the result.",
            file=sys.stderr,
        )
        return 1

    if entered:
        detail = "\n".join(
            f"    {name} {sorted(after_pins[name])[0][0]}"
            f"  ({sorted(after_pins[name])[0][1]})"
            for name in entered
        )
        causes = "\n".join(lagging) or "    (no path-package edge changed)"
        print(
            f"{args.label}'s Cargo.lock does not match the sibling revision under\n"
            "  test. Re-resolving it pulls in packages the committed lock does not\n"
            "  pin, so Cargo picked whatever the registry offers right now:\n"
            + detail
            + "\n  Caused by these sibling dependency changes:\n"
            + causes
            + "\n"
            f"  Fix in {args.label}: check the siblings above out next to it, run\n"
            "  `cargo fetch`, and commit the refreshed Cargo.lock.",
            file=sys.stderr,
        )
        return 1

    if local:
        print(
            f"{args.label}'s Cargo.lock is out of date with {args.label}'s own\n"
            "  manifests. These packages are workspace members or in-repo path\n"
            "  dependencies -- no sibling checkout can explain their edges moving:\n"
            + "\n".join(local)
            + "\n"
            f"  Fix in {args.label}: run `cargo fetch` and commit Cargo.lock.",
            file=sys.stderr,
        )
        return 1

    if lagging or dropped:
        print(
            f"{args.label}'s Cargo.lock lags the sibling revisions under test.\n"
            "  Every pinned version, source and checksum is unchanged; only the\n"
            "  dependency edges of path packages differ, which is what a path\n"
            "  dependency on a sibling working tree means:"
        )
        for line in lagging:
            print(line)
        for name in dropped:
            print(f"    {name}: no longer reachable from the resolved graph")
        print(
            f"  Refresh {args.label}'s Cargo.lock against these siblings to clear\n"
            "  this notice. The gate continues: nothing pinned moved."
        )
        return 0

    print(f"{args.label}'s Cargo.lock matches the sibling revisions under test.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
