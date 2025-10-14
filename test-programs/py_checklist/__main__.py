"""Entry point for the Python checklist test suite.

Running ``python -m test-programs.py_checklist`` executes every module's
``run_all`` function in a stable order. Each module prints numbered lines, so
missing console events are immediately obvious when reviewing traces.

To add a new probe:
1. Create ``<topic>.py`` with numbered ``demo_*`` functions and a ``run_all``.
2. Import ``run_all`` here and append it to ``MODULES``.
3. Ensure any platform-specific code (e.g., multiprocessing) stays guarded by
   ``if __name__ == "__main__"`` inside the module itself.
"""

from __future__ import annotations

from importlib import import_module
from typing import Callable


MODULES: list[tuple[str, Callable[[], None]]] = []

def register(module_name: str) -> None:
    module = import_module(f"test-programs.py_checklist.{module_name}")
    MODULES.append((module_name, module.run_all))


for name in [
    "basics",
    "functions_exceptions",
    "contexts_iterators",
    "async_concurrency",
    "data_model",
    "collections_dataclasses",
    "system_utils",
    "introspection",
    "imports_demo",
    "advanced_runtime",
    "miscellaneous",
]:
    register(name)


def main() -> None:
    for name, runner in MODULES:
        print(f"== Running {name} ==")
        runner()


if __name__ == "__main__":
    main()
