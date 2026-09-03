#!/usr/bin/env python3
"""Report what a shipped ``node_modules`` carries beyond the production closure.

Invoked by ``ci/test/electron-supply-chain.sh``; see the prose at the top of
that file for the defect this measures.

The production closure cannot be read off ``yarn.lock`` alone.  Yarn writes the
workspace's ``dependencies`` and ``devDependencies`` into ONE flat map under the
``codetracer@workspace:.`` entry, so the lock knows the edges but not which
roots are production.  The split therefore comes from ``package.json``
(``dependencies`` + ``optionalDependencies``), and the lock supplies the
transitive edges from there.

Printed, always:

    production closure : <n> packages
    artefact           : <n> packages
    outside closure    : <n> packages, <n> files, <n> MB

and, when non-empty, every offending package by name.  A count with no names is
not actionable; a reader has to be able to see whether the answer is "eslint and
its 500 friends" or "one misdeclared runtime dependency".

Exit status is 1 when anything is outside the closure, 0 otherwise.
"""

from __future__ import annotations

import json
import os
import re
import sys


def parse_yarn_lock(path: str) -> dict[str, dict]:
    """Map each descriptor (``name@npm:range``) to its resolved entry.

    Yarn 4 lockfiles are YAML, but only a fixed subset of it: two-space
    indentation, one ``key: value`` per line, and block maps for
    ``dependencies`` / ``optionalDependencies``.  A hand parser is used rather
    than a YAML dependency so this runs in any dev shell; it is strict about the
    shapes it accepts and raises on anything else, so a future lockfile format
    change is a loud failure instead of a silently empty closure.
    """
    entries: dict[str, dict] = {}
    descriptors: list[str] = []
    current: dict | None = None
    section: str | None = None

    def split_descriptor(text: str) -> list[str]:
        # Yarn quotes the WHOLE group, not each member:
        #   "a@npm:^1.0.0, a@npm:^1.2.0":
        # so the quotes have to come off before the split, not after. Doing it
        # the other way round leaves a stray quote on the first and last member
        # and silently loses every edge that points at them.
        text = text.strip()
        if text.startswith('"') and text.endswith('"'):
            text = text[1:-1]
        out = []
        for part in text.split(", "):
            part = part.strip().strip('"')
            if part:
                out.append(part)
        return out

    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            # Top-level: a descriptor group header, ending in ':'.
            if not line.startswith(" "):
                if not line.endswith(":"):
                    continue  # `__metadata:` style headers and the version banner
                header = line[:-1]
                if header == "__metadata":
                    current = None
                    section = None
                    continue
                descriptors = split_descriptor(header)
                current = {"dependencies": {}, "version": None}
                for descriptor in descriptors:
                    entries[descriptor] = current
                section = None
                continue

            if current is None:
                continue

            stripped = line.strip()

            # Two-space indent: a field of the entry.
            if line.startswith("  ") and not line.startswith("    "):
                if stripped in ("dependencies:", "optionalDependencies:"):
                    section = "dependencies"
                    continue
                section = None
                if stripped.startswith("version:"):
                    current["version"] = stripped.split(":", 1)[1].strip().strip('"')
                continue

            # Four-space indent: a member of the current block map.
            if line.startswith("    ") and section == "dependencies":
                if ":" not in stripped:
                    continue
                name, spec = stripped.split(":", 1)
                name = name.strip().strip('"')
                spec = spec.strip().strip('"')
                current["dependencies"][name] = spec

    if not entries:
        raise SystemExit(f"parsed no entries from {path}; lockfile format changed?")
    return entries


def descriptor_for(name: str, spec: str) -> str:
    """Build the lockfile descriptor for a dependency edge.

    ``package.json`` writes bare ranges (``^4.1.1``); the lock and the lock's own
    edges write them protocol-qualified (``npm:^4.1.1``).  Anything already
    carrying a protocol (``patch:``, ``workspace:``, ``portal:``, a git URL) is
    passed through untouched.
    """
    if re.match(r"^[a-z][a-z0-9+.-]*:", spec) or spec.startswith("http"):
        return f"{name}@{spec}"
    return f"{name}@npm:{spec}"


