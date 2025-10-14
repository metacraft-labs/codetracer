"""Context manager and iterator protocol demonstrations."""

from __future__ import annotations

from contextlib import contextmanager, suppress
from typing import Generator, Iterable, Iterator, Optional


def demo_1_custom_context() -> None:
    """Custom __enter__/__exit__ implementation with suppression."""

    class TracingContext:
        def __init__(self) -> None:
            self.entered = False

        def __enter__(self) -> "TracingContext":
            self.entered = True
            print("ctx: enter")
            return self

        def __exit__(self, exc_type, exc, tb) -> bool:
            print("ctx: exit", exc_type.__name__ if exc_type else None)
            return True  # suppress the error for demonstration.

    with TracingContext():
        raise RuntimeError("suppressed error")

    print("1. custom-context: finished")


def demo_2_contextlib_helpers() -> None:
    """Use contextlib helpers for generator-based context managers."""

    @contextmanager
    def demo_resource(name: str) -> Iterator[str]:
        print(f"resource {name}: setup")
        try:
            yield f"resource {name}"
        finally:
            print(f"resource {name}: teardown")

    with demo_resource("A"), demo_resource("B") as res:
        print("2. contextlib:", res)


def demo_3_suppress() -> None:
    """Use suppress to absorb expected exceptions (e.g., cache misses)."""
    with suppress(KeyError):
        {}["missing"]
    print("3. suppress: key error ignored")


class CountingIterator:
    """Simple iterator implementing __iter__, __next__, and __reversed__.

    Iterators with explicit state tracking appear in data loaders,
    streaming APIs, and protocol implementations.
    """

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.n = 0

    def __iter__(self) -> "CountingIterator":
        return self

    def __next__(self) -> int:
        if self.n >= self.limit:
            raise StopIteration
        self.n += 1
        return self.n

    def __reversed__(self) -> Iterable[int]:
        return range(self.limit, 0, -1)


def demo_4_iterator_protocol() -> None:
    """Exercise the CountingIterator in forward and reverse directions."""
    iterator = CountingIterator(3)
    forward = list(iterator)
    reverse = list(reversed(CountingIterator(3)))
    print("4. iterator:", forward, reverse)


def generator_demo() -> Generator[str, Optional[int], None]:
    """Generator showcasing yield, send, throw, and close."""
    try:
        value = yield "start"
        yield f"got {value}"
    except ValueError:
        yield "handled error"


def demo_5_generator_behaviors() -> None:
    """Drive generator lifecycle including send/throw/close."""
    gen = generator_demo()
    start = next(gen)
    sent = gen.send(5)
    try:
        thrown = gen.throw(ValueError("boom"))
    except StopIteration:
        thrown = "stop"
    gen.close()

    def outer() -> Iterable[int]:
        yield from range(3)

    collected = list(outer())
    print("5. generators:", start, sent, thrown, collected)


def run_all() -> None:
    """Run all context and iterator demos."""
    demo_1_custom_context()
    demo_2_contextlib_helpers()
    demo_3_suppress()
    demo_4_iterator_protocol()
    demo_5_generator_behaviors()


if __name__ == "__main__":
    run_all()
