"""Runtime helpers for locating and executing the packaged binaries."""

from __future__ import annotations

import platform
import subprocess
from importlib import resources
from pathlib import Path, PurePath
from typing import Mapping, Sequence

PACKAGE_BIN_DIR = "bin"
DEFAULT_BINARY_NAME = "ct"
# ``BINARY_NAME`` is kept for backward compatibility with the public API.
BINARY_NAME = DEFAULT_BINARY_NAME
DB_BACKEND_RECORD_BINARY_NAME = "db-backend-record"
CT_REMOTE_BINARY_NAME = "ct-remote"


class BinaryNotFoundError(FileNotFoundError):
    """Raised when the platform specific binary can not be located."""

    def __init__(
        self,
        message: str,
        *,
        target_os: str | None = None,
        target_arch: str | None = None,
        binary_name: str | None = None,
    ) -> None:
        super().__init__(message)
        self.target_os = target_os
        self.target_arch = target_arch
        self.binary_name = binary_name


def _normalize_os(value: str) -> str:
    normalized = value.lower()
    if normalized.startswith("linux"):
        return "linux"
    if normalized.startswith("darwin") or normalized.startswith("mac"):
        return "macos"
    raise BinaryNotFoundError(
        f"Unsupported operating system '{value}'.",
        target_os=value,
    )


def _normalize_arch(value: str) -> str:
    normalized = value.lower()
    if normalized in {"x86_64", "amd64"}:
        return "amd64"
    if normalized in {"aarch64", "arm64"}:
        return "arm64"
    raise BinaryNotFoundError(
        f"Unsupported CPU architecture '{value}'.",
        target_arch=value,
    )


def _candidate_name(target_os: str, target_arch: str) -> str:
    return f"{target_os}-{target_arch}"


def _validate_binary_name(binary_name: str) -> str:
    if not binary_name:
        raise ValueError("binary_name must be a non-empty file name.")
    if PurePath(binary_name).name != binary_name:
        raise ValueError("binary_name must not contain path separators.")
    return binary_name


def get_executable_path(
    target_os: str | None = None,
    target_arch: str | None = None,
    binary_name: str = BINARY_NAME,
) -> Path:
    """Resolve the absolute path to the packaged binary.

    ``target_os`` and ``target_arch`` accept either canonical identifiers
    (``linux``/``macos`` and ``amd64``/``arm64`` respectively) or raw results
    from :func:`platform.system` and :func:`platform.machine`. The
    ``binary_name`` parameter selects which packaged executable to return and
    defaults to the main ``ct`` binary for backwards compatibility.
    """

    os_value = _normalize_os(target_os or platform.system())
    arch_value = _normalize_arch(target_arch or platform.machine())
    normalized_binary = _validate_binary_name(binary_name)
    candidate = resources.files(__package__).joinpath(
        PACKAGE_BIN_DIR, _candidate_name(os_value, arch_value), normalized_binary
    )

    if not candidate.is_file():
        raise BinaryNotFoundError(
            "Packaged binary not found for the detected platform.",
            target_os=os_value,
            target_arch=arch_value,
            binary_name=normalized_binary,
        )

    return Path(candidate)


def run_binary(
    arguments: Sequence[str] | None = None,
    *,
    target_os: str | None = None,
    target_arch: str | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    capture_output: bool = False,
    text: bool | None = None,
    binary_name: str = BINARY_NAME,
) -> subprocess.CompletedProcess[str] | subprocess.CompletedProcess[bytes]:
    """Execute the packaged binary with the provided arguments.

    ``binary_name`` selects which packaged executable to run. The default
    preserves the historical behaviour of invoking the ``ct`` binary.
    """

    executable = get_executable_path(
        target_os=target_os,
        target_arch=target_arch,
        binary_name=binary_name,
    )
    exec_args: list[str] = [str(executable)]
    if arguments:
        exec_args.extend(arguments)

    run_kwargs: dict[str, object] = {
        "check": check,
    }
    if capture_output:
        run_kwargs["capture_output"] = True
    if text is not None:
        run_kwargs["text"] = text
    if env is not None:
        run_kwargs["env"] = dict(env)

    return subprocess.run(exec_args, **run_kwargs)
