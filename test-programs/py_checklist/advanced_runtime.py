"""Runtime-related probes: logging, warnings, GC, weakrefs, typing."""

from __future__ import annotations

import gc
import logging
import warnings
import weakref
from typing import Generic, Literal, Protocol, TypeAlias, TypedDict, TypeVar, runtime_checkable


def demo_1_logging_warnings() -> None:
    """Configure a module-scoped logger and emit a warning.

    Logging is often customized per subsystem, so we avoid modifying the
    global root logger. Warnings are promoted so that traces capture them.
    """

    logger = logging.getLogger("python_checklist.advanced")
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("LOG:%(levelname)s:%(message)s"))
        logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

    logger.info("1a. logging info message")

    warnings.simplefilter("always", ResourceWarning)
    warnings.warn("1b. sample resource warning", ResourceWarning)

    print("1. logging/warnings: configured")


def demo_2_gc_weakrefs() -> None:
    """Show garbage collection handling cycles and weak references."""

    class Node:
        def __init__(self, name: str) -> None:
            self.name = name
            self.ref: "Node | None" = None

        def __repr__(self) -> str:
            return f"Node({self.name})"

    node_a = Node("A")
    node_b = Node("B")
    node_a.ref = node_b
    node_b.ref = node_a  # create a reference cycle.

    weak_a = weakref.ref(node_a)
    finalizer = weakref.finalize(
        node_b,
        lambda name=node_b.name: print(f"2b. finalize called for Node {name}"),
    )

    del node_a
    del node_b
    collected = gc.collect()
    weak_alive = weak_a() is not None

    print(
        "2. gc/weakref:",
        {"collected": collected, "weak_alive": weak_alive, "finalizer_alive": finalizer.alive},
    )


def demo_3_typing_runtime() -> None:
    """Runtime checks for typing constructs; useful for validation."""

    UserId: TypeAlias = int
    Mode = Literal["r", "w"]

    class User(TypedDict):
        id: UserId
        name: str

    @runtime_checkable
    class Greeter(Protocol):
        def greet(self) -> str:
            ...

    class Impl:
        def greet(self) -> str:
            return "hello"

    T = TypeVar("T")

    class Box(Generic[T]):
        def __init__(self, value: T, mode: Mode = "r") -> None:
            self.value = value
            self.mode = mode

    user: User = {"id": 7, "name": "Ada"}
    greeter_ok = isinstance(Impl(), Greeter)
    boxed = Box(user, mode="w")
    print("3. typing:", user, greeter_ok, boxed.mode)


def run_all() -> None:
    """Execute advanced runtime demonstrations."""
    demo_1_logging_warnings()
    demo_2_gc_weakrefs()
    demo_3_typing_runtime()


if __name__ == "__main__":
    run_all()
