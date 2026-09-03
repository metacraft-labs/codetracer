#!/usr/bin/env python3
"""Stage ``node_modules`` into a desktop bundle so the bundle is SELF-CONTAINED.

WHAT WAS WRONG, MEASURED ON THE PUBLISHED ARTEFACT
--------------------------------------------------
``CodeTracer-latest-arm64.dmg`` as served by downloads.codetracer.com (built
2026-08-30, downloaded and mounted 2026-09-03) contains eight symlinks.  Seven
of them do not resolve on a user's Mac:

    Contents/MacOS/node_modules
        -> /nix/store/dfpgz4fsfayxmin7vr285rha5siz43ar-node-modules-derivation/bin/node_modules
    Contents/MacOS/public/third_party/@exuanbo          -> ../../../../node_modules/@exuanbo
    Contents/MacOS/public/third_party/mousetrap         -> ../../../../node_modules/mousetrap
    Contents/MacOS/public/third_party/vex-js            -> ../../../../node_modules/vex-js
    Contents/MacOS/public/third_party/xterm             -> ../../../../node_modules/xterm
    Contents/MacOS/public/third_party/golden-layout/dist
        -> ../../../../../node_modules/golden-layout/dist
    Contents/MacOS/public/third_party/monaco-editor/min
        -> ../../../../../node_modules/monaco-editor/min

The first is an ABSOLUTE path into the build machine's Nix store.  ``repro.nim``
staged it with ``cp -a node_modules``, and in a Nix dev shell ``node_modules`` is
itself a symlink into the store (``nix/shells/ci-base.nix`` creates it), so
``cp -a`` faithfully copied the LINK.  The store path exists on the build machine
and on the ``dmg-lib-check`` runner — they are the same self-hosted
``aarch64-darwin`` host — which is exactly why every release smoke test passed
while the artefact was broken for everyone else.

The other six are relative and escape the bundle regardless of machine: they
carry the ``../../../..`` that reaches the REPOSITORY root from the build tree,
and in the ``.app`` four levels up from ``Contents/MacOS/public/third_party`` is
``CodeTracer.app`` itself, which has no ``node_modules``.  They are broken on the
build machine too.

WHAT THIS SCRIPT DOES
---------------------
``stage`` copies ``node_modules`` into the bundle with the symlinks RESOLVED
(``dereference``), pruned to the PRODUCTION closure, so the bundle carries real
bytes and only the bytes the product loads.  Both halves are needed and neither
is optional:

  * dereference alone ships the development tree — measured against this
    repository's own lockfile, 550 packages / 297.6 MB / 26,452 files outside the
    production closure, which is the exact payload the AppImage stopped shipping
    in 0d5ad67d.  Doing the opposite here would be incoherent.
  * prune alone leaves the dangling store path in place.

``relink`` then walks the whole bundle and REWRITES any symlink whose target
escapes it, when the target names a path under some ``node_modules`` — the six
``third_party`` links above become relative links into the bundle's own staged
tree.  Anything else that escapes is reported and is an error: silently deleting
a link a developer meant to keep is how a bundle loses an asset.

The production closure is computed by ``ci/test/electron-supply-chain-closure.py``
— the same module ``ci/test/electron-supply-chain.sh`` checks the artefact
against — so the pruner and the guard cannot disagree about what "production"
means.  ``electron`` is deliberately NOT part of the yarn closure: the runtime is
pinned separately in ``appimage-scripts/electron/package.json`` and staged by
``scripts/stage-electron-runtime.sh``.

Usage:

    scripts/stage-desktop-node-modules.py stage <src-node_modules> <dest-node_modules>
    scripts/stage-desktop-node-modules.py relink <bundle-root> <bundle-node_modules>

Every run prints VALUES — packages kept, packages dropped, files, bytes, links
rewritten — because "staged ok" is not a measurement.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_closure_module():
    """Import ci/test/electron-supply-chain-closure.py by path.

    The filename is hyphenated, so it is not importable as a module name; the
    alternative to this six-line loader is a SECOND implementation of the
    yarn.lock walk, and two implementations of "what is production" is precisely
    the divergence that lets a pruner and its guard both pass while disagreeing.
    """
    path = os.path.join(REPO_ROOT, "ci", "test", "electron-supply-chain-closure.py")
    spec = importlib.util.spec_from_file_location("ct_electron_closure", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load the closure module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def subtree(root: str) -> tuple[int, int]:
    """(files, bytes) under root, counting symlinks as their own small selves."""
    files = 0
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_size
                files += 1
            except OSError:
                pass
    return files, total


def top_level_entries(node_modules: str) -> list[str]:
    """Package names present, scoped ones as ``@scope/name``.

    Mirrors ``installed_packages`` in the closure module so that what this stages
    and what the guard counts are the same set.
    """
    names: list[str] = []
    for name in sorted(os.listdir(node_modules)):
        if name.startswith("."):
            continue
        path = os.path.join(node_modules, name)
        if name.startswith("@"):
            if not os.path.isdir(path):
                continue
            for inner in sorted(os.listdir(path)):
                if os.path.isfile(os.path.join(path, inner, "package.json")):
                    names.append(f"{name}/{inner}")
        elif os.path.isfile(os.path.join(path, "package.json")):
            names.append(name)
    return names


def stage(src: str, dest: str) -> int:
    closure_module = load_closure_module()
    manifest = os.path.join(REPO_ROOT, "node-packages", "package.json")
    lock = os.path.join(REPO_ROOT, "node-packages", "yarn.lock")
    closure, unresolved = closure_module.production_closure(manifest, lock)

    src = os.path.realpath(src)
    present = top_level_entries(src)
    keep = sorted(name for name in present if name in closure)
    drop = sorted(name for name in present if name not in closure)

    if os.path.exists(dest):
        force_rmtree(dest)
    os.makedirs(dest)

    for name in keep:
        source = os.path.join(src, name)
        target = os.path.join(dest, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        # symlinks=False is the whole point: every link inside a package is
        # replaced by the bytes it pointed at, so nothing in the staged tree can
        # reach back out to the build machine.
        shutil.copytree(source, target, symlinks=False, ignore_dangling_symlinks=True)

    # `.bin` is not a package and the closure has no opinion about it, but the
    # shipped tree should not carry shims for pruned packages. Keep the ones that
    # still resolve into what was staged, drop the rest, and say how many.
    bin_kept = 0
    bin_dropped = 0
    src_bin = os.path.join(src, ".bin")
    if os.path.isdir(src_bin):
        dest_bin = os.path.join(dest, ".bin")
        os.makedirs(dest_bin, exist_ok=True)
        for name in sorted(os.listdir(src_bin)):
            entry = os.path.join(src_bin, name)
            resolved = os.path.realpath(entry)
            relative = os.path.relpath(resolved, src)
            staged = os.path.join(dest, relative)
            if relative.startswith("..") or not os.path.exists(staged):
                bin_dropped += 1
                continue
            # A real file, not a link: a relative link would be correct here too,
            # but a copy cannot be wrong, and these are a few hundred kilobytes.
            shutil.copy2(staged, os.path.join(dest_bin, name))
            bin_kept += 1
        if not os.listdir(dest_bin):
            os.rmdir(dest_bin)

    # BEFORE the measurements below, because the numbers this prints are the
    # evidence that the source of the CI checkout outage is closed. See
    # `restore_owner_write` for the run/job/runner this is measured against.
    ro_dirs_before = unwritable_dirs(dest)
    dirs_fixed, files_fixed = restore_owner_write(dest)
    ro_dirs_after = unwritable_dirs(dest)

    kept_files, kept_bytes = subtree(dest)
    dropped_files = 0
    dropped_bytes = 0
    for name in drop:
        f, b = subtree(os.path.join(src, name))
        dropped_files += f
        dropped_bytes += b

    print(f"source              : {src}")
    print(f"destination         : {dest}")
    print(f"production closure  : {len(closure)} packages")
    print(f"present in source   : {len(present)} packages")
    print(f"staged              : {len(keep)} packages, {kept_files} files, {kept_bytes / 1e6:.1f} MB")
    print(f"pruned              : {len(drop)} packages, {dropped_files} files, {dropped_bytes / 1e6:.1f} MB")
    print(f".bin shims          : {bin_kept} kept, {bin_dropped} dropped")
    print(
        f"read-only dirs      : {ro_dirs_before} before, {ro_dirs_after} after"
        f" (owner-write restored on {dirs_fixed} dirs, {files_fixed} files)"
    )

    staged_links = sum(1 for _ in iter_symlinks(dest))
    print(f"symlinks in staged  : {staged_links}")

    if ro_dirs_after:
        # Not a warning. A directory the owner cannot write is a directory the
        # next job's `git clean` cannot empty, and that is the whole outage.
        print(
            f"UNWRITABLE DIRS     : {ro_dirs_after} directory(ies) in the staged tree"
            " are still not owner-writable; the next checkout on a persistent"
            " runner will fail to clean them"
        )
        return 1

    if unresolved:
        print(f"UNRESOLVED EDGES    : {len(unresolved)} (yarn.lock is out of date with package.json)")
        for descriptor in sorted(unresolved)[:20]:
            print(f"    ? {descriptor}")
        return 1

    if staged_links:
        # Not fatal on its own — `relink` runs next and the gate has the final
        # word — but a dereferenced copy that still contains links is a surprise
        # worth printing rather than discovering in the artefact.
        for link in list(iter_symlinks(dest))[:10]:
            print(f"    ~ {os.path.relpath(link, dest)} -> {os.readlink(link)}")

    return 0


def unwritable_dirs(root: str) -> int:
    """Directories under (and including) ``root`` without owner-write.

    Directories, not files: a 0444 FILE is unremovable only if its parent is
    also unwritable, and 0444 files are ordinary — git's own pack and idx files
    are 0444 by design. Counting them would bury the signal under noise.
    """
    count = 0
    for dirpath, _dirnames, _filenames in os.walk(root, followlinks=False):
        try:
            if not os.lstat(dirpath).st_mode & 0o200:
                count += 1
        except OSError:
            pass
    return count


def restore_owner_write(root: str) -> tuple[int, int]:
    """Give the owner write permission back over a tree copied out of the store.

    ``shutil.copytree`` uses ``copy2``/``copystat``, so the staged tree inherits
    the SOURCE's mode bits.  In a Nix dev shell the source is
    ``/nix/store/…-node-modules-derivation/…``, and store paths are 0555
    directories / 0444 files.  The bundle therefore lands in the build tree with
    directories nobody can write.

    That is not a cosmetic detail; it broke CI.  ``non-nix-build/CodeTracer.app``
    is gitignored (non-nix-build/.gitignore), so on a PERSISTENT self-hosted
    runner it survives into the next job, and the next ``actions/checkout``'s
    ``git clean -ffdx`` cannot unlink a single file inside those directories —
    POSIX unlink needs write permission on the PARENT DIRECTORY.  Measured on
    run 33734457928 / job 100581650873 / runner m3-mcl-003: 31,307
    ``failed to remove … Permission denied`` warnings, every one of them under
    ``CodeTracer.app/Contents/MacOS/node_modules``, then checkout gave up,
    tried to delete the whole checkout, and died on
    ``EACCES … unlink '…/node_modules/abbrev/LICENSE'``.

    It also breaks a plain second local build: ``stage`` starts by removing
    ``dest``, and ``rmtree`` over 0555 directories raises ``PermissionError``.

    Directories are what matters, but files get ``u+w`` too so that a rebuild
    can overwrite in place.  Returns ``(directories_fixed, files_fixed)`` —
    VALUES, because "made it writable" is not a measurement, and a chmod over a
    tree that needed nothing is indistinguishable from one that never ran.
    """
    def add_owner_write(path: str) -> bool:
        try:
            mode = os.lstat(path).st_mode
        except OSError:
            return False
        if mode & 0o200:
            return False
        try:
            os.chmod(path, (mode & 0o7777) | 0o200)
        except OSError:
            return False
        return True

    dirs_fixed = 0
    files_fixed = 0
    # topdown, so a directory is chmodded before the walk descends into it.
    # Store directories are r-x, so descent would work either way, but a tree
    # copied from somewhere stricter would not.
    for dirpath, _dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        if add_owner_write(dirpath):
            dirs_fixed += 1
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            if add_owner_write(path):
                files_fixed += 1
    return dirs_fixed, files_fixed


def force_rmtree(path: str) -> None:
    """``shutil.rmtree`` that survives a previously staged read-only tree.

    Without this, the second ``stage`` run on a machine that has already staged
    once dies in ``rmtree`` with ``PermissionError`` on the first 0555 directory
    — the local-developer face of the CI defect above.
    """
    def on_error(func, failed, _exc):
        parent = os.path.dirname(failed)
        for target in (failed, parent):
            try:
                mode = os.lstat(target).st_mode
                os.chmod(target, (mode & 0o7777) | 0o700)
            except OSError:
                pass
        func(failed)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=lambda f, p, e: on_error(f, p, e))
    else:  # pragma: no cover - the runners are on 3.12+
        shutil.rmtree(path, onerror=on_error)


def iter_symlinks(root: str):
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in list(dirnames) + list(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                yield path


def relink(bundle_root: str, bundle_node_modules: str) -> int:
    """Point bundle-escaping ``node_modules`` symlinks at the bundle's own tree.

    Returns 0 when every symlink under ``bundle_root`` resolves inside it.
    """
    bundle_root = os.path.realpath(bundle_root)
    bundle_node_modules = os.path.realpath(bundle_node_modules)
    if not bundle_node_modules.startswith(bundle_root + os.sep):
        raise SystemExit(
            f"{bundle_node_modules} is not inside {bundle_root}; refusing to relink"
        )

    rewritten = 0
    left_alone = 0
    escaping: list[tuple[str, str]] = []

    for link in list(iter_symlinks(bundle_root)):
        target = os.readlink(link)
        resolved = os.path.realpath(link)
        inside = resolved == bundle_root or resolved.startswith(bundle_root + os.sep)
        if inside and os.path.exists(link):
            left_alone += 1
            continue

        # Escapes, or dangles. If the target names something under a
        # `node_modules`, the bundle has that package staged and the link can be
        # re-aimed there. `monaco-editor/min` and friends are exactly this shape.
        marker = "node_modules" + os.sep
        index = target.rfind(marker)
        if index == -1:
            escaping.append((link, target))
            continue

        suffix = target[index + len(marker):].rstrip(os.sep)
        candidate = os.path.join(bundle_node_modules, suffix)
        if not os.path.exists(candidate):
            escaping.append((link, target))
            continue

        new_target = os.path.relpath(candidate, os.path.dirname(link))
        os.unlink(link)
        os.symlink(new_target, link)
        rewritten += 1
        print(f"    relinked {os.path.relpath(link, bundle_root)}")
        print(f"             {target}  ->  {new_target}")

    print(f"bundle root         : {bundle_root}")
    print(f"symlinks unchanged  : {left_alone}")
    print(f"symlinks relinked   : {rewritten}")
    print(f"symlinks unfixable  : {len(escaping)}")
    for link, target in escaping:
        print(f"    ! {os.path.relpath(link, bundle_root)} -> {target}")

    return 1 if escaping else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_stage = sub.add_parser("stage", help="prune + dereference node_modules into a bundle")
    p_stage.add_argument("src")
    p_stage.add_argument("dest")

    p_relink = sub.add_parser("relink", help="re-aim bundle-escaping node_modules symlinks")
    p_relink.add_argument("bundle_root")
    p_relink.add_argument("bundle_node_modules")

    args = parser.parse_args(argv[1:])
    if args.command == "stage":
        return stage(args.src, args.dest)
    return relink(args.bundle_root, args.bundle_node_modules)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
