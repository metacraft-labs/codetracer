#!/usr/bin/env python3
"""Read the Mach-O load commands of every binary in a bundle and resolve them.

## The defect this exists to close, measured on the published artefact

`CodeTracer-latest-arm64.dmg` was downloaded from downloads.codetracer.com on
2026-09-04 (63,356,720 bytes, built 2026-08-30), mounted, and run:

    $ Contents/MacOS/bin/ct_unwrapped --version
    dyld[65642]: Library not loaded: @executable_path/../Frameworks/libcrypto.3.dylib
      Referenced from: <...> /Volumes/CT-PUB/CodeTracer.app/Contents/MacOS/bin/ct_unwrapped
      Reason: tried: '/Volumes/CT-PUB/CodeTracer.app/Contents/MacOS/Frameworks/libcrypto.3.dylib' (no such file)
    exit 134 (SIGABRT)

THE LIBRARY IS NOT MISSING. All ten dylibs are present, in
`Contents/Frameworks/`. The LOAD COMMAND is wrong by one directory level.
`repro.nim` rewrites the binaries under `Contents/MacOS/bin` with the prefix
`@executable_path/../Frameworks`, but `@executable_path` is the directory of
the executable -- `Contents/MacOS/bin` -- so `../Frameworks` names
`Contents/MacOS/Frameworks`, which has never existed in any build. The prefix
that reaches `Contents/Frameworks` from `Contents/MacOS/bin` is `../../`.

Four executables ship with the wrong prefix: ct_unwrapped, db-backend-record,
replay-server, session-manager -- i.e. every native program in the bundle.

## Why the existing gate could not see it

`ci/test/desktop-bundle-self-contained.sh` asks "does every path in this bundle
resolve inside it", and answers it by walking SYMLINKS. A `LC_LOAD_DYLIB`
string is not a symlink. Not one of that gate's six checks opens a Mach-O
header, so a bundle whose every native binary aborts in dyld is indistinguish-
able, to it, from a correct one. "Self-contained" was being asserted about the
filesystem shape of the bundle and never about its linkage.

This is the linkage half, and it is deliberately a separate reader rather than
another symlink rule, because the question is different: not "where does this
name point in the filesystem" but "what will dyld do with this load command".

## What this checks

For every Mach-O file in the bundle (executables, dylibs, bundles, including
the members of fat archives), every dependency load command --

    LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB

-- is expanded the way dyld expands it (`@loader_path`, `@executable_path`,
`@rpath` against the file's own LC_RPATHs) and classified:

    system   /usr/lib/... or /System/...   -- lives in the dyld shared cache
    inside   resolves to a file that is present in the bundle
    MISSING  resolves to a path that does not exist          -> FAILURE
    OUTSIDE  resolves to a path outside the bundle           -> FAILURE

`LC_ID_DYLIB` is read but never treated as a dependency: a bundled dylib's own
install name is legitimately `@rpath/libfoo.dylib` with no LC_RPATH anywhere,
because its consumers name it by an explicit path. Counting the id as a
dependency would redden every correct bundle, which is how a gate gets deleted.

Weak dependencies are reported and NOT failed: dyld tolerates their absence by
design, so failing them would be asserting something untrue about the runtime.

The parser is pure Python and reads the headers itself rather than shelling out
to `otool`, so this runs on the Linux CI hosts against an extracted .app just as
it does on a Mac -- the AppImage lesson that a check must not be able to pass
merely because it was run on the machine that built the thing.

## Usage

    ci/test/macho-closure.py <bundle-dir>

Exit status is 0 when every dependency resolves, 1 otherwise. Every binary is
reported either way, so one run tells a reader the whole linkage picture rather
than only the first thing that broke.
"""

import os
import struct
import sys

# ---------------------------------------------------------------------------
# Mach-O constants (mach-o/loader.h)
# ---------------------------------------------------------------------------
MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA

LC_REQ_DYLD = 0x80000000
LC_ID_DYLIB = 0x0D
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD

DEP_COMMANDS = {
    LC_LOAD_DYLIB: "LC_LOAD_DYLIB",
    LC_LOAD_WEAK_DYLIB: "LC_LOAD_WEAK_DYLIB",
    LC_REEXPORT_DYLIB: "LC_REEXPORT_DYLIB",
    LC_LOAD_UPWARD_DYLIB: "LC_LOAD_UPWARD_DYLIB",
}
WEAK_COMMANDS = {LC_LOAD_WEAK_DYLIB}

