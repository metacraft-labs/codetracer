"""Dataclasses, enums, and standard collections module demonstrations."""

from __future__ import annotations

from collections import Counter, defaultdict, deque, namedtuple
from dataclasses import dataclass, field
from enum import Enum, IntFlag
from types import MappingProxyType


def demo_1_dataclass() -> None:
    """Dataclass with ordering, slots, and default factory for collections."""

    @dataclass(order=True, slots=True)
    class Point:
        x: int
        y: int = 0
        tags: list[str] = field(default_factory=list)

    p1 = Point(1, 2)
    p2 = Point(2, 3, tags=["hotspot"])
    p1.tags.append("visited")
    print("1. dataclass:", p1, p2, p1 < p2, p1.tags)


def demo_2_enums_flags() -> None:
    """Enumerations and IntFlag for bitwise permission sets."""

    class Color(Enum):
        RED = 1
        GREEN = 2

    class Perm(IntFlag):
        READ = 4
        WRITE = 2
        EXEC = 1

    combined = Perm.READ | Perm.WRITE
    print("2. enums:", Color.RED, combined, bool(combined & Perm.WRITE))


def demo_3_namedtuple_deque_dicts() -> None:
    """Common containers from collections with practical use cases."""

    PointNT = namedtuple("PointNT", "x y")
    dq = deque([1, 2], maxlen=3)
    dq.appendleft(0)
    dd = defaultdict(int)
    dd["x"] += 1
    cnt = Counter("mississippi")
    print("3. collections:", PointNT(1, 2), list(dq), dict(dd), cnt.most_common(1))


def demo_4_mapping_proxy() -> None:
    """MappingProxyType creates read-only views over dictionaries."""
    original = {"a": 1}
    proxy = MappingProxyType(original)
    original["b"] = 2
    print("4. mapping-proxy:", dict(proxy))


def demo_5_match_with_class() -> None:
    """Pattern matching utilizing __match_args__ to destructure objects."""

    class Box:
        __match_args__ = ("value",)

        def __init__(self, value):
            self.value = value

    def unbox(x) -> int | None:
        match x:
            case Box(v):
                return v
            case _:
                return None

    print("5. match class:", unbox(Box(10)), unbox("other"))


def run_all() -> None:
    """Execute all collection-focused demonstrations."""
    demo_1_dataclass()
    demo_2_enums_flags()
    demo_3_namedtuple_deque_dicts()
    demo_4_mapping_proxy()
    demo_5_match_with_class()


if __name__ == "__main__":
    run_all()
