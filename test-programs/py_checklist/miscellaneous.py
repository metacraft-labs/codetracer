"""Assorted Python features not covered elsewhere."""

from __future__ import annotations


def demo_1_iter_callable() -> None:
    """iter(callable, sentinel) repeatedly calls until the sentinel appears."""

    def counter():
        value = 0

        def next_value():
            nonlocal value
            value += 1
            return value

        return next_value

    iterator = iter(counter(), 3)
    values = list(iterator)
    print("1. iter(callable):", values)


def demo_2_del_statements() -> None:
    """del removes bindings and dictionary entries."""
    x = 1
    del x
    data = {"a": 1}
    del data["a"]
    print("2. del statements:", "a" in data)


class Bag:
    """Simple mapping implementing container protocol."""

    def __init__(self) -> None:
        self._store: dict[str, int] = {}

    def __contains__(self, key: str) -> bool:  # supports "key in bag"
        return key in self._store

    def __getitem__(self, key: str) -> int:  # bag[key]
        return self._store[key]

    def __setitem__(self, key: str, value: int) -> None:  # bag[key] = value
        self._store[key] = value

    def __delitem__(self, key: str) -> None:
        del self._store[key]

    def __len__(self) -> int:
        return len(self._store)


def demo_3_custom_mapping() -> None:
    """Demonstrate mapping protocol hooks used in cache implementations."""
    bag = Bag()
    bag["x"] = 1
    present = "x" in bag
    length = len(bag)
    print("3. custom mapping:", present, bag["x"], length)


class NoSuppress:
    """Context manager that does not suppress exceptions."""

    def __enter__(self) -> "NoSuppress":
        print("4a. enter")
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        print("4b. exit", exc_type)
        return False  # falsy -> exception will propagate


def demo_4_context_no_suppress() -> None:
    """Contexts returning falsy from __exit__ propagate errors."""
    try:
        with NoSuppress():
            raise ValueError("will propagate")
    except ValueError as exc:
        print("4. context no suppress:", exc)


def run_all() -> None:
    demo_1_iter_callable()
    demo_2_del_statements()
    demo_3_custom_mapping()
    demo_4_context_no_suppress()


if __name__ == "__main__":
    run_all()
