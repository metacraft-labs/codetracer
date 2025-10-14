"""Python data model demonstrations and class mechanics."""

from __future__ import annotations

from typing import Any, Optional


def demo_1_repr_str_hash() -> None:
    """Objects can customize printing, formatting, equality, and hashing."""

    class Thing:
        def __init__(self, x: int) -> None:
            self.x = x

        def __repr__(self) -> str:
            return f"Thing({self.x})"

        def __str__(self) -> str:
            return f"<{self.x}>"

        def __format__(self, spec: str) -> str:
            return f"FMT:{self.x:{spec}}"

        def __eq__(self, other: object) -> bool:
            return isinstance(other, Thing) and self.x == other.x

        def __hash__(self) -> int:
            return hash(self.x)

        def __bool__(self) -> bool:
            return bool(self.x)

    t1 = Thing(5)
    t2 = Thing(5)
    print(
        "1. repr/str/hash:",
        repr(t1),
        str(t1),
        format(t1, ">3"),
        t1 == t2,
        {t1, t2},
        bool(t1),
    )


def demo_2_callable_and_ops() -> None:
    """Callable objects with rich operations and in-place modifications."""

    class Vector:
        def __init__(self, *xs: int) -> None:
            self.xs = list(xs)

        def __call__(self) -> int:
            return sum(self.xs)

        def __iter__(self):
            return iter(self.xs)

        def __add__(self, other: "Vector") -> "Vector":
            return Vector(*(a + b for a, b in zip(self.xs, other.xs)))

        def __iadd__(self, other: "Vector") -> "Vector":
            self.xs = [a + b for a, b in zip(self.xs, other.xs)]
            return self

        def __radd__(self, other):
            return sum(other) + sum(self.xs)

        def __matmul__(self, other: "Vector") -> int:
            return sum(a * b for a, b in zip(self.xs, other.xs))

    v1 = Vector(1, 2)
    v2 = Vector(3, 4)
    v3 = v1 + v2
    v1 += v2
    run = v3()
    rhs = [10, 20] + v2  # invokes __radd__
    dot = Vector(1, 2, 3) @ Vector(4, 5, 6)
    print("2. callable+ops:", v3.xs, v1.xs, run, rhs, dot)


def demo_3_properties_slots() -> None:
    """Properties with __slots__ restrict attributes and control access."""

    class P:
        __slots__ = ("_x",)

        def __init__(self) -> None:
            self._x = 0

        @property
        def x(self) -> int:
            return self._x

        @x.setter
        def x(self, value: int) -> None:
            if value < 0:
                raise ValueError("x must be non-negative")
            self._x = value

    p = P()
    p.x = 10
    print("3. properties:", p.x, tuple(p.__slots__))


def demo_4_attribute_hooks() -> None:
    """Instrument attribute access via __getattribute__ and friends."""

    class Probe:
        def __init__(self) -> None:
            super().__setattr__("log", [])

        def __getattribute__(self, name: str) -> Any:
            log = super().__getattribute__("log")
            log.append(("getattribute", name))
            try:
                return super().__getattribute__(name)
            except AttributeError:
                return 42

        def __setattr__(self, name: str, value: Any) -> None:
            self.log.append(("setattr", name, value))
            super().__setattr__(name, value)

        def __delattr__(self, name: str) -> None:
            self.log.append(("delattr", name))
            super().__delattr__(name)

        def __del__(self) -> None:
            print("probe finalized")

    probe = Probe()
    probe.x = 1
    _ = probe.y  # missing attribute returns fallback 42.
    del probe.x
    print("4. attribute-hooks:", probe.log)


def demo_5_descriptors() -> None:
    """Distinguish data vs non-data descriptors."""

    class NonData:
        def __get__(self, obj, owner):
            print("NonData.__get__")
            return 99

    class DataDesc:
        def __set__(self, obj, val):
            print("DataDesc.__set__", val)
            obj.__dict__["d"] = val

        def __get__(self, obj, owner):
            print("DataDesc.__get__")
            return obj.__dict__.get("d", 0)

    class D:
        nd = NonData()
        dd = DataDesc()

    d = D()
    d.dd = 5
    nd_value = d.nd
    dd_value = d.dd
    print("5. descriptors:", nd_value, dd_value)


def demo_6_subclass_hooks_metaclass() -> None:
    """__init_subclass__, metaclasses, and class creation hooks."""

    class Base:
        def __init_subclass__(cls, **kwargs):
            cls.tag = kwargs.get("tag")

    class Child(Base, tag="worker"):
        pass

    class Meta(type):
        @classmethod
        def __prepare__(mcls, name, bases):
            print("Meta.__prepare__", name)
            return {}

        def __new__(mcls, name, bases, namespace):
            print("Meta.__new__", name)
            return super().__new__(mcls, name, bases, namespace)

    class M(metaclass=Meta):
        pass

    print("6. subclass-hooks:", getattr(Child, "tag"), isinstance(M, Meta))


def run_all() -> None:
    """Execute all data model demos."""
    demo_1_repr_str_hash()
    demo_2_callable_and_ops()
    demo_3_properties_slots()
    demo_4_attribute_hooks()
    demo_5_descriptors()
    demo_6_subclass_hooks_metaclass()


if __name__ == "__main__":
    run_all()