def package_name(descriptor: str) -> str:
    """``@scope/pkg@npm:^1.0.0`` -> ``@scope/pkg``.

    Splitting on the LAST '@' is wrong for yarn's alias descriptors, where the
    range itself contains one: ``string-width-cjs@npm:string-width@^4.2.0``
    names the package ``string-width-cjs``, not ``string-width-cjs@npm:string-width``.
    """
    match = re.match(r"^(@[^/]+/[^@]+|[^@][^@]*)@", descriptor)
    if not match:
        raise SystemExit(f"cannot read a package name out of descriptor {descriptor!r}")
    return match.group(1)


def production_closure(manifest_path: str, lock_path: str) -> tuple[set[str], list[str]]:
    manifest = json.load(open(manifest_path, encoding="utf-8"))
    lock = parse_yarn_lock(lock_path)

    roots: dict[str, str] = {}
    for field in ("dependencies", "optionalDependencies"):
        roots.update(manifest.get(field, {}))

    # A name listed under BOTH `dependencies` and `devDependencies` (this
    # manifest does that for `@playwright/test` and `@types/node`) is resolved
    # ONCE by yarn, and the lock's workspace entry records which range won. Take
    # the spec from there when it is available, so a root is looked up under the
    # descriptor the lock actually contains; the manifest still decides WHICH
    # names are production roots.
    workspace_specs: dict[str, str] = {}
    for descriptor, entry in lock.items():
        if descriptor.endswith("@workspace:."):
            workspace_specs = entry["dependencies"]
            break

    seen: set[str] = set()
    unresolved: list[str] = []
    queue = [
        descriptor_for(name, workspace_specs.get(name, spec))
        for name, spec in roots.items()
    ]

    while queue:
        descriptor = queue.pop()
        if descriptor in seen:
            continue
        seen.add(descriptor)
        entry = lock.get(descriptor)
        if entry is None:
            unresolved.append(descriptor)
            continue
        for name, spec in entry["dependencies"].items():
            queue.append(descriptor_for(name, spec))

    return {package_name(descriptor) for descriptor in seen}, unresolved


def installed_packages(node_modules: str) -> list[str]:
    """Top-level package names present in a node_modules directory."""
    found = []
    try:
        listing = sorted(os.listdir(node_modules))
    except OSError as exc:
        raise SystemExit(f"cannot read {node_modules}: {exc}")

    for name in listing:
        if name.startswith("."):
            continue
        path = os.path.join(node_modules, name)
        if name.startswith("@"):
            try:
                scoped = sorted(os.listdir(path))
            except OSError:
                continue
            for inner in scoped:
                if os.path.isfile(os.path.join(path, inner, "package.json")):
                    found.append(f"{name}/{inner}")
        elif os.path.isfile(os.path.join(path, "package.json")):
            found.append(name)
    return found


def subtree_size(root: str) -> tuple[int, int]:
    files = 0
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for filename in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, filename)).st_size
                files += 1
            except OSError:
                pass
    return files, total


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(f"usage: {argv[0]} <package.json> <yarn.lock> <artefact-node_modules>")
        return 2

    manifest_path, lock_path, node_modules = argv[1], argv[2], argv[3]

    closure, unresolved = production_closure(manifest_path, lock_path)
    present = installed_packages(node_modules)

    # `electron` is installed by `appimage-scripts/install_electron.sh` from its
    # own pinned lockfile, not by yarn, so it is legitimately outside the yarn
    # closure wherever a build stages it into the same tree.
    allowed = closure | {"electron"}
    outside = sorted(name for name in present if name not in allowed)

    files = 0
    total = 0
    for name in outside:
        sub_files, sub_bytes = subtree_size(os.path.join(node_modules, name))
        files += sub_files
        total += sub_bytes

    print(f"production closure : {len(closure)} packages")
    print(f"artefact           : {len(present)} packages")
    print(f"outside closure    : {len(outside)} packages, {files} files, {total / 1e6:.1f} MB")

    if unresolved:
        print(f"unresolved edges   : {len(unresolved)} (lockfile is out of date with package.json)")
        for descriptor in sorted(unresolved)[:20]:
            print(f"    ? {descriptor}")

    if outside:
        print("packages shipped that are not in the production closure:")
        for name in outside:
            print(f"    + {name}")

    return 1 if (outside or unresolved) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
