from __future__ import annotations

import sys
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from ct import runtime


class RuntimeTests(unittest.TestCase):
    def test_get_executable_path_for_supported_target(self) -> None:
        path = runtime.get_executable_path(target_os="linux", target_arch="amd64")
        self.assertIsInstance(path, Path)
        self.assertTrue(path.name == runtime.BINARY_NAME)

    def test_get_executable_path_for_db_backend_record(self) -> None:
        path = runtime.get_executable_path(
            target_os="linux",
            target_arch="amd64",
            binary_name=runtime.DB_BACKEND_RECORD_BINARY_NAME,
        )
        self.assertIsInstance(path, Path)
        self.assertTrue(path.name == runtime.DB_BACKEND_RECORD_BINARY_NAME)

    def test_get_executable_path_for_ct_remote(self) -> None:
        path = runtime.get_executable_path(
            target_os="linux",
            target_arch="amd64",
            binary_name=runtime.CT_REMOTE_BINARY_NAME,
        )
        self.assertIsInstance(path, Path)
        self.assertTrue(path.name == runtime.CT_REMOTE_BINARY_NAME)

    def test_get_executable_path_raises_for_unsupported_os(self) -> None:
        with self.assertRaises(runtime.BinaryNotFoundError):
            runtime.get_executable_path(target_os="plan9", target_arch="amd64")

    def test_get_executable_path_rejects_invalid_binary_name(self) -> None:
        with self.assertRaises(ValueError):
            runtime.get_executable_path(
                target_os="linux",
                target_arch="amd64",
                binary_name="../evil",
            )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
