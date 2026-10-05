#!/usr/bin/env python3
"""Select checkout-owned, compiler-bound Cargo outputs for the owning Tup build."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular(path, single_link=False):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or (single_link and info.st_nlink != 1):
        raise RuntimeError(f"not a qualified regular file: {path}")
    if getattr(info, "st_file_attributes", 0) & 0x400:
        raise RuntimeError(f"reparse file refused: {path}")
    return info


def directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"not a real directory: {path}")
    if getattr(info, "st_file_attributes", 0) & 0x400:
        raise RuntimeError(f"reparse directory refused: {path}")
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise RuntimeError(f"foreign directory owner: {path}")
    if os.name != "nt" and info.st_mode & 0o022:
        raise RuntimeError(f"writable by other principals: {path}")
    return info


def tool(name):
    selected = shutil.which(name)
    if selected is None:
        raise RuntimeError(f"required owning tool absent: {name}")
    resolved = Path(selected).resolve(strict=True)
    regular(resolved)
    if not os.access(resolved, os.X_OK):
        raise RuntimeError(f"required owning tool is not executable: {resolved}")
    # Preserve proxy argv[0]: resolving a rustup rustc symlink and executing
    # the resulting rustup path would invoke the rustup CLI instead of rustc.
    return Path(selected).absolute()


def command(executable, argument, root):
    return subprocess.check_output(
        [str(executable), argument], cwd=root, text=True
    ).strip()


def marker_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def verify_marker(path, expected):
    info = regular(path, single_link=True)
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise RuntimeError(f"foreign marker owner: {path}")
    if os.name != "nt" and stat.S_IMODE(info.st_mode) != 0o600:
        raise RuntimeError(f"unexpected marker mode: {path}")
    if path.read_bytes() != expected:
        raise RuntimeError(f"unknown Cargo target marker: {path}")


def create_owned_directory(path, expected):
    path.mkdir(mode=0o700)
    marker = path / "owner.json"
    descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(expected)
        output.flush()
        os.fsync(output.fileno())
    directory(path)
    verify_marker(marker, expected)


def main():
    script = Path(__file__).absolute()
    regular(script)
    root = script.parent.parent
    # The actual checkout owns the helper, tracked Tup rules and Cargo callers.
    root_info = directory(root)
    if not re.fullmatch(r"[A-Za-z0-9_./:\\-]+", str(root)):
        raise RuntimeError("owning checkout path cannot be represented safely in Tup rules")
    rules = root / "src" / "Tuprules.tup"
    regular(rules)
    for ancestor in [root, *root.parents]:
        info = ancestor.lstat()
        if not stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise RuntimeError(f"nonregular checkout ancestry: {ancestor}")
    if Path.cwd().resolve(strict=True) != root:
        raise RuntimeError("Cargo target setup must run from the owning UI root")
    rustc = tool("rustc")
    cargo = tool("cargo")
    # Cargo's explicit compiler override must select the same owning principal.
    if os.environ.get("RUSTC"):
        override = Path(os.environ["RUSTC"])
        if not override.is_absolute() or override.absolute() != rustc:
            raise RuntimeError("RUSTC differs from the owning selected compiler")
    sysroot = Path(command(rustc, "--print=sysroot", root)).resolve(strict=True)
    actual_compiler = sysroot / "bin" / ("rustc.exe" if os.name == "nt" else "rustc")
    regular(actual_compiler)
    rustup = shutil.which("rustup")
    cargo_is_rustup_proxy = rustup is not None and os.path.samefile(cargo, rustup)
    actual_cargo = (
        sysroot / "bin" / ("cargo.exe" if os.name == "nt" else "cargo")
        if cargo_is_rustup_proxy else cargo.resolve(strict=True)
    )
    regular(actual_cargo)
    wrappers = {}
    for key in ["RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER"]:
        value = os.environ.get(key, "")
        if value:
            selected = shutil.which(value)
            if selected is None:
                raise RuntimeError(f"declared compiler wrapper absent: {key}")
            selected = Path(selected).resolve(strict=True)
            regular(selected)
            wrappers[key] = {"path": str(selected), "sha256": digest(selected)}
    principal = {
        "rustc": str(rustc), "rustcExecutable": str(rustc.resolve(strict=True)),
        "rustcSha256": digest(rustc),
        "actualCompiler": str(actual_compiler), "actualCompilerSha256": digest(actual_compiler),
        "version": command(rustc, "-vV", root), "sysroot": str(sysroot),
        "cargo": str(cargo), "cargoExecutable": str(cargo.resolve(strict=True)),
        "cargoSha256": digest(cargo),
        "actualCargo": str(actual_cargo), "actualCargoSha256": digest(actual_cargo),
        "cargoVersion": command(cargo, "-V", root),
        "rustupToolchain": os.environ.get("RUSTUP_TOOLCHAIN", ""), "wrappers": wrappers,
    }
    compiler_id = hashlib.sha256(marker_bytes(principal)).hexdigest()
    parent = root / ".cargo-tup-targets"
    base = parent / compiler_id
    checkout = {"path": str(root), "device": root_info.st_dev, "inode": root_info.st_ino}
    parent_owner = marker_bytes({"schema": 1, "checkout": checkout})
    base_owner = marker_bytes({"schema": 1, "checkout": checkout, "compiler": principal})
    absolute = base.as_posix()
    escaped = re.escape(absolute).replace("/", r"[/\\]")
    selections = [
        ("CODETRACER_TUP_CARGO_BASE", absolute),
        ("CODETRACER_TUP_CARGO_REGEX", "^" + escaped),
    ]
    for key, value in selections:
        prior = os.environ.get(key)
        if prior is not None and prior != value:
            raise RuntimeError(f"conflicting inherited target selection: {key}")
    # Refuse malformed/unknown prior paths before the first filesystem write.
    parent_exists = os.path.lexists(parent)
    base_exists = os.path.lexists(base)
    if parent_exists:
        directory(parent)
        verify_marker(parent / "owner.json", parent_owner)
    if base_exists:
        directory(base)
        verify_marker(base / "owner.json", base_owner)
    for path, expected in [(rustc, principal["rustcSha256"]),
                           (actual_compiler, principal["actualCompilerSha256"]),
                           (actual_cargo, principal["actualCargoSha256"]),
                           (cargo, principal["cargoSha256"])]:
        if digest(path) != expected:
            raise RuntimeError(f"compiler principal changed during setup: {path}")
    for wrapper in wrappers.values():
        if digest(Path(wrapper["path"])) != wrapper["sha256"]:
            raise RuntimeError("compiler wrapper changed during setup")
    if not parent_exists:
        create_owned_directory(parent, parent_owner)
    if not base_exists:
        create_owned_directory(base, base_owner)
    # Tup imports these values as parsing dependencies. Shell quoting is literal;
    # no arbitrary caller-supplied output root or regular expression is accepted.
    for key, value in selections:
        print("export " + key + "=" + shlex.quote(value))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"owning Tup Cargo target refused: {error}", file=sys.stderr)
        sys.exit(1)
