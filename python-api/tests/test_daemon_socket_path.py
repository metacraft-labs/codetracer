"""``default_daemon_socket_path`` resolves the daemon's socket as the daemon does.

The daemon resolves it in ``DaemonConfig::daemon_paths``
(``src/backend-manager/src/config.rs``); the Python API mirrors that. These
tests pin the precedence of each input, including the branches the
backend-manager's ``python_daemon_socket_agreement_test`` cannot start a real
daemon for: the per-OS default (no ``CODETRACER_HOME``, which would put the
daemon's log in the developer's profile) and ``CODETRACER_DAEMON_SOCK``, the
socket the daemon hands to the scripts it runs. That test is the one that
compares the two implementations against a real daemon.

No mocks: the function reads only the environment and the daemon config file,
so each test sets the environment with ``monkeypatch`` and writes the config
file in a real temporary directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

from codetracer.connection import DaemonConnection, default_daemon_socket_path

ALL_VARIABLES = (
    "CODETRACER_DAEMON_SOCK",
    "CODETRACER_DAEMON_SOCKET",
    "CODETRACER_DAEMON_CONFIG",
    "CODETRACER_TMP_PATH",
    "CODETRACER_HOME",
)

posix_not_macos = pytest.mark.skipif(
    sys.platform in ("darwin", "win32"),
    reason="the TMPDIR-based default is the Linux/other-POSIX branch; "
    "macOS and Windows have their own tests",
)


@pytest.fixture
def env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> pytest.MonkeyPatch:
    """A clean environment: no override set, HOME and TMPDIR in scratch."""
    for name in ALL_VARIABLES:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path / "user-home"))
    monkeypatch.setenv("TMPDIR", str(tmp_path / "tmpdir"))
    return monkeypatch


def write_config(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


@posix_not_macos
def test_the_default_is_codetracer_under_tmpdir(env, tmp_path):
    # Rust `std::env::temp_dir()` is $TMPDIR; the old client said /tmp.
    assert default_daemon_socket_path() == tmp_path / "tmpdir" / "codetracer" / "daemon.sock"


@posix_not_macos
def test_without_tmpdir_the_default_is_under_slash_tmp(env):
    env.delenv("TMPDIR")
    assert default_daemon_socket_path() == Path("/tmp/codetracer/daemon.sock")


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS branch")
def test_the_macos_default_is_under_library_caches(env, tmp_path):
    assert default_daemon_socket_path() == (
        tmp_path / "user-home" / "Library" / "Caches" / "com.codetracer.CodeTracer" / "daemon.sock"
    )


def test_codetracer_home_moves_it_to_its_tmp(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    assert default_daemon_socket_path() == tmp_path / "ct-home" / "tmp" / "daemon.sock"


def test_a_relative_codetracer_home_is_resolved_against_the_working_directory(env, tmp_path):
    env.chdir(tmp_path)
    env.setenv("CODETRACER_HOME", "rel-home")
    assert default_daemon_socket_path() == tmp_path / "rel-home" / "tmp" / "daemon.sock"


@posix_not_macos
def test_an_empty_codetracer_home_is_unset(env, tmp_path):
    env.setenv("CODETRACER_HOME", "")
    assert default_daemon_socket_path() == tmp_path / "tmpdir" / "codetracer" / "daemon.sock"


def test_codetracer_tmp_path_outranks_codetracer_home(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    env.setenv("CODETRACER_TMP_PATH", str(tmp_path / "electron"))
    assert default_daemon_socket_path() == tmp_path / "electron" / "daemon.sock"


def test_the_config_file_in_codetracer_home_outranks_codetracer_tmp_path(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    env.setenv("CODETRACER_TMP_PATH", str(tmp_path / "electron"))
    write_config(
        tmp_path / "ct-home" / "config" / "daemon.conf",
        "# comment\nsocket_path = /first.sock\n  socket_path\t=  /second.sock  \r\nmax_sessions=2\n",
    )
    # Keys and values are trimmed, and a later key wins (`parse_config_file`).
    assert default_daemon_socket_path() == Path("/second.sock")


def test_the_config_file_defaults_to_dot_codetracer_in_home(env, tmp_path):
    write_config(tmp_path / "user-home" / ".codetracer" / "daemon.conf", "socket_path=/from-home.sock\n")
    assert default_daemon_socket_path() == Path("/from-home.sock")


def test_codetracer_home_hides_the_config_file_in_home(env, tmp_path):
    write_config(tmp_path / "user-home" / ".codetracer" / "daemon.conf", "socket_path=/from-home.sock\n")
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    assert default_daemon_socket_path() == tmp_path / "ct-home" / "tmp" / "daemon.sock"


def test_codetracer_daemon_config_names_the_config_file(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    write_config(tmp_path / "ct-home" / "config" / "daemon.conf", "socket_path=/ignored.sock\n")
    env.setenv("CODETRACER_DAEMON_CONFIG", str(write_config(tmp_path / "x.conf", "socket_path=/x.sock\n")))
    assert default_daemon_socket_path() == Path("/x.sock")


def test_a_missing_or_invalid_config_file_is_ignored(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    env.setenv("CODETRACER_DAEMON_CONFIG", str(tmp_path / "missing.conf"))
    assert default_daemon_socket_path() == tmp_path / "ct-home" / "tmp" / "daemon.sock"
    bad = tmp_path / "bad.conf"
    bad.write_bytes(b"socket_path=/\xff.sock\n")  # not UTF-8: the daemon ignores it
    env.setenv("CODETRACER_DAEMON_CONFIG", str(bad))
    assert default_daemon_socket_path() == tmp_path / "ct-home" / "tmp" / "daemon.sock"


def test_lines_without_the_key_or_an_equals_sign_are_skipped(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    write_config(
        tmp_path / "ct-home" / "config" / "daemon.conf",
        "socket_path\n#socket_path=/commented.sock\nsocket_paths=/other.sock\n",
    )
    assert default_daemon_socket_path() == tmp_path / "ct-home" / "tmp" / "daemon.sock"


def test_codetracer_daemon_socket_outranks_the_config_file(env, tmp_path):
    env.setenv("CODETRACER_DAEMON_CONFIG", str(write_config(tmp_path / "x.conf", "socket_path=/x.sock\n")))
    env.setenv("CODETRACER_DAEMON_SOCKET", str(tmp_path / "override.sock"))
    assert default_daemon_socket_path() == tmp_path / "override.sock"


def test_the_socket_the_daemon_handed_over_outranks_everything(env, tmp_path):
    env.setenv("CODETRACER_DAEMON_SOCKET", str(tmp_path / "override.sock"))
    env.setenv("CODETRACER_DAEMON_SOCK", str(tmp_path / "handed.sock"))
    assert default_daemon_socket_path() == tmp_path / "handed.sock"


def test_a_connection_without_a_socket_uses_the_resolved_one(env, tmp_path):
    env.setenv("CODETRACER_HOME", str(tmp_path / "ct-home"))
    assert DaemonConnection().socket_path == tmp_path / "ct-home" / "tmp" / "daemon.sock"
    assert DaemonConnection(tmp_path / "explicit.sock").socket_path == tmp_path / "explicit.sock"