MH_EXECUTE = 2
MH_DYLIB = 6
MH_DYLINKER = 7
MH_BUNDLE = 8
FILETYPES = {
    MH_EXECUTE: "executable",
    MH_DYLIB: "dylib",
    MH_DYLINKER: "dylinker",
    MH_BUNDLE: "bundle",
}

# Prefixes served by the dyld shared cache. These paths deliberately do NOT
# exist as files on a modern macOS install, so they must be classified by name
# and never by os.path.exists -- checking existence would fail every binary on
# earth, including /usr/lib/libSystem.B.dylib.
#
# /usr/local and /opt/homebrew are NOT in this list on purpose: they are the
# canonical "worked on the build machine" paths, and a shipped binary that
# names one is exactly the defect this file exists to find.
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/", "/System/iOSSupport/")


class MachO:
    """One Mach-O image: its filetype, its LC_RPATHs and its dependencies."""

    def __init__(self, path, filetype, rpaths, deps, ident):
        self.path = path
        self.filetype = filetype
        self.rpaths = rpaths
        self.deps = deps          # list of (command-name, raw string)
        self.ident = ident        # LC_ID_DYLIB, or None


def _read_lc_string(blob, base, cmdsize):
    """A load-command string is an offset from the START OF THE COMMAND."""
    (offset,) = struct.unpack_from("<I", blob, base + 8)
    if offset >= cmdsize:
        return None
    start = base + offset
    end = blob.find(b"\x00", start, base + cmdsize)
    if end < 0:
        end = base + cmdsize
    return blob[start:end].decode("utf-8", "replace")


def _parse_thin(data, offset, path):
    """Parse one thin Mach-O image starting at `offset`."""
    (magic,) = struct.unpack_from("<I", data, offset)
    if magic in (MH_MAGIC_64, MH_CIGAM_64):
        hdr_size = 32
    elif magic in (MH_MAGIC, MH_CIGAM):
        hdr_size = 28
    else:
        return None
    # Only little-endian images are parsed. Every Apple platform this project
    # ships to is little-endian; a big-endian image is reported rather than
    # silently skipped, so it can never be mistaken for "no dependencies".
    if magic in (MH_CIGAM, MH_CIGAM_64):
        raise ValueError("big-endian Mach-O is not supported by this reader")

    filetype, ncmds, sizeofcmds = struct.unpack_from("<III", data, offset + 12)
    blob = data[offset + hdr_size: offset + hdr_size + sizeofcmds]

    rpaths, deps, ident = [], [], None
    pos = 0
    for _ in range(ncmds):
        if pos + 8 > len(blob):
            break
        cmd, cmdsize = struct.unpack_from("<II", blob, pos)
        if cmdsize < 8:
            break
        if cmd in DEP_COMMANDS:
            name = _read_lc_string(blob, pos, cmdsize)
            if name is not None:
                deps.append((DEP_COMMANDS[cmd], name, cmd in WEAK_COMMANDS))
        elif cmd == LC_ID_DYLIB:
            ident = _read_lc_string(blob, pos, cmdsize)
        elif cmd == LC_RPATH:
            rp = _read_lc_string(blob, pos, cmdsize)
            if rp is not None:
                rpaths.append(rp)
        pos += cmdsize

    return MachO(path, FILETYPES.get(filetype, f"type-{filetype}"), rpaths, deps, ident)


