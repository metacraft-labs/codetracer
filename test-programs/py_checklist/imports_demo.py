"""Demonstrate dynamic imports, package layout, and module caching.

Note that the repository uses a hyphen in ``test-programs``. Because
Python identifiers cannot contain ``-``, we adjust ``sys.path`` to load
the local ``pkg`` package by name. This mirrors production systems where
tooling often injects search paths dynamically.
"""

from __future__ import annotations

import importlib
import sys
import types
from pathlib import Path


def demo_1_dynamic_module() -> None:
    """Create a module at runtime and insert it into sys.modules."""
    module = types.ModuleType("dynamic_mod")
    code = "x = 1\ndef value():\n    return x"
    exec(code, module.__dict__)
    sys.modules["dynamic_mod"] = module
    imported = importlib.import_module("dynamic_mod")
    print("1. dynamic module:", imported.value(), id(imported))
    # Inserting into sys.modules is what makes repeated imports return the
    # same module object; tooling often relies on this caching behavior.


def demo_2_importlib_package() -> None:
    """Import the sample package to show relative import behavior."""
    package_root = Path(__file__).resolve().parent
    if str(package_root) not in sys.path:
        sys.path.append(str(package_root))
    package = importlib.import_module("pkg")
    helper = package.helper()
    print("2. package import:", helper, package.__all__)


def demo_3_module_guard() -> None:
    """Illustrate __name__ == '__main__' guarding script entry points."""

    def scriptlike() -> str:
        if __name__ == "__main__":
            return "running as script"
        return "imported module"

    print("3. module guard:", scriptlike())


def run_all() -> None:
    """Execute import-related demonstrations."""
    demo_1_dynamic_module()
    demo_2_importlib_package()
    demo_3_module_guard()


if __name__ == "__main__":
    run_all()