def read_macho(path):
    """Return a list of MachO images in `path`, or [] if it is not Mach-O."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(4)
            if len(head) < 4:
                return []
            (be_magic,) = struct.unpack("<I", head)
            (fat_magic,) = struct.unpack(">I", head)
            if be_magic not in (MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64) and \
               fat_magic not in (FAT_MAGIC, FAT_MAGIC_64):
                return []
            fh.seek(0)
            data = fh.read()
    except OSError:
        return []

    if fat_magic in (FAT_MAGIC, FAT_MAGIC_64):
        # Fat header and arch table are BIG-endian regardless of the slices.
        (nfat,) = struct.unpack_from(">I", data, 4)
        wide = fat_magic == FAT_MAGIC_64
        entry = 32 if wide else 20
        images = []
        for i in range(nfat):
            base = 8 + i * entry
            if base + entry > len(data):
                break
            if wide:
                off = struct.unpack_from(">Q", data, base + 8)[0]
            else:
                off = struct.unpack_from(">I", data, base + 8)[0]
            img = _parse_thin(data, off, path)
            if img:
                images.append(img)
        return images

    img = _parse_thin(data, 0, path)
    return [img] if img else []


def expand(dep, image, executables):
    """Expand a dyld load-command string into candidate filesystem paths.

    Returns (candidates, kind). `kind` is 'system' for shared-cache paths,
    'absolute' for any other absolute path, and 'expanded' otherwise.
    """
    if dep.startswith(SYSTEM_PREFIXES):
        return [dep], "system"

    loader_dir = os.path.dirname(image.path)

    def sub(text, exec_dir):
        out = text
        if out.startswith("@loader_path"):
            out = loader_dir + out[len("@loader_path"):]
        elif out.startswith("@executable_path"):
            if exec_dir is None:
                return None
            out = exec_dir + out[len("@executable_path"):]
        return out

    # For an executable, @executable_path is its own directory. For a dylib it
    # depends on who loaded it, so every executable in the bundle is tried and
    # the dependency counts as resolved if ANY of them reaches it -- claiming
    # otherwise would redden correctly-linked helper dylibs.
    exec_dirs = [loader_dir] if image.filetype == "executable" else executables

    if dep.startswith("@rpath/"):
        tail = dep[len("@rpath/"):]
        cands = []
        for rp in image.rpaths:
            for exec_dir in (exec_dirs or [None]):
                base = sub(rp, exec_dir)
                if base is not None:
                    cands.append(os.path.normpath(os.path.join(base, tail)))
        return cands, "expanded"

    if dep.startswith("@"):
        cands = []
        for exec_dir in (exec_dirs or [None]):
            got = sub(dep, exec_dir)
            if got is not None:
                cands.append(os.path.normpath(got))
        return cands, "expanded"

    if os.path.isabs(dep):
        return [os.path.normpath(dep)], "absolute"

    # A bare relative name is resolved by dyld against the CWD, which is
    # whatever Finder or the shell happened to leave it as. Never correct in a
    # shipped bundle.
    return [os.path.normpath(os.path.join(loader_dir, dep))], "relative"


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: macho-closure.py <bundle-dir>\n")
        return 2
    root = os.path.realpath(argv[1])
    if not os.path.isdir(root):
        sys.stderr.write(f"not a directory: {root}\n")
        return 2

    images = []
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                images.extend(read_macho(path))
            except ValueError as exc:
                print(f"    ! [UNREADABLE] {os.path.relpath(path, root)}: {exc}")

    executables = sorted({
        os.path.dirname(i.path) for i in images if i.filetype == "executable"
    })

    def inside(path):
        return path == root or path.startswith(root + os.sep)

    missing, outside, weak_missing = [], [], []
    counted = 0

    for image in sorted(images, key=lambda i: i.path):
        for cmd, dep, is_weak in image.deps:
            counted += 1
            cands, kind = expand(dep, image, executables)
            if kind == "system":
                continue
            hit = next((c for c in cands if os.path.exists(c)), None)
            shown = os.path.relpath(image.path, root)
            if hit is None:
                tried = cands[0] if cands else "<unexpandable>"
                row = (shown, cmd, dep, tried)
                (weak_missing if is_weak else missing).append(row)
            elif not inside(hit):
                outside.append((shown, cmd, dep, hit))

    print(f"mach-o images     : {len(images)}")
    print(f"dependency loads  : {counted}")
    print(f"unresolvable      : {len(missing)}")
    print(f"resolving outside : {len(outside)}")
    print(f"weak & absent     : {len(weak_missing)}  (informational; dyld tolerates these)")

    for shown, cmd, dep, tried in missing:
        print(f"    ! [MISSING] {shown}")
        print(f"        {cmd} {dep}")
        print(f"        tried: {tried}")
    for shown, cmd, dep, hit in outside:
        print(f"    ! [OUTSIDE] {shown}")
        print(f"        {cmd} {dep}")
        print(f"        resolves to: {hit}")
    for shown, cmd, dep, tried in weak_missing:
        print(f"    - [weak, absent] {shown}: {dep}")

    return 1 if (missing or outside) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
